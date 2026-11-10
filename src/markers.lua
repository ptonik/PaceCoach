-- The driving line drawn on the track, taken from the benchmark lap:
--   red    where the benchmark brakes
--   green  where it is on full throttle
--   yellow in between
-- plus a red bar across the track at each brake point and a white square at
-- the slowest point of each corner.
--
-- On top of that, the things a coach would put on the track:
--   a lead car a moment ahead of you, with brake lights, to follow
--   an orange board at YOUR brake marker for the corner (it moves as you improve)
--   cones at turn-in (white), apex (yellow) and exit (green)
--
-- This is the least certain part of the app, so it protects itself: the first
-- error switches it off for the session and is reported in Diagnostics.

local Sim = require('src/sim')
local U = require('src/util')
local Track = require('src/track')
local Ghost = require('src/ghost')
local config = require('src/config')

local Markers = {
  disabled = false,
  status = 'waiting for a benchmark lap',
  quads = 0,           -- drawn in the last frame
  ghostShown = false,  -- the lead car was drawn in the last frame
  cones = 0,           -- cones and boards drawn in the last frame
  sides = {},          -- cell -> { left, right } track width, cached
}

local RED = rgbm(1.0, 0.12, 0.08, 0.85)
local GREEN = rgbm(0.15, 1.0, 0.30, 0.75)
local YELLOW = rgbm(1.0, 0.85, 0.10, 0.80)
local GATE = rgbm(1.0, 0.05, 0.05, 0.95)
local WHITE = rgbm(1.0, 1.0, 1.0, 0.95)
local ORANGE = rgbm(1.0, 0.55, 0.05, 0.95)
local APEX = rgbm(1.0, 0.9, 0.1, 0.95)
local EXIT = rgbm(0.2, 1.0, 0.35, 0.95)
local BODY = rgbm(0.55, 0.85, 1.0, 0.38)
local ROOF = rgbm(0.75, 0.93, 1.0, 0.5)
local LIGHTS = rgbm(1.0, 0.08, 0.05, 0.98)
local LIGHTS_OFF = rgbm(0.45, 0.05, 0.05, 0.6)

local pool, poolIndex = {}, 0
local function V(x, y, z)
  poolIndex = (poolIndex % 16) + 1
  local v = pool[poolIndex]
  if not v then
    v = vec3(0, 0, 0)
    pool[poolIndex] = v
  end
  v.x, v.y, v.z = x, y, z
  return v
end

-- Drawn with both windings so it shows whichever way the game culls faces.
local function quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, color)
  render.quad(V(ax, ay, az), V(bx, by, bz), V(cx, cy, cz), V(dx, dy, dz), color)
  render.quad(V(dx, dy, dz), V(cx, cy, cz), V(bx, by, bz), V(ax, ay, az), color)
  Markers.quads = Markers.quads + 1
end

local function sidesAt(track, cell)
  local cached = Markers.sides[cell]
  if cached then return cached[1], cached[2] end
  local l, r = Sim.trackSides((cell - 1) / track.n)
  local half = config.line3d.defaultHalfTrackM
  l, r = l or half, r or half
  Markers.sides[cell] = { l, r }
  return l, r
end

