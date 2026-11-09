-- The driving line drawn on the track, taken from the benchmark lap:
--   red    where the benchmark brakes
--   green  where it is on full throttle
--   yellow in between
-- plus a red bar across the track at each brake point and a white square at
-- the slowest point of each corner.
--
-- This is the least certain part of the app, so it protects itself: the first
-- error switches it off for the session and is reported in Diagnostics.

local Sim = require('src/sim')
local U = require('src/util')
local Track = require('src/track')
local config = require('src/config')

local Markers = {
  disabled = false,
  status = 'waiting for a benchmark lap',
  quads = 0,           -- drawn in the last frame
  sides = {},          -- cell -> { left, right } track width, cached
}

local RED = rgbm(1.0, 0.12, 0.08, 0.85)
local GREEN = rgbm(0.15, 1.0, 0.30, 0.75)
local YELLOW = rgbm(1.0, 0.85, 0.10, 0.80)
local GATE = rgbm(1.0, 0.05, 0.05, 0.95)
local WHITE = rgbm(1.0, 1.0, 1.0, 0.95)

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

-- Called from the 3D render callback.
function Markers.draw(app)
  if Markers.disabled then return end
  if not app.settings.line3d then
    Markers.status = 'switched off in Settings'
    return
  end
  local plan = app.benchPlan
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
  if ok then
    Markers.status = 'drawing'
  else
    Markers.disabled = true
    Markers.status = 'switched off after an error: ' .. tostring(err)
    Sim.log('3D line switched off after an error: ' .. tostring(err))
  end
end

return Markers
