-- The co-driver: decides which corner to call, when to call it, and when to
-- say "brake". Pure logic: no game API, standard Lua only.
--
-- The brake cue is adaptive. The plan holds, for every point of the track,
-- the highest speed from which the coming corners can still be made
-- (plan.env). "Brake" fires when the car's own speed is about to cross that
-- curve, so a slower approach gets a later cue.

local U = require('src/util')
local Track = require('src/track')

local Pilot = {}
Pilot.__index = Pilot

function Pilot.new(track, cfg)
  local self = setmetatable({}, Pilot)
  self.track, self.cfg = track, cfg
  self.plan = nil
  self.card = {}
  self.events = {}
  self:reset()
  return self
end

function Pilot:setPlan(plan)
  self.plan = plan
end

-- Call after a teleport or session restart.
function Pilot:reset()
  self.target = nil
  self.announced = {}
  self.armed = true
  self.belowT = 0
  self.cueT = nil
  self.cueKind = nil
  self.lastCell = nil
  self.recued = false
  self.cueFor, self.cueN, self.brakeCueT = nil, 0, nil
  self.lastBestD = nil
end

-- Call after the driver has recovered from a spin or an excursion: the corner
-- ahead is announced again, because they have lost their place.
function Pilot:reorient()
  if self.target then self.announced[self.target] = nil end
  self.armed = true
end

-- The corner a given cell belongs to, or the next one after it.
local function cornerAt(track, cell)
  local bestI, bestD
  for i, c in ipairs(track.corners) do
    local d = U.forward(cell, c.endCell, track.n)
    if not bestD or d < bestD then bestI, bestD = i, d end
  end
  return bestI
end

