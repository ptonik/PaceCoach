-- Plays a whole coaching session against the stand-in game and prints what
-- the coach said and showed, moment by moment.
--   luajit tests/story.lua [laps]
--
-- The driver is a simulated learner with a different weakness in every
-- corner. After each lap the learner does what the coach asked for in the
-- focus corner, and nothing else, so the printout shows the lesson plan at
-- work: one corner at a time until the lap is clean.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/?.lua;' .. here .. '/?.lua;' .. package.path

local config = require('src/config')
local Track = require('src/track')
local Recorder = require('src/recorder')
local Reference = require('src/reference')
local Synth = require('synth')
local Fake = require('fake_game')
local Story = {}

Story.QUICK = { latG = 1.3, brakeG = 1.2, accelG = 0.45, vmaxMs = 70 }
Story.LEARNER = { latG = 1.3, brakeG = 1.2, accelG = 0.45, vmaxMs = 70 }

-- The learner's weaknesses at the start of the session.
function Story.flaws()
  return {
    [1] = { brake = 0.6 },                    -- brakes far too early for the hairpin
    [2] = { lat = 0.72, lift = true },        -- lifts on the straight, then too slow at the apex
    [3] = { off = 3.5 },                      -- wrong side of the road going in
    [4] = {},
    [5] = {},
    [6] = { coastM = 45 },                    -- late back on the throttle
    [7] = { brake = 0.75, lat = 0.85 },
  }
end

-- The car can do more than the teacher asks of it: this much more cornering
-- grip (as a factor) and this much braking, in g.
Story.CAR = { lat = 1.09, brakeG = 1.32 }

-- What the learner changes when the coach names a corner: the weakness in
-- that corner shrinks by two thirds. When the coach says "find the limit",
-- or is already working against the limit lap, the learner uses a little
-- more of the car there instead.
function Story.improve(flaws, k, base, mode)
  local f = flaws[k]
  if mode then
    f = f or {}
    flaws[k] = f
    local step = (mode == 'push') and 0.4 or 0.67
    local lat, brake = f.lat or 1, f.brake or base.brakeG
    f.lat = lat + (Story.CAR.lat - lat) * step
    f.brake = brake + (Story.CAR.brakeG - brake) * step
    f.coastM, f.off, f.earlyGas, f.lift = nil, nil, nil, nil
    return
  end
  if not f then return end
  if f.brake then
    f.brake = f.brake + (base.brakeG - f.brake) * 0.67
    if base.brakeG - f.brake < 0.04 then f.brake = nil end
  end
  if f.lat then
    f.lat = f.lat + (1 - f.lat) * 0.67
    if 1 - f.lat < 0.02 then f.lat = nil end
  end
  if f.coastM then
    f.coastM = f.coastM * 0.33
    if f.coastM < 5 then f.coastM = nil end
  end
  if f.off then
    f.off = f.off * 0.33
    if math.abs(f.off) < 0.6 then f.off = nil end
  end
  f.earlyGas, f.lift = nil, nil
end

-- The lap this car can really do: every corner at the car's own limit. The
-- app cannot know this number; the simulation does, which is what makes it
-- a fair yardstick for how far the coaching gets.
function Story.carLimitMs(world, base)
  local flaws = {}
  for k = 1, #world.corners do flaws[k] = { lat = Story.CAR.lat, brake = Story.CAR.brakeG } end
  local st = {}
  Synth.lap(world, Synth.plan(world, base or Story.LEARNER, flaws), st)   -- a lap to get up to speed
  Synth.lap(world, Synth.plan(world, base or Story.LEARNER, flaws), st)
  return st.lastLapMs
end

-- A store that already holds a teacher lap, as it would after one session
-- with an AI opponent.
function Story.storeWithTeacher(world)
  local rec, lap = Recorder.new(world.n, config.lap), nil
  for _, s in ipairs((Synth.drive(world, { latG = 1.3, brakeG = 1.2, accelG = 0.45, vmaxMs = 70, laps = 2.2 }))) do
    local done = rec:feed(s)
    if done and done.valid then lap = done break end
  end
  lap.source = 'ai'
  local store = {}
  store['C:/Users/me/Documents/Assetto Corsa/PaceCoach/ks_synthetic-rect__test_car.txt'] =
    Reference.encode({ track = 'ks_synthetic-rect', car = 'test_car', n = world.n, laps = { teacher = lap } })
  return store, lap
end

