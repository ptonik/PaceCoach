-- The spotter: says when a car is alongside and when it has gone, the way a
-- spotter on the radio does. Pure logic: no game API, standard Lua only.
--
-- It also reports traffic close ahead, so the coach can stay out of it:
-- nobody wants to hear about their brake point while they are in a fight.

local Spotter = {}
Spotter.__index = Spotter

function Spotter.new(cfg)
  local self = setmetatable({}, Spotter)
  self.cfg = cfg
  self.state = { left = false, right = false, traffic = false }
  self.events = {}
  self:reset()
  return self
end

function Spotter:reset()
  self.onT = { left = 0, right = 0 }
  self.offT = { left = 0, right = 0 }
  self.state.left, self.state.right, self.state.traffic = false, false, false
  self.quietT = 0
end

-- me:     { x =, z =, lookX =, lookZ = (unit vector the car points along), speedKmh = }
-- others: array of { x =, z =, inPit = }, count: how many of them are in use
-- leftSign: which way is left in this world (see sim.lua)
-- Returns state { left =, right =, traffic = } and events
-- ({ id = 'carLeft' | 'carRight' | 'threeWide' | 'clear' }).
function Spotter:update(me, others, count, leftSign, dt)
  local cfg, events = self.cfg, self.events
  for i = #events, 1, -1 do events[i] = nil end
  local st = self.state
  local seen = { left = false, right = false }
  local traffic = false
  if me.lookX and me.speedKmh >= cfg.minKmh then
    local fx, fz = me.lookX, me.lookZ
    local lx, lz = -fz * leftSign, fx * leftSign
    for i = 1, count do
      local o = others[i]
      if not o.inPit then
        local dx, dz = o.x - me.x, o.z - me.z
        local ahead, side = dx * fx + dz * fz, dx * lx + dz * lz
        if math.abs(ahead) <= cfg.overlapM and math.abs(side) >= cfg.minSideM and math.abs(side) <= cfg.maxSideM then
          if side > 0 then seen.left = true else seen.right = true end
        end
        if ahead > 0 and ahead <= cfg.trafficAheadM and math.abs(side) <= cfg.trafficSideM then traffic = true end
      end
    end
  end
  st.traffic = traffic or seen.left or seen.right

  local was = st.left or st.right
  for _, name in ipairs({ 'left', 'right' }) do
    if seen[name] then
      self.onT[name], self.offT[name] = self.onT[name] + dt, 0
      if not st[name] and self.onT[name] >= cfg.onS then
        st[name] = true
        local other = (name == 'left') and 'right' or 'left'
        events[#events + 1] = { id = st[other] and 'threeWide' or ((name == 'left') and 'carLeft' or 'carRight') }
      end
    else
      self.offT[name], self.onT[name] = self.offT[name] + dt, 0
      if st[name] and self.offT[name] >= cfg.offS then st[name] = false end
    end
  end
  if was and not (st.left or st.right) then events[#events + 1] = { id = 'clear' } end
  return st, events
end

return Spotter