local function drawAll(app, plan)
  local track, lap, pts, cfg = app.track, plan.lap, app.points, config.line3d
  local n = track.n
  Markers.quads = 0

  if Sim.has['render.setBlendMode'] and Sim.has['render.BlendMode.AlphaBlend'] then
    render.setBlendMode(render.BlendMode.AlphaBlend)
  end
  if Sim.has['render.setDepthMode'] and Sim.has['render.DepthMode.ReadOnly'] then
    render.setDepthMode(render.DepthMode.ReadOnly)
  end

  local cell = Track.cellAt(track, app.car.pos or 0)
  local aheadCells = math.floor(cfg.aheadM / track.cellM)
  local lift, half = cfg.liftM, cfg.halfWidthM

  -- The ribbon.
  local i0 = cell
  local x0, y0, z0 = lap.x[i0], (pts[i0].y or 0) + lift, lap.z[i0]
  for k = cfg.stepCells, aheadCells, cfg.stepCells do
    local i1 = U.wrapIndex(cell + k, n)
    local x1, y1, z1 = lap.x[i1], (pts[i1].y or 0) + lift, lap.z[i1]
    local dx, dz = x1 - x0, z1 - z0
    local len = math.sqrt(dx * dx + dz * dz)
    if len > 0.01 and len < 60 then
      local sx, sz = -dz / len * half, dx / len * half
      local color = YELLOW
      if lap.brake[i0] > 0.1 then
        color = RED
      elseif lap.gas[i0] >= 0.9 then
        color = GREEN
      end
      quad(x0 - sx, y0, z0 - sz, x0 + sx, y0, z0 + sz, x1 + sx, y1, z1 + sz, x1 - sx, y1, z1 - sz, color)
    end
    i0, x0, y0, z0 = i1, x1, y1, z1
  end

  -- Brake bars and slowest-point squares for the corners coming up.
  for k, _ in ipairs(track.corners) do
    local tg = plan.targets and plan.targets[k]
    if tg then
      local bc = tg.brakeCell
      if bc and U.forward(cell, bc, n) <= aheadCells then
        local p, q = pts[bc], pts[(bc % n) + 1]
        local dx, dz = q.x - p.x, q.z - p.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.01 then
          dx, dz = dx / len, dz / len
          local leftX, leftZ = -dz * track.leftSign, dx * track.leftSign
          local l, r = sidesAt(track, bc)
          local y = (p.y or 0) + lift + 0.02
          local ax, az = p.x + leftX * l, p.z + leftZ * l
          local bx, bz = p.x - leftX * r, p.z - leftZ * r
          local d = cfg.gateDepthM
          quad(ax, y, az, bx, y, bz, bx + dx * d, y, bz + dz * d, ax + dx * d, y, az + dz * d, GATE)
        end
      end
      local mc = tg.minCell
      if mc and U.forward(cell, mc, n) <= aheadCells then
        local x, z, y = lap.x[mc], lap.z[mc], (pts[mc].y or 0) + lift + 0.03
        local s = 0.45
        quad(x - s, y, z - s, x + s, y, z - s, x + s, y, z + s, x - s, y, z + s, WHITE)
      end
    end
  end
end

-- A point on the ideal line with the directions along and across the track.
local function frameAt(track, pts, cell)
  local n = track.n
  local p, q = pts[cell], pts[(cell % n) + 1]
  local dx, dz = q.x - p.x, q.z - p.z
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 0.01 then return nil end
  dx, dz = dx / len, dz / len
  return p.x, (p.y or 0), p.z, dx, dz, -dz * track.leftSign, dx * track.leftSign
end

-- A cone standing at the edge of the track: two crossed upright blades, so
-- it reads as a cone from any direction.
local function cone(x, y, z, fx, fz, lx, lz, size, color)
  local h, r = size, size * 0.38
  quad(x - lx * r, y, z - lz * r, x + lx * r, y, z + lz * r, x + lx * 0.04, y + h, z + lz * 0.04, x - lx * 0.04, y + h, z - lz * 0.04, color)
  quad(x - fx * r, y, z - fz * r, x + fx * r, y, z + fz * r, x + fx * 0.04, y + h, z + fz * 0.04, x - fx * 0.04, y + h, z - fz * 0.04, color)
  Markers.cones = Markers.cones + 1
end

-- An upright board facing the driver, standing at (x, z).
local function board(x, y, z, lx, lz, width, height, color)
  local w = width / 2
  quad(x - lx * w, y + 0.3, z - lz * w, x + lx * w, y + 0.3, z + lz * w, x + lx * w, y + 0.3 + height, z + lz * w, x - lx * w, y + 0.3 + height, z - lz * w, color)
  Markers.cones = Markers.cones + 1
end

-- The coach's cones for the corners coming up, and the driver's own brake
-- marker: a step later than where they last braked (see lesson.lua).
local function drawCones(app, plan)
  local track, pts, cfg = app.track, app.points, config.cones
  local n, cellM = track.n, track.cellM
  local cell = Track.cellAt(track, app.car.pos or 0)
  local aheadCells = math.floor(cfg.aheadM / cellM)
  local lift = config.line3d.liftM
  for k, c in ipairs(track.corners) do
    local tg = plan.targets and plan.targets[k]
    local info = app.live and app.live.info[k]
    if tg then
      local inside = (c.dir == 'left') and 1 or -1          -- +1: the inside of the corner is on the left
      local function at(target, side, size, color)
        if not target or U.forward(cell, target, n) > aheadCells then return end
        local x, y, z, fx, fz, lx, lz = frameAt(track, pts, target)
        if not x then return end
        local l, r = sidesAt(track, target)
        local off = (side > 0) and (l + 0.3) or -(r + 0.3)
        cone(x + lx * off, y + lift, z + lz * off, fx, fz, lx, lz, size, color)
      end
      at(info and info.turnCell or c.startCell, -inside, cfg.coneM, WHITE)   -- turn in from the outside
      at(tg.minCell or c.apexCell, inside, cfg.coneM, APEX)                  -- clip the inside
      at(c.endCell, -inside, cfg.coneM, EXIT)                                -- run out to the outside

      -- Your brake marker.
      local targetM = app.lesson and app.lesson:brakeTargetM(k)
      if tg.brakeCell and targetM then
        local bc = U.wrapIndex(tg.brakeCell - U.round(targetM / cellM), n)
        if U.forward(cell, bc, n) <= aheadCells then
          local x, y, z, fx, fz, lx, lz = frameAt(track, pts, bc)
          if x then
            local l, r = sidesAt(track, bc)
            y = y + lift
            board(x + lx * (l + 0.6), y, z + lz * (l + 0.6), lx, lz, cfg.boardWidthM, cfg.boardHeightM, ORANGE)
            board(x - lx * (r + 0.6), y, z - lz * (r + 0.6), lx, lz, cfg.boardWidthM, cfg.boardHeightM, ORANGE)
            local d = cfg.stripeM
            quad(x + lx * l, y + 0.03, z + lz * l, x - lx * r, y + 0.03, z - lz * r,
              x - lx * r + fx * d, y + 0.03, z - lz * r + fz * d, x + lx * l + fx * d, y + 0.03, z + lz * l + fz * d, ORANGE)
          end
        end
      end
    end
  end
