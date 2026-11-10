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

local TABS = { 'Coach', 'Track', 'Teacher', 'Laps', 'Mistakes', 'Settings', 'Diagnostics' }
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
    'ac.AudioEvent', 'ac.onCarJumped', 'ac.onSessionStart', 'ac.log', 'ac.unloadApp', 'web',
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
  eq(table.concat(clips(state), ' '):sub(1, 17), 'best_lap streak_3', 'no corner calls: the best lap, then three clean laps in a row')
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
  local judgedAt
  run(app, state, driveAs(SLOW, { laps = 1.3 }), function(_, s)
    if not judgedAt and app.cornerResults[2] then judgedAt = s.pos * world.lengthM end
  end)
  noErrors(app, state)
  local c2 = world.corners[2]
  check(judgedAt, 'T2 was judged')
  check(judgedAt > c2.endM and judgedAt < c2.endM + config.metrics.exitPadM + 15,
    'feedback should come right at the exit: T2 ends at ' .. c2.endM .. ' m, judged at ' .. judgedAt .. ' m')
  check(sawText(state, 'EXIT'), 'the card shows the exit phase')
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
  check(state.quads > 0, 'driving alone, the line and the lead car come from your own limit lap')
  check(sawText(state, 'No teacher lap yet'), 'the panel explains how to get one')
end)

