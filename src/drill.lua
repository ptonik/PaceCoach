-- Corner repeat. A coach does not let you drive a whole lap to try one
-- corner once: they send you back to do it again while it is fresh. This
-- module decides when to remember the car's state on the way to the focus
-- corner and when to put the car back there. The game calls themselves are
-- made by the app. Pure logic: standard Lua only.

local U = require('src/util')

local Drill = {}
Drill.__index = Drill

function Drill.new(cfg)
  local self = setmetatable({}, Drill)
  self.cfg = cfg
  self:stop()
  return self
end

-- Forgets everything: the remembered state, the corner and the attempts.
function Drill:stop()
  self.phase = 'idle'        -- idle | saving | run | wait
  self.k, self.data = nil, nil
  self.attempts, self.best, self.last = 0, nil, nil
  self.waitT, self.stuckT = 0, 0
  self.lastCell = nil
end

-- The app got the car's state from the game (or failed to).
function Drill:saved(data)
  if self.phase ~= 'saving' then return end
  if data then
    self.data, self.phase, self.attempts = data, 'run', 1
  else
    self.phase = 'idle'
  end
end

-- The result of the attempt just driven (time lost by the corner exit, ms).
function Drill:record(lossMs)
  self.last = lossMs
  if not self.best or lossMs < self.best then self.best = lossMs end
  self.judged = true
end

-- inp: { on =, k = corner to repeat (or nil), n = cells in a lap, cell =,
--        saveCell = where an attempt starts, endCell = where it ends,
--        speedKmh =, steady = car under control }
-- Returns 'save' when the app should remember the car's state now, 'load'
-- when it should put the car back, or nil.
function Drill:update(inp, dt)
  local cfg = self.cfg
  if not (inp.on and inp.k) then
    if self.phase ~= 'idle' or self.k then self:stop() end
    return nil
  end
  if inp.k ~= self.k then
    self:stop()
    self.k = inp.k
  end
  local n, cell = inp.n, inp.cell
  local last = self.lastCell
  self.lastCell = cell
  local span = U.forward(inp.saveCell, inp.endCell, n)
  local into = U.forward(inp.saveCell, cell, n)        -- cells past the start of the attempt

  if self.phase == 'idle' then
    -- Remember the car as it passes the start point, at speed and in control.
    if last and last ~= cell and U.forward(last, inp.saveCell, n) <= U.forward(last, cell, n)
        and inp.speedKmh >= cfg.minKmh and inp.steady then
      self.phase = 'saving'
      return 'save'
    end
    return nil
  end
  if self.phase == 'saving' then return nil end

  if self.phase == 'run' then
    -- Stuck in the gravel or stopped on the way: go again without waiting.
    if into <= span and inp.speedKmh < cfg.stuckKmh then
      self.stuckT = self.stuckT + dt
    else
      self.stuckT = 0
    end
    if into > span or self.stuckT >= cfg.stuckS then
      self.phase, self.waitT = 'wait', 0
    end
    return nil
  end

  -- wait: a moment to read the result, then back to the start.
  self.waitT = self.waitT + dt
  if self.waitT >= cfg.pauseS then
    self.phase, self.stuckT, self.judged = 'run', 0, false
    self.attempts = self.attempts + 1
    self.lastCell = nil
    return 'load'
  end
  return nil
end

return Drill
