-- The live coach: every frame it compares the driver with the benchmark lap
-- at the same place on the track, and says the one thing that would help
-- right now. Pure logic: no game API, standard Lua only.
--
-- It needs a benchmark plan from targets.lua (a teacher lap, a friend's lap
-- or the driver's own best). Without one it stays silent.
--
-- Cues:
--   brakeHarder   braking, but too gently to make the corner at this speed
--   easeOff       still braking although already well under the benchmark's speed
--   tooEarly      braking long before the benchmark's brake point
--   noBrake       braking for a corner the benchmark only lifts for
--   turnIn        the benchmark's turn-in point, spoken as you reach it
--   wait          on the throttle mid-corner, well before the benchmark
--   fullThrottle  the benchmark is flat out on this exit and you are not
--   stayFlat      lifting on a straight where the benchmark is still flat out
--   moveLeft / moveRight   off the benchmark's line on the way to a corner

local U = require('src/util')

local Live = {}
Live.__index = Live

-- Most urgent first: when several apply in the same frame, the first wins.
Live.PRIORITY = {
  'brakeHarder', 'noBrake', 'tooEarly', 'easeOff', 'wait', 'turnIn',
  'fullThrottle', 'stayFlat', 'moveLeft', 'moveRight',
}

-- How long each condition must hold before it is spoken (names in config.live).
local HOLD = {
  brakeHarder = 'harderHoldS', noBrake = 'noBrakeHoldS', tooEarly = 'earlyHoldS',
  easeOff = 'easeHoldS', wait = 'waitHoldS', stayFlat = 'liftHoldS',
  moveLeft = 'lineHoldS', moveRight = 'lineHoldS',
}

function Live.new(track, cfg)
  local self = setmetatable({}, Live)
  self.track, self.cfg = track, cfg
  self.gauge = { active = false }
  self.events = {}
  self.info = {}
  self.cond = {}
  self.plan = nil
  self:reset()
  return self
end

-- Call after a teleport or a session restart.
function Live:reset()
  self.said, self.count = {}, {}
  self.hold = {}
  self.clock = 0
  self.lastCueT = -1e9
  self.ahead = nil
  self.flatSaid = false
  self.unflatCell = nil
  self.gauge.cue, self.gauge.cueT, self.gauge.cueCorner = nil, nil, nil
end

-- plan: from Targets.build, or nil to switch the coach off.
function Live:setPlan(plan)
  self.plan = (plan and plan.lap and plan.targets and plan.slices) and plan or nil
  self.info = {}
  self.gauge.active = self.plan ~= nil
  if not self.plan then return end
  local track, cfg = self.track, self.cfg
  local n, cellM, corners = track.n, track.cellM, track.corners
  for k, c in ipairs(corners) do
    local tg, sl = plan.targets[k], plan.slices[k]
    if tg and sl and tg.minCell then
      local info = {
        brakeCell = tg.brakeCell, minCell = tg.minCell, throttleCell = tg.throttleCell,
        minMs = tg.minKmh / 3.6,
      }
      if tg.fullJ then info.fullCell = sl.cell[tg.fullJ] end

      -- Turn-in: where the benchmark's steering first reaches a share of its
      -- peak for this corner. Without a usable steering trace, the point
      -- where the ideal line starts to bend stands in.
      local from = math.max(1, tg.sJ - math.floor(cfg.turnPadM / cellM))
      local peak = 0
      for j = from, tg.eJ do
        local a = math.abs(sl.steer[j] or 0)
        if a > peak then peak = a end
      end
      info.turnCell = c.startCell
      if peak >= cfg.minSteerDeg then
        for j = from, tg.aJ do
          if math.abs(sl.steer[j] or 0) >= cfg.turnFrac * peak then
            info.turnCell, info.turnFromSteer = sl.cell[j], true
            break
          end
        end
      end

      -- Line advice is given between the exit of the previous corner and
      -- turn-in, where there is still room to move across the track.
      local prev = corners[((k - 2) % #corners) + 1]
      local room = track.lengthM
      if #corners > 1 then room = U.forward(prev.endCell, info.turnCell, n) * cellM end
      local ahead = math.min(cfg.lineAheadM, room - cfg.lineAfterExitM)
      if ahead > cfg.lineBeforeTurnM + 10 then
        info.lineFrom = U.wrapIndex(info.turnCell - math.floor(ahead / cellM), n)
        info.lineTo = U.wrapIndex(info.turnCell - math.floor(cfg.lineBeforeTurnM / cellM), n)
      end
      info.chained = #corners > 1 and prev.linkNext == true
      info.turnWorth = tg.brakeCell ~= nil or c.severity == 'hairpin'
        or c.severity == 'tight' or c.severity == 'medium'
      self.info[k] = info
    end
  end
end

local function inWindow(from, to, cell, n)
  return U.forward(from, cell, n) <= U.forward(from, to, n)
end

function Live:_saidFor(k)
  local said = self.said[k]
  if not said then
    said = {}
    self.said[k], self.count[k] = said, 0
  end
  return said
end

-- Rules that belong to one corner. Writes cue id -> corner index into cond.
function Live:_corner(k, inp, cell, v, vRef, cond)
  local info = self.info[k]
  if not info then return end
  local track, cfg, lap = self.track, self.cfg, self.plan.lap
  local n, cellM = track.n, track.cellM
  local c = track.corners[k]
  local half = n / 2

  if info.brakeCell then
    local toMin = U.forward(cell, info.minCell, n)
    if toMin < half and inWindow(info.brakeCell, info.minCell, cell, n) then
      -- Inside the benchmark's braking zone.
      local dMinM = toMin * cellM
      if dMinM > cfg.minRoomM then
        local vv, vr, vm = v / 3.6, vRef / 3.6, info.minMs
        local need = (vv * vv - vm * vm) / (2 * dMinM)
        local needRef = math.max(0, (vr * vr - vm * vm) / (2 * dMinM))
        if inp.brake >= cfg.brakingOn and inp.brake < cfg.hardBrake
            and v - vRef > cfg.harderKmh
            and need > math.max(needRef * cfg.harderRatio, cfg.harderMinG * 9.81) then
          cond.brakeHarder = k
        end
        if inp.brake > cfg.easeBrake
            and v - vRef < -math.max(cfg.easeKmh, cfg.easeFrac * vRef) then
          cond.easeOff = k
        end
      end
    else
      -- Before it: is the driver braking where the benchmark is still flat out?
      local toBrake = U.forward(cell, info.brakeCell, n)
      local dBrakeM = toBrake * cellM
      if toBrake < half and dBrakeM < 400 and inp.brake > cfg.earlyBrake
          and lap.gas[cell] >= cfg.flatRefGas
          and dBrakeM > math.max(cfg.earlyM, v / 3.6 * cfg.earlyS) then
        cond.tooEarly = k
      end
    end
  else
    local from = U.wrapIndex(c.startCell - math.floor(cfg.noBrakeAheadM / cellM), n)
    if inp.brake > cfg.earlyBrake and inWindow(from, c.apexCell, cell, n) then
      cond.noBrake = k
    end
  end

  -- Mid-corner: on the throttle while the benchmark is still waiting.
  if inp.gas > cfg.waitGas and inWindow(c.startCell, info.throttleCell or c.endCell, cell, n) then
    local aheadCell = U.wrapIndex(cell + math.floor(cfg.waitAheadM / cellM), n)
    if lap.gas[cell] < cfg.waitRefGas and lap.gas[aheadCell] < cfg.waitRefGas
        and v - vRef > -cfg.waitSlackKmh then
      cond.wait = k
    end
  end

  -- Line on the way in.
  if info.lineFrom and inp.lineCue ~= false and inWindow(info.lineFrom, info.lineTo, cell, n) then
    local off = self.gauge.offLeftM or 0
    if off > cfg.lineM then
      cond.moveRight = k
    elseif off < -cfg.lineM then
      cond.moveLeft = k
    end
  end

  -- Turn-in point.
  if inp.turnCue ~= false and info.turnWorth and not info.chained then
    local toTurn = U.forward(cell, info.turnCell, n)
    if toTurn < half and toTurn * cellM <= v / 3.6 * cfg.turnLeadS then cond.turnIn = k end
  end
end

-- inp: { cell =, pos = 0..1, v = km/h, gas =, brake =, x =, z =,
--        busy = true while the driver is dealing with a mistake,
--        pilotCue = the co-driver's current cue ('brake', ...), if any,
--        turnCue = false to leave out "turn in", lineCue = false to leave out the line,
--        maxPerCorner = cap on cues per corner }
-- Returns gauge (what to show) and events (what to say this frame).
function Live:update(inp, dt)
  local events = self.events
  for i = #events, 1, -1 do events[i] = nil end
  local g, cfg = self.gauge, self.cfg
  self.clock = self.clock + dt
  if g.cue and self.clock - (g.cueT or 0) > cfg.showS then
    g.cue, g.cueCorner = nil, nil
  end
  local plan = self.plan
  local track = self.track
  local corners = track.corners
  if not plan or #corners == 0 then
    g.active = false
    return g, events
  end
  local lap = plan.lap
  local n, cellM = track.n, track.cellM
  local cell, v = inp.cell, inp.v
  local nextCell = (cell % n) + 1

  -- The gauges: the benchmark's speed and pedals here, and how far the car
  -- is to the left of the benchmark's line.
  local vRef = lap.v[cell]
  g.active = true
  g.vRef, g.dv = vRef, v - vRef
  g.refGas, g.refBrake = lap.gas[cell], lap.brake[cell]
  local off = 0
  if inp.x and inp.z then
    local f = inp.pos and (inp.pos * n - math.floor(inp.pos * n)) or 0
    local rx = lap.x[cell] + (lap.x[nextCell] - lap.x[cell]) * f
    local rz = lap.z[cell] + (lap.z[nextCell] - lap.z[cell]) * f
    local i0, i1 = U.wrapIndex(cell - 2, n), U.wrapIndex(cell + 2, n)
    local dx, dz = lap.x[i1] - lap.x[i0], lap.z[i1] - lap.z[i0]
    local len = math.sqrt(dx * dx + dz * dz)
    if len > 1e-6 then
      off = ((inp.x - rx) * -dz + (inp.z - rz) * dx) / len * track.leftSign
    end
  end
  g.offLeftM = off

  -- The corner whose apex comes next, and the one just passed.
  local a, aD
  for i, c in ipairs(corners) do
    local d = U.forward(cell, c.apexCell, n)
    if not aD or d < aD then a, aD = i, d end
  end
  if a ~= self.ahead then
    self.ahead = a
    self.said[a], self.count[a] = {}, 0      -- a new approach: everything may be said again
  end
  local b = ((a - 2) % #corners) + 1

  local cond = self.cond
  for id in pairs(cond) do cond[id] = nil end
  self:_corner(a, inp, cell, v, vRef, cond)
  if b ~= a then self:_corner(b, inp, cell, v, vRef, cond) end

  -- Flat out: the benchmark has been on full throttle for a while, stays on
  -- it for a while yet, and the driver is not.
  local flatKey, flatHold
  local refFlat = lap.gas[cell] >= cfg.flatRefGas and lap.brake[cell] < 0.05
  if refFlat then
    self.unflatCell = nil
  else
    self.unflatCell = self.unflatCell or cell
    if U.forward(self.unflatCell, cell, n) * cellM >= 20 then self.flatSaid = false end
  end
  if refFlat and not self.flatSaid and inp.brake < 0.05 and inp.gas < cfg.partGas then
    local behind = U.wrapIndex(cell - math.floor(cfg.flatBehindM / cellM), n)
    local ahead = U.wrapIndex(cell + math.floor(cfg.flatAheadM / cellM), n)
    if lap.gas[behind] >= cfg.flatRefGas and lap.gas[ahead] >= cfg.flatRefGas
        and lap.brake[ahead] < 0.05 then
      local ib = self.info[b]
      local exitFrom = ib and (ib.fullCell or ib.throttleCell) or corners[b].endCell
      local onExit = U.forward(exitFrom, cell, n) * cellM <= cfg.exitRegionM
      local lifting = inp.gas < cfg.liftGas
      if onExit then
        cond.fullThrottle, flatKey = b, 'flatOut'
      elseif lifting then
        cond.stayFlat, flatKey = a, 'flatIn'
      else
        cond.fullThrottle, flatKey = a, 'flatIn'
      end
      flatHold = lifting and cfg.liftHoldS or cfg.partHoldS
    end
  end

  -- Each condition has to hold for a moment before it is worth saying.
  local quiet = inp.busy == true or v < cfg.minKmh
  local hold = self.hold
  for _, id in ipairs(Live.PRIORITY) do
    if cond[id] and not quiet then
      hold[id] = (hold[id] or 0) + dt
    else
      hold[id] = 0
    end
  end
  if quiet then return g, events end

  local cap = inp.maxPerCorner or cfg.maxPerCorner
  for _, id in ipairs(Live.PRIORITY) do
    local k = cond[id]
    if k then
      local needS = 0
      if id == 'fullThrottle' then
        needS = flatHold or cfg.partHoldS
      elseif HOLD[id] then
        needS = cfg[HOLD[id]]
      end
      if hold[id] >= needS then
        local said = self:_saidFor(k)
        local key = id
        if id == 'moveLeft' or id == 'moveRight' then
          key = 'line'
        elseif id == 'fullThrottle' or id == 'stayFlat' then
          key = flatKey or 'flatIn'
        end
        local urgent = id == 'brakeHarder'
        local quick = urgent or id == 'turnIn'
        local gapOk = self.clock - self.lastCueT >= (quick and cfg.gapS * 0.5 or cfg.gapS)
        local room = id == 'turnIn' or self.count[k] < cap
        if not said[key] and gapOk and room and (urgent or inp.pilotCue ~= 'brake') then
          said[key] = true
          if key == 'flatIn' or key == 'flatOut' then self.flatSaid = true end
          if id ~= 'turnIn' then self.count[k] = self.count[k] + 1 end
          self.lastCueT = self.clock
          g.cue, g.cueT, g.cueCorner = id, self.clock, corners[k]
          events[#events + 1] = { kind = 'coach', id = id, corner = corners[k], urgent = urgent }
          break
        end
      end
    end
  end
  return g, events
end

return Live