test('beating the teacher moves the coaching on to the limit lap', function()
  local app, state = session({ others = { { model = 'test_car' } } })
  run(app, state, driveAs(QUICK, { laps = 3.2 }), nil, { (driveAs(SLOW, { laps = 6 })) })
  noErrors(app, state)
  check(app.teacherLap, 'the slow AI still set a lap')
  eq(app.benchLabel, 'limit')
  eq(app.benchmark, app.limitLap)
  eq(app.limitLap.source, 'limit')
  check(app.limitLap.timeMs <= app.best.timeMs, 'the limit lap is never slower than the lap it is built on')
  check(app.limitLap.timeMs > app.best.timeMs * 0.9, 'and not absurdly faster: ' .. app.limitLap.timeMs)
  check(app.level and app.level.index >= 5, 'someone ahead of the teacher is high on the ladder: ' .. tostring(app.level and app.level.id))
  check(sawText(state, 'You beat the teacher'), 'the app says so')
  check(sawText(state, 'limit lap'), 'and names the new benchmark')
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

print('when things go wrong at start-up')
test('a drawing call that fails shows the reason instead of an empty window', function()
  local app, state = session()
  rawset(ui, 'dwriteDrawText', function() error('dwrite is broken here') end)
  local samples = drive({ laps = 0.05 })
  for i, s in ipairs(samples) do
    state.frame = i
    Fake.drive(s)
    script.update(s.dt)
    script.windowMain(s.dt)
    script.windowPanel(s.dt)
  end
  check(app.lastError and app.lastError:find('dwrite is broken here', 1, true), tostring(app.lastError))
  check(sawText(state, 'PaceCoach could not draw the HUD'), 'the HUD window explains itself')
  check(sawText(state, 'dwrite is broken here'), 'with the actual error')
end)
test('a module that fails to load is reported in the window, not hidden', function()
  Fake.unload()
  local state = Fake.install({ track = world, appDir = root })
  package.preload['src/app'] = function() error('boom while loading') end
  local okLoad, err = pcall(dofile, root .. '/PaceCoach.lua')
  package.preload['src/app'] = nil
  check(okLoad, 'the entry file itself must not raise: ' .. tostring(err))
  script.update(0.016)
  script.draw3D()
  script.windowMain(0.016)
  check(sawText(state, 'PaceCoach could not start'), 'window shows the failure')
  check(sawText(state, 'boom while loading'), 'with the reason')
  check(#state.logs >= 1 and state.logs[1]:find('could not start', 1, true), 'and it is logged')
end)
test('the folder name GitHub gives a downloaded zip still starts the app', function()
  Fake.unload()
  package.loaded['PaceCoach'] = nil
  local state = Fake.install({ track = world, appDir = root })
  dofile(root .. '/PaceCoach-main.lua')
  package.loaded['PaceCoach'] = nil
  check(type(script.update) == 'function' and type(script.windowMain) == 'function', 'callbacks defined')
  local samples = drive({ laps = 0.1 })
  for i, s in ipairs(samples) do
    state.frame = i
    Fake.drive(s)
    script.update(s.dt)
    script.windowMain(s.dt)
  end
  eq(package.loaded['src/app'].lastError, nil)
  eq(package.loaded['src/app'].state, 'ready')
end)

-- Stage 3: the live coach, the lesson plan, history and updates -----------------

local Story = require('story')
local Updater = require('src/updater')
local S = require('src/strings')
local lessonStore = Story.storeWithTeacher(world)

print('live coach and lesson plan')
test('a learner who does what the coach says gets faster, corner by corner', function()
  local panel
  local app, state, laps = Story.run({
    world = world, store = lessonStore, laps = 8, allWindows = true,
    onFrame = function(_, st)
      panel = panel or package.loaded['src/panel']
      panel.tab = 'Coach'
      st.window.x, st.window.y = 460, 380
    end,
  })
  noErrors(app, state)
  eq(#laps, 8)
  check(laps[8] < laps[1] - 1500, string.format('lap 1 %.2f s, lap 8 %.2f s', laps[1] / 1000, laps[8] / 1000))
  check(#app.lesson.fixed >= 3, 'corners sorted: ' .. #app.lesson.fixed)
  local seen = {}
  for _, done in ipairs(app.lesson.fixed) do
    check(not seen[done.k], 'the same corner is not "sorted" twice in a row')
    seen[done.k] = true
    check(done.toMs < done.fromMs * 0.5, 'T' .. done.k .. ' really improved')
  end

  for _, text in ipairs({ 'TOO EARLY', 'EASE OFF', 'TURN IN', 'FULL THROTTLE', 'MOVE RIGHT', 'FOCUS',
      'vs teacher', 'Sorted. Well done.', 'That is it.', 'Brake about 25 m later.', 'Next lap, ',
      'Coaching against the teacher', 'Training steps', 'Where the time goes', 'Skills, against the teacher',
      'Ideal lap', 'Said while you drove', 'This is the first one.',
      ' speed: white you, blue teacher', '- Come off the brake a little sooner' }) do
    check(sawText(state, text), 'never shown: ' .. text)
  end
  local played = {}
  for _, p in ipairs(state.plays) do played[p.clip] = (played[p.clip] or 0) + 1 end
  for _, clip in ipairs({ 'too_early', 'ease_off', 'turn_in', 'full_throttle', 'fixed', 'thats_it',
      'tip_brake_later', 'tip_more_speed', 'best_lap' }) do
    check(played[clip], 'never spoken: ' .. clip)
  end
  -- The co-driver must never stutter: no two "brake" calls within a second.
  local lastBrake
  for _, p in ipairs(state.plays) do
    if p.clip == 'brake' then
      check(not lastBrake or p.frame - lastBrake > 60, 'two "brake" calls ' .. (p.frame - (lastBrake or 0)) .. ' frames apart')
      lastBrake = p.frame
    end
  end
  check((played.brake or 0) <= 8 * #world.corners, 'brake calls: ' .. tostring(played.brake))

  local skills = app.lesson:skills()
  check(skills.braking and skills.braking >= 80, 'braking score after eight laps: ' .. tostring(skills.braking))
  check(app.lesson:ideal(), 'ideal lap known')
  check(app.lesson:ideal() <= app.best.timeMs + 1, 'the ideal lap is never slower than the best lap')
  local history = Reference.decodeHistory(lessonStore[COMBO .. '.history.txt'])
  eq(#history, 1, 'one line for this session')
  eq(history[1].laps, #app.laps)
  near(history[1].best, app.best.timeMs, 1)
  check(history[1].bench and history[1].braking, 'benchmark time and skills are kept')
end)

test('past the teacher: the learner keeps finding time against the limit lap', function()
  local carMs = Story.carLimitMs(world)
  local teacherMs, beatenAt, sawPush, lastLimit, limitFell = nil, nil, false, nil, 0
  local app, state, laps = Story.run({
    world = world, laps = 45,
    onLap = function(a, _, lapNumber, lapMs)
      teacherMs = teacherMs or (a.teacherLap and a.teacherLap.timeMs)
      if not beatenAt and a.coachLabel == 'limit' then beatenAt = lapNumber end
      local f = a.lesson.focus
      if f and f.id == 'push' then sawPush = true end
      if a.limitLap then
        if lastLimit and a.limitLap.timeMs < lastLimit - 20 then limitFell = limitFell + 1 end
        lastLimit = a.limitLap.timeMs
        check(a.limitLap.timeMs <= a.best.timeMs + 1, 'the limit lap is never slower than the best lap')
      end
    end,
  })
  noErrors(app, state)
  check(beatenAt and beatenAt < 20, 'the teacher is beaten: lap ' .. tostring(beatenAt))
  check(sawPush, 'the coach sent the learner looking for the limit')
  check(limitFell >= 5, 'the limit lap moved as grip was found: ' .. limitFell .. ' times')
  check(app.best.timeMs < teacherMs - 1000, string.format('more than a second ahead of the teacher: %.2f s', (teacherMs - app.best.timeMs) / 1000))
  check(app.best.timeMs < carMs * 1.006, string.format('within 0.6%% of what the car can really do: %.2f%%', app.best.timeMs / carMs * 100))
  check(app.best.timeMs >= carMs - 1, 'and not faster than the car can go')
  check(laps[1] > carMs * 1.09, 'having started more than 9% off')
  eq(app.level.id, 'limit')
  check(app.licence.index >= 5, 'pace plus forty-odd clean laps in the window: an endurance licence, got ' .. app.licence.id)
  check(app.stint.bestStreak >= 20, 'a full stint in the window: ' .. app.stint.bestStreak)
  check(sawText(state, 'Licence: '), 'licences are announced')
  check(sawText(state, 'Level up: '), 'level-ups are announced')
  check(sawText(state, 'Find the limit here'), 'the push instruction was shown')
  local joined = table.concat(clips(state), ' ')
  check(joined:find('level_up', 1, true) and joined:find('tip_push', 1, true), 'and spoken')
  check(joined:find('streak_10', 1, true) and joined:find('licence_up', 1, true), 'stint marks and licences too')
  print(string.format('        lap 1 %.2f s, teacher %.2f s, lap 45 %.2f s, the car itself %.2f s',
    laps[1] / 1000, teacherMs / 1000, app.best.timeMs / 1000, carMs / 1000))
end)

test('the next session remembers the last one and starts a new line', function()
  local app, state = session({ store = lessonStore })
  local panel = package.loaded['src/panel']
  state.lockTab = true
  panel.tab = 'Coach'
  run(app, state, driveAs(SLOW, { laps = 1.2 }))
  noErrors(app, state)
  eq(#app.history, 2)
  check(sawText(state, 'Session 1'), 'the earlier session is listed')
  check(sawText(state, 'laps, '), 'with its lap count')
  eq(#Reference.decodeHistory(lessonStore[COMBO .. '.history.txt']), 2)
end)

test('driving alone: the coach works against the limit lap built on your own best', function()
  local soloStore = {}
  local app, state = session({ store = soloStore })
  local panel = package.loaded['src/panel']
  state.lockTab = true
  panel.tab = 'Coach'
  run(app, state, driveAs(SLOW, { laps = 3.3 }))
  noErrors(app, state)
  eq(app.benchLabel, nil, 'no teacher, so the brake cue stays with the cautious estimate')
  eq(app.cuePlan, app.plan)
  eq(app.coachLabel, 'limit')
  eq(app.coachPlan.lap.source, 'limit')
  check(app.coachPlan.lap.timeMs <= app.best.timeMs, 'never slower than your own best')
  check(app.gauge and app.gauge.active, 'the live comparison runs')
  eq(app.level, nil, 'no pace level without somebody else to measure against')
  check(sawText(state, 'Coaching against the limit lap'), 'the panel says what it compares with')
  local report = soloStore[COMBO .. '.report.txt']
  check(report, 'a session report is written')
  check(report:find('PaceCoach session report', 1, true) and report:find('Laps: 3, 3 clean', 1, true), report)
  check(report:find('Self-test: everything', 1, true), report)
  check(sawText(state, '.report.txt'), 'and the panel says where it is')
end)

test('without any benchmark the coach explains how to get one', function()
  local app, state = session()
  local panel = package.loaded['src/panel']
  state.lockTab = true
  panel.tab = 'Coach'
  run(app, state, drive({ laps = 0.4 }))
  noErrors(app, state)
  check(sawText(state, 'No lesson plan yet.'), 'says so')
  eq(app.gauge, nil, 'no live comparison without a lap to compare with')
end)

test('live coaching can be switched off, piece by piece', function()
  local app, state = session({ store = lessonStore })
  local quietAfter
  run(app, state, driveAs(SLOW, { laps = 2.2 }), function(i, s)
    if s.lapCount >= 1 and not quietAfter then
      quietAfter = #state.plays
      app.settings.liveCoach, app.settings.lessons, app.settings.praise = false, false, false
    end
  end)
  noErrors(app, state)
  check(quietAfter and quietAfter > 0)
  local live = {}
  for _, def in pairs(S.live) do live[def.clip] = true end
  for _, def in pairs(S.remedy) do live[def.clip] = true end
  local before = 0
  for i, p in ipairs(state.plays) do
    if live[p.clip] then
      if i <= quietAfter then before = before + 1 else error('spoke "' .. p.clip .. '" after being switched off') end
    end
  end
  check(before > 0, 'it did speak while it was on')
  check(app.gauge and app.gauge.active, 'the speed bar keeps working')
end)

test('a session can be replayed from the files the app writes, in either handedness', function()
  local Real = dofile(root .. '/tools/real_laps.lua')
  for _, mirror in ipairs({ false, true }) do
    local files = Story.storeWithTeacher(world)
    if mirror then
      -- In a mirrored game the saved teacher lap is in mirrored coordinates too.
      local saved = Reference.decode(files[COMBO .. '.txt'])
      for i = 1, saved.n do saved.laps.teacher.x[i] = -saved.laps.teacher.x[i] end
      saved.track, saved.car = 'ks_synthetic-rect', 'test_car'
      files[COMBO .. '.txt'] = Reference.encode(saved)
    end
    local app, state, laps = Story.run({ world = world, store = files, laps = 4, fake = { mirror = mirror } })
    noErrors(app, state)
    eq(app.track.leftSign, mirror and -1 or 1)
    local sessionText = files[COMBO .. '.session.txt']
    check(sessionText, 'the session log is written')
    local logged = Reference.decode(sessionText)
    eq(logged.left, mirror and -1 or 1, 'the log remembers which way left is')
    local count = 0
    for _ in pairs(logged.laps) do count = count + 1 end
    eq(count, 4)

    local real = assert(Real.load(sessionText, files[COMBO .. '.txt']))
    eq(#real.laps, 4)
    near(real.teacherMs, app.teacherLap.timeMs, 1)
    local again, state2, laps2 = Story.run({ world = real.world, store = real.store, samples = real.samples, fake = real.fake })
    noErrors(again, state2)
    eq(#laps2, 4, 'every lap is seen again')
    for i = 1, 4 do near(laps2[i], laps[i], 80, 'lap ' .. i .. ' time') end
    eq(again.benchLabel, 'teacher')
    eq(#again.track.corners, 7, 'the track is rebuilt from the teacher lap')
    eq(again.track.corners[1].dir, 'right', 'left and right survive the round trip')
    eq(again.track.corners[3].dir, 'left')
    check(again.cornerResults[2] and again.cornerResults[2].id == app.cornerResults[2].id,
      'the coach says the same about turn 2: ' .. tostring(again.cornerResults[2] and again.cornerResults[2].id))
    check(sawText(state2, 'EASE OFF'), 'live cues fire on the replayed laps')
  end
  eq(Real.load('nonsense'), nil)
end)

test('the session log keeps only the newest laps, and can be switched off', function()
  local files = Story.storeWithTeacher(world)
  local app = Story.run({ world = world, store = files, laps = 8, windows = false })
  local logged = Reference.decode(files[COMBO .. '.session.txt'])
  local names = {}
  for name in pairs(logged.laps) do names[#names + 1] = name end
  table.sort(names)
  eq(#names, config.lap.logKeep)
  eq(names[#names], 'lap008')
  local quiet = {}
  local app2, state2 = session({ store = quiet })
  app2.settings.sessionLog = false
  run(app2, state2, drive({ laps = 1.3 }), function() app2.settings.sessionLog = false end)
  eq(quiet[COMBO .. '.session.txt'], nil)
end)

print('the first minutes, as seen on a real screen')
test('line, brake points and corner strip are there from the first corner, estimated', function()
  local app, state = session()
  local markers = package.loaded['src/markers']
  local panel = package.loaded['src/panel']
  state.lockTab = true
  panel.tab = 'Coach'
  local quadsEarly
  run(app, state, drive({ laps = 0.6 }), function(i)
    if i == 600 then quadsEarly = state.quads end
  end)
  noErrors(app, state)
  eq(app.coachLabel, 'estimate')
  eq(app.judged, false, 'an estimate is not something to be judged against')
  check(quadsEarly and quadsEarly > 100, 'the line is on the track within ten seconds: ' .. tostring(quadsEarly))
  check(markers.cones > 0, 'cones are out')
  check(sawText(state, 'Estimated line and brake points.'), 'the HUD says what it is showing and how to get more')
  check(sawText(state, 'about ') and sawText(state, '(est.)'), 'the corner strip is labelled as an estimate')
  check(sawText(state, 'How to get more out of the coach'), 'the panel lists the steps')
  check(sawText(state, 'Too small? Drag the corner'), 'and the HUD says it can be made bigger')
  eq(next(app.cornerResults), nil, 'nobody is judged against an estimate')
  local live = {}
  for _, def in pairs(S.live) do live[def.clip] = true end
  for _, p in ipairs(state.plays) do check(not live[p.clip], 'no live coaching from an estimate: ' .. p.clip) end
end)

test('a beginner who runs off every lap still gets a coach', function()
  local files = {}
  local app, state = session({ store = files })
  state.lockTab = true
  package.loaded['src/panel'].tab = 'Coach'      -- the Mistakes tab keeps the full explanations
  local lapFrame = {}
  run(app, state, driveAs(SLOW, { laps = 3.3 }), function(i, s)
    lapFrame[s.lapCount] = lapFrame[s.lapCount] or i
    local k = i - lapFrame[s.lapCount]
    if k >= 1500 and k < 1560 then return { wheelsOutside = 4 } end   -- four wheels off, once a lap
  end)
  noErrors(app, state)
  eq(app.best, nil, 'no lap counted')
  for _, lap in ipairs(app.laps) do eq(lap.valid, false) end
  check(app.roughLap, 'but the fastest of them is kept to work from')
  eq(app.coachLabel, 'limit')
  eq(app.judged, true)
  check(next(app.cornerResults) ~= nil, 'corners are judged from the second lap on')
  check(app.gauge and app.gauge.active, 'and the live comparison runs')
  check(sawText(state, 'Coaching from your last lap.'), 'the HUD says what it is working from')
  check(sawText(state, 'all the same.'), 'and the lap note says so too (it wraps over two lines)')
  check(sawText(state, 'Brake earlier here next lap.'), 'tips on the HUD are one short line')
  check(not sawText(state, 'Nearly always caused by arriving too fast'), 'not a paragraph')
  eq(files[COMBO .. '.txt'], nil, 'a lap that does not count is never saved as your best')
  -- The first clean lap takes over.
  run(app, state, driveAs(SLOW, { laps = 1.3 }))
  check(app.best, 'a clean lap counts')
  eq(app.roughLap, nil)
end)

print('in the passenger seat')
test('corner repeat: the focus corner again and again without driving the lap', function()
  local files = Story.storeWithTeacher(world)
  Fake.unload()
  local state = Fake.install({ track = world, appDir = root, store = files })
  dofile(root .. '/PaceCoach.lua')
  local app = package.loaded['src/app']
  local markers = package.loaded['src/markers']
  local base = Story.LEARNER
  local flaws = { [2] = { lat = 0.7 } }                 -- one weakness: far too slow through turn 2
  local plan = Synth.plan(world, base, flaws)
  local st, snaps = {}, {}
  local function copy(t) local c = {} for key, v in pairs(t) do c[key] = v end return c end
  local loadsSeen, lapsAtStart, passesAtStart, sawGhost, sawCones, sawBoard = 0, nil, nil, false, 0, false
  local frame = 0
  local function drive(frames, each)
    for _ = 1, frames do
      frame = frame + 1
      state.frame = frame
      local s = Synth.step(world, plan, st)
      snaps[frame] = copy(st)
      Fake.drive(s)
      script.update(s.dt)
      script.draw3D()
      script.windowMain(s.dt)
      if app.lastError then error('app error at frame ' .. frame .. ': ' .. app.lastError) end
      sawGhost = sawGhost or markers.ghostShown
      sawCones = math.max(sawCones, markers.cones)
      if #state.loads > loadsSeen then
        -- The game put the car back: so does the simulation, and the learner
        -- does a little better each time.
        loadsSeen = #state.loads
        st = copy(snaps[state.loads[loadsSeen]])
        flaws[2].lat = math.min(1, flaws[2].lat + 0.12)
        plan = Synth.plan(world, base, flaws)
        st.plan, st.blend = plan, 1
      end
      if each then each(s) end
    end
  end
  -- A lap and a bit, so the coach has a focus corner.
  drive(60 * 75)
  check(app.lesson.focus and app.lesson.focus.k == 2, 'turn 2 is the focus')
  eq(#state.loads, 0, 'nothing happens until it is switched on')
  app.settings.repeatCorner = true
  lapsAtStart, passesAtStart = app.lapNumber, app.lesson.corners[2].count
  drive(60 * 90, function() if app.lesson.focus == nil or app.lesson.focus.k ~= 2 then sawBoard = true end end)
  noErrors(app, state)
  check(#state.loads >= 3, 'the car was put back several times: ' .. #state.loads)
  local passes = app.lesson.corners[2].count - passesAtStart
  check(passes >= 3, 'each attempt was judged: ' .. passes)
  check(app.lapNumber - lapsAtStart <= 1, 'without driving laps in between: ' .. (app.lapNumber - lapsAtStart))
  check(sawText(state, 'Try 2:'), 'attempts are numbered on the HUD')
  check(sawText(state, 'Corner repeat: T2'), 'and the start is announced')
  check(#app.lesson.fixed >= 1 and app.lesson.fixed[1].k == 2, 'turn 2 gets sorted by repetition')
  check(sawText(state, 'T2 sorted'), 'and the coach says so')
  check(sawGhost, 'the lead car was on the track')
  check(sawCones >= 3, 'cones were out: ' .. sawCones)
  check(sawText(state, 'target ') and sawText(state, 'apex '), 'the corner strip showed the target and the result')
  check(app.lesson:brakeTargetM(2) ~= nil, 'a personal brake marker exists for turn 2')
end)

test('corner repeat says so where the game does not allow it, and has a button', function()
  local app, state = session({ store = Story.storeWithTeacher(world) })
  state.resetAllowed = false
  run(app, state, driveAs(SLOW, { laps = 1.2 }), function()
    if app.lesson and app.lesson.focus then app.settings.repeatCorner = true end
  end)
  -- the setting is refused each time it is switched on
  check(sawText(state, 'only works in an offline practice session'), 'explained on the HUD')
  eq(#state.loads, 0)
  eq(app.lastError, nil)
  -- The bound button toggles it.
  local app2, state2 = session({ store = Story.storeWithTeacher(world) })
  local laps = driveAs(SLOW, { laps = 1.3 })
  run(app2, state2, laps)
  eq(app2.settings.repeatCorner, false)
  state2.buttons['__APP_PACECOACH_REPEAT'] = true
  run(app2, state2, driveAs(SLOW, { laps = 0.02, startPos = 0.3 }), function() return nil end)
  eq(app2.settings.repeatCorner, true, 'one press switches it on')
  state2.buttons['__APP_PACECOACH_REPEAT'] = false
  run(app2, state2, driveAs(SLOW, { laps = 0.01, startPos = 0.32 }))
  eq(app2.settings.repeatCorner, true, 'and it stays on when the button is released')
end)

print('racing')
test('the spotter calls a car alongside, and the coach stays out of a fight', function()
  local app, state = session({ store = Story.storeWithTeacher(world), others = { { model = 'another_car' } } })
  local c2 = world.corners[2]
  local lap = driveAs(SLOW, { laps = 2.2 })
  local sawEdge, quietInTraffic = false, true
  local livePlays = {}
  for _, def in pairs(S.live) do livePlays[def.clip] = true end
  for i, s in ipairs(lap) do
    state.frame = i
    Fake.drive(s)
    local m = s.pos * world.lengthM
    -- On the second lap another car sits alongside on the left from before
    -- turn 2 until after it; otherwise it is half a lap away.
    local beside = s.lapCount == 1 and m > c2.startM - 250 and m < c2.endM + 30
    if beside then
      Fake.driveOther(1, s, { offLeftM = 2.6 })
    else
      local far = {}
      for k, v in pairs(s) do far[k] = v end
      far.pos = (s.pos + 0.5) % 1
      Fake.driveOther(1, far)
    end
    local before = #state.plays
    script.update(s.dt)
    script.windowMain(s.dt)
    if app.lastError then error(app.lastError) end
    if beside and app.spot and app.spot.left then
      sawEdge = true
      for j = before + 1, #state.plays do
        if livePlays[state.plays[j].clip] then quietInTraffic = false end
      end
    end
  end
  noErrors(app, state)
  local joined = table.concat(clips(state), ' ')
  check(joined:find('car_left', 1, true), 'called: ' .. joined:sub(1, 300))
  check(not joined:find('car_right', 1, true), 'on the correct side')
  check(joined:find('clear', 1, true), 'and cleared')
  check(sawEdge, 'the spotter state reached the HUD')
  check(quietInTraffic, 'no live coaching while a car is alongside')
  check(app.cornerResults[2] and app.cornerResults[2].traffic, 'turn 2 in traffic is not held against the driver')
  eq(app.lesson.corners[2].count, 1, 'only the clear pass through turn 2 counts for the lesson plan')
end)

test('the spotter gets left and right the right way round in a mirrored game too', function()
  local app, state = session({ mirror = true, others = { { model = 'another_car' } } })
  for i, s in ipairs(drive({ laps = 0.3 })) do
    state.frame = i
    Fake.drive(s)
    Fake.driveOther(1, s, { offLeftM = (i > 300 and i < 500) and -2.6 or 60 })
    script.update(s.dt)
  end
  noErrors(app, state)
  local joined = table.concat(clips(state), ' ')
  check(joined:find('car_right', 1, true) and not joined:find('car_left', 1, true), joined)
end)

print('shared laps')
test('a fast lap shared through the repository becomes the benchmark and raises the limit', function()
  -- Someone quick has shared their lap file for this car and track.
  local rec, fast = Recorder.new(world.n, config.lap), nil
  for _, s in ipairs((driveAs({ latG = 1.45, brakeG = 1.35, accelG = 0.45, vmaxMs = 70 }, { laps = 2.2 }))) do
    local done = rec:feed(s)
    if done and done.valid then fast = done break end
  end
  local url = config.update.base .. config.update.laps .. 'ks_synthetic-rect__test_car.txt'
  local files = Story.storeWithTeacher(world)
  local app, state = session({ store = files, web = { [url] = Reference.encode({
    track = 'ks_synthetic-rect', car = 'test_car', n = world.n, laps = { best = fast } }) } })
  local before
  run(app, state, driveAs(SLOW, { laps = 1.3 }), function()
    if app.limitLap and not app.sharedLap then before = app.limitLap.timeMs end
  end)
  noErrors(app, state)
  check(app.sharedLap, 'the shared lap arrived')
  eq(app.benchLabel, 'shared')
  near(app.benchmark.timeMs, fast.timeMs, 1)
  check(sawText(state, 'Shared lap downloaded'), 'a note says so')
  check(files[COMBO .. '.shared.txt'], 'and it is kept for next time')
  check(app.limitLap.timeMs < app.teacherLap.timeMs - 500, 'the limit lap now reflects grip the teacher never showed')

  -- Offline next time: it is still there.
  local later, state3 = session({ store = files })
  state3.offline = true
  run(later, state3, driveAs(SLOW, { laps = 0.3 }))
  eq(later.benchLabel, 'shared')

  -- A file for another track layout is ignored.
  local wrong, state4 = session({ web = { [url] = Reference.encode({
    track = 'x', car = 'y', n = world.n + 7, laps = {} }) } })
  run(wrong, state4, driveAs(SLOW, { laps = 0.3 }))
  noErrors(wrong, state4)
  eq(wrong.sharedLap, nil)
end)

print('updates')
local function site(version)
  local base = config.update.base
  local files = {
    { path = 'PaceCoach.lua', data = '-- entry ' .. version },
    { path = 'src/config.lua', data = '-- config ' .. version },
    { path = 'sounds/new_clip.wav', data = string.rep('\0\7\255', 300) },
  }
  local web = { [base .. config.update.manifest] = Updater.encode(version, 'test', files) }
  for _, f in ipairs(files) do web[base .. f.path] = f.data end
  return web
end
local function fetched(state)                  -- requests other than the shared-lap lookup
  local count = 0
  for _, url in ipairs(state.requests) do
    if not url:find('/laps/', 1, true) then count = count + 1 end
  end
  return count
end
local function idle(app, state, seconds, extra)
  local s = threeLaps[1]
  for i = 1, math.floor(seconds * 60) do
    state.frame = (state.frame or 0) + 1
    Fake.drive(s, extra or { speedKmh = 0, isInPit = true })
    script.update(1 / 60)
    script.windowMain(1 / 60)
    script.windowPanel(1 / 60)
    if app.lastError then error('app error: ' .. app.lastError, 2) end
  end
end

test('a newer version on GitHub is fetched and installed by itself', function()
  local app, state = session({ web = site('9.9.9') })
  idle(app, state, 4)
  eq(#state.requests, 0, 'it leaves the first seconds alone')
  idle(app, state, 3)
  eq(app.updater.state, 'done')
  eq(state.store[root .. '/PaceCoach.lua'], '-- entry 9.9.9')
  eq(state.store[root .. '/src/config.lua'], '-- config 9.9.9')
  eq(#state.store[root .. '/sounds/new_clip.wav'], 900)
  eq(fetched(state), 4, 'the list and three files')
  check(sawText(state, 'PaceCoach 9.9.9 installed'), 'and says so')
  noErrors(app, state)
end)

test('at speed the update waits until the car stands still', function()
  local app, state = session({ web = site('9.9.9') })
  run(app, state, drive({ laps = 0.5 }))
  eq(app.updater.state, 'ready', 'downloaded while driving')
  eq(state.store[root .. '/PaceCoach.lua'], nil, 'but not written at speed')
  idle(app, state, 0.2)
  eq(app.updater.state, 'done')
  eq(state.store[root .. '/PaceCoach.lua'], '-- entry 9.9.9')
end)

test('with automatic installing switched off it asks first', function()
  local app, state = session({ web = site('9.9.9') })
  local panel = package.loaded['src/panel']
  idle(app, state, 1)
  app.settings.autoInstall = false
  panel.tab = 'Settings'
  idle(app, state, 6)
  eq(app.updater.state, 'available')
  check(sawText(state, 'PaceCoach 9.9.9 is available'), 'a note appears')
  check(sawText(state, 'Version 9.9.9 is available.'), 'and the Settings tab shows it')
  eq(state.store[root .. '/PaceCoach.lua'], nil)
  state.click = 'Update now'
  idle(app, state, 1)
  eq(state.click, nil, 'the button was there')
  eq(app.updater.state, 'done')
  state.click = 'Reload PaceCoach now'
  idle(app, state, 0.1)
  eq(state.unloaded, 1, 'the app asks CSP to unload it')
end)

test('nothing new, no connection, or no download support: all quiet', function()
  local app, state = session({ web = site(config.version) })
  idle(app, state, 7)
  eq(app.updater.state, 'current')
  eq(fetched(state), 1)
  noErrors(app, state)

  app, state = session({ web = site('9.9.9') })
  state.offline = true
  idle(app, state, 7)
  eq(app.updater.state, 'failed')
  eq(app.lastError, nil)
  check(sawText(state, 'could not reach GitHub') == false, 'not shouted on the HUD')

  app, state = session({ web = site('9.9.9') })
  idle(app, state, 1)
  app.settings.autoCheck, app.settings.sharedLaps = false, false
  idle(app, state, 7)
  eq(#state.requests, 0, 'switched off means no request at all')

  app, state = session({ web = site('9.9.9'), remove = { 'web' } })
  package.loaded['src/panel'].tab = 'Settings'
  idle(app, state, 7)
  eq(app.updater.state, 'idle')
  check(sawText(state, 'cannot download files'), 'the Settings tab explains')
  eq(app.lastError, nil)
end)

test('the update list in the repository matches the files on disk', function()
  local make = dofile(root .. '/tools/make_update.lua')
  local notes, onDisk = make.currentNotes()
  check(onDisk, 'update.txt is missing: run  luajit tools/make_update.lua "what is new"')
  local fresh = make.build(notes)
  check(fresh == onDisk, 'update.txt is out of date: run  luajit tools/make_update.lua')
  local list = Updater.parse(onDisk, config.update)
  check(list, 'the list must be acceptable to the updater itself')
  eq(list.version, config.version)
  local manifest = Fake.realIo.open(root .. '/manifest.ini'):read('*a')
  eq(manifest:match('VERSION = ([%d.]+)'), config.version, 'manifest.ini and config.lua agree on the version')
end)

test('every clip the app can ask for exists on disk', function()
  local index = dofile(root .. '/sounds/index.lua')
  local want = { 'brake', 'beep', 'best_lap', 'then_left', 'then_right', 'throttle', 'teacher_ready',
    'good', 'nice', 'better', 'thats_it', 'fixed', 'level_up' }
  for _, def in pairs(S.live) do want[#want + 1] = def.clip end
  for _, def in pairs(S.remedy) do want[#want + 1] = def.clip end
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
