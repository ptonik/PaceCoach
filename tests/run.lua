-- Offline tests for the pure-logic modules. Run from anywhere:
--   luajit tests/run.lua

local here = (arg and arg[0] or ''):match('^(.*)/[^/]*$') or '.'
package.path = here .. '/../?.lua;' .. here .. '/?.lua;' .. package.path

local config = require('src/config')
local U = require('src/util')
local Track = require('src/track')
local Grip = require('src/grip')
local Recorder = require('src/recorder')
local Pilot = require('src/pilot')
local Mistakes = require('src/mistakes')
local Reference = require('src/reference')
local Synth = require('synth')

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

-- Shared fixtures -----------------------------------------------------------

local points, length, closure = Synth.line(Synth.rectangle(), 1000)
local track = Track.build(points, { cfg = config.track, leftSign = 1 })
local DRIVER = { latG = 1.2, brakeG = 1.1, accelG = 0.4, vmaxMs = 70 }

local function driver(extra)
  local o = {}
  for k, v in pairs(DRIVER) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local function recordAll(samples, n)
  local rec, laps = Recorder.new(n or track.n, config.lap), {}
  for _, s in ipairs(samples) do
    local done = rec:feed(s)
    if done then laps[#laps + 1] = done end
  end
  return laps, rec
end

-- util ----------------------------------------------------------------------

print('util')
test('formats lap times and deltas', function()
  eq(U.formatLap(83456), '1:23.456')
  eq(U.formatLap(59999), '0:59.999')
  eq(U.formatLap(0), '-:--.---')
  eq(U.formatDelta(420), '+0.42')
  eq(U.formatDelta(-1234), '-1.23')
end)
test('wraps text at spaces', function()
  local lines = U.wrapText('one two three four five', 9)
  eq(#lines, 3)
  eq(lines[1], 'one two')
  eq(lines[2], 'three')
  eq(lines[3], 'four five')
end)
test('wraps angles and indices', function()
  near(U.wrapAngle(3 * math.pi / 2), -math.pi / 2, 1e-9)
  near(U.wrapAngle(-3 * math.pi / 2), math.pi / 2, 1e-9)
  eq(U.wrapIndex(0, 10), 10)
  eq(U.wrapIndex(11, 10), 1)
  eq(U.forward(8, 2, 10), 4)
end)

-- track ---------------------------------------------------------------------

print('track')
test('synthetic track closes on itself', function()
  near(closure, 0, 0.5, 'closure error in metres')
  near(length, 1906, 3, 'track length')
  near(track.lengthM, length, 2)
end)
test('finds the seven corners in order with the right direction', function()
  local want = { 'right', 'right', 'left', 'right', 'left', 'right', 'right' }
  eq(#track.corners, #want, 'corner count')
  for i, dir in ipairs(want) do
    eq(track.corners[i].dir, dir, 'T' .. i .. ' direction')
    eq(track.corners[i].name, 'T' .. i)
  end
end)
test('grades severity from the radius', function()
  local want = { 'hairpin', 'tight', 'tight', 'tight', 'tight', 'medium', 'fast' }
  for i, sev in ipairs(want) do
    eq(track.corners[i].severity, sev, 'T' .. i .. ' severity')
  end
end)
test('measures radius and angle', function()
  local radius = { 15, 30, 30, 30, 30, 60, 120 }
  local angle = { 90, 90, 30, 60, 30, 90, 90 }
  -- Where the chicane changes direction the curvature passes through zero,
  -- so a few degrees at each end belong to neither corner.
  local angleTol = { 4, 4, 8, 13, 8, 4, 4 }
  for i, c in ipairs(track.corners) do
    near(c.minRadiusM, radius[i], radius[i] * 0.08, 'T' .. i .. ' radius')
    near(c.angleDeg, angle[i], angleTol[i], 'T' .. i .. ' angle')
  end
end)
test('puts each apex inside its arc', function()
  -- T1 is the 90 degree R15 arc starting 232.5 m after the line.
  local c = track.corners[1]
  local arcLen = 15 * math.pi / 2
  near(c.apexM, 232.5 + arcLen / 2, 4, 'T1 apex should be mid-arc')
  check(c.startM < c.apexM and c.apexM < c.endM, 'start < apex < end')
  -- T7 is a long constant-radius arc: the apex belongs in the middle of it.
  local c7 = track.corners[7]
  near(c7.apexM, (c7.startM + c7.endM) / 2, 10, 'T7 apex should be mid-arc')
end)
test('links the chicane but not the isolated corners', function()
  eq(track.corners[3].linkNext, true, 'T3 links to T4')
  eq(track.corners[4].linkNext, true, 'T4 links to T5')
  eq(track.corners[1].linkNext, false, 'T1 stands alone')
  eq(track.corners[5].linkNext, false, 'T5 is followed by a straight')
end)
test('mirrored world flips left and right', function()
  local mirrored = Track.build(points, { cfg = config.track, leftSign = -1 })
  eq(mirrored.corners[1].dir, 'left')
  eq(mirrored.corners[3].dir, 'right')
end)
test('a track that starts mid-corner still gets whole corners', function()
  -- Rotate the point list so index 1 sits inside T1.
  local shift = Track.cellAt(track, track.corners[1].apexM / track.lengthM)
  local rotated = {}
  for i = 1, #points do rotated[i] = points[U.wrapIndex(i + shift, #points)] end
  local t2 = Track.build(rotated, { cfg = config.track, leftSign = 1 })
  eq(#t2.corners, 7, 'corner count after rotation')
end)
test('degenerate input does not crash', function()
  eq(#Track.build({}, { cfg = config.track }).corners, 0)
  local dot = {}
  for i = 1, 100 do dot[i] = { x = 0, z = 0 } end
  eq(#Track.build(dot, { cfg = config.track }).corners, 0)
  local straight = {}
  for i = 1, 100 do straight[i] = { x = i * 2, z = 0 } end
  check(#Track.build(straight, { cfg = config.track }).corners <= 2)
end)

-- grip ----------------------------------------------------------------------

print('grip')
test('starts cautious', function()
  local g = Grip.new(config.grip)
  near(g.lat[1], 0.9, 1e-9)
  near(g.brake, 0.9, 1e-9)
  near(g:cornerSpeed(50), math.sqrt(0.9 * 9.81 * 50), 1e-6)
end)
test('learns from sustained cornering and braking', function()
  local g = Grip.new(config.grip)
  local v0 = g.version
  for _ = 1, 300 do g:feed(1 / 60, 25, 1.4, 0, true) end            -- 90 km/h, 1.4 g
  -- The estimate moves in steps (so the plan is not rebuilt every frame) and
  -- therefore may sit one step below what the peak allows, never above it.
  local want = 1.4 * config.grip.latUse
  check(g.lat[2] <= want + 1e-6, 'lateral estimate above the trusted peak: ' .. g.lat[2])
  check(g.lat[2] >= want * (1 - config.grip.changeRatio) - 0.01, 'lateral estimate too low: ' .. g.lat[2])
  local speed = 60
  for _ = 1, 120 do
    speed = speed - 1.3 * 9.81 / 60
    g:feed(1 / 60, speed, 0, 1, true)
  end
  want = 1.3 * config.grip.brakeUse
  check(g.brake <= want + 1e-6, 'brake estimate above the trusted peak: ' .. g.brake)
  check(g.brake >= want * (1 - config.grip.changeRatio) - 0.02, 'brake estimate too low: ' .. g.brake)
  check(g.version > v0, 'version should rise when the estimate changes')
end)
test('ignores crashes and untrusted samples', function()
  local g = Grip.new(config.grip)
  for _ = 1, 300 do g:feed(1 / 60, 30, 9, 0, true) end                -- impact spike
  for _ = 1, 300 do g:feed(1 / 60, 30, 2.0, 0, false) end             -- off track
  near(g.lat[2], 0.9, 1e-9)
end)
test('faster bands inherit grip seen at lower speed', function()
  local g = Grip.new(config.grip)
  for _ = 1, 300 do g:feed(1 / 60, 20, 1.5, 0, true) end              -- 72 km/h
  near(g.lat[1], 1.5 * config.grip.latUse, 0.07)
  near(g.lat[4], g.lat[1], 1e-9)
end)
test('corner speed never falls as the radius grows', function()
  local g = Grip.new(config.grip)
  for _ = 1, 300 do g:feed(1 / 60, 20, 1.6, 0, true) end
  for _ = 1, 300 do g:feed(1 / 60, 45, 1.0, 0, true) end
  local prev = 0
  for r = 5, 400, 5 do
    local v = g:cornerSpeed(r)
    check(v >= prev - 1e-9, 'speed dropped at radius ' .. r)
    prev = v
  end
end)
test('survives export and import', function()
  local g = Grip.new(config.grip)
  for _ = 1, 300 do g:feed(1 / 60, 25, 1.4, 0, true) end
  local g2 = Grip.new(config.grip, g:export())
  near(g2.lat[2], config.grip.latUse * g:export().lat[2], 1e-9)
  check(g2.lat[2] >= g.lat[2], 'a reloaded estimate must not be lower')
end)

-- speed plan ----------------------------------------------------------------

print('plan')
local grip = Grip.new(config.grip)
local plan = Track.plan(track, grip, config.grip)
test('corner target speed matches v = sqrt(a R)', function()
  for i, c in ipairs(track.corners) do
    local want = math.sqrt(0.9 * 9.81 * c.minRadiusM)
    near(c.vTargetMs, want, want * 0.03, 'T' .. i .. ' target speed')
  end
end)
test('braking curve rises with distance before a corner', function()
  local c = track.corners[1]
  local a = 0.9 * 9.81
  for _, back in ipairs({ 20, 50, 100 }) do
    local cell = U.wrapIndex(c.apexCell - U.round(back / track.cellM), track.n)
    local want = math.sqrt(c.vTargetMs ^ 2 + 2 * a * back)
    check(plan.env[cell] <= want * 1.02, back .. ' m before T1 apex: curve too high')
    check(plan.env[cell] >= c.vTargetMs, 'curve below the corner speed')
  end
  check(plan.env[c.apexCell] <= c.vTargetMs + 0.01)
end)

-- recorder ------------------------------------------------------------------

print('recorder')
local samples, trueLapMs = Synth.drive(track, driver({ laps = 2 }))
test('records complete, valid laps with the right time', function()
  local laps = recordAll(samples)
  eq(#laps, 2, 'laps finished')
  for i, lap in ipairs(laps) do
    eq(lap.complete, true, 'lap ' .. i .. ' complete')
    eq(lap.valid, true, 'lap ' .. i .. ' valid')
    near(lap.timeMs, trueLapMs, 40, 'lap ' .. i .. ' time')
    eq(#lap.t, track.n)
  end
end)
test('channels hold what was driven', function()
  local lap = recordAll(samples)[2]
  local c = track.corners[1]
  near(lap.v[c.apexCell], math.sqrt(1.2 * 9.81 * c.minRadiusM) * 3.6, 3, 'apex speed km/h')
  check(lap.steer[c.apexCell] < -20, 'steering right at T1 apex')
  check(lap.steer[track.corners[3].apexCell] > 20, 'steering left at T3 apex')
  near(lap.x[1], points[1].x, 0.5)
  near(lap.z[1], points[1].z, 0.5)
end)
test('two identical laps show no delta', function()
  local laps = recordAll(samples)
  for _, pos in ipairs({ 0.1, 0.33, 0.5, 0.77, 0.95 }) do
    local t = Recorder.valueAt(laps[2], 't', pos)
    near(Recorder.deltaMs(laps[1], pos, t), 0, 25, 'delta at ' .. pos)
  end
end)
test('a slower lap shows a growing positive delta', function()
  local slow, slowMs = Synth.drive(track, driver({ laps = 2, scale = 0.9 }))
  local ref = recordAll(samples)[2]
  local lap = recordAll(slow)[2]
  local d1 = Recorder.deltaMs(ref, 0.25, Recorder.valueAt(lap, 't', 0.25))
  local d2 = Recorder.deltaMs(ref, 0.75, Recorder.valueAt(lap, 't', 0.75))
  check(d1 > 0 and d2 > d1, 'delta should grow: ' .. d1 .. ', ' .. d2)
  near(d2, (slowMs - trueLapMs) * 0.75, (slowMs - trueLapMs) * 0.2)
end)
test('an out-lap that resets the timer is not a valid lap', function()
  local out = Synth.drive(track, driver({ laps = 1.6, startPos = 0.5 }))
  local laps = recordAll(out)
  eq(laps[1].complete, false, 'half lap must be incomplete')
  eq(laps[1].valid, false)
  eq(laps[2].valid, true, 'the full lap after it counts')
end)
test('an out-lap with a stopped timer leaves the next lap intact', function()
  -- The timer shows 0 and the lap count stays put until the first crossing.
  local out = Synth.drive(track, driver({ laps = 1.6, startPos = 0.5 }))
  local crossed = false
  for _, s in ipairs(out) do
    if s.lapCount == 0 then s.t = 0 else crossed = true end
    s.lapCount = math.max(0, s.lapCount - 1)
  end
  check(crossed)
  local laps = recordAll(out)
  eq(#laps, 1)
  eq(laps[1].valid, true)
  near(laps[1].timeMs, trueLapMs, 40)
end)
test('a teleport invalidates the lap', function()
  local jumped = {}
  for i, s in ipairs(samples) do
    jumped[i] = s
    if i == 200 then
      local copy = {}
      for k, v in pairs(s) do copy[k] = v end
      copy.pos = (s.pos + 0.3) % 1
      jumped[i] = copy
    end
  end
  local laps = recordAll(jumped)
  eq(laps[1].valid, false)
  check(laps[1].invalid ~= nil)
end)
test('low frame rate still fills every cell', function()
  local choppy = Synth.drive(track, driver({ laps = 2, hz = 12 }))
  local laps = recordAll(choppy)
  eq(laps[2].complete, true)
  near(laps[2].coverage, 1, 0.001)
end)
test('invalidate() sticks to the lap in progress only', function()
  local rec, laps = Recorder.new(track.n, config.lap), {}
  for i, s in ipairs(samples) do
    if i == 50 then rec:invalidate('offtrack') end
    local done = rec:feed(s)
    if done then laps[#laps + 1] = done end
  end
  eq(laps[1].valid, false)
  eq(laps[1].invalid, 'offtrack')
  eq(laps[2].valid, true)
end)

-- pilot ---------------------------------------------------------------------

print('pilot')
local function runPilot(lapSamples, opts)
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(plan)
  local log = {}
  for i, s in ipairs(lapSamples) do
    local card, events = pilot:update(s.pos, s.speedMs, s.dt, opts)
    for _, ev in ipairs(events) do
      log[#log + 1] = {
        kind = ev.kind, corner = ev.corner, chain = ev.chain,
        pos = s.pos, lap = s.lapCount, i = i, speedMs = s.speedMs,
        distM = s.pos * track.lengthM,
      }
    end
    check(card.ready, 'card should be ready on a track with corners')
  end
  return log
end

-- Three laps, then keep one full cycle: from the first T2 callout to the next.
local pilotSamples = Synth.drive(track, driver({ laps = 3 }))
local pilotLog = runPilot(pilotSamples)
local cycle = {}
do
  local t2 = 0
  for _, e in ipairs(pilotLog) do
    if e.kind == 'corner' and e.corner.index == 2 then t2 = t2 + 1 end
    if t2 == 1 then cycle[#cycle + 1] = e end
  end
end

test('calls every corner once per lap, in order', function()
  local seen = {}
  for _, e in ipairs(cycle) do
    if e.kind == 'corner' then
      seen[#seen + 1] = e.corner.index
      for _, c in ipairs(e.chain or {}) do seen[#seen + 1] = c.index end
    end
  end
  eq(table.concat(seen, ','), '2,3,4,5,6,7,1')
end)
test('calls the chicane as one phrase', function()
  local found = false
  for _, e in ipairs(cycle) do
    if e.kind == 'corner' and e.corner.index == 3 then
      check(e.chain and #e.chain == 2, 'T3 should bring T4 and T5 with it')
      eq(e.chain[1].index, 4)
      eq(e.chain[2].index, 5)
      found = true
    end
  end
  check(found, 'T3 was never called')
end)
test('names the corner before saying brake, every time', function()
  local lastCalled = {}
  local cues = 0
  for _, e in ipairs(cycle) do
    if e.kind == 'corner' then
      lastCalled[e.corner.index] = e.i
      for _, c in ipairs(e.chain or {}) do lastCalled[c.index] = e.i end
    elseif e.kind == 'brake' then
      cues = cues + 1
      local called = lastCalled[e.corner.index]
      check(called and called < e.i, 'brake for ' .. e.corner.name .. ' came before its callout')
      local warnS = (e.i - called) / 60
      check(warnS >= 1.0, e.corner.name .. ': only ' .. warnS .. ' s between callout and brake')
    end
  end
  check(cues >= 4, 'expected brake cues in the cycle, got ' .. cues)
end)
test('says brake before the driver really has to', function()
  -- The driver has more grip (1.1 g) than the cautious plan (0.9 g), so the
  -- cue has to arrive earlier than the point where the driver brakes.
  local c = track.corners[1]
  local cue
  for _, e in ipairs(pilotLog) do
    if e.kind == 'brake' and e.corner.index == 1 and e.lap == 1 then cue = e break end
  end
  check(cue, 'no brake cue for T1 on lap 1')
  local driverBrakeM
  for _, s in ipairs(pilotSamples) do
    if s.lapCount == 1 and s.brake > 0.2 and s.pos * track.lengthM < c.apexM then
      driverBrakeM = s.pos * track.lengthM
      break
    end
  end
  check(driverBrakeM, 'driver should brake for T1')
  check(cue.distM < driverBrakeM, 'cue at ' .. cue.distM .. ' m, driver braked at ' .. driverBrakeM)
  check(cue.distM > driverBrakeM - 150, 'cue should not be absurdly early: ' .. cue.distM)
end)
test('gives one brake cue per braking zone', function()
  local per = {}
  for _, e in ipairs(cycle) do
    if e.kind == 'brake' then per[e.corner.index] = (per[e.corner.index] or 0) + 1 end
  end
  for idx, count in pairs(per) do eq(count, 1, 'brake cues for T' .. idx) end
  for _, idx in ipairs({ 1, 2, 6, 7 }) do eq(per[idx], 1, 'T' .. idx .. ' needs a brake cue') end
end)

local function approach(speedMs, leadS)
  -- Constant speed towards T1 from the start line; returns where the cue fired.
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(plan)
  local dt, dist = 1 / 60, 0
  while dist < track.corners[1].apexM do
    local _, events = pilot:update(dist / track.lengthM, speedMs, dt, { leadS = leadS })
    for _, ev in ipairs(events) do
      if ev.kind == 'brake' then return dist end
    end
    dist = dist + speedMs * dt
  end
  return nil
end
test('a slower approach gets a later cue', function()
  local fast, slow = approach(55), approach(30)
  check(fast and slow, 'both approaches need a cue')
  check(slow > fast + 30, 'fast cue at ' .. fast .. ' m, slow cue at ' .. slow .. ' m')
end)
test('the cue leaves room to stop at the planned rate', function()
  local c = track.corners[1]
  for _, v in ipairs({ 30, 45, 60 }) do
    local at = approach(v)
    local need = (v * v - c.vTargetMs ^ 2) / (2 * 0.9 * 9.81)
    local room = c.apexM - at
    check(room >= need, v .. ' m/s: room ' .. room .. ' m, need ' .. need .. ' m')
    check(room <= need + v * 0.6 + 40, v .. ' m/s: cue far too early (' .. room .. ' m)')
  end
end)
test('extra lead time moves the cue earlier', function()
  check(approach(50, 0.5) < approach(50, 0), 'lead time had no effect')
end)
test('no cue when the corner needs no braking', function()
  eq(approach(10), nil)
end)
test('stays quiet below walking pace and with no plan', function()
  local pilot = Pilot.new(track, config.pilot)
  local card = pilot:update(0.1, 30, 1 / 60)
  eq(card.ready, false)
  pilot:setPlan(plan)
  local _, events = pilot:update(track.corners[1].startM / track.lengthM, 2, 1 / 60)
  eq(#events, 0)
end)
test('card reports distance and the corner after next', function()
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(plan)
  local card = pilot:update(0, 40, 1 / 60)
  eq(card.corner.index, 1)
  near(card.distStartM, track.corners[1].startM, 3)
  eq(card.nextCorner.index, 2)
  card = pilot:update(track.corners[1].apexM / track.lengthM + 0.002, 12, 1 / 60)
  eq(card.corner.index, 2, 'past the apex the next corner takes over')
end)

-- mistakes ------------------------------------------------------------------

print('mistakes')
local function calm()
  return {
    v = 120, gas = 0.6, brake = 0, steer = 0, wheelsOut = 0, abs = false, velAngleDeg = 1,
    slipRatio = { 0, 0, 0.02, 0.02 }, slipAngle = { 1, 1, 1, 1 },
  }
end
local function runMistakes(seconds, mutate, opts)
  local m, got, dt = Mistakes.new(config.mistakes), {}, 1 / 60
  for i = 1, math.floor(seconds * 60) do
    local s = calm()
    mutate(s, i * dt)
    for _, id in ipairs(m:update(s, dt, opts)) do got[#got + 1] = id end
  end
  return got
end
test('calm driving raises nothing', function()
  eq(#runMistakes(20, function() end), 0)
end)
test('detects each mistake once', function()
  local cases = {
    lockup = function(s) s.gas, s.brake, s.slipRatio = 0, 0.9, { -0.6, -0.1, 0, 0 } end,
    wheelspin = function(s) s.gas, s.v, s.slipRatio = 1, 60, { 0, 0, 0.5, 0.4 } end,
    abs = function(s) s.gas, s.brake, s.abs = 0, 1, true end,
    understeer = function(s) s.slipAngle = { 13, 12, 4, 4 } end,
    oversteer = function(s) s.slipAngle = { 3, 3, 14, 13 } end,
    offtrack = function(s) s.wheelsOut = 4 end,
    spin = function(s) s.v, s.velAngleDeg = 60, 95 end,
    coast = function(s) s.gas, s.brake = 0, 0 end,
  }
  for id, mutate in pairs(cases) do
    local got = runMistakes(3, mutate)
    eq(got[1], id, 'first event for ' .. id)
    eq(#got, 1, 'events for ' .. id .. ' in 3 s')
  end
end)
test('respects the cooldown', function()
  local got = runMistakes(config.mistakes.cooldownS * 2.5, function(s)
    s.gas, s.brake, s.slipRatio = 0, 0.9, { -0.6, -0.6, 0, 0 }
  end)
  eq(#got, 3)
end)
test('brief blips are ignored', function()
  local got = runMistakes(5, function(s, t)
    if t > 1 and t < 1.05 then s.gas, s.brake, s.slipRatio = 0, 0.9, { -0.6, -0.6, 0, 0 } end
    if t > 2 and t < 2.1 then s.wheelsOut = 4 end
  end)
  eq(#got, 0)
end)
test('a spin silences the knock-on mistakes', function()
  local got = runMistakes(3, function(s)
    s.v, s.velAngleDeg, s.slipAngle, s.slipRatio = 60, 95, { 20, 20, 40, 40 }, { -1, -1, -1, -1 }
    s.brake, s.gas = 1, 0
  end)
  eq(table.concat(got, ','), 'spin')
end)
test('detects sawing at the wheel, but not a chicane or a gamepad', function()
  local saw = function(s, t) s.steer = 25 * math.sin(t * 2 * math.pi * 2.5) end
  eq(runMistakes(4, saw)[1], 'sawing')
  eq(#runMistakes(4, saw, { gamepad = true }), 0)
  local chicane = function(s, t)
    if t > 1 and t < 3 then s.steer = 90 * math.sin((t - 1) * math.pi * 1.5) end
  end
  eq(#runMistakes(5, chicane), 0)
end)
test('works with missing optional data', function()
  local got = runMistakes(3, function(s)
    s.slipRatio, s.slipAngle, s.velAngleDeg, s.steer, s.wheelsOut = nil, nil, nil, nil, nil
  end)
  eq(#got, 0)
end)
test('picks the most important mistake', function()
  eq(Mistakes.mostImportant({ 'coast', 'lockup', 'wheelspin' }), 'lockup')
  eq(Mistakes.mostImportant({}), nil)
end)

-- reference -----------------------------------------------------------------

print('reference')
test('a lap survives save and load', function()
  local store = {}
  local ref = Reference.new({
    dir = '/data',
    save = function(path, text) store[path] = text return true end,
    load = function(path) return store[path] end,
  })
  local lap = recordAll(samples)[2]
  lap.source = 'player'
  local g = Grip.new(config.grip)
  for _ = 1, 300 do g:feed(1 / 60, 25, 1.4, 0, true) end
  local data = {
    track = 'ks_test/layout a', car = 'abarth500', n = track.n,
    grip = g:export(), laps = { best = lap },
  }
  eq(ref:saveCombo(data), true)
  local path = ref:path('ks_test/layout a', 'abarth500')
  eq(path, '/data/ks_test_layout_a__abarth500.txt')
  check(store[path], 'file should be written')
  local back = ref:loadCombo('ks_test/layout a', 'abarth500', track.n)
  local got = back.laps.best
  check(got, 'best lap should load')
  eq(got.n, track.n)
  near(got.timeMs, lap.timeMs, 1)
  eq(got.valid, true)
  for _, i in ipairs({ 1, 250, 777, track.n }) do
    near(got.t[i], lap.t[i], 0.6, 't[' .. i .. ']')
    near(got.v[i], lap.v[i], 0.06, 'v[' .. i .. ']')
    near(got.brake[i], lap.brake[i], 0.006, 'brake[' .. i .. ']')
    near(got.steer[i], lap.steer[i], 0.06, 'steer[' .. i .. ']')
    near(got.x[i], lap.x[i], 0.006, 'x[' .. i .. ']')
    eq(got.gear[i], lap.gear[i], 'gear[' .. i .. ']')
  end
  near(back.grip.lat[2], g:export().lat[2], 0.001)
end)
test('a missing or broken file gives an empty, usable result', function()
  local ref = Reference.new({ dir = '/d', save = function() return false end,
    load = function() return nil end })
  local data = ref:loadCombo('t', 'c', 500)
  eq(data.n, 500)
  eq(next(data.laps), nil)
  eq(Reference.decode('garbage'), nil)
  eq(Reference.decode(nil), nil)
  eq(ref:saveCombo(data), false)
end)
test('laps from another grid size are dropped, grip is kept', function()
  local store = {}
  local ref = Reference.new({ dir = '/d',
    save = function(p, t) store[p] = t return true end, load = function(p) return store[p] end })
  local lap = recordAll(samples)[2]
  ref:saveCombo({ track = 't', car = 'c', n = track.n, laps = { best = lap },
    grip = { lat = { 1.2, 0, 0, 0 }, brake = 1.1 } })
  local back = ref:loadCombo('t', 'c', track.n + 100)
  eq(next(back.laps), nil)
  near(back.grip.brake, 1.1, 1e-6)
end)
test('a truncated lap is rejected, not half-loaded', function()
  local lap = recordAll(samples)[2]
  local text = Reference.encode({ track = 't', car = 'c', n = track.n, laps = { best = lap } })
  local cut = text:sub(1, math.floor(#text * 0.6))
  local data = Reference.decode(cut)
  check(data, 'header should still parse')
  eq(data.laps.best, nil)
end)

-- Stage 2: metrics, targets, coach, teacher ----------------------------------

local Metrics = require('src/metrics')
local Targets = require('src/targets')
local Coach = require('src/coach')
local Teacher = require('src/teacher')

local TEACHER = { latG = 1.3, brakeG = 1.2, accelG = 0.45, vmaxMs = 70 }
local LEARNER = { latG = 1.0, brakeG = 0.7, accelG = 0.35, vmaxMs = 70 }
local function with(base, extra)
  local o = {}
  for k, v in pairs(base) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end
local teacherSamples, teacherMs = Synth.drive(track, with(TEACHER, { laps = 3 }))
local learnerSamples, learnerMs = Synth.drive(track, with(LEARNER, { laps = 3 }))
local teacherLap = recordAll(teacherSamples)[2]
local learnerLap = recordAll(learnerSamples)[2]
teacherLap.source = 'ai'
local segs = Metrics.segments(track)
local function measureAll(lap)
  local out, slices = {}, {}
  for k, c in ipairs(track.corners) do
    slices[k] = Metrics.slice(track, lap, nil, segs[k])
    out[k] = Metrics.measure(slices[k], track, c, segs[k], config.metrics)
  end
  return out, slices
end
local function copyLap(lap)
  local c = {}
  for k, v in pairs(lap) do
    if type(v) == 'table' then
      local a = {}
      for i = 1, #v do a[i] = v[i] end
      c[k] = a
    else
      c[k] = v
    end
  end
  return c
end

print('metrics')
test('segments cover the lap exactly once', function()
  eq(#segs, 7)
  local total = 0
  for k, seg in ipairs(segs) do
    total = total + seg.cells
    eq(seg.to, segs[(k % #segs) + 1].from, 'segment ' .. k .. ' joins the next')
    eq(Metrics.segmentAt(segs, track.corners[k].apexCell, track.n), k, 'apex of T' .. k)
  end
  eq(total, track.n)
end)
test('segment times add up to the lap time, across the timing line too', function()
  local sum = 0
  for k = 1, #segs do
    local sl = Metrics.slice(track, teacherLap, nil, segs[k])
    check(sl, 'slice ' .. k)
    check(sl.timeMs > 0, 'segment ' .. k .. ' time')
    sum = sum + sl.timeMs
  end
  near(sum, teacherMs, 40)
end)
test('measures the brake point, slowest speed, gear and throttle of a corner', function()
  local m = measureAll(teacherLap)[1]
  local c = track.corners[1]
  -- Where did the synthetic driver really start braking for T1?
  local realBrakeM
  for _, s in ipairs(teacherSamples) do
    if s.lapCount == 1 and s.brake > 0.1 and s.pos * track.lengthM > 50 then
      realBrakeM = s.pos * track.lengthM
      break
    end
  end
  near(track.s[m.brakeCell], realBrakeM, 6, 'brake point')
  check(m.brakeRelM < 0, 'braking starts before turn-in')
  near(m.minKmh, math.sqrt(1.3 * 9.81 * 15) * 3.6, 3, 'slowest speed')
  eq(m.gear, 2)
  check(m.peakBrake > 0.8, 'peak brake ' .. m.peakBrake)
  check(m.throttleCell and m.throttleRelM > -12, 'throttle comes around the apex')
  eq(m.lifts, 0)
  check(m.coastM < 10, 'no coasting: ' .. m.coastM)
  check(m.exitKmh > m.minKmh, 'accelerating out')
  check(c.startM < track.s[m.minCell] and track.s[m.minCell] < c.endM, 'slowest point inside the corner')
end)
test('a corner straddling the timing line can be measured mid-lap', function()
  local rec = Recorder.new(track.n, config.lap)
  local want = Metrics.slice(track, teacherLap, nil, segs[1]).timeMs
  local got
  for _, s in ipairs(teacherSamples) do
    rec:feed(s)
    if s.lapCount == 1 and not got then
      -- Not there yet: T6 has not been driven on this lap.
      eq(Metrics.slice(track, rec.lap, rec.prev, segs[6]), nil, 'T6 must not come from the old lap')
      if Metrics.segmentAt(segs, Track.cellAt(track, s.pos), track.n) == 2 then
        got = Metrics.slice(track, rec.lap, rec.prev, segs[1])
      end
    end
  end
  check(got, 'T1 slice should be available once the car is in T2')
  near(got.timeMs, want, 30)
end)
test('after a restart nothing is borrowed from the old lap', function()
  local rec = Recorder.new(track.n, config.lap)
  for _, s in ipairs(teacherSamples) do
    rec:feed(s)
    if s.lapCount == 1 and s.pos > 0.02 and s.pos < 0.03 then rec:restart('jump') end
  end
  eq(rec.prev ~= nil, true, 'a later lap sets prev again')
  local rec2 = Recorder.new(track.n, config.lap)
  for _, s in ipairs(teacherSamples) do
    if s.lapCount == 1 and s.pos > 0.3 then break end
    rec2:feed(s)
    if s.lapCount == 1 and s.pos > 0.02 and s.pos < 0.025 then rec2:restart('jump') end
  end
  eq(Metrics.slice(track, rec2.lap, rec2.prev, segs[1]), nil)
end)
test('rebuilds pedals from speed when the game gives none', function()
  local blind = copyLap(teacherLap)
  for i = 1, blind.n do blind.gas[i], blind.brake[i] = 0, 0 end
  eq(Metrics.pedalsLookReal(blind), false)
  eq(Metrics.pedalsLookReal(teacherLap), true)
  Metrics.derivePedals(blind)
  eq(Metrics.pedalsLookReal(blind), true)
  eq(blind.pedals, 'derived')
  local real, derived = measureAll(teacherLap), measureAll(blind)
  for _, k in ipairs({ 1, 2, 6 }) do
    check(derived[k].brakeCell, 'T' .. k .. ' brake point found')
    near(track.s[derived[k].brakeCell], track.s[real[k].brakeCell], 15, 'T' .. k .. ' brake point')
    check(derived[k].throttleCell, 'T' .. k .. ' throttle point found')
  end
end)
test('measures how far off the benchmark line a car is', function()
  local ref = Metrics.slice(track, teacherLap, nil, segs[2])
  local shifted = copyLap(teacherLap)
  -- T2's segment begins on the straight after T1, heading -z: left is +x.
  for i = 1, shifted.n do shifted.x[i] = shifted.x[i] + 2 end
  local got = Metrics.slice(track, shifted, nil, segs[2])
  near(Metrics.lateral(got, ref, 5, 1), 2, 0.05)
  near(Metrics.lateral(got, ref, 5, -1), -2, 0.05)
  near(Metrics.lateral(ref, ref, 5, 1), 0, 1e-9)
end)

print('targets')
local bench = Targets.build(track, teacherLap, segs, config.targets, config.metrics)
test('builds targets for every corner', function()
  for k = 1, 7 do
    local t = bench.targets[k]
    check(t, 'target for T' .. k)
    check(t.minKmh > 20 and t.minKmh < 250, 'T' .. k .. ' speed ' .. t.minKmh)
    check(t.gear >= 1, 'T' .. k .. ' gear')
  end
  eq(bench.source, 'ai')
  near(bench.brakeG, 1.2 * config.targets.brakeUse, 0.12, 'braking rate learned from the lap')
  check(bench.targets[1].brakeCell and bench.targets[2].brakeCell and bench.targets[6].brakeCell,
    'the heavy braking corners have brake points')
end)
test('the braking curve follows the benchmark in corners and is open on straights', function()
  local c = track.corners[1]
  near(bench.env[c.apexCell] * 3.6, teacherLap.v[c.apexCell], 2, 'at the T1 apex')
  -- Mid-way down the straight after T1 the benchmark is flat out.
  local mid = Track.cellAt(track, (c.endM + 150) / track.lengthM)
  check(teacherLap.gas[mid] > 0.9, 'fixture: flat out mid-straight')
  check(bench.env[mid] * 3.6 > teacherLap.v[mid] + 5,
    'curve should sit above the benchmark speed: ' .. bench.env[mid] * 3.6 .. ' vs ' .. teacherLap.v[mid])
end)
test('gear-change blips do not dent the braking curve', function()
  local blip = copyLap(teacherLap)
  local c = track.corners[1]
  local mid = Track.cellAt(track, (c.endM + 150) / track.lengthM)
  for i = mid, mid + 3 do blip.gas[i] = 0 end
  local plan2 = Targets.build(track, blip, segs, config.targets, config.metrics)
  near(plan2.env[mid], bench.env[mid], 0.01)
end)

local function approachWith(thePlan, speedOf, fromM, toM, gas)
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(thePlan)
  local dt, dist, events = 1 / 60, fromM, {}
  while dist < toM do
    local v = speedOf(dist)
    local _, evs = pilot:update((dist / track.lengthM) % 1, v, dt, { gas = gas })
    for _, ev in ipairs(evs) do events[#events + 1] = { kind = ev.kind, distM = dist, corner = ev.corner } end
    dist = dist + v * dt
  end
  return events
end
local function firstOf(events, kind)
  for _, e in ipairs(events) do if e.kind == kind then return e end end
end
test('with a benchmark the brake cue sits just before the benchmark brake point', function()
  local t1 = bench.targets[1]
  local brakeM = track.s[t1.brakeCell]
  local function teacherSpeed(dist)
    return Recorder.valueAt(teacherLap, 'v', (dist / track.lengthM) % 1) / 3.6
  end
  local cue = firstOf(approachWith(bench, teacherSpeed, 5, track.corners[1].apexM), 'brake')
  check(cue, 'cue expected')
  check(cue.distM <= brakeM, 'cue at ' .. cue.distM .. ' m, benchmark brakes at ' .. brakeM .. ' m')
  check(cue.distM >= brakeM - 60, 'cue too early: ' .. cue.distM .. ' vs ' .. brakeM)
end)
test('with a benchmark a slower approach still gets a later cue', function()
  local apex = track.corners[1].apexM
  local fast = firstOf(approachWith(bench, function() return 55 end, 5, apex), 'brake')
  local slow = firstOf(approachWith(bench, function() return 30 end, 5, apex), 'brake')
  check(fast and slow)
  check(slow.distM > fast.distM + 30, 'fast ' .. fast.distM .. ', slow ' .. slow.distM)
end)
test('being faster than the benchmark on a straight is not a reason to brake', function()
  local c1, c2 = track.corners[1], track.corners[2]
  local from = c1.endM + 60
  local function quick(dist)
    return Recorder.valueAt(teacherLap, 'v', dist / track.lengthM) / 3.6 + 8
  end
  local events = approachWith(bench, quick, from, c2.apexM)
  local cue = firstOf(events, 'brake')
  check(cue, 'a cue for T2 is still expected')
  check(cue.distM > from + 80, 'cue fired straight away at ' .. cue.distM .. ' m')
  eq(firstOf(events, 'lift'), nil, 'no lift cue on the straight')
end)
test('throttle cue only when the driver is late on the throttle', function()
  local apex1, start2 = track.corners[1].apexM, track.corners[2].startM
  local function teacherSpeed(dist)
    return Recorder.valueAt(teacherLap, 'v', (dist / track.lengthM) % 1) / 3.6
  end
  local late = firstOf(approachWith(bench, teacherSpeed, apex1 - 30, start2 - 100, 0), 'throttle')
  check(late, 'off the throttle: cue expected')
  eq(late.corner.index, 1)
  near(late.distM, track.s[bench.targets[1].throttleCell], 4)
  eq(firstOf(approachWith(bench, teacherSpeed, apex1 - 30, start2 - 100, 1), 'throttle'), nil,
    'already on the throttle: no cue')
  eq(firstOf(approachWith(plan, teacherSpeed, apex1 - 30, start2 - 100, 0), 'throttle'), nil,
    'no benchmark: no throttle cue')
end)

print('coach')
test('tells the early braker to brake later, with the distance', function()
  local ref = bench.targets
  local got = measureAll(learnerLap)
  for _, k in ipairs({ 1, 2, 6 }) do
    local res = Coach.judge(ref[k], got[k], nil, config.coach)
    eq(res.id, 'brakeEarly', 'T' .. k)
    local realDiff = track.s[ref[k].brakeCell] - track.s[got[k].brakeCell]
    near(res.value, realDiff, 4, 'T' .. k .. ' distance')
    check(res.value > 10 and res.lossMs > 80, 'T' .. k .. ' loss')
    eq(res.good, false)
  end
end)
test('each cause is recognised', function()
  local ref = { timeMs = 10000, brakeRelM = -80, minKmh = 80, throttleRelM = 5, lifts = 0,
    coastM = 0, exitKmh = 120, peakBrake = 1 }
  local function got(change)
    local g = { timeMs = 10400 }
    for k, v in pairs(ref) do if g[k] == nil then g[k] = v end end
    for k, v in pairs(change or {}) do g[k] = v end
    return g
  end
  local function id(change, extra) return Coach.judge(ref, got(change), extra, config.coach).id end
  eq(id({ timeMs = 9900 }), 'gain')
  eq(id({ timeMs = 10030 }), 'ok')
  eq(id({}, { offTrack = true }), 'offTrack')
  eq(id({ brakeRelM = -110 }), 'brakeEarly')
  eq(id({ brakeRelM = -55, minKmh = 70 }), 'brakeLate')
  eq(id({ brakeRelM = -55 }), 'slower', 'braking later and still making the corner is not a fault')
  eq(id({ minKmh = 72 }), 'overSlow')
  eq(id({ lifts = 1 }), 'gasLift')
  eq(id({ throttleRelM = 30 }), 'throttleLate')
  eq(id({ coastM = 40 }), 'coast')
  eq(id({}, { wideM = 3 }), 'wide')
  eq(id({ exitKmh = 110 }), 'exitSlow')
  eq(id({}), 'slower')
  local res = Coach.judge(ref, got({ brakeRelM = -110 }), nil, config.coach)
  near(res.value, 30, 1e-9)
  near(res.lossMs, 400, 1e-9)
  -- The benchmark does not brake here but the driver does.
  local flat = { timeMs = 5000, minKmh = 150, lifts = 0, coastM = 0, exitKmh = 160, peakBrake = 0 }
  eq(Coach.judge(flat, { timeMs = 5400, brakeRelM = -30, minKmh = 120, lifts = 0, coastM = 0,
    exitKmh = 150, peakBrake = 0.8 }, nil, config.coach).id, 'noBrake')
end)

print('teacher')
local function feedCars(teacher, cars)
  local found = {}
  local longest = 0
  for _, car in ipairs(cars) do longest = math.max(longest, #car.samples) end
  for i = 1, longest do
    for _, car in ipairs(cars) do
      local s = car.samples[i]
      if s then
        s.inPit = car.pit and car.pit(s) or false
        s.wheelsOut = 0
        local lap = teacher:feed(car.key, s)
        if lap then found[#found + 1] = { key = car.key, lap = lap, frame = i } end
      end
    end
  end
  return found
end
test('keeps the fastest clean lap among the watched cars', function()
  local teacher = Teacher.new(track.n, config.lap, config.teacher)
  local found = feedCars(teacher, {
    { key = 1, samples = Synth.drive(track, with(LEARNER, { laps = 3 })) },
    { key = 2, samples = Synth.drive(track, with(TEACHER, { laps = 3 })) },
  })
  check(#found >= 1, 'a teacher lap should be reported')
  eq(found[#found].key, 2, 'the quick car is the teacher')
  near(teacher.best.timeMs, teacherMs, 40)
  eq(teacher.best.source, 'ai')
  check(teacher.lapsSeen >= 4, 'laps seen: ' .. teacher.lapsSeen)
  for i = 2, #found do
    check(found[i].lap.timeMs < found[i - 1].lap.timeMs - config.teacher.improveMs + 1, 'only real improvements')
  end
end)
test('ignores pit laps and watches a limited number of cars', function()
  local teacher = Teacher.new(track.n, config.lap, config.teacher)
  local found = feedCars(teacher, {
    { key = 1, samples = Synth.drive(track, with(TEACHER, { laps = 2 })),
      pit = function(s) return s.pos > 0.5 and s.pos < 0.52 end },
  })
  eq(#found, 0, 'every lap went through the pits')
  eq(teacher.best, nil)
  local crowd = {}
  for k = 1, config.teacher.maxCars + 3 do
    crowd[k] = { key = k, samples = Synth.drive(track, with(TEACHER, { laps = 0.1 })) }
  end
  feedCars(teacher, crowd)
  eq(teacher.count, config.teacher.maxCars)
end)
test('chooses the right benchmark', function()
  local t, f, slow, quick = { timeMs = 60000 }, { timeMs = 58000 }, { timeMs = 70000 }, { timeMs = 55000 }
  local lap, label = Teacher.choose(nil, nil, slow)
  eq(lap, nil, 'your own lap alone is not a guide for braking')
  eq(label, nil)
  lap, label = Teacher.choose(t, nil, slow)
  eq(lap, t)
  eq(label, 'teacher')
  lap, label = Teacher.choose(t, f, slow)
  eq(lap, f)
  eq(label, 'friend')
  lap, label = Teacher.choose(t, f, quick)
  eq(lap, quick, 'once you beat the teacher you are the benchmark')
  eq(label, 'you')
  lap, label = Teacher.choose(nil, f, nil)
  eq(label, 'friend')
end)

print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
