-- The stint coach. A fast lap gets you a grid slot; a race is won by doing
-- nearly that lap again and again without a mistake. This module counts
-- laps "in the window" (close to your best) in a row, and marks the
-- milestones on the way to a full stint. Pure logic: standard Lua only.

local Stint = {}
Stint.__index = Stint

function Stint.new(cfg)
  local self = setmetatable({}, Stint)
  self.cfg = cfg
  self.streak, self.bestStreak = 0, 0
  self.clean, self.bestClean = 0, 0
  self.laps, self.sumMs = 0, 0
  return self
end

-- Leaving the track for the pits ends the stint.
function Stint:pit()
  self.streak, self.clean, self.laps, self.sumMs = 0, 0, 0, 0
end

-- timeMs: the lap just finished, valid: clean or not, bestMs: the driver's best lap.
-- Returns { inWindow =, windowMs =, deltaMs =, streak =, milestone = n or nil, broke = n or nil }.
function Stint:lap(timeMs, valid, bestMs)
  local cfg = self.cfg
  local out = { inWindow = false }
  if not bestMs or bestMs <= 0 then bestMs = timeMs end
  out.windowMs = bestMs * (1 + cfg.windowFrac)
  out.deltaMs = timeMs - bestMs
  if valid then
    self.clean = self.clean + 1
    if self.clean > self.bestClean then self.bestClean = self.clean end
    self.laps, self.sumMs = self.laps + 1, self.sumMs + timeMs
  else
    self.clean = 0
  end
  if valid and timeMs <= out.windowMs then
    out.inWindow = true
    self.streak = self.streak + 1
    if self.streak > self.bestStreak then self.bestStreak = self.streak end
    for _, n in ipairs(cfg.milestones) do
      if self.streak == n then out.milestone = n end
    end
  else
    if self.streak >= cfg.milestones[1] then out.broke = self.streak end
    self.streak = 0
  end
  out.streak = self.streak
  out.averageMs = self.laps > 0 and (self.sumMs / self.laps) or nil
  return out
end

-- The next milestone above the current run, or nil when the longest is reached.
function Stint:nextGoal()
  for _, n in ipairs(self.cfg.milestones) do
    if self.streak < n then return n end
  end
  return nil
end

return Stint
