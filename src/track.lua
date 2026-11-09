-- Turns the ideal line of a track into a list of corners and a speed plan.
-- Pure logic: no game API, standard Lua only.
--
-- Conventions
--   points[i] = { x =, z = } is the line at track position (i - 1) / n.
--   Curvature is signed: positive means LEFT. `leftSign` tells which way the
--   world coordinate system turns (see sim.lua, which measures it in game).

local U = require('src/util')

local Track = {}

local function severityOf(radiusM, angleDeg, cfg)
  if angleDeg >= cfg.hairpinAngleDeg and radiusM < cfg.hairpinAngleRadiusM then
    return 'hairpin'
  end
  for _, s in ipairs(cfg.severity) do
    if radiusM < s.maxRadiusM then return s.id end
  end
  return 'kink'
end

-- points: array of { x, z }, closed loop.
-- opts: { cfg = config.track, leftSign = 1 | -1 }
function Track.build(points, opts)
  local cfg = opts.cfg
  local leftSign = opts.leftSign or 1
  local n = #points
  local track = { n = n, points = points, leftSign = leftSign, corners = {} }
  if n < 16 then
    track.lengthM, track.cellM, track.ds, track.s, track.curv = 0, 0, {}, {}, {}
    return track
  end

  -- Segment lengths and distance along the line.
  local ds, s, total = {}, {}, 0
  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
  for i = 1, n do
    local a, b = points[i], points[(i % n) + 1]
    local dx, dz = b.x - a.x, b.z - a.z
    ds[i] = math.sqrt(dx * dx + dz * dz)
    s[i] = total
    total = total + ds[i]
    if a.x < minX then minX = a.x end
    if a.x > maxX then maxX = a.x end
    if a.z < minZ then minZ = a.z end
    if a.z > maxZ then maxZ = a.z end
  end
  local cellM = total / n
  track.ds, track.s, track.lengthM, track.cellM = ds, s, total, cellM
  track.bounds = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
  if cellM <= 0 then
    track.curv = {}
    return track
  end

  -- Heading from a chord around each point (robust against sampling noise).
  local k = math.max(1, U.round(cfg.headingBaseM / cellM))
  local heading = {}
  for i = 1, n do
    local a, b = points[U.wrapIndex(i - k, n)], points[U.wrapIndex(i + k, n)]
    heading[i] = math.atan2(b.z - a.z, b.x - a.x)
  end

  -- Raw signed curvature (1/m), then a circular moving average.
  local raw = {}
  for i = 1, n do
    local prev, nxt = U.wrapIndex(i - 1, n), (i % n) + 1
    local dHeading = U.wrapAngle(heading[nxt] - heading[prev])
    local len = ds[prev] + ds[i]
    raw[i] = (len > 1e-6) and (dHeading / len) * leftSign or 0
  end
  local half = math.max(0, U.round(cfg.smoothM / cellM / 2))
  local curv = {}
  for i = 1, n do
    local sum = 0
    for j = -half, half do sum = sum + raw[U.wrapIndex(i + j, n)] end
    curv[i] = sum / (2 * half + 1)
  end
  track.curv = curv

  -- Runs of cells that turn the same way, walking the loop from a straight.
  local thr = 1 / cfg.cornerRadiusM
  local start = 1
  for i = 1, n do
    if math.abs(curv[i]) < thr then start = i break end
  end
  local runs, cur = {}, nil
  for j = 0, n - 1 do
    local c = curv[U.wrapIndex(start + j, n)]
    local sign = (c > thr) and 1 or ((c < -thr) and -1 or 0)
    if sign ~= 0 and cur and cur.sign == sign then
      cur.to = j
    else
      if cur then runs[#runs + 1] = cur end
      cur = (sign ~= 0) and { sign = sign, from = j, to = j } or nil
    end
  end
  if cur then runs[#runs + 1] = cur end

  -- Merge same-direction runs separated by a short straight (double apex).
  local gapCells = cfg.mergeGapM / cellM
  local merged = {}
  for _, r in ipairs(runs) do
    local last = merged[#merged]
    if last and last.sign == r.sign and (r.from - last.to - 1) <= gapCells then
      last.to = r.to
    else
      merged[#merged + 1] = r
    end
  end

  -- Measure each run and keep the ones that turn enough to matter.
  local corners = {}
  for _, r in ipairs(merged) do
    local angle, peak, lengthM = 0, 0, 0
    for j = r.from, r.to do
      local i = U.wrapIndex(start + j, n)
      angle = angle + curv[i] * ds[i]
      lengthM = lengthM + ds[i]
      if math.abs(curv[i]) > peak then peak = math.abs(curv[i]) end
    end
    -- Apex: the middle of the tightest part (a constant-radius arc has no
    -- single tightest point, so take the centre of the plateau).
    local firstJ, lastJ
    for j = r.from, r.to do
      if math.abs(curv[U.wrapIndex(start + j, n)]) >= 0.95 * peak then
        firstJ = firstJ or j
        lastJ = j
      end
    end
    local apexJ = math.floor(((firstJ or r.from) + (lastJ or r.to)) / 2)
    local angleDeg = math.abs(math.deg(angle))
    if angleDeg >= cfg.minAngleDeg and peak > 0 then
      local startCell = U.wrapIndex(start + r.from, n)
      local apexCell = U.wrapIndex(start + apexJ, n)
      local endCell = U.wrapIndex(start + r.to, n)
      local radius = 1 / peak
      corners[#corners + 1] = {
        dir = (r.sign > 0) and 'left' or 'right',
        startCell = startCell, apexCell = apexCell, endCell = endCell,
        startM = s[startCell], apexM = s[apexCell], endM = s[endCell],
        lengthM = lengthM,
        angleDeg = angleDeg,
        minRadiusM = radius,
        severity = severityOf(radius, angleDeg, cfg),
      }
    end
  end

  -- Number from the start line, by apex position.
  table.sort(corners, function(a, b) return a.apexM < b.apexM end)
  for i, c in ipairs(corners) do
    c.index = i
    c.name = 'T' .. i
  end
  for i, c in ipairs(corners) do
    local nxt = corners[(i % #corners) + 1]
    local gapM = U.forward(c.endCell, nxt.startCell, n) * cellM
    c.gapNextM = gapM
    c.linkNext = (#corners > 1) and (gapM <= cfg.linkGapM) or false
  end
  track.corners = corners
  return track
end

-- 1-based cell index for a track position in 0..1.
function Track.cellAt(track, pos)
  return (math.floor(pos * track.n) % track.n) + 1
end

-- Speed plan for the current grip estimate.
--   vLim[i]  fastest speed the line can be driven at point i (m/s)
--   env[i]   fastest speed at point i from which every later corner can
--            still be made by braking at grip.brake (m/s)
-- Also stores the target speed of every corner in corner.vTargetMs.
function Track.plan(track, grip, cfg)
  local n = track.n
  local vLim, env = {}, {}
  for i = 1, n do
    local kappa = math.abs(track.curv[i] or 0)
    local v = cfg.vCapMs
    if kappa > 1e-4 then v = grip:cornerSpeed(1 / kappa) end
    vLim[i], env[i] = v, v
  end
  local a = grip.brake * 9.81
  for _ = 1, 2 do            -- twice round, so the loop closes on itself
    for j = n, 1, -1 do
      local nxt = (j % n) + 1
      local vmax = math.sqrt(env[nxt] * env[nxt] + 2 * a * track.ds[j])
      if env[j] > vmax then env[j] = vmax end
    end
  end
  for _, c in ipairs(track.corners) do
    local vmin = math.huge
    local cells = U.forward(c.startCell, c.endCell, n)
    for j = 0, cells do
      local v = vLim[U.wrapIndex(c.startCell + j, n)]
      if v < vmin then vmin = v end
    end
    c.vTargetMs = vmin
  end
  return { vLim = vLim, env = env, gripVersion = grip.version }
end

return Track
