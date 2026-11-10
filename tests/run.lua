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
  eq(card.corner.index, 1, 'just past the apex the card stays with the corner being finished')
  eq(card.phase, 'exit')
  eq(card.nextCorner.index, 2)
  card = pilot:update((track.corners[1].endM + 30) / track.lengthM, 12, 1 / 60)
  eq(card.corner.index, 2, 'past the exit the next corner takes over')
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

-- Staying with the driver ------------------------------------------------------

print('reactive co-driver')
-- A small track whose corners come in close pairs: 80 m between T1 and T2.
local closePoints = Synth.line({
  { 's', 120 }, { 'a', 30, -90 }, { 's', 80 }, { 'a', 30, -90 }, { 's', 240 },
  { 'a', 30, -90 }, { 's', 80 }, { 'a', 30, -90 }, { 's', 120 },
}, 414)
local closeTrack = Track.build(closePoints, { cfg = config.track, leftSign = 1 })
local closePlan = Track.plan(closeTrack, Grip.new(config.grip), config.grip)
local closeSamples = Synth.drive(closeTrack, driver({ laps = 3 }))

test('fixture: four corners, two close pairs, not linked', function()
  eq(#closeTrack.corners, 4)
  near(closeTrack.corners[1].gapNextM, 80, 8)
  eq(closeTrack.corners[1].linkNext, false)
end)
test('the next corner is not called while the driver is still finishing this one', function()
  local pilot = Pilot.new(closeTrack, config.pilot)
  pilot:setPlan(closePlan)
  local c1 = closeTrack.corners[1]
  local calledAt, cuedAt, sawExit
  for _, s in ipairs(closeSamples) do
    local card, events = pilot:update(s.pos, s.speedMs, s.dt, { gas = s.gas, brake = s.brake })
    local m = s.pos * closeTrack.lengthM
    if s.lapCount == 1 then
      if m > c1.apexM + 4 and m < c1.endM - 2 then
        eq(card.corner.index, 1, 'card stays on T1 through its exit (at ' .. m .. ' m)')
        eq(card.phase, 'exit')
        eq(card.nextCorner.index, 2, 'with T2 as the preview')
        sawExit = true
      end
      for _, ev in ipairs(events) do
        if ev.kind == 'corner' and ev.corner.index == 2 and not calledAt then calledAt = m end
        if ev.kind == 'brake' and ev.corner.index == 2 and not cuedAt then cuedAt = m end
      end
    end
  end
  check(sawExit, 'the exit phase was never seen')
  check(calledAt, 'T2 must still be called')
  check(calledAt >= c1.endM, 'T2 called at ' .. calledAt .. ' m, T1 ends at ' .. c1.endM .. ' m')
  check(calledAt < closeTrack.corners[2].startM, 'and before T2 begins')
  if cuedAt then check(calledAt < cuedAt, 'callout before the brake cue') end
end)
test('past the exit the card moves on to the next corner', function()
  local pilot = Pilot.new(closeTrack, config.pilot)
  pilot:setPlan(closePlan)
  local c1 = closeTrack.corners[1]
  local card = pilot:update((c1.endM + config.pilot.exitHoldM + 6) / closeTrack.lengthM, 15, 1 / 60)
  eq(card.corner.index, 2)
  eq(card.phase, nil)
end)
test('a chicane is still called in one breath, with no waiting', function()
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(plan)
  local c4 = track.corners[4]
  -- Just past T3's apex, T4 begins within a few metres: no exit hold.
  local card = pilot:update((track.corners[3].apexM + 6) / track.lengthM, 20, 1 / 60)
  check(card.phase ~= 'exit' or card.corner.index ~= 3 or c4.startM - track.corners[3].apexM > 40,
    'linked corners must not be held back')
  eq(card.corner.index, 4)
end)

local function approachBusy(busyUntilM, speedMs)
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(plan)
  local dt, dist, log = 1 / 60, 0, {}
  while dist < track.corners[1].apexM do
    local _, events = pilot:update(dist / track.lengthM, speedMs, dt, { busy = dist < busyUntilM })
    for _, ev in ipairs(events) do log[#log + 1] = { kind = ev.kind, distM = dist } end
    dist = dist + speedMs * dt
  end
  return log
end
test('while the driver is in trouble the co-driver waits, then speaks at once', function()
  local free = firstOf(approachBusy(0, 30), 'corner')
  local held = firstOf(approachBusy(110, 30), 'corner')
  check(free and held)
  check(free.distM < 100, 'fixture: normally called early, at ' .. free.distM .. ' m')
  near(held.distM, 110, 1.5, 'called the moment the trouble is over')
end)
test('but never so long that the brake cue arrives unannounced', function()
  local log = approachBusy(1e9, 45)            -- in trouble the whole way
  local called, cue = firstOf(log, 'corner'), firstOf(log, 'brake')
  check(called and cue, 'both must still happen')
  check(called.distM < cue.distM, 'callout at ' .. called.distM .. ', brake at ' .. cue.distM)
  local gapS = (cue.distM - called.distM) / 45
  check(gapS >= 0.5, 'only ' .. gapS .. ' s between the callout and the brake cue')
end)
test('after a recovery the corner ahead is called again', function()
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(plan)
  local pos = (track.corners[1].startM - 100) / track.lengthM
  local _, events = pilot:update(pos, 30, 1 / 60)
  eq(events[1] and events[1].kind, 'corner')
  _, events = pilot:update(pos, 30, 1 / 60)
  eq(#events, 0, 'not repeated on its own')
  pilot:reorient()
  _, events = pilot:update(pos, 30, 1 / 60)
  eq(events[1] and events[1].kind, 'corner', 'repeated after reorient()')
end)
test('how early corners are called can be changed', function()
  local function calledAt(lead)
    local pilot = Pilot.new(track, config.pilot)
    pilot:setPlan(plan)
    local dist = 0
    while dist < track.corners[1].apexM do
      local _, events = pilot:update(dist / track.lengthM, 30, 1 / 60, { callLeadS = lead })
      if events[1] and events[1].kind == 'corner' then return dist end
      dist = dist + 0.5
    end
  end
  local early, late = calledAt(6), calledAt(2)
  check(early and late and late > early + 40, 'early ' .. tostring(early) .. ' m, late ' .. tostring(late) .. ' m')
end)
test('sailing past the benchmark brake point unbraked gets a second, single reminder', function()
  local apex = track.corners[1].apexM
  local function cues(thePlan, brakePedal)
    local pilot = Pilot.new(track, config.pilot)
    pilot:setPlan(thePlan)
    local dt, dist, out = 1 / 60, 5, {}
    while dist < apex do
      local _, events = pilot:update(dist / track.lengthM, 50, dt, { brake = brakePedal })
      for _, ev in ipairs(events) do
        if ev.kind == 'brake' then out[#out + 1] = { distM = dist, again = ev.again } end
      end
      dist = dist + 50 * dt
    end
    return out
  end
  local ignored = cues(bench, 0)
  eq(#ignored, 2, 'cue plus one reminder')
  eq(ignored[2].again, true)
  check((ignored[2].distM - ignored[1].distM) / 50 >= config.pilot.reCueS - 0.02, 'not sooner than the delay')
  eq(#cues(bench, 0.9), 0, 'already braking: nothing to say')
  eq(#cues(plan, 0), 1, 'the cautious estimate does not nag')
  -- Someone who brakes when told to hears it once.
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(bench)
  local dt, dist, heard = 1 / 60, 5, 0
  while dist < apex do
    local _, events = pilot:update(dist / track.lengthM, 50, dt, { brake = heard > 0 and 0.9 or 0 })
    for _, ev in ipairs(events) do if ev.kind == 'brake' then heard = heard + 1 end end
    dist = dist + 50 * dt
  end
  eq(heard, 1, 'braking after the cue: no reminder')
end)
test('"brake" is never repeated in a burst for a gentle braker', function()
  -- A driver who slows at half the benchmark's rate skims along under the
  -- braking curve for a long time. That used to fire the cue every frame.
  local c = track.corners[1]
  local pilot = Pilot.new(track, config.pilot)
  pilot:setPlan(bench)
  local dt, dist, v, times = 1 / 60, 5, 55, {}
  local clock = 0
  while dist < c.apexM do
    local braking = dist > 60
    if braking then v = math.max(bench.targets[1].minKmh / 3.6, v - 0.5 * 9.81 * dt) end
    local card, events = pilot:update(dist / track.lengthM, v, dt, { brake = braking and 0.5 or 0, gas = braking and 0 or 1 })
    for _, ev in ipairs(events) do if ev.kind == 'brake' then times[#times + 1] = clock end end
    dist, clock = dist + v * dt, clock + dt
    if braking and v < bench.env[Track.cellAt(track, dist / track.lengthM)] then
      check(card.cue ~= 'brake', 'no red BRAKE card for a driver who is braking and under the curve, at ' .. dist .. ' m')
    end
  end
  check(#times <= config.pilot.maxBrakeCues, 'said ' .. #times .. ' times')
  for i = 2, #times do
    check(times[i] - times[i - 1] >= config.pilot.brakeCueGapS - 0.02, 'two cues too close together')
  end
end)
test('feedback targets exist for the exit of every corner', function()
  for k = 1, 7 do
    local es, full = bench.exitSegs[k], segs[k]
    check(es and es.cells <= full.cells, 'T' .. k .. ' exit segment')
    eq(es.from, full.from)
    check(bench.exitTargets[k], 'T' .. k .. ' exit target')
    check(bench.exitSlices[k].timeMs <= bench.slices[k].timeMs, 'T' .. k .. ' exit comes no later')
    eq(bench.exitTargets[k].brakeCell, bench.targets[k].brakeCell, 'T' .. k .. ' same brake point')
    near(bench.exitTargets[k].minKmh, bench.targets[k].minKmh, 1e-9)
  end
  -- On the long straights the exit point is well before the end of the segment.
  check(bench.exitSegs[1].cells < segs[1].cells - 20, 'T1 feedback comes early')
end)

-- Live coach ------------------------------------------------------------------

local Live = require('src/live')
print('live coach')

-- Drives from fromM to toM. By default the driver copies the benchmark
-- exactly; act(distM, ref) may return overrides { v =, gas =, brake =, off =,
-- busy =, pilotCue =, turnCue =, lineCue =, max = } for that frame.
local function coachRun(thePlan, fromM, toM, act)
  local lap = thePlan.lap
  local live = Live.new(track, config.live)
  live:setPlan(thePlan)
  local dt, dist, said, gauge = 1 / 60, fromM, {}, nil
  local n = track.n
  while dist < toM do
    local pos = (dist / track.lengthM) % 1
    local cell = Track.cellAt(track, pos)
    local ref = { v = lap.v[cell], gas = lap.gas[cell], brake = lap.brake[cell] }
    local o = act and act(dist % track.lengthM, ref, cell) or {}
    local v = o.v or ref.v
    local x, z = Recorder.valueAt(lap, 'x', pos), Recorder.valueAt(lap, 'z', pos)
    if o.off then
      local i0, i1 = U.wrapIndex(cell - 2, n), U.wrapIndex(cell + 2, n)
      local dx, dz = lap.x[i1] - lap.x[i0], lap.z[i1] - lap.z[i0]
      local len = math.sqrt(dx * dx + dz * dz)
      x, z = x - dz / len * o.off, z + dx / len * o.off
    end
    local events
    gauge, events = live:update({
      cell = cell, pos = pos, v = v, gas = o.gas or ref.gas, brake = o.brake or ref.brake, x = x, z = z,
      busy = o.busy, pilotCue = o.pilotCue, turnCue = o.turnCue, lineCue = o.lineCue, maxPerCorner = o.max,
    }, dt)
    for _, ev in ipairs(events) do
      said[#said + 1] = { id = ev.id, distM = dist, k = ev.corner.index, urgent = ev.urgent }
    end
    dist = dist + math.max(5, v / 3.6) * dt
  end
  return said, gauge, live
end
local function ids(said)
  local out = {}
  for i, e in ipairs(said) do out[i] = e.id .. '@T' .. e.k end
  return table.concat(out, ' ')
end
local function find(said, id)
  for _, e in ipairs(said) do if e.id == id then return e end end
end
local T2 = track.corners[2]
local t2 = bench.targets[2]
local t2BrakeM = track.s[t2.brakeCell]
local t2MinM = track.s[t2.minCell]

test('fixture: the benchmark brakes for T2 well before the corner', function()
  check(t2BrakeM < T2.startM - 30 and t2MinM > t2BrakeM + 40, 'brake at ' .. t2BrakeM .. ', slowest at ' .. t2MinM)
end)
test('a driver who copies the benchmark is only told where to turn in', function()
  local said, gauge = coachRun(bench, 5, track.lengthM + 5)
  for _, e in ipairs(said) do eq(e.id, 'turnIn', 'unexpected cue ' .. ids(said)) end
  check(#said >= 4, 'turn-in for the main corners: ' .. ids(said))
  for _, e in ipairs(said) do
    local c = track.corners[e.k]
    near(e.distM % track.lengthM, c.startM, 25, 'turn-in for ' .. c.name .. ' comes at the corner')
  end
  check(not find(said, 'x') and not ids(said):find('@T4') and not ids(said):find('@T5'),
    'the second and third part of a chicane get no turn-in call: ' .. ids(said))
  near(gauge.dv, 0, 0.01, 'speed difference')
  near(gauge.offLeftM, 0, 0.05, 'on the line')
end)
test('"turn in" can be switched off', function()
  local said = coachRun(bench, 5, track.lengthM + 5, function() return { turnCue = false } end)
  eq(#said, 0, ids(said))
end)
test('braking long before the benchmark: "too early", then "ease off"', function()
  local said = coachRun(bench, t2BrakeM - 160, T2.startM - 5, function(m, ref)
    if m > t2BrakeM - 100 then
      -- On the brakes 100 m early, and 20% under the benchmark's speed from then on.
      return { brake = 0.7, gas = 0, v = ref.v * (m > t2BrakeM - 60 and 0.8 or 1) }
    end
  end)
  local early, ease = find(said, 'tooEarly'), find(said, 'easeOff')
  check(early and ease, 'both cues: ' .. ids(said))
  eq(early.k, 2)
  check(early.distM < t2BrakeM - 80, 'said at once, at ' .. early.distM .. ' m')
  check(ease.distM >= t2BrakeM and ease.distM < t2MinM, 'ease off comes inside the braking zone')
  eq(#said, 2, 'each said once: ' .. ids(said))
end)
test('arriving faster and braking gently: "brake harder", urgently', function()
  local function run(pedal, extra)
    return coachRun(bench, t2BrakeM - 60, t2MinM - 20, function(m, ref)
      local o = { turnCue = false }
      if m > t2BrakeM + 5 then o.v, o.brake, o.gas = ref.v + 14, pedal, 0 end
      for k, v in pairs(extra or {}) do o[k] = v end
      return o
    end)
  end
  local said = run(0.4)
  local harder = find(said, 'brakeHarder')
  check(harder, 'cue expected: ' .. ids(said))
  eq(harder.urgent, true)
  check(harder.distM < t2BrakeM + 40, 'within half a second, at ' .. (harder.distM - t2BrakeM) .. ' m into the zone')
  eq(#said, 1, 'once: ' .. ids(said))
  eq(#run(0.95), 0, 'already braking as hard as possible: nothing useful to add')
  check(find(run(0.4, { pilotCue = 'brake' }), 'brakeHarder'), 'it may speak over the red BRAKE card')
  eq(#run(0.4, { busy = true }), 0, 'never while the driver is busy with a slide')
end)
test('on the throttle mid-corner before the benchmark: "wait"', function()
  -- The synthetic benchmark holds part throttle through corners. Give it a
  -- realistic trace: off the throttle from turn-in until 10 m past the apex.
  local lap = copyLap(teacherLap)
  local cells = U.forward(T2.startCell, T2.apexCell, track.n) + 5
  for j = -10, cells do lap.gas[U.wrapIndex(T2.startCell + j, track.n)] = 0 end
  local plan2 = Targets.build(track, lap, segs, config.targets, config.metrics)
  local function run(scale)
    return coachRun(plan2, T2.startM - 30, T2.endM, function(m, ref)
      if m > T2.startM + 4 then return { gas = 0.8, v = ref.v * scale, turnCue = false } end
      return { turnCue = false }
    end)
  end
  local said = run(1)
  check(find(said, 'wait'), 'cue expected: ' .. ids(said))
  eq(find(said, 'wait').k, 2)
  eq(#said, 1, ids(said))
  eq(find(run(0.8), 'wait'), nil, 'a driver who is much slower may use the throttle')
end)
test('lifting on a straight: "stay flat"; part throttle on an exit: "full throttle"', function()
  local c1 = track.corners[1]
  local mid = c1.endM + 170
  check(teacherLap.gas[Track.cellAt(track, mid / track.lengthM)] > 0.9, 'fixture: flat out mid-straight')
  local said = coachRun(bench, c1.endM + 150, c1.endM + 280, function(m)
    if m > mid and m < mid + 80 then return { gas = 0 } end
  end)
  eq(ids(said), 'stayFlat@T2')
  check(said[1].distM - mid < 45, 'after about half a second')
  local exit = coachRun(bench, c1.apexM, c1.endM + 140, function(m)
    if m > c1.endM then return { gas = 0.5 } end
  end)
  eq(ids(exit), 'fullThrottle@T1')
  local twice = coachRun(bench, c1.endM + 150, c1.endM + 290, function(m)
    if (m > mid and m < mid + 40) or m > mid + 70 then return { gas = 0 } end
  end)
  eq(#twice, 1, 'once per straight: ' .. ids(twice))
end)
test('braking for a corner the benchmark only lifts for: "no brake"', function()
  local lap = copyLap(teacherLap)
  local c7 = track.corners[7]
  local from = Track.cellAt(track, (c7.startM - 200) / track.lengthM)
  for j = 0, U.forward(from, c7.endCell, track.n) do
    local i = U.wrapIndex(from + j, track.n)
    lap.brake[i] = 0
  end
  local plan2 = Targets.build(track, lap, segs, config.targets, config.metrics)
  eq(plan2.targets[7].brakeCell, nil, 'fixture: no brake point for T7')
  local said = coachRun(plan2, c7.startM - 120, c7.apexM, function(m)
    if m > c7.startM - 50 then return { brake = 0.5, gas = 0, turnCue = false } end
    return { turnCue = false }
  end)
  eq(ids(said), 'noBrake@T7')
end)
test('off the line on the way in: "move right" / "move left"', function()
  local function run(off, extra)
    return coachRun(bench, T2.startM - 220, T2.startM - 15, function()
      local o = { off = off, turnCue = false }
      for k, v in pairs(extra or {}) do o[k] = v end
      return o
    end)
  end
  local said, gauge = run(3.2)
  eq(ids(said), 'moveRight@T2')
  near(gauge.offLeftM, 3.2, 0.2, 'gauge shows the offset')
  eq(ids((run(-3.2))), 'moveLeft@T2')
  eq(#run(1.5), 0, 'a metre and a half is close enough')
  eq(#run(3.2, { lineCue = false }), 0, 'can be switched off')
end)
test('never more than the cap per corner, and silent without a benchmark', function()
  local said = coachRun(bench, t2BrakeM - 220, T2.startM - 5, function(m, ref)
    local o = { off = 4, turnCue = false, max = 2 }
    if m > t2BrakeM - 100 then o.brake, o.gas, o.v = 0.7, 0, ref.v * 0.8 end
    return o
  end)
  eq(#said, 2, 'three things were wrong, two were said: ' .. ids(said))
  local live = Live.new(track, config.live)
  live:setPlan(nil)
  local gauge, events = live:update({ cell = 1, pos = 0, v = 100, gas = 0, brake = 1 }, 1 / 60)
  eq(gauge.active, false)
  eq(#events, 0)
end)

-- Lesson plan -----------------------------------------------------------------

local Lesson = require('src/lesson')
print('lesson plan')
local LC = config.lesson
local function res(id, lossMs, value) return { id = id, lossMs = lossMs, value = value, good = id == 'ok' or id == 'gain' } end

test('picks the corner with the biggest typical loss that has a cause', function()
  local lesson = Lesson.new(7, LC)
  lesson:record(1, res('brakeEarly', 300, 30))
  lesson:record(2, res('overSlow', 700, 12))
  lesson:record(3, res('slower', 900))            -- no cause to give an instruction for
  lesson:record(4, res('ok', 20))
  lesson:record(5, res('throttleLate', 90, 12))   -- too small to bother with
  local sum = lesson:lapDone(60000, true)
  eq(sum.changed, true)
  eq(sum.focus.k, 2)
  eq(sum.focus.id, 'overSlow')
  eq(sum.worstK, 3, 'the summary still names the biggest loss')
end)
test('one bad pass does not outweigh two good ones', function()
  local lesson = Lesson.new(3, LC)
  lesson:record(1, res('ok', 30))
  lesson:record(1, res('ok', 40))
  lesson:record(1, res('offTrack', 100))
  lesson:record(2, res('brakeEarly', 250, 20))
  lesson:record(2, res('brakeEarly', 260, 22))
  lesson:record(2, res('overSlow', 240, 8))
  local focus = lesson:choose()
  eq(focus.k, 2)
  eq(focus.id, 'brakeEarly', 'the cause seen most often')
  near(focus.baseMs, 250, 0.1, 'median loss')
end)
test('a focus corner is worked on until it is sorted, then the next one is named', function()
  local lesson = Lesson.new(3, LC)
  lesson:record(1, res('brakeEarly', 800, 40))
  lesson:record(2, res('throttleLate', 300, 20))
  lesson:lapDone(60000, true)
  eq(lesson.focus.k, 1)
  local v = lesson:record(1, res('brakeEarly', 500, 25))
  eq(v.focus, true)
  eq(v.kind, 'better')
  near(v.prevMs, 800, 0.1)
  eq(lesson.focus.value, 25, 'the instruction follows the latest attempt')
  v = lesson:record(1, res('overSlow', 250, 6))
  eq(v.kind, 'good', 'under 40% of where it started')
  eq(lesson:settle(1, 30000, 260, true), nil, 'one good pass is not enough')
  v = lesson:record(1, res('brakeEarly', 600, 30))
  eq(v.kind, 'worse')
  eq(lesson.focus.streak, 0, 'a miss starts the count again')
  lesson:settle(1, 30000, 600, true)
  lesson:record(1, res('ok', 60))
  eq(lesson:settle(1, 30000, 70, true), nil)
  v = lesson:record(1, res('ok', 40))
  eq(v.kind, 'good')
  check(lesson.focus, 'not sorted until the whole segment has been driven')
  local done = lesson:settle(1, 30000, 50, true)
  eq(done.kind, 'fixed')
  eq(#lesson.fixed, 1)
  eq(lesson.fixed[1].k, 1)
  near(done.fromMs, 800, 0.1)
  near(done.toMs, 50, 0.1)
  check(done.next and done.next.k == 2 and done.next.id == 'throttleLate', 'moves straight on to the next corner')
  eq(lesson.focus, done.next)
end)
test('a loss that only shows on the following straight is not praised at the exit', function()
  -- Late on the throttle: 100 ms lost by the exit, 430 ms by the end of the straight.
  local lesson = Lesson.new(2, LC)
  lesson:record(1, res('throttleLate', 100, 20))
  lesson:settle(1, 30000, 430, true)
  lesson:lapDone(60000, true)
  eq(lesson.focus.k, 1)
  near(lesson.focus.baseMs, 430, 0.1)
  near(lesson.focus.baseExitMs, 100, 0.1)
  local v = lesson:record(1, res('ok', 70))
  check(v.kind ~= 'good', '70 ms at the exit is barely better than 100: ' .. v.kind)
  lesson:settle(1, 30000, 380, true)
  -- Looks sorted at the exit twice, but the second time the straight says otherwise.
  eq(lesson:record(1, res('ok', 20)).kind, 'good')
  eq(lesson:settle(1, 30000, 60, true), nil)
  eq(lesson:record(1, res('ok', 25)).kind, 'good')
  eq(lesson:settle(1, 30000, 300, true), nil, 'taken back')
  eq(lesson.focus.streak, 0)
  eq(#lesson.fixed, 0)
end)
test('a corner that will not come good is parked, and comes back later', function()
  local lesson = Lesson.new(2, LC)
  lesson:record(1, res('brakeEarly', 900, 40))
  lesson:record(2, res('wide', 400, 3))
  lesson:lapDone(60000, true)
  eq(lesson.focus.k, 1)
  local v
  for _ = 1, LC.parkAfter do v = lesson:record(1, res('brakeEarly', 900, 40)) end
  eq(v.kind, 'parked')
  eq(lesson.focus.k, 2, 'works on something else meanwhile')
  eq(lesson:ranking()[1].parked, true)
  for _ = 1, LC.parkPasses do lesson:record(1, res('brakeEarly', 900, 40)) end
  lesson.focus = nil
  eq(lesson:choose().k, 1, 'and returns to it')
end)
test('brake points move in steps, not all at once', function()
  eq(Lesson.stepM(69, LC), 25)
  eq(Lesson.stepM(30, LC), 15)
  eq(Lesson.stepM(12, LC), 5)
  eq(Lesson.stepM(3, LC), 5)
end)
test('ideal lap, consistency, skills and training steps', function()
  local lesson = Lesson.new(2, LC)
  eq(lesson:ideal(), nil)
  eq(lesson:consistency(), nil)
  local d1 = { braking = true, brakeDiffM = 20, minDiffKmh = -6, throttleDiffM = 8, exitDiffKmh = 4, wideM = 1 }
  local d2 = { braking = false, minDiffKmh = 1, exitDiffKmh = -2, wideM = -0.5 }
  lesson:record(1, res('brakeEarly', 400, 20), d1)
  lesson:record(2, res('ok', 20), d2)
  lesson:settle(1, 30500, 450, true)
  lesson:settle(2, 30000, 30, true)
  lesson:settle(1, 30200, 300, true)
  lesson:settle(1, 29000, 100, false)             -- an off-track pass is not a time you can count on
  eq(lesson:ideal(), 60200)
  eq(lesson.corners[1].passes[1].lossMs, 100, 'the full-segment loss replaces the one measured at the exit')
  local skills = lesson:skills()
  eq(skills.braking, 50, '20 m out')
  eq(skills.speed, 85, '6 and 0 km/h slow')
  eq(skills.line, 85, '1 m and 0.5 m off')
  eq(skills.exits, 75, '8 m late where it was measured, 4 km/h down in one of two corners')
  eq(skills.consistency, nil, 'not enough laps yet')
  for _, ms in ipairs({ 61000, 60400, 60600 }) do lesson:lapDone(ms, true) end
  local cons = lesson:consistency()
  near(cons.spreadMs, 600, 0.1)
  check(lesson:skills().consistency > 80)
  local st = {}
  for _, s in ipairs(lesson:stages()) do st[s.id] = s end
  eq(st.clean.done, true, 'three clean laps')
  eq(st.braking.done, false, 'the one braking corner is 20 m out')
  eq(st.braking.need, 1)
  eq(st.speed.have, 1, 'one of two corners within 5 km/h')
  eq(st.exits.done, true)
  eq(st.consistency.have, 2, '60.4 and 60.6 are within half a second, 61.0 is not')
  eq(lesson:stage().id, 'braking', 'the first step that is still open')
  lesson:lapDone(90000, false)
  eq(lesson:stages()[1].done, true, 'a step stays done once reached')
  eq(lesson.cleanStreak, 0)
end)
test('a new benchmark starts the corner history afresh but keeps the laps', function()
  local lesson = Lesson.new(2, LC)
  lesson:record(1, res('brakeEarly', 400, 20))
  lesson:lapDone(60000, true)
  check(lesson.focus)
  lesson:rebase()
  eq(lesson.focus, nil)
  eq(#lesson:ranking(), 0)
  eq(#lesson.lapTimes, 1)
end)
test('the coach turns a corner into plain numbers', function()
  local ref = { timeMs = 5000, brakeRelM = -60, minKmh = 80, throttleRelM = 5, exitKmh = 120 }
  local got = { timeMs = 5400, brakeRelM = -85, minKmh = 74, throttleRelM = 20, exitKmh = 113 }
  local d = Coach.detail(ref, got, { wideM = 1.5, offTrack = false })
  eq(d.lossMs, 400)
  eq(d.brakeDiffM, 25)
  eq(d.minDiffKmh, -6)
  eq(d.throttleDiffM, 15)
  eq(d.exitDiffKmh, 7)
  eq(d.braking, true)
  local lift = Coach.detail({ timeMs = 1, minKmh = 1, exitKmh = 1 }, { timeMs = 1, minKmh = 1, exitKmh = 1, brakeRelM = -5 })
  eq(lift.braking, false)
  eq(lift.brakeDiffM, nil)
end)
test('session history survives a round trip to disk', function()
  local list = {
    { at = 1731200000, best = 83456, bench = 80123, laps = 12, valid = 9, braking = 72, speed = 64 },
    { at = 1731300000, best = 82990, laps = 8, valid = 8, ideal = 82500, consistency = 55.4 },
  }
  local back = Reference.decodeHistory(Reference.encodeHistory(list))
  eq(#back, 2)
  eq(back[1].best, 83456)
  eq(back[1].braking, 72)
  eq(back[2].bench, nil)
  eq(back[2].consistency, 55)
  eq(#Reference.decodeHistory('garbage'), 0)
  eq(#Reference.decodeHistory(nil), 0)
  local saved = {}
  local ref = Reference.new({ dir = 'D', save = function(p, t) saved[p] = t return true end, load = function(p) return saved[p] end })
  for i = 1, 5 do list[#list + 1] = { at = i, laps = i } end
  check(ref:saveHistory('ks_track', 'car', list, 4))
  eq(#ref:loadHistory('ks_track', 'car'), 4, 'only the newest are kept')
  eq(#ref:loadHistory('other', 'car'), 0)
end)

-- Updater -----------------------------------------------------------------------

local Updater = require('src/updater')
print('updater')
test('checksums and version numbers', function()
  eq(Updater.checksum('Wikipedia'), 0x11E60398)
  eq(Updater.checksum(''), 1)
  check(Updater.newer('0.4.1', '0.4.0'))
  check(Updater.newer('0.10.0', '0.9.9'))
  check(Updater.newer('1.0', '0.99.99'))
  check(not Updater.newer('0.4.0', '0.4.0'))
  check(not Updater.newer('0.3.9', '0.4.0'))
  check(not Updater.newer('banana', '0.4.0'))
end)
test('the update list round-trips, and refuses anything suspicious', function()
  local files = { { path = 'src/app.lua', data = 'return 1\n' }, { path = 'PaceCoach.lua', data = string.rep('\0\255x', 50) } }
  local text = Updater.encode('1.2.3', 'What is new', files)
  local list = Updater.parse(text)
  eq(list.version, '1.2.3')
  eq(list.notes, 'What is new')
  eq(#list.files, 2)
  eq(list.files[2].size, 150)
  eq(list.files[2].sum, Updater.checksum(files[2].data))
  eq(Updater.parse('<html>404</html>'), nil)
  for _, bad in ipairs({ '../evil.lua', '/etc/passwd', 'C:/x.lua', 'src\\app.lua', 'a b.lua', '.hidden', 'src//x.lua', 'src/' }) do
    eq(Updater.parse('PACECOACH-UPDATE 1\nversion=1.0\nfile=1 00000001 ' .. bad .. '\n'), nil, 'must refuse ' .. bad)
  end
  eq(Updater.parse('PACECOACH-UPDATE 1\nversion=1.0\n'), nil, 'empty list')
  eq(Updater.parse(text, { maxFiles = 1 }), nil, 'too many files')
  eq(Updater.parse(text, { maxBytes = 100 }), nil, 'too many bytes')
end)

-- A tiny fake GitHub and a fake disk.
local function updateWorld(version, opts)
  opts = opts or {}
  local base = 'https://example.test/app/'
  local files = {
    { path = 'PaceCoach.lua', data = 'entry ' .. version },
    { path = 'src/app.lua', data = 'app ' .. version },
    { path = 'sounds/deep/a.wav', data = string.rep('\0\1\2', 400) },
  }
  local web = { [base .. 'update.txt'] = Updater.encode(version, 'notes', files) }
  for _, f in ipairs(files) do web[base .. f.path] = f.data end
  local w = { web = web, saved = {}, order = {}, dirs = {}, disk = opts.disk or {}, requests = 0, base = base }
  w.updater = Updater.new({
    base = base, list = 'update.txt', dir = 'APP', current = '0.4.0',
    get = function(url, cb)
      w.requests = w.requests + 1
      if opts.offline then cb('no network') return end
      local body = w.web[url]
      if body then cb(nil, 200, body) else cb(nil, 404, 'Not Found') end
    end,
    save = function(path, data)
      if opts.readOnly and path:find('PaceCoach.lua', 1, true) then return false end
      w.saved[path], w.order[#w.order + 1] = data, path
      return true
    end,
    mkdir = function(path) w.dirs[#w.dirs + 1] = path end,
    load = function(path)
      local data = w.saved[path] or w.disk[path]
      if data and opts.lossy then return (data:gsub('%z.*', '')) end    -- cuts at the first zero byte
      return data
    end,
  })
  return w
end
local function fetch(u)
  for _ = 1, 1000 do
    if u.state ~= 'downloading' then return end
    u:pump()
  end
  error('the updater never finished')
end
test('a newer version is downloaded, checked, and only then installed', function()
  local w = updateWorld('0.5.0')
  local u = w.updater
  eq(u.state, 'idle')
  u:check()
  eq(u.state, 'available')
  eq(u.remote.version, '0.5.0')
  eq(next(w.saved), nil)
  check(u:install())
  eq(u.state, 'downloading')
  u:pump()
  eq(u.progress, 1, 'one file per call')
  fetch(u)
  eq(u.state, 'ready', 'downloaded, waiting for a good moment')
  eq(u.progress, 3)
  eq(next(w.saved), nil, 'nothing written before apply()')
  check(u:apply())
  eq(u.state, 'done')
  eq(u.installed, '0.5.0')
  eq(w.saved['APP/src/app.lua'], 'app 0.5.0')
  eq(#w.saved['APP/sounds/deep/a.wav'], 1200, 'binary data arrives whole')
  eq(w.order[#w.order], 'APP/PaceCoach.lua', 'the entry file is written last')
  eq(w.order[1], 'APP/update-check.bin', 'a write test comes before anything else')
  eq(table.concat(w.dirs, ' '), 'APP/src APP/sounds APP/sounds/deep', 'folders are made first, parents before children')
  eq(u:check(), false, 'nothing more to do this session')
end)
test('files that are already on disk unchanged are not downloaded again', function()
  local w = updateWorld('0.5.0', { disk = {
    ['APP/sounds/deep/a.wav'] = string.rep('\0\1\2', 400),      -- identical
    ['APP/src/app.lua'] = 'app 0.4.0',                             -- same length, older content
  } })
  local u = w.updater
  u:check()
  u:install()
  fetch(u)
  eq(u.state, 'ready')
  eq(u.skipped, 1)
  eq(w.requests, 3, 'the list and the two files that changed')
  check(u:apply())
  eq(w.saved['APP/sounds/deep/a.wav'], nil, 'the unchanged file is not rewritten')
  eq(w.saved['APP/src/app.lua'], 'app 0.5.0')
end)
test('the same or an older version is left alone', function()
  local w = updateWorld('0.4.0')
  w.updater:check()
  eq(w.updater.state, 'current')
  eq(w.updater:install(), false)
  local old = updateWorld('0.3.9')
  old.updater:check()
  eq(old.updater.state, 'current')
end)
test('a damaged download changes nothing on disk', function()
  local w = updateWorld('0.5.0')
  w.web[w.base .. 'src/app.lua'] = 'app 0.5.X'                 -- same length, different content
  w.updater:check()
  w.updater:install()
  fetch(w.updater)
  eq(w.updater.state, 'failed')
  check(w.updater.error:find('src/app.lua', 1, true) and w.updater.error:find('damaged', 1, true), w.updater.error)
  eq(next(w.saved), nil)
  eq(w.updater:apply(), false)
  local short = updateWorld('0.5.0')
  short.web[short.base .. 'sounds/deep/a.wav'] = 'cut off'
  short.updater:check()
  short.updater:install()
  fetch(short.updater)
  eq(short.updater.state, 'failed')
  eq(next(short.saved), nil)
  local missing = updateWorld('0.5.0')
  missing.web[missing.base .. 'PaceCoach.lua'] = nil
  missing.updater:check()
  missing.updater:install()
  fetch(missing.updater)
  eq(missing.updater.state, 'failed')
  eq(next(missing.saved), nil)
end)
test('a game build that damages binary files is noticed before anything is installed', function()
  local w = updateWorld('0.5.0', { lossy = true })
  local u = w.updater
  u:check()
  u:install()
  fetch(u)
  eq(u.state, 'ready')
  eq(u:apply(), false)
  eq(u.state, 'failed')
  check(u.error:find('cannot store the files safely', 1, true), u.error)
  eq(w.saved['APP/PaceCoach.lua'], nil)
  eq(w.saved['APP/src/app.lua'], nil)
  eq(w.saved['APP/sounds/deep/a.wav'], nil)
end)
test('no network, a broken list and a read-only folder are reported plainly', function()
  local off = updateWorld('0.5.0', { offline = true })
  off.updater:check()
  eq(off.updater.state, 'failed')
  check(off.updater.error:find('could not reach GitHub', 1, true), off.updater.error)
  check(off.updater:check(), 'trying again is allowed')
  local broken = updateWorld('0.5.0')
  broken.web[broken.base .. 'update.txt'] = '<html>rate limited</html>'
  broken.updater:check()
  eq(broken.updater.state, 'failed')
  local ro = updateWorld('0.5.0', { readOnly = true })
  ro.updater:check()
  ro.updater:install()
  fetch(ro.updater)
  eq(ro.updater:apply(), false)
  eq(ro.updater.state, 'failed')
  check(ro.updater.error:find('could not write PaceCoach.lua', 1, true), ro.updater.error)
end)

print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
