-- Thin drawing helpers over the CSP ui.* functions, shared by the HUD, the
-- map and the panel. Coordinates are relative to the current window.

local Sim = require('src/sim')

local G = {}

-- A small ring of reusable vec2 objects, so drawing does not create garbage.
local pool, poolIndex, POOL = {}, 0, 48
local function P(x, y)
  poolIndex = (poolIndex % POOL) + 1
  local v = pool[poolIndex]
  if not v then
    v = vec2(0, 0)
    pool[poolIndex] = v
  end
  v.x, v.y = x, y
  return v
end
G.P = P

G.colors = {
  white = rgbm(1, 1, 1, 1),
  dim = rgbm(1, 1, 1, 0.65),
  faint = rgbm(1, 1, 1, 0.3),
  cardBg = rgbm(0.06, 0.07, 0.09, 0.78),
  tipBg = rgbm(0.10, 0.11, 0.14, 0.85),
  brakeBg = rgbm(0.75, 0.05, 0.05, 0.92),
  liftBg = rgbm(0.80, 0.50, 0.00, 0.90),
  goodBg = rgbm(0.05, 0.42, 0.18, 0.90),
  red = rgbm(1.0, 0.25, 0.22, 1),
  orange = rgbm(1.0, 0.58, 0.12, 1),
  yellow = rgbm(1.0, 0.86, 0.20, 1),
  green = rgbm(0.30, 0.90, 0.40, 1),
  cyan = rgbm(0.35, 0.80, 1.0, 1),
  track = rgbm(1, 1, 1, 0.55),
  barBg = rgbm(1, 1, 1, 0.14),
  pedalDimRed = rgbm(1.0, 0.25, 0.22, 0.5),
  pedalDimGreen = rgbm(0.30, 0.90, 0.40, 0.5),
}

G.severityColor = {
  hairpin = G.colors.red,
  tight = G.colors.orange,
  medium = G.colors.yellow,
  fast = G.colors.green,
  kink = G.colors.cyan,
}

function G.rect(x0, y0, x1, y1, color, rounding)
  ui.drawRectFilled(P(x0, y0), P(x1, y1), color, rounding or 0)
end

function G.line(x0, y0, x1, y1, color, thickness)
  ui.drawLine(P(x0, y0), P(x1, y1), color, thickness or 1)
end

function G.dot(x, y, radius, color)
  if Sim.has['ui.drawCircleFilled'] then
    ui.drawCircleFilled(P(x, y), radius, color, 16)
  else
    ui.drawRectFilled(P(x - radius, y - radius), P(x + radius, y + radius), color, radius)
  end
end

function G.text(str, size, x, y, color)
  ui.dwriteDrawText(str, size, P(x, y), color or G.colors.white)
end

local measureWorks = nil
function G.textWidth(str, size)
  if measureWorks ~= false and Sim.has['ui.measureDWriteText'] then
    local ok, r = pcall(ui.measureDWriteText, str, size)
    if ok and r ~= nil then
      local okX, w = pcall(function() return r.x end)
      if okX and type(w) == 'number' then
        measureWorks = true
        return w
      end
    end
    measureWorks = false
  end
  return G.guessWidth(str, size)
end

-- Rough text width for when the game cannot measure it.
function G.guessWidth(str, size)
  local wide = select(2, str:gsub('[%u%dmwMW]', ''))
  return (wide * 0.66 + (#str - wide) * 0.5) * size
end

function G.textRight(str, size, xRight, y, color)
  G.text(str, size, xRight - G.textWidth(str, size), y, color)
end

function G.textCenter(str, size, xCenter, y, color)
  G.text(str, size, xCenter - G.textWidth(str, size) / 2, y, color)
end

-- An open polyline. points is a flat array { x1, y1, x2, y2, ... }.
function G.polyline(points, count, color, thickness, closed)
  if count < 2 then return end
  if Sim.has['ui.pathClear'] and Sim.has['ui.pathLineTo'] and Sim.has['ui.pathStroke'] then
    ui.pathClear()
    for i = 1, count do
      ui.pathLineTo(P(points[i * 2 - 1], points[i * 2]))
    end
    ui.pathStroke(color, closed == true, thickness or 1)
  else
    for i = 1, count - 1 do
      G.line(points[i * 2 - 1], points[i * 2], points[i * 2 + 1], points[i * 2 + 2], color, thickness)
    end
    if closed then
      G.line(points[count * 2 - 1], points[count * 2], points[1], points[2], color, thickness)
    end
  end
end

-- A bent arrow showing which way the corner goes and how sharp it is.
local BEND_DEG = { tight = 90, medium = 62, fast = 38, kink = 20 }
function G.cornerArrow(x, y, size, dir, severity, color)
  local sgn = (dir == 'left') and -1 or 1
  local th = size * 0.12
  local function seg(x0, y0, x1, y1)
    G.line(x0, y0, x1, y1, color, th)
    G.dot(x0, y0, th * 0.5, color)
    G.dot(x1, y1, th * 0.5, color)
  end
  local ex, ey, dx, dy
  if severity == 'hairpin' then
    local xa, xb = x + size * (0.5 - sgn * 0.2), x + size * (0.5 + sgn * 0.2)
    seg(xa, y + size * 0.9, xa, y + size * 0.25)
    seg(xa, y + size * 0.25, xb, y + size * 0.25)
    seg(xb, y + size * 0.25, xb, y + size * 0.62)
    ex, ey, dx, dy = xb, y + size * 0.62, 0, 1
  else
    local cx = x + size * (0.5 - sgn * 0.14)
    local yBend = y + size * 0.52
    local a = math.rad(BEND_DEG[severity] or 62)
    local len = size * 0.38
    dx, dy = sgn * math.sin(a), -math.cos(a)
    ex, ey = cx + dx * len, yBend + dy * len
    seg(cx, y + size * 0.92, cx, yBend)
    seg(cx, yBend, ex, ey)
  end
  -- arrow head
  local hl = size * 0.2
  local px, py = -dy, dx
  seg(ex + dx * th * 0.3, ey + dy * th * 0.3, ex - dx * hl + px * hl * 0.7, ey - dy * hl + py * hl * 0.7)
  seg(ex + dx * th * 0.3, ey + dy * th * 0.3, ex - dx * hl - px * hl * 0.7, ey - dy * hl - py * hl * 0.7)
end

return G
