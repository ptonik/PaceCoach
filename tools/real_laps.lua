-- Turns the files the app writes during a real session back into something
-- the stand-in game can drive, so the session can be replayed and looked at.
--
--   <track>__<car>.session.txt   the last laps of the session (always needed)
--   <track>__<car>.txt           the saved laps: the teacher lap comes from here
--
-- The app is then run over those laps again. What it says is what the
-- current version makes of them, which can differ from what was heard in
-- the car; lock-ups, slides and track limits are not in the files at all.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/?.lua;' .. package.path

local config = require('src/config')
local Track = require('src/track')
local Reference = require('src/reference')

local Real = {}

-- Returns { world =, store =, samples =, fake =, laps = { ms }, teacherMs = } or nil and a reason.
function Real.load(sessionText, comboText)
  local session, why = Reference.decode(sessionText)
  if not session then return nil, 'session file: ' .. tostring(why) end
  local n = session.n
  local names = {}
  for name in pairs(session.laps) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then return nil, 'the session file holds no complete laps' end
  local laps = {}
  for i, name in ipairs(names) do laps[i] = session.laps[name] end

  local teacher
  local combo = comboText and Reference.decode(comboText)
  if combo and combo.n == n then teacher = combo.laps.teacher end

  -- The track as the game described it: the teacher follows the ideal line
  -- closely, so its path stands in for it; failing that, the fastest lap.
  local lineLap = teacher
  if not lineLap then
    for _, lap in ipairs(laps) do
      if not lineLap or lap.timeMs < lineLap.timeMs then lineLap = lap end
    end
  end
  local mirror = session.left == -1
  local sx = mirror and -1 or 1
  local points = {}
  for i = 1, n do points[i] = { x = lineLap.x[i] * sx, z = lineLap.z[i] } end
  local world = Track.build(points, { cfg = config.track, leftSign = 1 })

  local store = {}
  if teacher then
    store['C:/Users/me/Documents/Assetto Corsa/PaceCoach/ks_synthetic-rect__test_car.txt'] =
      Reference.encode({ track = 'ks_synthetic-rect', car = 'test_car', n = n, laps = { teacher = teacher } })
  end

  -- Each lap as 60 samples a second, with how far it ran from the line.
  local samples, dt = {}, 1 / 60
  local out = { world = world, store = store, samples = samples, laps = {},
    teacherMs = teacher and teacher.timeMs or nil,
    fake = { mirror = mirror, lengthM = (n > config.grid.minCells and n < config.grid.maxCells) and n * config.grid.cellM or nil } }
  local function at(arr, j, f)
    local nxt = (j % n) + 1
    return arr[j] + (arr[nxt] - arr[j]) * f
  end
  for li, lap in ipairs(laps) do
    out.laps[li] = lap.timeMs
    local off = {}
    for i = 1, n do
      local a, b = points[i], points[(i % n) + 1]
      local dx, dz = b.x - a.x, b.z - a.z
      local len = math.sqrt(dx * dx + dz * dz)
      off[i] = (len > 1e-6) and ((lap.x[i] * sx - a.x) * -dz + (lap.z[i] - a.z) * dx) / len or 0
    end
    local j, tt = 1, 0
    while tt * 1000 < lap.timeMs do
      local ms = tt * 1000
      while j < n and lap.t[j + 1] <= ms do j = j + 1 end
      local t0 = lap.t[j]
      local t1 = (j < n) and lap.t[j + 1] or lap.timeMs
      local f = (t1 > t0) and math.max(0, math.min(1, (ms - t0) / (t1 - t0))) or 0
      local v = (j < n) and at(lap.v, j, f) or lap.v[j]
      samples[#samples + 1] = {
        pos = math.min(0.999999, (j - 1 + f) / n), t = ms, lapCount = li - 1, dt = dt,
        v = v, speedMs = v / 3.6,
        gas = (j < n) and at(lap.gas, j, f) or lap.gas[j], brake = (j < n) and at(lap.brake, j, f) or lap.brake[j],
        steer = (j < n) and at(lap.steer, j, f) or lap.steer[j], gear = lap.gear[j],
        offLeftM = (j < n) and at(off, j, f) or off[j],
        prevLapMs = (li > 1) and laps[li - 1].timeMs or 0,
      }
      tt = tt + dt
    end
  end
  -- A moment into the next lap, so the app gets to sum up the last one.
  local first, last = samples[1], laps[#laps]
  for k = 0, 45 do
    samples[#samples + 1] = {
      pos = math.min(0.2, first.speedMs * k * dt / world.lengthM), t = k * dt * 1000, lapCount = #laps, dt = dt,
      v = first.v, speedMs = first.speedMs, gas = first.gas, brake = first.brake, steer = first.steer,
      gear = first.gear, offLeftM = first.offLeftM, prevLapMs = last.timeMs,
    }
  end
  return out
end

return Real
