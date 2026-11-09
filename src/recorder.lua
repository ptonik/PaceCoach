-- Records laps on a fixed grid of track positions.
-- Pure logic: no game API, standard Lua only.
--
-- A lap is a table of arrays, one value per cell. Index i holds the value at
-- track position (i - 1) / n:
--   t      lap time in ms when the car passed that point
--   v      speed in km/h
--   gas    0..1        brake  0..1
--   steer  steering wheel angle in degrees
--   gear   integer
--   x, z   world position

local U = require('src/util')

local Recorder = {}
Recorder.__index = Recorder

Recorder.CHANNELS = { 't', 'v', 'gas', 'brake', 'steer', 'gear', 'x', 'z' }
local LERPED = { 't', 'v', 'gas', 'brake', 'steer', 'x', 'z' }

function Recorder.new(n, cfg)
  local self = setmetatable({}, Recorder)
  self.n = n
  self.cfg = cfg
  self.last = nil
  self.prev = nil          -- the lap finished just before the one in progress
  self:_begin()
  return self
end

function Recorder:_begin()
  local lap = { n = self.n, filled = 0, invalid = nil }
  for _, ch in ipairs(Recorder.CHANNELS) do lap[ch] = {} end
  self.lap = lap
end

-- Marks the lap in progress as not usable as a reference.
function Recorder:invalidate(reason)
  if not self.lap.invalid then self.lap.invalid = reason or 'invalid' end
end

-- Forgets the previous sample (after a teleport or session restart).
function Recorder:restart(reason)
  self.last = nil
  self.prev = nil
  self:_begin()
  if reason then self.lap.invalid = reason end
end

function Recorder:_fill(a, b)
  local n, lap = self.n, self.lap
  local fa = a.pos * n
  local d = (b.pos * n - fa) % n
  if d > n * 0.5 then return end                 -- rolling backwards
  if d > n * self.cfg.jumpFraction then           -- teleport
    self:invalidate('jump')
    return
  end
  local first, last = math.floor(fa) + 1, math.floor(fa + d)
  for c = first, last do
    local f = (d > 0) and ((c - fa) / d) or 1
    local i = (c % n) + 1
    if lap.t[i] == nil then lap.filled = lap.filled + 1 end
    for _, ch in ipairs(LERPED) do
      lap[ch][i] = a[ch] + (b[ch] - a[ch]) * f
    end
    lap.gear[i] = b.gear
  end
end

function Recorder:_finish()
  local lap, n = self.lap, self.n
  lap.coverage = lap.filled / n
  lap.complete = lap.coverage >= self.cfg.minCoverage
  lap.timeMs = self.last and (self.last.t + (self.last.dt or 0) * 1000) or 0
  if lap.complete then
    -- Patch the few missing cells from their neighbour behind.
    if lap.filled < n then
      local seed
      for i = n, 1, -1 do if lap.t[i] ~= nil then seed = i break end end
      local src = seed
      for i = 1, n do
        if lap.t[i] == nil then
          for _, ch in ipairs(Recorder.CHANNELS) do lap[ch][i] = lap[ch][src] end
        else
          src = i
        end
      end
    end
    -- Time must rise along the lap and drop exactly once (at the timing line).
    local drops = 0
    for i = 1, n do
      if lap.t[(i % n) + 1] < lap.t[i] - 50 then drops = drops + 1 end
    end
    if drops > 1 then
      lap.complete = false
      lap.invalid = lap.invalid or 'timing'
    end
  end
  lap.valid = lap.complete and not lap.invalid and lap.timeMs >= self.cfg.minLapMs
  return lap
end

-- s: { pos = 0..1, t = lap time ms, lapCount =, dt = seconds, v =, gas =,
--      brake =, steer =, gear =, x =, z = }
-- Returns the lap that just ended, or nil.
function Recorder:feed(s)
  local done
  local last = self.last
  if last then
    if s.lapCount ~= last.lapCount or s.t + 500 < last.t then
      done = self:_finish()
      self.prev = done
      self:_begin()
      last.t = math.max(0, s.t - (s.dt or 0) * 1000)   -- re-base into the new lap
    end
    self:_fill(last, s)
  else
    last = {}
    self.last = last
  end
  last.pos, last.t, last.lapCount, last.dt = s.pos, s.t, s.lapCount, s.dt
  last.v, last.gas, last.brake, last.steer = s.v, s.gas, s.brake, s.steer
  last.gear, last.x, last.z = s.gear, s.x, s.z
  return done
end

-- Interpolated channel value of a finished lap at track position 0..1.
function Recorder.valueAt(lap, ch, pos)
  local n = lap.n
  local f = (pos % 1) * n
  local i0 = (math.floor(f) % n) + 1
  local i1 = (i0 % n) + 1
  local a, b = lap[ch][i0], lap[ch][i1]
  if ch == 't' and math.abs(b - a) > 1000 then return a end   -- timing line
  return a + (b - a) * (f - math.floor(f))
end

-- Milliseconds ahead (negative) or behind (positive) a reference lap.
function Recorder.deltaMs(ref, pos, lapTimeMs)
  return lapTimeMs - Recorder.valueAt(ref, 't', pos)
end

return Recorder
