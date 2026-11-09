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

return Synth