function Pilot:_announce(idx, events)
  if self.announced[idx] then return end
  local corners = self.track.corners
  local c = corners[idx]
  self.announced[idx] = true
  local ev = { kind = 'corner', corner = c }
  -- Corners that follow immediately (a chicane) are called in the same breath.
  local at = idx
  while corners[at].linkNext and #corners > 1 and (not ev.chain or #ev.chain < 2) do
    local ni = (at % #corners) + 1
    if ni == idx or self.announced[ni] then break end
    ev.chain = ev.chain or {}
    ev.chain[#ev.chain + 1] = corners[ni]
    self.announced[ni] = true
    at = ni
  end
  events[#events + 1] = ev
end

-- pos: track position 0..1, speedMs: m/s, dt: seconds
-- opts: { leadS = extra seconds of warning for the brake cue,
--         callLeadS = how early corners are called (default from config),
--         gas, brake = current pedals 0..1,
--         busy = true while the driver is dealing with a mistake }
-- Returns card (what to show) and events (what to say this frame).
function Pilot:update(pos, speedMs, dt, opts)
  local events = self.events
  for i = #events, 1, -1 do events[i] = nil end
  local card = self.card
  local track, plan, cfg = self.track, self.plan, self.cfg
  local corners = track.corners
  card.ready = false
  if not plan or #corners == 0 then return card, events end

  local n, cellM, env = track.n, track.cellM, plan.env
  local cell = Track.cellAt(track, pos)
  local v = speedMs
  local active = v * 3.6 >= cfg.minActiveKmh

  -- Target: the corner whose apex comes next.
  local best, bestD
  for i, c in ipairs(corners) do
    local d = U.forward(cell, c.apexCell, n)
    if not bestD or d < bestD then best, bestD = i, d end
  end
  if self.target ~= best or (self.lastBestD and bestD > self.lastBestD + 2) then
    -- An apex has just been passed.
    if self.target then self.announced[self.target] = nil end
    if self.cueFor == self.target then self.cueFor = nil end
    self.target = best
  end
  self.lastBestD = bestD
  local c = corners[best]
  local startD = U.forward(cell, c.startCell, n)
  local inCorner = startD > bestD
  local distStartM = inCorner and 0 or startD * cellM

  -- Where, at this speed, does the car meet the braking curve?
  local brakeCells
  if v > 1 then
    for j = 0, bestD do
      if env[U.wrapIndex(cell + j, n)] <= v then brakeCells = j break end
    end
  end
  local kind, governIdx, distBrakeM
  if brakeCells then
    -- Follow the curve down to its minimum: that corner is the reason to brake.
    local i = U.wrapIndex(cell + brakeCells, n)
    for _ = 1, n do
      local nxt = (i % n) + 1
      if env[nxt] > env[i] + 1e-6 then break end
      i = nxt
    end
    local dropKmh = (v - env[i]) * 3.6
    if dropKmh >= cfg.minBrakeDropKmh then
      kind = 'brake'
    elseif dropKmh >= cfg.minLiftDropKmh then
      kind = 'lift'
    end
    if kind then
      governIdx = cornerAt(track, i)
      distBrakeM = brakeCells * cellM
      -- Being over the plan on the way OUT of a corner is not a reason to brake.
      if U.forward(cell, corners[governIdx].apexCell, n) >= n / 2 then
        kind, governIdx, distBrakeM = nil, nil, nil
      end
    end
  end

  -- Stay with the driver. From the apex of the corner just taken until a
  -- little past its end they are busy with the exit, and after a mistake
  -- they are busy recovering. The next corner waits, unless it cannot.
  local prev = corners[((best - 2) % #corners) + 1]
  local exiting = false
  if prev ~= c then
    local span = U.forward(prev.apexCell, prev.endCell, n) + math.floor(cfg.exitHoldM / cellM)
    exiting = U.forward(prev.apexCell, cell, n) <= span
  end
  local vv = math.max(v, 1)
  local urgent = (kind == 'brake' and distBrakeM / vv <= cfg.urgentS) or distStartM / vv <= cfg.urgentS
  local hold = (exiting or (opts and opts.busy) == true) and not urgent

  -- Corner callouts come first so "brake" never precedes the corner name.
  if active and not hold then
    local leadS = (opts and opts.callLeadS) or cfg.announceLeadS
    local brakeSoon = kind == 'brake' and (distBrakeM / vv) <= leadS
    if brakeSoon or distStartM <= math.max(cfg.announceMinM, v * leadS) then
      self:_announce(best, events)
      if brakeSoon and governIdx and governIdx ~= best then
        self:_announce(governIdx, events)
      end
    end
  end

  -- Brake / lift cue, fired once per approach.
  if v < 0.93 * env[cell] then
    self.belowT = self.belowT + dt
    if self.belowT >= 0.3 then
      self.armed = true
      self.recued = false
    end
  else
    self.belowT = 0
  end
  local lead = cfg.reactionS + ((opts and opts.leadS) or 0)
  local needNow = kind ~= nil and distBrakeM <= v * lead
  if self.cueT then self.cueT = self.cueT + dt end
  if self.brakeCueT then self.brakeCueT = self.brakeCueT + dt end
  -- Someone who is already slowing down does not need to be told to.
  local pedalBrake, pedalGas = (opts and opts.brake) or 0, (opts and opts.gas) or 1
  local already = pedalBrake >= cfg.brakingOn or (kind == 'lift' and pedalGas < cfg.liftedGas)
  local repeatOk = self.cueFor ~= governIdx
    or (self.cueN < cfg.maxBrakeCues and (self.brakeCueT or math.huge) >= cfg.brakeCueGapS)
  if active and needNow and self.armed and not already and repeatOk then
    self.armed = false
    self.belowT = 0
    if self.cueFor ~= governIdx then self.cueFor, self.cueN = governIdx, 0 end
    self.cueN = self.cueN + 1
    self.brakeCueT = 0
    self.cueT, self.cueKind = 0, kind
    events[#events + 1] = { kind = kind, corner = corners[governIdx] }
  elseif plan.fixed and active and kind == 'brake' and not self.armed and not self.recued
      and self.cueKind == 'brake' and self.cueT and self.cueT >= cfg.reCueS
      and v > env[cell] and opts and opts.brake and opts.brake < 0.1 then
    -- Past the benchmark's brake point and still not braking: say it again.
    self.recued = true
    self.cueT = 0
    events[#events + 1] = { kind = 'brake', corner = corners[governIdx], again = true }
  end
  -- Throttle cue: with a benchmark, say so at the point where it went back
  -- to the throttle, if the driver has not done so yet.
  local targets = plan.targets
  if targets and self.lastCell and active and not needNow then
    local moved = U.forward(self.lastCell, cell, n)
    if moved > 0 and moved < n / 10 then
      for step = 0, 1 do
        local idx = ((best - 1 - step) % #corners) + 1      -- this corner, then the one just passed
        local tg = targets[idx]
        if tg and tg.throttleCell then
          local toPoint = U.forward(self.lastCell, tg.throttleCell, n)
          if toPoint > 0 and toPoint <= moved and ((opts and opts.gas) or 1) < cfg.throttleLowGas then
            self.cueT, self.cueKind = 0, 'throttle'
            events[#events + 1] = { kind = 'throttle', corner = corners[idx] }
            break
          end
        end
      end
    end
  end
  self.lastCell = cell

  local cue
  if needNow and (not already or v > env[cell]) then
    cue = kind
  elseif self.cueT and self.cueT < cfg.cueHoldS then
    cue = self.cueKind
  end

  card.ready = true
  card.corner = c
  card.inCorner = inCorner
  card.distStartM = distStartM
  card.distBrakeM = distBrakeM
  card.cue = cue
  card.brakeFor = governIdx and corners[governIdx] or nil
  card.target = targets and targets[best] or nil            -- real targets, if a benchmark exists
  card.estKmh = (c.vTargetMs or 0) * 3.6
  card.nextCorner = (#corners > 1) and corners[(best % #corners) + 1] or nil
  card.nextGapM = c.gapNextM
  card.phase = nil
  if exiting and hold then
    -- Still on the way out: keep showing the corner being finished, with the
    -- one ahead as a preview.
    card.phase = 'exit'
    card.corner, card.inCorner = prev, false
    card.target = nil
    card.estKmh = 0
    card.nextCorner, card.nextGapM = c, distStartM
  end
  return card, events
end

return Pilot
