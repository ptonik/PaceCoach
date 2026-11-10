-- Measures what a driver did in one corner: where they braked, how slow they
-- got, when they went back to the throttle, how long it took.
-- Pure logic: no game API, standard Lua only.
--
-- The same measurement is taken from the benchmark lap (giving the targets)
-- and from the lap being driven (giving what to compare against them).

local U = require('src/util')

local Metrics = {}

local CHANNELS = { 'v', 'gas', 'brake', 'steer', 'gear', 'x', 'z' }

-- Splits the lap into one segment per corner. Each corner owns the track from
-- the middle of the straight before it to the middle of the straight after.
-- seg = { from = cell, to = cell, cells = number of steps from `from` to `to` }
function Metrics.segments(track)
  local corners, n = track.corners, track.n
  local m = #corners
  local segs, starts = {}, {}
  if m == 0 then return segs end
  for k = 1, m do
    local c = corners[k]
    if m == 1 then
      starts[k] = U.wrapIndex(c.apexCell - math.floor(n / 2), n)
    else
      local prev = corners[((k - 2) % m) + 1]
      local gap = U.forward(prev.endCell, c.startCell, n)
      starts[k] = U.wrapIndex(prev.endCell + math.floor(gap / 2), n)
    end
  end
  for k = 1, m do
    local from = starts[k]
    local to = (m == 1) and U.wrapIndex(from - 1, n) or starts[(k % m) + 1]
    segs[k] = { from = from, to = to, cells = U.forward(from, to, n) }
  end
  return segs
end

-- Index of the segment a cell is in, or nil.
function Metrics.segmentAt(segs, cell, n)
  for k, seg in ipairs(segs) do
    if U.forward(seg.from, cell, n) < math.max(1, seg.cells) then return k end
  end
  return nil
end

-- Copies one segment out of a lap into small arrays that start at index 1.
-- `prev` is the lap before `lap`: a segment that straddles the timing line has
-- its first cells in the previous lap and the rest in the current one.
-- Time is made continuous across the line. Returns nil if any cell is missing.
function Metrics.slice(track, lap, prev, seg)
  local n = track.n
  local out = { t = {}, dist = {}, cell = {}, count = 0 }
  for _, ch in ipairs(CHANNELS) do out[ch] = {} end
  local offset, dist = 0, 0
  local lastRaw, lastSrc, usedLap = nil, nil, false
  for j = 0, seg.cells do
    local i = U.wrapIndex(seg.from + j, n)
    local src = lap
    if src.t[i] == nil then
      if usedLap then return nil end            -- a hole, not the timing line
      src = prev
      if not src or src.t[i] == nil then return nil end
    else
      usedLap = true
    end
    local raw = src.t[i]
    if lastRaw and raw < lastRaw - 1000 then
      offset = offset + (lastSrc.timeMs or 0)    -- crossed the timing line
    elseif lastSrc and src ~= lastSrc then
      return nil                                 -- changed lap without crossing it
    end
    lastRaw, lastSrc = raw, src
    local k = j + 1
    out.t[k] = raw + offset
    out.dist[k] = dist
    out.cell[k] = i
    for _, ch in ipairs(CHANNELS) do out[ch][k] = src[ch][i] end
    dist = dist + track.ds[i]
  end
  if not usedLap then return nil end             -- this lap has not reached the segment
  out.count = seg.cells + 1
  out.timeMs = out.t[out.count] - out.t[1]
  if out.timeMs <= 0 then return nil end
  return out
end

