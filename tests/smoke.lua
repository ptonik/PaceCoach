-- Smoke test: runs the WHOLE app (PaceCoach.lua and everything it loads)
-- against a strict stand-in for the game, driving synthetic laps through it.
--   luajit tests/smoke.lua
--
-- This proves the app's own code paths run without errors and only use API
-- names from the verified list. It cannot prove the real game behaves the way
-- the stand-in does; only an in-game run can.

local here = (arg and arg[0] or ''):match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/?.lua;' .. here .. '/?.lua;' .. package.path

local config = require('src/config')
local Track = require('src/track')
local Synth = require('synth')
local Fake = require('fake_game')

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print('  ok    ' .. name)
  else
    failed = failed + 1
    print('  FAIL  ' .. name .. '\n' .. tostring(err))
  end
end
local function check(cond, msg) if not cond then error(msg or 'check failed', 2) end end
local function eq(got, want, msg)
  if got ~= want then
    error((msg or 'value') .. ': got ' .. tostring(got) .. ', want ' .. tostring(want), 2)
  end
end
local function near(got, want, tol, msg)
  if type(got) ~= 'number' or math.abs(got - want) > tol then
    error((msg or 'value') .. ': got ' .. tostring(got) .. ', want ' .. tostring(want)
      .. ' +/- ' .. tostring(tol), 2)
  end
end

-- The synthetic world --------------------------------------------------------

local points = Synth.line(Synth.rectangle(), 1000)
local world = Track.build(points, { cfg = config.track, leftSign = 1 })
local DRIVER = { latG = 1.2, brakeG = 1.1, accelG = 0.4, vmaxMs = 70 }
local function drive(extra)
  local o = {}
  for k, v in pairs(DRIVER) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return Synth.drive(world, o)
end
local threeLaps, trueLapMs = drive({ laps = 3 })

local TABS = { 'Track', 'Teacher', 'Laps', 'Mistakes', 'Settings', 'Diagnostics' }
local SIZES = { { 460, 260 }, { 300, 200 }, { 900, 500 }, { 380, 380 } }

-- Starts a fresh session of the app. Returns the app and the fake's state.
local function session(opts)
  opts = opts or {}
  opts.track = opts.track or world
  opts.appDir = root
  Fake.unload()
  local state = Fake.install(opts)
  state.officialLapMs = trueLapMs
  dofile(root .. '/PaceCoach.lua')
  return package.loaded['src/app'], state
end

