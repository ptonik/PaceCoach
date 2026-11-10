-- Synthetic tracks and laps with known answers, for testing without the game.

local Synth = {}

local G = 9.81

-- segments: list of { 's', lengthM } and { 'a', radiusM, angleDeg }.
-- A positive angle turns left (heading rises in the x/z plane).
-- Returns n evenly spaced points, the length, and how far the loop misses closing.
function Synth.line(segments, n)
  local step = 0.1
  local fine, x, z, th = { { x = 0, z = 0 } }, 0, 0, 0
  for _, seg in ipairs(segments) do
    if seg[1] == 's' then
      local k = math.max(1, math.floor(seg[2] / step + 0.5))
      local d = seg[2] / k
      for _ = 1, k do
        x, z = x + math.cos(th) * d, z + math.sin(th) * d
        fine[#fine + 1] = { x = x, z = z }
      end
    else
      local radius, ang = seg[2], math.rad(seg[3])
      local k = math.max(1, math.floor(radius * math.abs(ang) / step + 0.5))
      local dth = ang / k
      local chord = 2 * radius * math.sin(math.abs(dth) / 2)
      for _ = 1, k do
        local mid = th + dth / 2
        x, z = x + math.cos(mid) * chord, z + math.sin(mid) * chord
        th = th + dth
        fine[#fine + 1] = { x = x, z = z }
      end
    end
  end
  local closure = math.sqrt(x * x + z * z)

  local cum = { 0 }
  for i = 2, #fine do
    local dx, dz = fine[i].x - fine[i - 1].x, fine[i].z - fine[i - 1].z
    cum[i] = cum[i - 1] + math.sqrt(dx * dx + dz * dz)
  end
  local length = cum[#cum]
  local points, j = {}, 1
  for i = 1, n do
    local target = (i - 1) / n * length
    while j < #fine - 1 and cum[j + 1] < target do j = j + 1 end
    local span = cum[j + 1] - cum[j]
    local f = (span > 0) and ((target - cum[j]) / span) or 0
    points[i] = {
      x = fine[j].x + (fine[j + 1].x - fine[j].x) * f,
      z = fine[j].z + (fine[j + 1].z - fine[j].z) * f,
    }
  end
  return points, length, closure
end

-- A 600 x 400 m rectangle driven clockwise, every corner a different radius,
-- with a left-right-left chicane on the back straight. Known answers:
--   T1 right R15   T2 right R30   T3 left R30 (30 deg)   T4 right R30 (60 deg)
--   T5 left R30 (30 deg)   T6 right R60   T7 right R120
function Synth.rectangle()
  return {
    { 's', 232.5 },
    { 'a', 15, -90 },
    { 's', 355 },
    { 'a', 30, -90 },
    { 's', 200 },
    { 'a', 30, 30 }, { 'a', 30, -60 }, { 'a', 30, 30 },
    { 's', 250 },
    { 'a', 60, -90 },
    { 's', 220 },
    { 'a', 120, -90 },
    { 's', 232.5 },
  }
end

-- Speed profile (m/s per point) for a car with the given limits.
function Synth.profile(track, o)
  local n, v = track.n, {}
  for i = 1, n do
    local kappa = math.abs(track.curv[i])
    v[i] = o.vmaxMs
    if kappa > 1e-4 then v[i] = math.min(o.vmaxMs, math.sqrt(o.latG * G / kappa)) end
  end
  for _ = 1, 2 do
    for j = n, 1, -1 do
      local nxt = (j % n) + 1
      v[j] = math.min(v[j], math.sqrt(v[nxt] ^ 2 + 2 * o.brakeG * G * track.ds[j]))
    end
    for j = 1, n do
      local nxt = (j % n) + 1
      v[nxt] = math.min(v[nxt], math.sqrt(v[j] ^ 2 + 2 * o.accelG * G * track.ds[j]))
    end
  end
  if o.scale then
    for i = 1, n do v[i] = v[i] * o.scale end
  end
  return v
end

local function at(arr, f, n)
  local i0 = (math.floor(f) % n) + 1
  local i1 = (i0 % n) + 1
  return arr[i0] + (arr[i1] - arr[i0]) * (f - math.floor(f))
end

-- Drives the profile for `laps` laps plus a little more, at `hz` samples per second.
-- o: { latG, brakeG, accelG, vmaxMs, scale, hz, laps, startPos }
-- Returns the samples and the true lap time in ms.
function Synth.drive(track, o)
  local n, length = track.n, track.lengthM
  local v = Synth.profile(track, o)
  local dt = 1 / (o.hz or 60)
  local xs, zs = {}, {}
  for i = 1, n do xs[i], zs[i] = track.points[i].x, track.points[i].z end

  -- True lap time by integrating ds / v.
  local lapS = 0
  for i = 1, n do
    local nxt = (i % n) + 1
    lapS = lapS + track.ds[i] / ((v[i] + v[nxt]) / 2)
  end

  local samples = {}
  local dist = (o.startPos or 0) * length
  local t, lapCount = 0, 0
  local stopAt = (o.laps or 2) * length + 30 + dist
  local travelled = dist
  while travelled < stopAt do
    local f = dist / length * n
    local speed = at(v, f, n)
    local ahead = at(v, f + 2, n)
    local accel = (ahead - speed) / (2 * track.cellM) * speed
    local gas, brake = 0.4, 0
    if accel > 0.3 then
      gas = math.min(1, accel / (o.accelG * G))
    elseif accel < -0.5 then
      gas, brake = 0, math.min(1, -accel / (o.brakeG * G))
    end
    local kappa = at(track.curv, f, n)
    samples[#samples + 1] = {
      pos = dist / length, t = t * 1000, lapCount = lapCount, dt = dt,
      v = speed * 3.6, speedMs = speed, gas = gas, brake = brake,
      steer = math.deg(math.atan(2.6 * kappa)) * 12,
      gear = math.min(6, 1 + math.floor(speed * 3.6 / 45)),
      x = at(xs, f, n), z = at(zs, f, n),
    }
    local move = speed * dt
    dist, travelled, t = dist + move, travelled + move, t + dt
    if dist >= length then
      -- Carry the part of the frame that happened after the line.
      dist = dist - length
      t = dist / speed
      lapCount = lapCount + 1
    end
  end
  return samples, lapS * 1000
end

-- A learner: a driver with flaws that can differ from corner to corner and
-- change from lap to lap, for testing what the coach says about them.
--
-- base:  { latG, brakeG, accelG, vmaxMs, hz }
-- flaws: corner index -> {
--   lat      scale on the grip used in this corner (0.8 = slow at the apex)
--   brake    g used when braking for this corner (lower = earlier and softer)
--   coastM   metres spent off both pedals after the end of the corner
--   off      metres to the left of the line on the way in (negative = right)
--   earlyGas true: on the throttle half way into the corner
--   lift     true: lifts off for 40 m on the straight before the corner
--   softBrake 0..1: pedal pressure used while arriving faster than the plan }
-- Returns a plan for Synth.lap.
function Synth.plan(track, base, flaws)
  flaws = flaws or {}
  local n, cellM, corners = track.n, track.cellM, track.corners
  local lat, brakeG, noAccel, off, gasSet = {}, {}, {}, {}, {}
  for i = 1, n do lat[i], brakeG[i], off[i] = 1, base.brakeG, 0 end
  local function span(from, cells, fn)
    for j = 0, math.max(0, cells) do fn(((from - 1 + j) % n) + 1) end
  end
  local function metres(m) return math.floor(m / cellM + 0.5) end
  for k, c in ipairs(corners) do
    local f = flaws[k] or {}
    local prev = corners[((k - 2) % #corners) + 1]
    span(c.startCell, (c.endCell - c.startCell) % n, function(i) lat[i] = f.lat or 1 end)
    local zone = (#corners > 1) and ((c.apexCell - prev.apexCell) % n) or n
    span(((c.apexCell - zone) % n) + 1, zone - 1, function(i) brakeG[i] = f.brake or base.brakeG end)
    if f.coastM then
      -- Off the throttle all the way through, and still off it this far past the exit.
      span(c.startCell, (c.endCell - c.startCell) % n, function(i) gasSet[i] = 0 end)
      span(c.endCell, metres(f.coastM), function(i) noAccel[i], gasSet[i] = true, 0 end)
    end
    if f.off then
      local room = (#corners > 1) and ((c.startCell - prev.endCell) % n) * cellM or 200
      local len = math.min(140, room - 30)
      if len > 20 then
        span(((c.startCell - metres(len) - 1) % n) + 1, metres(len - 6), function(i) off[i] = f.off end)
      end
    end
    if f.earlyGas then
      span(c.startCell, math.floor(((c.apexCell - c.startCell) % n) * 0.8), function(i) gasSet[i] = 0.75 end)
    end
    if f.lift then
      span(((c.startCell - metres(f.liftAtM or 230) - 1) % n) + 1, metres(40), function(i) gasSet[i] = 0 end)
    end
  end
  local v = {}
  for i = 1, n do
    local kappa = math.abs(track.curv[i])
    v[i] = base.vmaxMs
    if kappa > 1e-4 then v[i] = math.min(base.vmaxMs, math.sqrt(base.latG * lat[i] * G / kappa)) end
  end
  for _ = 1, 2 do
    for j = n, 1, -1 do
      local nxt = (j % n) + 1
      v[j] = math.min(v[j], math.sqrt(v[nxt] ^ 2 + 2 * brakeG[j] * G * track.ds[j]))
    end
    for j = 1, n do
      local nxt = (j % n) + 1
      local reach = noAccel[j] and v[j] or math.sqrt(v[j] ^ 2 + 2 * base.accelG * G * track.ds[j])
      v[nxt] = math.min(v[nxt], reach)
    end
  end
  return { v = v, off = off, gasSet = gasSet, brakeG = brakeG, base = base }
end

-- Advances the learner by one frame and returns the sample.
-- st carries distance, time and lap count: start with {}. Changing the plan
-- between frames is allowed; the speed blends over to the new one in a second.
function Synth.step(track, plan, st)
  local n, length, base = track.n, track.lengthM, plan.base
  local dt = 1 / (base.hz or 60)
  if not st.xs then
    st.xs, st.zs = {}, {}
    for i = 1, n do st.xs[i], st.zs[i] = track.points[i].x, track.points[i].z end
    st.dist, st.t, st.lapCount = st.dist or 0, st.t or 0, st.lapCount or 0
  end
  if st.plan ~= plan then
    st.old, st.blend = st.plan, st.plan and 0 or 1
    st.plan = plan
  end
  local f = st.dist / length * n
  local cell = (math.floor(f) % n) + 1
  local speed, ahead = at(plan.v, f, n), at(plan.v, f + 2, n)
  if st.blend < 1 then
    local w = st.blend
    speed = at(st.old.v, f, n) * (1 - w) + speed * w
    ahead = at(st.old.v, f + 2, n) * (1 - w) + ahead * w
    st.blend = math.min(1, st.blend + dt)
  end
  local accel = (ahead - speed) / (2 * track.cellM) * speed
  local gas, brake = 0.4, 0
  if accel > 0.3 then
    gas = math.min(1, accel / (base.accelG * G))
  elseif accel < -0.5 then
    gas, brake = 0, math.min(1, -accel / (plan.brakeG[cell] * G))
  end
  if plan.gasSet[cell] and brake == 0 then gas = plan.gasSet[cell] end
  local kappa = at(track.curv, f, n)
  local sample = {
    pos = st.dist / length, t = st.t * 1000, lapCount = st.lapCount, dt = dt,
    v = speed * 3.6, speedMs = speed, gas = gas, brake = brake,
    steer = math.deg(math.atan(2.6 * kappa)) * 12,
    gear = math.min(6, 1 + math.floor(speed * 3.6 / 45)),
    x = at(st.xs, f, n), z = at(st.zs, f, n), offLeftM = plan.off[cell],
  }
  local move = speed * dt
  st.dist, st.t = st.dist + move, st.t + dt
  if st.dist >= length then
    st.dist = st.dist - length
    st.lastLapMs = (st.t - st.dist / speed) * 1000
    st.t = st.dist / speed
    st.lapCount = st.lapCount + 1
  end
  return sample
end

-- Drives one lap of a plan, from the start line to the start line.
function Synth.lap(track, plan, st)
  local samples = {}
  local lap = st.lapCount or 0
  repeat
    samples[#samples + 1] = Synth.step(track, plan, st)
  until st.lapCount ~= lap
  return samples
end

return Synth
