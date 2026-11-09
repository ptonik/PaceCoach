-- Learns how much grip this car has from what it is seen doing.
-- Starts cautious and only ever moves towards observed peaks.
-- Pure logic: no game API, standard Lua only.

local U = require('src/util')

local Grip = {}
Grip.__index = Grip

function Grip.new(cfg, saved)
  local self = setmetatable({}, Grip)
  self.cfg = cfg
  self.nBands = #cfg.bandsKmh + 1
  self.latObs = {}
  for b = 1, self.nBands do self.latObs[b] = 0 end
  self.brakeObs = 0
  self.latSm, self.decSm = 0, 0
  self.lastSpeedMs = nil
  self.lat = {}
  self.brake = cfg.brakeStartG
  self.version = 0
  if saved then self:import(saved) end
  self:_refresh(true)
  return self
end

function Grip:band(kmh)
  for b, limit in ipairs(self.cfg.bandsKmh) do
    if kmh < limit then return b end
  end
  return self.nBands
end

-- dt in seconds, latG in g (sign ignored), brakePedal 0..1.
-- ok = false when the sample cannot be trusted (off track, spinning, paused).
function Grip:feed(dt, speedMs, latG, brakePedal, ok)
  if not dt or dt <= 0 then return end
  local cfg = self.cfg
  local lat = math.abs(latG or 0)
  local dec = 0
  if self.lastSpeedMs then dec = (self.lastSpeedMs - speedMs) / dt / 9.81 end
  self.lastSpeedMs = speedMs
  if not ok or lat > cfg.spikeG or math.abs(dec) > cfg.spikeG then
    self.latSm, self.decSm = 0, 0     -- a crash must not teach grip
    return
  end
  self.latSm = self.latSm + (lat - self.latSm) * math.min(1, dt / cfg.latSmoothS)
  self.decSm = self.decSm + (dec - self.decSm) * math.min(1, dt / cfg.brakeSmoothS)
  local kmh = speedMs * 3.6
  if kmh < cfg.minSpeedKmh then return end
  local b = self:band(kmh)
  if self.latSm > self.latObs[b] then self.latObs[b] = self.latSm end
  if (brakePedal or 0) > 0.5 and self.decSm > self.brakeObs then
    self.brakeObs = self.decSm
  end
  self:_refresh(false)
end

function Grip:_refresh(force)
  local cfg = self.cfg
  local changed = force
  local prev = cfg.latStartG
  for b = 1, self.nBands do
    local v = prev                       -- unobserved band inherits the one below
    if self.latObs[b] > 0 then
      v = math.max(cfg.latStartG, cfg.latUse * self.latObs[b])
    end
    v = U.clamp(v, cfg.latStartG, cfg.latMaxG)
    prev = v
    local used = self.lat[b]
    if not used or math.abs(v - used) / used > cfg.changeRatio then
      self.lat[b] = v
      changed = true
    end
  end
  local brake = U.clamp(math.max(cfg.brakeStartG, cfg.brakeUse * self.brakeObs),
    cfg.brakeStartG, cfg.brakeMaxG)
  if math.abs(brake - self.brake) / self.brake > cfg.changeRatio then
    self.brake = brake
    changed = true
  end
  if changed then self.version = self.version + 1 end
end

-- Fastest speed (m/s) a corner of the given radius can be taken at.
function Grip:cornerSpeed(radiusM)
  local cfg = self.cfg
  for b = 1, self.nBands do
    local v = math.sqrt(self.lat[b] * 9.81 * radiusM)
    local upper = (b < self.nBands) and (cfg.bandsKmh[b] / 3.6) or math.huge
    if v <= upper then
      local lower = (b > 1) and (cfg.bandsKmh[b - 1] / 3.6) or 0
      return math.min(math.max(v, lower), cfg.vCapMs)
    end
  end
  return cfg.vCapMs
end

function Grip:export()
  local lat = {}
  for b = 1, self.nBands do lat[b] = self.latObs[b] end
  return { lat = lat, brake = self.brakeObs }
end

function Grip:import(saved)
  if type(saved) ~= 'table' then return end
  if type(saved.lat) == 'table' then
    for b = 1, self.nBands do
      local v = tonumber(saved.lat[b])
      if v and v > 0 and v < self.cfg.spikeG then self.latObs[b] = v end
    end
  end
  local brake = tonumber(saved.brake)
  if brake and brake > 0 and brake < self.cfg.spikeG then self.brakeObs = brake end
end

return Grip
