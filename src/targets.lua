-- Turns a benchmark lap (the teacher's, or your own best) into:
--   * a braking curve for the co-driver's adaptive "brake" cue, and
--   * targets for every corner (brake point, gear, slowest speed, throttle).
-- Pure logic: no game API, standard Lua only.

local U = require('src/util')
local Metrics = require('src/metrics')

local Targets = {}

-- How hard the benchmark brakes, in g: the 80th percentile of its braking.
local function brakingG(lap, cfg)
  local n, decels = lap.n, {}
  for i = 1, n do
    local nxt = (i % n) + 1
    local dt = (lap.t[nxt] - lap.t[i]) / 1000
    if dt > 0.001 and dt < 5 and lap.brake[i] > 0.5 then
      decels[#decels + 1] = (lap.v[i] - lap.v[nxt]) / 3.6 / dt / 9.81
    end
  end
  if #decels < 5 then return cfg.fallbackBrakeG end
  table.sort(decels)
  local g = decels[math.max(1, math.floor(#decels * 0.8))] * cfg.brakeUse
  return U.clamp(g, cfg.minBrakeG, cfg.maxBrakeG)
end

-- track: from track.lua, lap: a complete lap, segs: Metrics.segments(track)
-- cfg = config.targets, metricsCfg = config.metrics
function Targets.build(track, lap, segs, cfg, metricsCfg)
  local n = track.n
  local plan = { lap = lap, source = lap.source or 'player', fixed = true, targets = {}, slices = {} }

  -- Where is the benchmark holding the car back? Everywhere it is not flat
  -- out. Short blips (gear changes) are ignored.
  local held = {}
  for i = 1, n do
    held[i] = not (lap.gas[i] >= cfg.fullGas and lap.brake[i] < cfg.brakeOn)
  end
  local minRun = math.max(1, U.round(cfg.minZoneM / track.cellM))
  local start = 1
  for i = 1, n do
    if not held[i] then start = i break end
  end
  local runFrom
  for j = 0, n do
    local i = U.wrapIndex(start + j, n)
    local isHeld = held[i] and j < n
    if isHeld and not runFrom then
      runFrom = j
    elseif not isHeld and runFrom then
      if j - runFrom < minRun then
        for q = runFrom, j - 1 do held[U.wrapIndex(start + q, n)] = false end
      end
      runFrom = nil
    end
  end

  -- Braking curve: the benchmark's own speed where it is held back, extended
  -- backwards along the straights at the rate the benchmark brakes.
  local vLim, env = {}, {}
  for i = 1, n do
    local v = held[i] and (lap.v[i] / 3.6) or cfg.vCapMs
    vLim[i], env[i] = v, v
  end
  plan.brakeG = brakingG(lap, cfg)
  local a = plan.brakeG * 9.81
  for _ = 1, 2 do
    for j = n, 1, -1 do
      local nxt = (j % n) + 1
      local vmax = math.sqrt(env[nxt] * env[nxt] + 2 * a * track.ds[j])
      if env[j] > vmax then env[j] = vmax end
    end
  end
  plan.vLim, plan.env = vLim, env

  for k, c in ipairs(track.corners) do
    local sl = Metrics.slice(track, lap, nil, segs[k])
    if sl then
      plan.slices[k] = sl
      plan.targets[k] = Metrics.measure(sl, track, c, segs[k], metricsCfg)
    end
  end
  return plan
end

return Targets
