-- The limit lap: what happens to the coaching once you have beaten the
-- teacher. Pure logic: no game API, standard Lua only.
--
-- A teacher lap is only as good as whoever drove it. This module works out
-- the lap the CAR could do, from the grip it has actually been seen to
-- produce (by the teacher, by you, by the grip meter while you drive):
--
--   1. Envelope: the most cornering, braking and acceleration seen so far,
--      by speed range.
--   2. Lap: the fastest way along the line of the best real lap that stays
--      inside that envelope, sharing the tyre between braking and turning
--      (which is what trail braking is), and never slower than the real lap
--      at any point.
--
-- It is an estimate, and it moves: find more grip in one corner and the
-- limit rises in every corner of that speed range.

local U = require('src/util')

local Limit = {}
local G = 9.81

local function percentile(values, share)
  if #values == 0 then return nil end
  table.sort(values)
  return values[math.max(1, math.min(#values, math.ceil(#values * share)))]
end

-- Curvature (1/m, unsigned) and step lengths of the line a lap was driven on.
function Limit.path(track, lap, trackCfg)
  local n = lap.n
  local ds, kappa, raw, heading = {}, {}, {}, {}
  for i = 1, n do
    local nxt = (i % n) + 1
    local dx, dz = lap.x[nxt] - lap.x[i], lap.z[nxt] - lap.z[i]
    ds[i] = math.sqrt(dx * dx + dz * dz)
    if ds[i] < 0.01 then ds[i] = track.ds[i] end
  end
  local k = math.max(1, U.round(trackCfg.headingBaseM / track.cellM))
  for i = 1, n do
    local a, b = U.wrapIndex(i - k, n), U.wrapIndex(i + k, n)
    heading[i] = math.atan2(lap.z[b] - lap.z[a], lap.x[b] - lap.x[a])
  end
  for i = 1, n do
    local prev, nxt = U.wrapIndex(i - 1, n), (i % n) + 1
    local len = ds[prev] + ds[i]
    raw[i] = (len > 1e-6) and math.abs(U.wrapAngle(heading[nxt] - heading[prev])) / len or 0
  end
  local half = math.max(0, U.round(trackCfg.smoothM / track.cellM / 2))
  for i = 1, n do
    local sum = 0
    for j = -half, half do sum = sum + raw[U.wrapIndex(i + j, n)] end
    kappa[i] = sum / (2 * half + 1)
  end
  return kappa, ds
end

local function bandOf(kmh, bands)
  for b, limit in ipairs(bands) do
    if kmh < limit then return b end
  end
  return #bands + 1
end

-- The grip seen so far.
--   laps: real laps to learn from (nil entries are skipped)
--   grip: the live grip meter (grip.lua), or nil
-- Returns { lat = { g per speed band }, brake = g, accel = { g per speed bin }, bands =, binKmh = }
function Limit.envelope(track, laps, grip, cfg, gripCfg, trackCfg)
  local bands = gripCfg.bandsKmh
  local nBands = #bands + 1
  local env = { lat = {}, brake = 0, accel = {}, bands = bands, binKmh = cfg.accelBinKmh }
  local seen = {}
  for b = 1, nBands do seen[b] = 0 end
  local minKappa = 1 / cfg.minRadiusM

  for _, lap in pairs(laps) do
    if lap and lap.n and lap.x then
      local n = lap.n
      local kappa = Limit.path(track, lap, trackCfg)
      local lat, decel, accel = {}, {}, {}
      for b = 1, nBands do lat[b] = {} end
      -- Cornering force at every point, then the middle value over a short
      -- stretch: a swerve, a kerb or a jump in the position data lasts a few
      -- metres and must not be mistaken for grip; a real corner lasts longer.
      local rawLat, window = {}, {}
      for i = 1, n do
        local v = lap.v[i] / 3.6
        rawLat[i] = v * v * kappa[i] / G
      end
      local half = math.max(1, math.floor(cfg.steadyM / track.cellM / 2))
      for i = 1, n do
        local nxt = (i % n) + 1
        local dt = (lap.t[nxt] - lap.t[i]) / 1000
        local aLat = 0
        if kappa[i] > minKappa and lap.v[i] >= cfg.minKmh then
          for j = -half, half do window[j + half + 1] = rawLat[U.wrapIndex(i + j, n)] end
          table.sort(window)
          aLat = window[half + 1]
        end
        -- The player's own cornering is taken from the grip meter instead
        -- (below): it measures the car, where a hand-driven line is too
        -- ragged to work the force out from.
        if aLat > 0 and aLat < gripCfg.spikeG and lap.source ~= 'player' then
          local list = lat[bandOf(lap.v[i], bands)]
          list[#list + 1] = aLat
        end
        if dt > 0.001 and dt < 5 then
          local a = (lap.v[nxt] - lap.v[i]) / 3.6 / dt / G
          if lap.brake[i] > 0.5 and a < 0 and -a < gripCfg.spikeG then
            decel[#decel + 1] = -a
          elseif lap.gas[i] >= 0.9 and lap.brake[i] < 0.05 and a > 0 and a < gripCfg.spikeG then
            local bin = math.floor(lap.v[i] / cfg.accelBinKmh) + 1
            accel[bin] = accel[bin] or {}
            accel[bin][#accel[bin] + 1] = a
          end
        end
      end
      for b = 1, nBands do
        local p = percentile(lat[b], cfg.latPct)
        if p and p > seen[b] then seen[b] = p end
      end
      local p = percentile(decel, cfg.brakePct)
      if p and p > env.brake then env.brake = p end
      for bin, list in pairs(accel) do
        local q = percentile(list, cfg.accelPct)
        if q and q > (env.accel[bin] or 0) then env.accel[bin] = q end
      end
    end
  end

  -- What the grip meter has measured while driving counts too.
  if grip then
    for b = 1, nBands do
      if (grip.latObs[b] or 0) > seen[b] then seen[b] = grip.latObs[b] end
    end
    if (grip.brakeObs or 0) > env.brake then env.brake = grip.brakeObs end
  end

  -- A speed range nobody has cornered in borrows from its neighbour.
  local prev
  for b = 1, nBands do
    if seen[b] > 0 then prev = seen[b] end
    env.lat[b] = prev
  end
  for b = nBands, 1, -1 do
    if env.lat[b] then prev = env.lat[b] else env.lat[b] = prev end
  end
  for b = 1, nBands do
    local v = U.clamp(env.lat[b] or gripCfg.latStartG, cfg.minLatG, gripCfg.latMaxG)
    -- Grip does not fall as speed rises (a range with little hard cornering
    -- in it only looks weak), and it does not leap either.
    if b > 1 then v = U.clamp(v, env.lat[b - 1], env.lat[b - 1] * cfg.bandRise) end
    env.lat[b] = v
  end
  env.brake = U.clamp(env.brake > 0 and env.brake or gripCfg.brakeStartG, cfg.minBrakeG, gripCfg.brakeMaxG)

  -- Acceleration falls with speed: fill gaps from the nearest slower bin.
  local bins = math.floor(cfg.maxKmh / cfg.accelBinKmh) + 1
  local last
  for bin = 1, bins do
    if env.accel[bin] then last = env.accel[bin] elseif last then env.accel[bin] = last end
  end
  for bin = bins, 1, -1 do
    if env.accel[bin] then last = env.accel[bin] else env.accel[bin] = last or cfg.fallbackAccelG end
  end
  return env
end

-- Builds the limit lap along the line of `base` (a real lap).
-- Returns a lap in the recorder's format with source = 'limit'.
function Limit.build(track, base, env, cfg, trackCfg)
  local n = base.n
  local kappa, ds = Limit.path(track, base, trackCfg)
  local bands = env.bands
  local vCap = cfg.vCapMs
  local function latAt(v) return env.lat[bandOf(v * 3.6, bands)] * G end
  local function accelAt(v)
    local bin = math.floor(v * 3.6 / env.binKmh) + 1
    return (env.accel[bin] or env.accel[#env.accel] or cfg.fallbackAccelG) * G
  end

  -- Fastest speed each point can be cornered at.
  local v = {}
  for i = 1, n do
    local best = vCap
    if kappa[i] > 1e-4 then
      best = nil
      for b = 1, #bands + 1 do
        local vb = math.sqrt(env.lat[b] * G / kappa[i])
        local upper = (b <= #bands) and (bands[b] / 3.6) or math.huge
        if vb <= upper then
          local lower = (b > 1) and (bands[b - 1] / 3.6) or 0
          best = math.max(vb, lower)
          break
        end
      end
      best = math.min(best or vCap, vCap)
    end
    v[i] = best
  end

  -- Braking shares the tyre with cornering, and so does acceleration.
  local brake = env.brake * G
  for _ = 1, 2 do
    for j = n, 1, -1 do
      local nxt = (j % n) + 1
      local use = math.min(1, v[nxt] * v[nxt] * kappa[j] / latAt(v[nxt]))
      local reach = math.sqrt(v[nxt] * v[nxt] + 2 * brake * math.sqrt(1 - use * use) * ds[j])
      if v[j] > reach then v[j] = reach end
    end
    for j = 1, n do
      local nxt = (j % n) + 1
      local use = math.min(1, v[j] * v[j] * kappa[j] / latAt(v[j]))
      local a = math.min(accelAt(v[j]), brake * math.sqrt(1 - use * use))
      local reach = math.sqrt(v[j] * v[j] + 2 * a * ds[j])
      if v[nxt] > reach then v[nxt] = reach end
    end
  end

  -- Never slower than what was really driven, and never wildly faster: the
  -- envelope is measured, and a bad reading must not ask for the impossible.
  for i = 1, n do
    local real = base.v[i] / 3.6
    if v[i] < real then v[i] = real end
    local cap = real * (1 + cfg.maxSpeedup)
    if v[i] > cap and real > 5 then v[i] = cap end
  end

  local lap = {
    n = n, t = {}, v = {}, gas = {}, brake = {}, steer = {}, gear = {}, x = {}, z = {},
    source = 'limit', pedals = 'derived', valid = true, complete = true, filled = n,
    basedOnMs = base.timeMs,
  }
  local t, tReal = 0, 0
  for i = 1, n do
    local nxt = (i % n) + 1
    lap.t[i] = t
    lap.v[i] = v[i] * 3.6
    lap.steer[i], lap.gear[i], lap.x[i], lap.z[i] = base.steer[i], base.gear[i], base.x[i], base.z[i]
    local a = (v[nxt] * v[nxt] - v[i] * v[i]) / (2 * ds[i])
    if a < -0.1 * G then
      lap.brake[i], lap.gas[i] = U.clamp(-a / brake, 0.11, 1), 0
    elseif a > 0.03 * G then
      lap.brake[i], lap.gas[i] = 0, 1
    else
      -- Holding speed: at the grip limit mid-corner that means waiting.
      local use = v[i] * v[i] * kappa[i] / latAt(v[i])
      lap.brake[i], lap.gas[i] = 0, (use > 0.85) and 0.15 or 1
    end
    -- Time is the real lap's own time through this cell, shortened by how
    -- much faster the limit is here: where the two agree, so do the clocks.
    local realV = math.max(1, (base.v[i] + base.v[nxt]) / 2 / 3.6)
    local limitV = math.max(realV, (v[i] + v[nxt]) / 2)
    local realDt = (nxt == 1) and 0 or (base.t[nxt] - base.t[i]) / 1000
    if realDt <= 0 or realDt > 5 then realDt = ds[i] / realV end
    tReal = tReal + realDt
    t = t + realDt * realV / limitV
  end
  -- The real lap's official time is the yardstick, whatever its own clock said.
  local scale = (tReal > 0) and (base.timeMs / tReal) or 1000
  for i = 1, n do lap.t[i] = lap.t[i] * scale end
  lap.timeMs = t * scale
  return lap
end

-- The estimated lap: what there is to go on before anybody has driven a lap.
-- It follows the game's ideal line at the grip seen so far (cautious at
-- first), so the line, the brake points and the corner strip can be shown
-- from the first corner. It is a guide to where things happen, not a
-- benchmark to be judged against. Returns a lap with source = 'estimate'.
function Limit.fromLine(track, points, grip, cfg)
  local n = track.n
  local v = {}
  for i = 1, n do
    local kappa = math.abs(track.curv[i] or 0)
    v[i] = cfg.estimateVCapMs
    if kappa > 1e-4 then v[i] = math.min(cfg.estimateVCapMs, grip:cornerSpeed(1 / kappa)) end
  end
  local brake, accel = grip.brake * G, cfg.estimateAccelG * G
  for _ = 1, 2 do
    for j = n, 1, -1 do
      local nxt = (j % n) + 1
      local reach = math.sqrt(v[nxt] * v[nxt] + 2 * brake * track.ds[j])
      if v[j] > reach then v[j] = reach end
    end
    for j = 1, n do
      local nxt = (j % n) + 1
      local reach = math.sqrt(v[j] * v[j] + 2 * accel * track.ds[j])
      if v[nxt] > reach then v[nxt] = reach end
    end
  end
  local lap = {
    n = n, t = {}, v = {}, gas = {}, brake = {}, steer = {}, gear = {}, x = {}, z = {},
    source = 'estimate', pedals = 'derived', estimated = true, valid = true, complete = true, filled = n,
  }
  local t = 0
  for i = 1, n do
    local nxt = (i % n) + 1
    lap.t[i] = t * 1000
    lap.v[i] = v[i] * 3.6
    lap.steer[i], lap.gear[i], lap.x[i], lap.z[i] = 0, 0, points[i].x, points[i].z
    local a = (v[nxt] * v[nxt] - v[i] * v[i]) / (2 * math.max(0.01, track.ds[i]))
    if a < -0.1 * G then
      lap.brake[i], lap.gas[i] = U.clamp(-a / brake, 0.11, 1), 0
    elseif a > 0.03 * G then
      lap.brake[i], lap.gas[i] = 0, 1
    else
      lap.brake[i], lap.gas[i] = 0, 0.3
    end
    t = t + track.ds[i] / math.max(1, (v[i] + v[nxt]) / 2)
  end
  lap.timeMs = t * 1000
  return lap
end

-- Pace levels: how close a lap time is to the limit lap.
-- levels: list of { id =, within = ratio } from slowest to fastest.
-- Returns { index =, id =, ratio =, nextId =, nextMs = time still to find for the next level }.
function Limit.level(lapMs, limitMs, levels)
  if not (lapMs and limitMs and limitMs > 0) then return nil end
  local ratio = lapMs / limitMs
  local index = 1
  for i, lv in ipairs(levels) do
    if ratio <= lv.within then index = i end
  end
  local out = { index = index, id = levels[index].id, ratio = ratio }
  local nxt = levels[index + 1]
  if nxt then
    out.nextId = nxt.id
    out.nextMs = math.max(0, lapMs - limitMs * nxt.within)
  end
  return out
end

return Limit
