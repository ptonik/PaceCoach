-- Top-down track map with numbered corners and the car's position.

local G = require('src/gfx')
local U = require('src/util')

local Map = {}
local C = G.colors

Map.LABEL_REACH = { 1, -1.2, 2.2, -2.4, 3.4 }

-- Builds the reduced point lists once per track.
function Map.prepare(track)
  local n, pts = track.n, track.points
  if n < 16 or not track.bounds then return nil end
  local step = math.max(1, math.floor(n / 360))
  local m = { xs = {}, zs = {}, count = 0, bounds = track.bounds, flip = track.leftSign or 1,
    corners = {}, buf = {} }
  for i = 1, n, step do
    m.count = m.count + 1
    m.xs[m.count], m.zs[m.count] = pts[i].x, pts[i].z
  end
  for _, c in ipairs(track.corners) do
    local cx, cz, count = {}, {}, 0
    local cells = U.forward(c.startCell, c.endCell, n)
    local cstep = math.max(1, math.floor(cells / 24))
    for j = 0, cells, cstep do
      local p = pts[U.wrapIndex(c.startCell + j, n)]
      count = count + 1
      cx[count], cz[count] = p.x, p.z
    end
    local last = pts[c.endCell]
    count = count + 1
    cx[count], cz[count] = last.x, last.z
    local apex = pts[c.apexCell]
    m.corners[#m.corners + 1] = {
      xs = cx, zs = cz, count = count, name = c.name, severity = c.severity,
      apexX = apex.x, apexZ = apex.z, index = c.index,
    }
  end
  m.startX, m.startZ = pts[1].x, pts[1].z
  return m
end

-- Draws the map inside the rectangle x, y, w, h (window coordinates).
-- carX, carZ: world position of the car, or nil. highlight: corner index or nil.
function Map.draw(m, x, y, w, h, carX, carZ, highlight, labelSize)
  if not m then return end
  local b = m.bounds
  local spanX, spanZ = math.max(1, b.maxX - b.minX), math.max(1, b.maxZ - b.minZ)
  local pad = (labelSize or 12) + 8
  local scale = math.min((w - 2 * pad) / spanX, (h - 2 * pad) / spanZ)
  if scale <= 0 then return end
  local midX, midZ = (b.minX + b.maxX) / 2, (b.minZ + b.maxZ) / 2
  local cx, cy = x + w / 2, y + h / 2
  local kx, ky = scale * m.flip, -scale
  local buf = m.buf

  for i = 1, m.count do
    buf[i * 2 - 1] = cx + (m.xs[i] - midX) * kx
    buf[i * 2] = cy + (m.zs[i] - midZ) * ky
  end
  G.polyline(buf, m.count, C.track, 2.5, true)

  for _, c in ipairs(m.corners) do
    for i = 1, c.count do
      buf[i * 2 - 1] = cx + (c.xs[i] - midX) * kx
      buf[i * 2] = cy + (c.zs[i] - midZ) * ky
    end
    local color = G.severityColor[c.severity] or C.white
    G.polyline(buf, c.count, color, (highlight == c.index) and 6 or 4, false)
  end

  -- Start line marker.
  local sx, sy = cx + (m.startX - midX) * kx, cy + (m.startZ - midZ) * ky
  G.rect(sx - 3, sy - 3, sx + 3, sy + 3, C.white, 0)

  -- Corner names, pushed outwards from the middle of the map.
  local size = labelSize or 12
  local placed = m.placed or {}
  m.placed = placed
  local used = 0
  local function free(lx, ly)
    for i = 1, used, 2 do
      if math.abs(placed[i] - lx) < size * 2.1 and math.abs(placed[i + 1] - ly) < size * 1.2 then
        return false
      end
    end
    return true
  end
  for _, c in ipairs(m.corners) do
    local ax, ay = cx + (c.apexX - midX) * kx, cy + (c.apexZ - midZ) * ky
    local ox, oy = ax - cx, ay - cy
    local len = math.sqrt(ox * ox + oy * oy)
    if len < 1 then ox, oy, len = 0, -1, 1 end
    ox, oy = ox / len, oy / len
    -- Outside the track first, then inside, then further out each way.
    for _, reach in ipairs(Map.LABEL_REACH) do
      local lx, ly = ax + ox * (size + 4) * reach, ay + oy * (size + 4) * reach
      if free(lx, ly) then
        placed[used + 1], placed[used + 2] = lx, ly
        used = used + 2
        G.textCenter(c.name, size, lx, ly - size * 0.6, (highlight == c.index) and C.white or C.dim)
        break
      end
    end
  end

  if carX and carZ then
    local px, py = cx + (carX - midX) * kx, cy + (carZ - midZ) * ky
    G.dot(px, py, 5.5, C.cardBg)
    G.dot(px, py, 4, C.white)
  end
end

return Map