-- Drives samples through update, the 3D callback and all three windows.
-- each(i, s) may return a table of car fields to override for that frame.
-- others: one list of samples per other car on track.
local function run(app, state, samples, each, others)
  local panel = package.loaded['src/panel']
  if type(each) ~= 'function' then each = nil end   -- drive() also returns the lap time
  for i, s in ipairs(samples) do
    state.frame = i
    local extra = each and each(i, s) or nil
    if extra ~= false then Fake.drive(s, extra) end
    for k, list in ipairs(others or {}) do
      Fake.driveOther(k, list[i] or list[#list])
    end
    script.update(s.dt)
    script.draw3D()
    local size = SIZES[(math.floor(i / 240) % #SIZES) + 1]
    state.window.x, state.window.y = size[1], size[2]
    script.windowMain(s.dt)
    script.windowMap(s.dt)
    state.window.x, state.window.y = 560, 620
    if not state.lockTab then panel.tab = TABS[(math.floor(i / 90) % #TABS) + 1] end
    script.windowPanel(s.dt)
    if app.lastError then error('app error at frame ' .. i .. ': ' .. app.lastError, 2) end
  end
end

local function noErrors(app, state)
  eq(app.lastError, nil, 'app.lastError')
  for _, msg in ipairs(state.logs) do
    check(not msg:lower():find('error'), 'error in log: ' .. msg)
  end
end

local function sawText(state, needle)
  for _, t in ipairs(state.texts) do
    if t:find(needle, 1, true) then return true end
  end
  return false
end

local function clips(state)
  local out = {}
  for i, p in ipairs(state.plays) do out[i] = p.clip end
  return out
end

-- Scenarios ------------------------------------------------------------------

print('whole app against the stand-in game')
local store = {}

test('a normal session: reads the track, calls corners, records and saves laps', function()
  local app, state = session({ store = store })
  local t0 = os.clock()
  run(app, state, threeLaps)
  local msPerFrame = (os.clock() - t0) * 1000 / #threeLaps
  noErrors(app, state)
  eq(app.state, 'ready')
  eq(#app.track.corners, 7, 'corners found')
  eq(app.track.corners[1].dir, 'right')
  eq(app.track.corners[3].dir, 'left')
  eq(app.leftMeasured, true, 'left/right measured from the wheels')
  eq(app.track.leftSign, 1)

  eq(#app.laps, 3, 'laps listed')
  for i, lap in ipairs(app.laps) do eq(lap.valid, true, 'lap ' .. i .. ' valid') end
  check(app.best, 'a best lap should exist')
  near(app.best.timeMs, trueLapMs, 1, 'best lap uses the official time')

  local path = 'C:/Users/me/Documents/Assetto Corsa/PaceCoach/ks_synthetic-rect__test_car.txt'
  check(store[path], 'lap file written to ' .. path)
  check(store['C:/Users/me/Documents/Assetto Corsa/PaceCoach/car__test_car.grip.txt'], 'grip file written')
  check(app.grip.lat[1] > 0.95, 'grip should have been learned: ' .. app.grip.lat[1])

  local played = clips(state)
  eq(played[1], 'hairpin_right', 'first callout')
  local joined = table.concat(played, ' ')
  check(joined:find('hairpin_right brake', 1, true), 'brake should follow the T1 callout: ' .. joined:sub(1, 200))
  check(joined:find('tight_left then_right then_left', 1, true), 'chicane phrase: ' .. joined:sub(1, 300))
  check(joined:find('best_lap', 1, true), 'best lap announced')
  check(sawText(state, 'HAIRPIN RIGHT'), 'card title drawn')
  check(sawText(state, 'BRAKE'), 'brake cue drawn')
  check(sawText(state, 'brake in '), 'brake countdown drawn')
  check(sawText(state, 'All ') and sawText(state, 'checks passed'), 'self-test summary drawn')
  check(sawText(state, 'Best lap'), 'laps tab drawn')
  check(state.calls > 10000, 'drawing happened')
  check(msPerFrame < 2, string.format('too slow: %.2f ms per frame', msPerFrame))
  print(string.format('        %.3f ms per frame for update + three windows', msPerFrame))
end)

test('the next session loads the saved lap and grip, and shows a delta', function()
  local app, state = session({ store = store })
  local seenDelta = false
  run(app, state, drive({ laps = 1.5, scale = 0.95 }), function()
    if app.deltaMs and app.deltaMs > 200 then seenDelta = true end
  end)
  noErrors(app, state)
  check(app.best, 'saved lap should load')
  near(app.best.timeMs, trueLapMs, 1)
  check(seenDelta, 'a slower lap should show a positive delta')
  check(app.grip.lat[1] > 0.95, 'saved grip should load')
end)

test('a mirrored coordinate system still gives the right left and right', function()
  local app, state = session({ mirror = true })
  run(app, state, drive({ laps = 1.2 }))
  noErrors(app, state)
  eq(app.state, 'ready')
  eq(app.track.leftSign, -1, 'handedness detected')
  eq(app.track.corners[1].dir, 'right', 'T1')
  eq(app.track.corners[3].dir, 'left', 'T3')
  eq(clips(state)[1], 'hairpin_right')
end)

test('an old CSP with every optional feature missing still works', function()
  local app, state = session({ remove = {
    'ac.hasTrackSpline', 'ac.getTrackFullID', 'ac.getFolder', 'ac.FolderID', 'ac.storage',
    'ac.AudioEvent', 'ac.onCarJumped', 'ac.onSessionStart', 'ac.log',
    'io.save', 'io.load', 'io.createDir',
    'ui.measureDWriteText', 'ui.drawCircleFilled', 'ui.pathClear', 'ui.pathLineTo', 'ui.pathStroke',
    'ui.textColored', 'ui.button', 'ui.sameLine', 'ui.checkbox', 'ui.slider', 'ui.separator',
    'ui.getCursor', 'ui.offsetCursorY', 'ui.availableSpaceX',
    'car.steer', 'car.gear', 'car.rpm', 'car.velocity', 'car.look', 'car.acceleration',
    'car.wheelsOutside', 'car.isInPitlane', 'car.isInPit', 'car.absInAction',
    'car.previousLapTimeMs', 'car.isLastLapValid', 'car.bestLapTimeMs', 'car.wheels',
    'sim.isPaused', 'sim.isReplayActive', 'sim.carsCount',
  } })
  run(app, state, threeLaps)
  eq(app.lastError, nil)
  eq(app.state, 'ready')
  eq(#app.track.corners, 7)
  eq(app.leftMeasured, false, 'cannot measure without wheel data')
  eq(#app.laps, 3)
  check(app.best, 'laps are still recorded')
  near(app.best.timeMs, trueLapMs, 40, 'falls back to its own timing')
  eq(#state.plays, 0, 'no audio API, no sound')
  check(sawText(state, 'missing'), 'diagnostics list what is missing')
  check(sawText(state, 'HAIRPIN RIGHT'), 'HUD still draws')
end)

test('a track with no ideal line says so and keeps recording laps', function()
  local app, state = session({ noLine = true })
  run(app, state, threeLaps)
  noErrors(app, state)
  eq(app.state, 'noline')
  check(sawText(state, 'no ideal line'), 'HUD explains')
  check(app.best, 'laps still recorded')
  eq(#state.plays, 1, 'only the best-lap call')
end)

test('a line that is not really there is rejected', function()
  local app, state = session({ noLine = true, remove = { 'ac.hasTrackSpline' } })
  run(app, state, drive({ laps = 0.3 }))
  eq(app.lastError, nil)
  eq(app.state, 'noline')
end)

test('a missing essential stops cleanly with an explanation', function()
  local app, state = session({ remove = { 'car.lapCount' } })
  run(app, state, drive({ laps = 0.2 }))
  eq(app.lastError, nil)
  eq(app.state, 'incompatible')
  local sim = package.loaded['src/sim']
  check(sim.fatal and sim.fatal:find('car.lapCount', 1, true), 'names what is missing: ' .. tostring(sim.fatal))
  check(sawText(state, 'missing something'), 'HUD explains')
  check(sawText(state, 'car.lapCount'), 'diagnostics name it')
end)

test('waits quietly while the car does not exist yet', function()
  local app, state = session()
  state.noCar = true
  run(app, state, drive({ laps = 0.05 }))
  eq(app.state, 'init')
  state.noCar = false
  run(app, state, drive({ laps = 0.3 }))
  noErrors(app, state)
  eq(app.state, 'ready')
end)

test('mistakes become tips, and an off-track lap does not count', function()
  local app, state = session()
  local lapStart = {}
  run(app, state, threeLaps, function(i, s)
    if s.lapCount == 1 then
      lapStart[1] = lapStart[1] or i
      local k = i - lapStart[1]
      if k >= 120 and k < 160 then              -- on the first straight
        return { brake = 0.9, gas = 0, slipRatio = { -0.6, -0.6, 0, 0 } }
      end
      if k >= 900 and k < 960 then
        return { wheelsOutside = 4 }
      end
    end
  end)
  noErrors(app, state)
  check((app.mistakeCounts.lockup or 0) >= 1, 'lock-up counted')
  check((app.mistakeCounts.offtrack or 0) >= 1, 'off-track counted')
  check(sawText(state, 'Locked brakes'), 'lock-up tip shown')
  check(sawText(state, 'Off track'), 'off-track tip shown')
  eq(app.laps[1].valid, true)
  eq(app.laps[2].valid, false, 'the lap with four wheels off')
  eq(app.laps[2].reason, 'offtrack')
  eq(app.laps[3].valid, true)
  check(sawText(state, 'does not count'), 'explains the invalid lap')
  check(next(app.cornerMistakes) ~= nil, 'mistakes are tied to corners')
end)

test('pause, teleport to the pits and session restart do no harm', function()
  local app, state = session()
  local frozen
  run(app, state, threeLaps, function(i, s)
    if i >= 600 and i < 700 then               -- paused: the game repeats one frame
      state.sim.isPaused = true
      return false
    end
    state.sim.isPaused = false
    if i == 1500 then
      for _, cb in ipairs(state.jumpCallbacks) do cb(0) end
    end
    if i >= 1500 and i < 1560 then             -- sitting in the pit box
      frozen = frozen or s
      Fake.drive(frozen, { isInPit = true, isInPitlane = true, speedKmh = 0 })
      return false
    end
    if i == 5000 then
      for _, cb in ipairs(state.sessionCallbacks) do cb(0, true) end
    end
  end)
  noErrors(app, state)
  eq(app.state, 'ready')
  check(app.best, 'a clean lap after the interruptions still counts')
  for _, lap in ipairs(app.laps) do
    check(lap.timeMs > 20000, 'no nonsense lap times: ' .. lap.timeMs)
  end
end)

test('a full disk is reported, not fatal', function()
  local app, state = session()
  state.diskFull = true
  run(app, state, drive({ laps = 1.2 }))
  eq(app.lastError, nil)
  check(app.best, 'lap still usable this session')
  check(tostring(app.lastSave):find('could not be saved', 1, true), 'says so: ' .. tostring(app.lastSave))
end)

test('settings work: swap left/right, test the voice, switch off sound', function()
  local app, state = session()
  local panel = package.loaded['src/panel']
  local short = drive({ laps = 0.4 })
  run(app, state, short)
  eq(app.track.corners[1].dir, 'right')
  state.lockTab = true
  panel.tab = 'Settings'
  state.click = 'Swap left and right (only if callouts are mirrored)'
  run(app, state, short)
  eq(state.click, nil, 'checkbox was drawn and clicked')
  eq(app.settings.swapLR, true)
  eq(app.track.corners[1].dir, 'left', 'directions flip after the swap')
  local before = #state.plays
  state.click = 'Test the voice'
  app.settings.voice, app.settings.brakeSound = false, false
  run(app, state, drive({ laps = 0.02 }))
  eq(#state.plays, before + 1, 'exactly the test clip plays')
  eq(state.plays[#state.plays].clip, 'brake')
  run(app, state, short)
  eq(#state.plays, before + 1, 'silent when sound is switched off')
  noErrors(app, state)
end)

-- Stage 2: the teacher ---------------------------------------------------------

local Reference = require('src/reference')
local Recorder = require('src/recorder')
local QUICK = { latG = 1.3, brakeG = 1.2, accelG = 0.45, vmaxMs = 70 }
local SLOW = { latG = 1.0, brakeG = 0.7, accelG = 0.35, vmaxMs = 70 }
local function driveAs(profile, extra)
  local o = {}
  for k, v in pairs(profile) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return Synth.drive(world, o)
end
local quickLaps, quickMs = driveAs(QUICK, { laps = 6 })
local slowLaps = driveAs(SLOW, { laps = 3.3 })
local COMBO = 'C:/Users/me/Documents/Assetto Corsa/PaceCoach/ks_synthetic-rect__test_car'
local teacherStore = {}

print('teacher sessions')
test('an AI opponent in the same car becomes the teacher', function()
  local app, state = session({ store = teacherStore, others = { { model = 'test_car', ai = true } } })
  local markers = package.loaded['src/markers']
  local t1 = world.corners[1]
  local readyAt
  run(app, state, slowLaps, function(i, s)
    if app.benchLabel == 'teacher' then
      readyAt = readyAt or i
      -- Stay off the throttle through T1 once, to provoke the throttle cue.
      local m = s.pos * world.lengthM
      if s.lapCount == 2 and m > t1.apexM - 15 and m < t1.endM + 40 then return { gas = 0 } end
    end
  end, { quickLaps })
  noErrors(app, state)
  check(readyAt, 'the teacher lap should arrive during the session')
  eq(#app.others, 1, 'cars watched')
  check(app.teacherLap, 'teacher lap stored')
  near(app.teacherLap.timeMs, quickMs, 40, 'teacher lap time')
  eq(app.benchLabel, 'teacher')
  check(app.benchPlan and app.cuePlan == app.benchPlan, 'the co-driver uses the teacher')
  eq(app.teacherDerived, false, 'real pedals were available')

  local joined = table.concat(clips(state), ' ')
  check(joined:find('teacher_ready', 1, true), 'announced: ' .. joined:sub(1, 200))
  check(joined:find('throttle', 1, true), 'throttle cue spoken')
  check(sawText(state, 'Teacher lap recorded'), 'toast shown')
  check(sawText(state, 'gear, '), 'gear and speed target on the card')
  check(sawText(state, 'THROTTLE'), 'throttle cue on the card')
  check(sawText(state, 'too early'), 'post-corner feedback shown')
  check(sawText(state, 'Benchmark: teacher'), 'teacher tab drawn')
  check(sawText(state, 'Targets from the benchmark'), 'targets listed')

  for _, k in ipairs({ 1, 2, 6 }) do
    local res = app.cornerResults[k]
    check(res, 'T' .. k .. ' was judged')
    eq(res.id, 'brakeEarly', 'T' .. k)
    check(res.lossMs > 100 and res.value > 10, 'T' .. k .. ' loss and distance')
  end
  check(state.quads > 100, 'the line was drawn on the track: ' .. state.quads)
  eq(markers.status, 'drawing')

  local saved = Reference.decode(teacherStore[COMBO .. '.txt'])
  check(saved and saved.laps.teacher, 'teacher lap saved to disk')
  eq(saved.laps.teacher.source, 'ai')
  check(saved.laps.best, 'your own best lap is saved beside it')
end)

test('the next session has the teacher from the first corner, with no AI on track', function()
  local app, state = session({ store = teacherStore })
  run(app, state, driveAs(SLOW, { laps = 1.3 }))
  noErrors(app, state)
  eq(app.benchLabel, 'teacher')
  near(app.teacherLap.timeMs, quickMs, 40)
  eq(#app.others, 0)
  check(app.cornerResults[1] and app.cornerResults[1].id == 'brakeEarly', 'feedback from the saved teacher')
  check(state.quads > 100, 'line drawn from the saved teacher')
  check(app.benchDeltaMs == nil or app.benchDeltaMs > 0, 'slower than the teacher')
end)

test('an AI whose pedals the game hides still makes a usable teacher', function()
  local app, state = session({ others = { { model = 'test_car' } } })
  local hidden = {}
  for i, s in ipairs(quickLaps) do
    local c = {}
    for k, v in pairs(s) do c[k] = v end
    c.gas, c.brake = 0, 0
    hidden[i] = c
  end
  run(app, state, slowLaps, nil, { hidden })
  noErrors(app, state)
  eq(app.benchLabel, 'teacher')
  eq(app.teacherDerived, true)
  eq(app.teacherLap.pedals, 'derived')
  local tg = app.benchPlan.targets[1]
  check(tg and tg.brakeCell and tg.throttleCell, 'brake and throttle points were worked out')
  check(sawText(state, 'worked out from its speed'), 'the app says so')
  check(app.cornerResults[1], 'feedback still works')
end)

test('cars of another model are not teachers', function()
  local app, state = session({ others = { { model = 'another_car' } } })
  run(app, state, slowLaps, nil, { quickLaps })
  noErrors(app, state)
  eq(#app.others, 0)
  eq(app.teacherLap, nil)
  eq(app.benchLabel, nil)
  check(app.coachPlan, 'feedback falls back to your own best lap')
  eq(state.quads, 0, 'no line without a benchmark')
  check(sawText(state, 'No teacher lap yet'), 'the panel explains how to get one')
end)

test('beating the teacher makes your own best lap the benchmark', function()
  local app, state = session({ others = { { model = 'test_car' } } })
  run(app, state, driveAs(QUICK, { laps = 3.2 }), nil, { (driveAs(SLOW, { laps = 6 })) })
  noErrors(app, state)
  check(app.teacherLap, 'the slow AI still set a lap')
  eq(app.benchLabel, 'you')
  eq(app.benchmark, app.best)
  check(sawText(state, 'You beat the teacher'), 'the app says so')
end)

test('a lap file from a friend is used as the benchmark', function()
  local rec, friendLap = Recorder.new(world.n, config.lap), nil
  for _, s in ipairs(quickLaps) do
    local done = rec:feed(s)
    if done and done.valid then friendLap = done break end
  end
  check(friendLap, 'fixture lap')
  local store2 = {}
  store2[COMBO .. '.teacher.txt'] = Reference.encode({
    track = 'ks_synthetic-rect', car = 'test_car', n = world.n, laps = { best = friendLap } })
  local app, state = session({ store = store2 })
  run(app, state, driveAs(SLOW, { laps = 1.2 }))
  noErrors(app, state)
  eq(app.benchLabel, 'friend')
  check(app.benchPlan, 'targets built from the friend lap')
  check(sawText(state, 'Benchmark: friend'), 'panel shows it')
end)

test('a 3D drawing error switches the line off without breaking anything', function()
  local app, state = session({ store = teacherStore, renderThrows = true })
  local markers = package.loaded['src/markers']
  run(app, state, driveAs(SLOW, { laps = 0.6 }))
  eq(app.lastError, nil)
  eq(markers.disabled, true)
  check(markers.status:find('switched off after an error', 1, true), markers.status)
  check(sawText(state, 'switched off after an error'), 'diagnostics show it')
  -- T2 is the first corner whose whole approach lies inside this part lap.
  check(app.cornerResults[2], 'everything else carries on')
end)

test('no 3D drawing API at all is handled too', function()
  local app, state = session({ store = teacherStore, remove = { 'render' } })
  local markers = package.loaded['src/markers']
  run(app, state, driveAs(SLOW, { laps = 0.6 }))
  noErrors(app, state)
  eq(markers.disabled, true)
  check(markers.status:find('not available', 1, true), markers.status)
end)

test('every clip the app can ask for exists on disk', function()
  local index = dofile(root .. '/sounds/index.lua')
  local want = { 'brake', 'beep', 'best_lap', 'then_left', 'then_right', 'throttle', 'teacher_ready' }
  for _, sev in ipairs({ 'hairpin', 'tight', 'medium', 'fast', 'kink' }) do
    want[#want + 1] = sev .. '_left'
    want[#want + 1] = sev .. '_right'
  end
  for _, name in ipairs(want) do
    check(index[name], 'no length for clip ' .. name)
    local f = Fake.realIo.open(root .. '/sounds/' .. name .. '.wav', 'rb')
    check(f, 'missing file sounds/' .. name .. '.wav')
    f:close()
  end
end)

print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