end

-- The lead car: the benchmark, a moment ahead of the driver.
local function drawGhost(app, plan)
  local cfg, lap, track, pts = config.ghost, plan.lap, app.track, app.points
  Markers.ghostShown = false
  if (app.car.speedKmh or 0) < cfg.minKmh then return end
  local cell = Track.cellAt(track, app.car.pos or 0)
  local gc, braking = Ghost.locate(lap, cell, cfg.leadS)
  if not gc or U.forward(cell, gc, track.n) * track.cellM < cfg.minGapM then return end
  local x, z, fx, fz = Ghost.pose(lap, gc)
  if not x then return end
  local lx, lz = -fz, fx                                    -- across the car; which side is which does not matter for a box
  local y0 = (pts[gc].y or 0) + 0.25
  local y1, y2 = y0 + cfg.heightM * 0.55, y0 + cfg.heightM
  local hl, hw = cfg.lengthM / 2, cfg.widthM / 2
  local function corner(along, across) return x + fx * along + lx * across, z + fz * along + lz * across end
  local rlx, rlz = corner(-hl, hw)
  local rrx, rrz = corner(-hl, -hw)
  local flx, flz = corner(hl, hw)
  local frx, frz = corner(hl, -hw)
  -- body: two sides, front, top deck
  quad(rlx, y0, rlz, flx, y0, flz, flx, y1, flz, rlx, y1, rlz, BODY)
  quad(rrx, y0, rrz, frx, y0, frz, frx, y1, frz, rrx, y1, rrz, BODY)
  quad(flx, y0, flz, frx, y0, frz, frx, y1, frz, flx, y1, flz, BODY)
  quad(rlx, y1, rlz, rrx, y1, rrz, frx, y1, frz, flx, y1, flz, BODY)
  -- cabin
  local clx, clz = corner(-hl * 0.55, hw * 0.8)
  local crx, crz = corner(-hl * 0.55, -hw * 0.8)
  local dlx, dlz = corner(hl * 0.25, hw * 0.8)
  local drx, drz = corner(hl * 0.25, -hw * 0.8)
  quad(clx, y2, clz, crx, y2, crz, drx, y2, drz, dlx, y2, dlz, ROOF)
  quad(clx, y1, clz, crx, y1, crz, crx, y2, crz, clx, y2, clz, ROOF)
  -- the back of the car is the brake light: bright when the benchmark is braking
  quad(rlx, y0, rlz, rrx, y0, rrz, rrx, y1, rrz, rlx, y1, rlz, braking and LIGHTS or LIGHTS_OFF)
  Markers.ghostShown = true
end

-- Called from the 3D render callback.
function Markers.draw(app)
  if Markers.disabled then return end
  if not app.settings.line3d then
    Markers.status = 'switched off in Settings'
    return
  end
  local plan = app.benchPlan or app.coachPlan
  if not (plan and plan.lap and app.track and app.points and app.state == 'ready') then
    Markers.status = 'waiting for a benchmark lap'
    return
  end
  if not (Sim.has['render.quad'] and Sim.has['vec3']) then
    Markers.disabled = true
    Markers.status = '3D drawing is not available in this CSP build'
    return
  end
  local ok, err = pcall(drawAll, app, plan)
  Markers.cones, Markers.ghostShown = 0, false
  if ok and app.settings.cones then ok, err = pcall(drawCones, app, plan) end
  if ok and app.settings.ghostCar then ok, err = pcall(drawGhost, app, plan) end
  if ok then
    Markers.status = 'drawing'
  else
    Markers.disabled = true
    Markers.status = 'switched off after an error: ' .. tostring(err)
    Sim.log('3D line switched off after an error: ' .. tostring(err))
  end
end

return Markers
