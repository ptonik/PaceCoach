-- Spots common beginner mistakes from the car's behaviour alone, with no
-- reference lap needed. Pure logic: no game API, standard Lua only.
--
-- update() returns the ids of mistakes that started this frame:
--   spin, offtrack, lockup, abs, wheelspin, understeer, oversteer, coast, sawing

local Mistakes = {}
Mistakes.__index = Mistakes

-- Most important first: the HUD shows only one tip at a time.
Mistakes.PRIORITY = {
  'spin', 'offtrack', 'lockup', 'oversteer', 'understeer',
  'wheelspin', 'abs', 'sawing', 'coast',
}

function Mistakes.new(cfg)
  local self = setmetatable({}, Mistakes)
  self.cfg = cfg
  self.t = 0
  self.hold = {}
  self.cool = {}
  self.quietUntil = 0
  self.coastM = 0
  self.saw = { dir = 1, extreme = nil, times = {} }
  self.events = {}
  return self
end

-- True once when `cond` has held for needS seconds and the cooldown is over.
function Mistakes:_held(id, cond, dt, needS, cooldownS)
  if not cond then
    self.hold[id] = 0
    return false
  end
  local h = (self.hold[id] or 0) + dt
  self.hold[id] = h
  if h >= needS and self.t >= (self.cool[id] or 0) then
    self.cool[id] = self.t + (cooldownS or self.cfg.cooldownS)
    return true
  end
  return false
end

-- s: { v = km/h, gas =, brake =, steer = degrees or nil, wheelsOut =,
--      abs = bool, velAngleDeg = number or nil,
--      slipRatio = { FL, FR, RL, RR } or nil, slipAngle = { ... } or nil }
-- opts: { gamepad = bool }
function Mistakes:update(s, dt, opts)
  local ev = self.events
  for i = #ev, 1, -1 do ev[i] = nil end
  self.t = self.t + dt
  local cfg, v = self.cfg, s.v
  local c

  c = cfg.spin
  if s.velAngleDeg and self:_held('spin',
      v > c.minKmh and s.velAngleDeg > c.angleDeg, dt, c.holdS) then
    ev[#ev + 1] = 'spin'
    self.quietUntil = self.t + cfg.quietAfterSpinS
  end

  c = cfg.offtrack
  local off = (s.wheelsOut or 0) >= c.wheels
  if self:_held('offtrack', off, dt, c.holdS) then
    ev[#ev + 1] = 'offtrack'
    self.quietUntil = math.max(self.quietUntil, self.t + 2)
  end

  -- What happens during a spin or an excursion is a consequence, not a new mistake.
  if off or self.t < self.quietUntil then
    self.coastM = 0
    self.saw.times = {}
    return ev
  end

  local sr = s.slipRatio
  if sr then
    c = cfg.lockup
    local lowest = math.min(sr[1], sr[2], sr[3], sr[4])
    if self:_held('lockup',
        s.brake > c.brake and v > c.minKmh and lowest < c.slipRatio, dt, c.holdS) then
      ev[#ev + 1] = 'lockup'
    end
    c = cfg.wheelspin
    local highest = math.max(sr[1], sr[2], sr[3], sr[4])
    if self:_held('wheelspin',
        s.gas > c.gas and v > c.minKmh and highest > c.slipRatio, dt, c.holdS) then
      ev[#ev + 1] = 'wheelspin'
    end
  end

  c = cfg.abs
  if self:_held('abs', s.abs == true and s.brake > c.brake, dt, c.holdS, c.cooldownS) then
    ev[#ev + 1] = 'abs'
  end

  local sa = s.slipAngle
  if sa then
    local front = (math.abs(sa[1]) + math.abs(sa[2])) / 2
    local rear = (math.abs(sa[3]) + math.abs(sa[4])) / 2
    c = cfg.understeer
    if self:_held('understeer',
        v > c.minKmh and front > c.frontDeg and front - rear > c.diffDeg, dt, c.holdS) then
      ev[#ev + 1] = 'understeer'
    end
    c = cfg.oversteer
    if self:_held('oversteer',
        v > c.minKmh and rear > c.rearDeg and rear - front > c.diffDeg, dt, c.holdS) then
      ev[#ev + 1] = 'oversteer'
    end
  end

  c = cfg.coast
  if v > c.minKmh and s.gas < c.pedal and s.brake < c.pedal then
    self.coastM = self.coastM + v / 3.6 * dt
    if self.coastM >= c.distM and self.t >= (self.cool.coast or 0) then
      self.cool.coast = self.t + cfg.cooldownS
      self.coastM = 0
      ev[#ev + 1] = 'coast'
    end
  else
    self.coastM = 0
  end

  c = cfg.sawing
  if s.steer and not (opts and opts.gamepad) then
    local saw = self.saw
    local reversed = false
    if saw.extreme == nil then saw.extreme = s.steer end
    if saw.dir > 0 then
      if s.steer > saw.extreme then
        saw.extreme = s.steer
      elseif s.steer < saw.extreme - c.ampDeg then
        saw.dir, saw.extreme, reversed = -1, s.steer, true
      end
    else
      if s.steer < saw.extreme then
        saw.extreme = s.steer
      elseif s.steer > saw.extreme + c.ampDeg then
        saw.dir, saw.extreme, reversed = 1, s.steer, true
      end
    end
    local times = saw.times
    if reversed and v > c.minKmh then times[#times + 1] = self.t end
    while times[1] and times[1] < self.t - c.windowS do table.remove(times, 1) end
    if #times >= c.count and self.t >= (self.cool.sawing or 0) then
      self.cool.sawing = self.t + cfg.cooldownS
      saw.times = {}
      ev[#ev + 1] = 'sawing'
    end
  end

  return ev
end

-- Picks the most important id from a list (nil if the list is empty).
function Mistakes.mostImportant(ids)
  for _, id in ipairs(Mistakes.PRIORITY) do
    for _, got in ipairs(ids) do
      if got == id then return id end
    end
  end
  return ids[1]
end

return Mistakes