-- Runs the session. onFrame(app, state, s, lapIndex) is called every frame
-- after the app has updated. Returns the app and the fake's state.
function Story.run(opts)
  opts = opts or {}
  local world = opts.world
  if not world then
    local points = Synth.line(Synth.rectangle(), 1000)
    world = Track.build(points, { cfg = config.track, leftSign = 1 })
  end
  local store = opts.store or Story.storeWithTeacher(world)
  if opts.samples then return Story.replay(world, store, opts) end
  Fake.unload()
  local fakeOpts = { track = world, appDir = root, store = store, web = opts.web }
  for key, value in pairs(opts.fake or {}) do fakeOpts[key] = value end
  local state = Fake.install(fakeOpts)
  dofile(root .. '/PaceCoach.lua')
  local app = package.loaded['src/app']
  local flaws = opts.flaws or Story.flaws()
  local base = opts.base or Story.LEARNER
  local st, frame = {}, 0
  local laps, lapsHeard = {}, 0
  local plan = Synth.plan(world, base, flaws)
  local want = opts.laps or 8
  -- Drive until the app has summed up the last lap (it does so a moment
  -- after the line), with a hard stop one lap later in case it never does.
  while lapsHeard < want and (st.lapCount or 0) <= want do
    local s = Synth.step(world, plan, st)
    local lapIndex = s.lapCount + 1
    frame = frame + 1
    state.frame = frame
    state.officialLapMs = st.lastLapMs or 0
    Fake.drive(s)
    script.update(s.dt)
    if opts.onFrame then opts.onFrame(app, state, s, lapIndex) end
    if opts.windows ~= false then
      script.windowMain(s.dt)
      if opts.allWindows then
        script.draw3D()
        script.windowMap(s.dt)
        script.windowPanel(s.dt)
      end
      if opts.afterDraw then opts.afterDraw(app, state, s, lapIndex) end
    end
    if app.lastError then error('app error at frame ' .. frame .. ': ' .. app.lastError) end
    if app.lapNumber > lapsHeard then
      -- The app has just summed up a lap. The learner listens, and from here
      -- on does what was asked in the focus corner.
      lapsHeard = app.lapNumber
      laps[lapsHeard] = app.laps[#app.laps].timeMs
      if opts.onLap then opts.onLap(app, state, lapsHeard, laps[lapsHeard], flaws) end
      local focus = app.lesson and app.lesson.focus
      if focus and opts.learn ~= false then
        local mode = (focus.id == 'push' and 'push') or (app.coachLabel == 'limit' and 'limit') or nil
        Story.improve(flaws, focus.k, base, mode)
        plan = Synth.plan(world, base, flaws)
      end
    end
  end
  return app, state, laps, world
end

-- Drives laps that were recorded earlier (see tools/real_laps.lua) through
-- the app, with the same hooks as Story.run.
function Story.replay(world, store, opts)
  Fake.unload()
  local fakeOpts = { track = world, appDir = root, store = store }
  for key, value in pairs(opts.fake or {}) do fakeOpts[key] = value end
  local state = Fake.install(fakeOpts)
  dofile(root .. '/PaceCoach.lua')
  local app = package.loaded['src/app']
  local laps, lapsHeard = {}, 0
  for frame, s in ipairs(opts.samples) do
    local lapIndex = s.lapCount + 1
    state.frame = frame
    state.officialLapMs = s.prevLapMs or 0
    Fake.drive(s)
    script.update(s.dt)
    if opts.onFrame then opts.onFrame(app, state, s, lapIndex) end
    if opts.windows ~= false then
      script.windowMain(s.dt)
      if opts.afterDraw then opts.afterDraw(app, state, s, lapIndex) end
    end
    if app.lastError then error('app error at frame ' .. frame .. ': ' .. app.lastError) end
    if app.lapNumber > lapsHeard then
      lapsHeard = app.lapNumber
      laps[lapsHeard] = app.laps[#app.laps].timeMs
      if opts.onLap then opts.onLap(app, state, lapsHeard, laps[lapsHeard], {}) end
    end
  end
  return app, state, laps, world
end

-- Printing ---------------------------------------------------------------------

if arg and arg[0] and arg[0]:match('story%.lua$') then
  local U = require('src/util')
  local S = require('src/strings')
  local lastTip, lastCue, shown = nil, nil, 0
  local playsSeen = 0
  local function where(app, s)
    local c = app.card and app.card.ready and app.card.corner
    return string.format('%4d m %-3s', s.pos * app.track.lengthM, c and c.name or '')
  end
  local app, _, laps = Story.run({
    laps = tonumber(arg[1]) or 8,
    onFrame = function(app, state, s, lapIndex)
      if not app.track then return end
      for i = playsSeen + 1, #state.plays do
        print(string.format('  lap %d  %s  says   "%s"', lapIndex, where(app, s), state.plays[i].clip))
      end
      playsSeen = #state.plays
      local cue = app.liveCue
      if cue and cue ~= lastCue then
        lastCue = cue
        print(string.format('  lap %d  %s  CARD   %s', lapIndex, where(app, s), cue.def.text))
      end
      local tip = app.tip
      if tip and tip ~= lastTip then
        lastTip = tip
        print(string.format('  lap %d  %s  note   %s | %s', lapIndex, where(app, s), tip.title, tip.body or ''))
      end
    end,
    onLap = function(app, _, lapIndex, lapMs)
      local f = app.lesson.focus
      local skills = app.lesson:skills()
      local lv = app.level
      print(string.format('== lap %d: %s   vs %s %s   level: %s   focus: %s   skills: braking %s, speed %s, exits %s',
        lapIndex, U.formatLap(lapMs), tostring(app.coachLabel), U.formatLap(app.coachPlan and app.coachPlan.lap.timeMs),
        lv and string.format('%s %.1f%%', S.level[lv.id], lv.ratio * 100) or '-',
        f and (app.track.corners[f.k].name .. ' ' .. S.remedy[f.id].short) or 'none',
        tostring(skills.braking), tostring(skills.speed), tostring(skills.exits)))
    end,
  })
  local points = Synth.line(Synth.rectangle(), 1000)
  local carMs = Story.carLimitMs(Track.build(points, { cfg = config.track, leftSign = 1 }))
  print(string.format('\nthe car can really do %s; best lap %s is %.2f%% of that', U.formatLap(carMs),
    U.formatLap(app.best.timeMs), app.best.timeMs / carMs * 100))
  print(string.format('benchmark %s   laps: %s', U.formatLap(app.benchmark and app.benchmark.timeMs),
    table.concat((function() local t = {} for i, ms in ipairs(laps) do t[i] = U.formatLap(ms) end return t end)(), '  ')))
  print('fixed: ' .. #app.lesson.fixed .. '   error: ' .. tostring(app.lastError))
end

return Story