-- Measures one corner from a slice. cfg = config.metrics.
function Metrics.measure(sl, track, c, seg, cfg)
  local n, L = track.n, sl.count
  local function loc(cell) return U.clamp(U.forward(seg.from, cell, n) + 1, 1, L) end
  local sJ, aJ, eJ = loc(c.startCell), loc(c.apexCell), loc(c.endCell)
  if eJ < sJ then eJ = L end
  local cellM = track.cellM
  local m = { timeMs = sl.timeMs, sJ = sJ, aJ = aJ, eJ = eJ }

  -- Slowest point, from a little before turn-in to the end of the corner.
  local minJ, minV = sJ, math.huge
  for j = math.max(1, sJ - math.floor(cfg.minSearchPadM / cellM)), eJ do
    if sl.v[j] < minV then minV, minJ = sl.v[j], j end
  end
  m.minJ, m.minKmh, m.gear = minJ, minV, sl.gear[minJ]
  m.minCell = sl.cell[minJ]
  m.minRelM = sl.dist[minJ] - sl.dist[aJ]

  -- Braking zone: the last stretch of braking that ends by the slowest point.
  local on = cfg.brakeOn
  local k = math.min(L, minJ + math.floor(cfg.trailPadM / cellM))
  while k >= 1 and sl.brake[k] <= on do k = k - 1 end
  m.peakBrake = 0
  if k >= 1 then
    local startJ, gap, q = k, 0, k
    while q >= 1 do
      if sl.brake[q] > on then
        startJ, gap = q, 0
        if sl.brake[q] > m.peakBrake then m.peakBrake = sl.brake[q] end
      else
        gap = gap + 1
        if gap > cfg.brakeGapCells then break end
      end
      q = q - 1
    end
    m.brakeStartJ, m.brakeEndJ = startJ, k
    m.brakeEndRelM = sl.dist[k] - sl.dist[sJ]        -- positive: still braking past turn-in
    m.brakeCell = sl.cell[startJ]
    m.brakeRelM = sl.dist[startJ] - sl.dist[sJ]      -- negative: before turn-in
    m.brakeKmh = sl.v[startJ]
  end

  -- Back on the throttle, then full throttle.
  local from = math.max(minJ, m.brakeEndJ or 1)
  for j = from, L do
    if sl.gas[j] > cfg.gasOn and (j == L or sl.gas[j + 1] > cfg.gasOn) then
      m.throttleJ = j
      break
    end
  end
  if m.throttleJ then
    m.throttleCell = sl.cell[m.throttleJ]
    m.throttleRelM = sl.dist[m.throttleJ] - sl.dist[aJ]
    for j = m.throttleJ, L do
      if sl.gas[j] >= cfg.gasFull then
        m.fullJ = j
        m.fullRelM = sl.dist[j] - sl.dist[aJ]
        break
      end
    end
  end

  -- Lifts after getting back on the throttle (went too early, had to back off).
  m.lifts = 0
  if m.throttleJ then
    local hi = sl.gas[m.throttleJ]
    for j = m.throttleJ, math.min(L, eJ + math.floor(cfg.exitPadM / cellM)) do
      local g = sl.gas[j]
      if g > hi then
        hi = g
      elseif g < hi - cfg.liftDrop then
        m.lifts = m.lifts + 1
        hi = g
      end
    end
  end

  -- Coasting: rolling with neither pedal, up to the point of full throttle.
  m.coastM = 0
  for j = 1, math.min(L - 1, m.fullJ or eJ) do
    if sl.gas[j] < cfg.pedalOff and sl.brake[j] < cfg.pedalOff and sl.v[j] > cfg.coastMinKmh then
      m.coastM = m.coastM + (sl.dist[j + 1] - sl.dist[j])
    end
  end

  m.entryKmh = sl.v[m.brakeStartJ or sJ]
  m.exitKmh = sl.v[math.min(L, eJ + math.floor(cfg.exitPadM / cellM))]
  return m
end

-- How far `got` is to the LEFT of `ref` at slice index j, in metres
-- (negative: to the right). Both slices must cover the same segment.
function Metrics.lateral(got, ref, j, leftSign)
  local L = ref.count
  local j0, j1 = math.max(1, j - 2), math.min(L, j + 2)
  local dx, dz = ref.x[j1] - ref.x[j0], ref.z[j1] - ref.z[j0]
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-6 then return 0 end
  local leftX, leftZ = -dz / len * leftSign, dx / len * leftSign
  return (got.x[j] - ref.x[j]) * leftX + (got.z[j] - ref.z[j]) * leftZ
end

-- True when a lap carries believable pedal traces.
function Metrics.pedalsLookReal(lap)
  local maxBrake, maxGas = 0, 0
  for i = 1, lap.n do
    if lap.brake[i] > maxBrake then maxBrake = lap.brake[i] end
    if lap.gas[i] > maxGas then maxGas = lap.gas[i] end
  end
  return maxBrake > 0.2 and maxGas > 0.5
end

-- Rebuilds pedal traces from the speed trace, for laps recorded from cars
-- whose pedals the game does not expose. Rough, but it places the braking
-- zones and the return to throttle correctly.
function Metrics.derivePedals(lap)
  local n = lap.n
  local accel, decels = {}, {}
  for i = 1, n do
    local nxt = (i % n) + 1
    local dt = (lap.t[nxt] - lap.t[i]) / 1000
    local a = 0
    if dt > 0.001 and dt < 5 then a = (lap.v[nxt] - lap.v[i]) / 3.6 / dt / 9.81 end
    accel[i] = a
    if a < -0.15 then decels[#decels + 1] = -a end
  end
  table.sort(decels)
  local peak = decels[math.max(1, math.floor(#decels * 0.9))] or 1
  if peak < 0.3 then peak = 0.3 end
  for i = 1, n do
    local a = accel[i]
    if a < -0.15 then
      lap.brake[i], lap.gas[i] = U.clamp(-a / peak, 0, 1), 0
    elseif a > 0.02 then
      lap.brake[i], lap.gas[i] = 0, 1
    else
      lap.brake[i], lap.gas[i] = 0, 0.5
    end
  end
  lap.pedals = 'derived'
  return lap
end

return Metrics
