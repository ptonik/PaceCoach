-- Records a simulated coaching session as data for the browser replay.
--   luajit tools/make_replay.lua out.json [laps]
--
-- The session is the one tests/story.lua plays: a simulated learner with a
-- different weakness in every corner, who after each lap does what the coach
-- asked for. Every drawing call the HUD makes is captured as it is made, so
-- the replay shows the app's own output, not a mock-up of it.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/?.lua;' .. root .. '/tests/?.lua;' .. package.path

local Story = require('story')
local S = require('src/strings')
local U = require('src/util')
local realIo = io

local target = arg and arg[1] or 'replay.json'
local wantLaps = tonumber(arg and arg[2]) or 20
local EVERY = 4                       -- keep one frame in four: 15 per second

-- What each clip says, for the captions (the same words tools/make_voice.sh speaks).
local SPOKEN = {
  brake = 'Brake!', beep = '(beep)', best_lap = 'Best lap', throttle = 'Throttle',
  teacher_ready = 'Teacher lap recorded', brake_harder = 'Brake harder!', ease_off = 'Ease off the brake',
  too_early = 'Too early', turn_in = 'Turn in', wait = 'Wait', full_throttle = 'Full throttle',
  stay_flat = 'Stay on the throttle', move_left = 'Move left', move_right = 'Move right',
  tip_brake_later = 'Brake a little later here', tip_brake_earlier = 'Brake a little earlier here',
  tip_lift = 'No brake, just lift', tip_more_speed = 'Carry more speed',
  tip_patience = 'Be patient with the throttle', tip_throttle_earlier = 'Earlier on the throttle',
  tip_no_coast = 'No coasting', tip_apex = 'Get close to the apex', tip_exit = 'Full throttle on the exit',
  good = 'Good', nice = 'Nice', better = 'Better', thats_it = "That's it", fixed = 'Sorted. Well done.',
}
for _, sev in ipairs({ 'hairpin', 'tight', 'medium', 'fast', 'kink' }) do
  for _, dir in ipairs({ 'left', 'right' }) do
    SPOKEN[sev .. '_' .. dir] = sev:sub(1, 1):upper() .. sev:sub(2) .. ' ' .. dir
  end
end
SPOKEN.then_left, SPOKEN.then_right = 'then left', 'then right'

-- Small JSON writer ---------------------------------------------------------------

local function num(x)
  if x ~= x or x == math.huge or x == -math.huge then return 'null' end
  local s = string.format('%.1f', x)
  s = s:gsub('%.0$', '')
  if s == '-0' then s = '0' end
  return s
end
local function str(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    return string.format('\\u%04x', c:byte())
  end) .. '"'
end

-- Recording ------------------------------------------------------------------------

local palette, paletteN, paletteList = {}, 0, {}
local function color(c)
  c = c or { r = 1, g = 1, b = 1, mult = 1 }
  local key = string.format('%d,%d,%d,%.2f', math.min(255, c.r * 255), math.min(255, c.g * 255),
    math.min(255, c.b * 255), c.mult)
  if not palette[key] then
    palette[key] = paletteN
    paletteN = paletteN + 1
    paletteList[paletteN] = '"rgba(' .. key .. ')"'
  end
  return palette[key]
end

local dict, dictN, dictList = {}, 0, {}
local current = {}
local function emit(call)
  local id = dict[call]
  if not id then
    id = dictN
    dict[call] = id
    dictN = dictN + 1
    dictList[dictN] = call
  end
  current[#current + 1] = id
end

local path = {}
local function hook()
  rawset(ui, 'drawRectFilled', function(a, b, c, rounding)
    emit(string.format('["r",%s,%s,%s,%s,%d,%s]', num(a.x), num(a.y), num(b.x), num(b.y), color(c), num(rounding or 0)))
  end)
  rawset(ui, 'drawLine', function(a, b, c, thickness)
    emit(string.format('["l",%s,%s,%s,%s,%d,%s]', num(a.x), num(a.y), num(b.x), num(b.y), color(c), num(thickness or 1)))
  end)
  rawset(ui, 'drawCircleFilled', function(p, radius, c)
    emit(string.format('["c",%s,%s,%s,%d]', num(p.x), num(p.y), num(radius), color(c)))
  end)
  rawset(ui, 'dwriteDrawText', function(text, size, pos, c)
    emit(string.format('["t",%s,%s,%s,%s,%d]', str(text), num(size), num(pos.x), num(pos.y), color(c)))
  end)
  rawset(ui, 'pathClear', function() path = {} end)
  rawset(ui, 'pathLineTo', function(p) path[#path + 1] = num(p.x) .. ',' .. num(p.y) end)
  rawset(ui, 'pathStroke', function(c, closed, thickness)
    emit(string.format('["p",[%s],%d,%s,%s]', table.concat(path, ','), color(c), closed and 1 or 0, num(thickness)))
    path = {}
  end)
  -- Keep the intent of right-aligned and centred text, so the page can align
  -- it with its own font instead of with the app's width estimate.
  local G = package.loaded['src/gfx']
  G.textRight = function(text, size, xRight, y, c)
    emit(string.format('["tr",%s,%s,%s,%s,%d]', str(text), num(size), num(xRight), num(y), color(c or G.colors.white)))
  end
  G.textCenter = function(text, size, xCenter, y, c)
    emit(string.format('["tc",%s,%s,%s,%s,%d]', str(text), num(size), num(xCenter), num(y), color(c or G.colors.white)))
  end
end

local frames, says, lapRows = {}, {}, {}
local hooked, count, playsSeen = false, 0, 0
local teacher, world
local clock = 0
local lapStart = { [1] = 0 }

local function ghostAt(track, lapTimeMs)
  -- Where the teacher was at this lap time: binary search in its time trace.
  local t, n = teacher.t, teacher.n
  if lapTimeMs >= teacher.timeMs then return track.points[1].x, track.points[1].z end
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if t[mid] <= lapTimeMs then lo = mid else hi = mid - 1 end
  end
  local p = track.points[lo]
  return p.x, p.z
end

local app, state, laps
app, state, laps, world = Story.run({
  laps = wantLaps,
  onFrame = function(a, st, s, lapIndex)
    if not hooked then
      hooked = true
      hook()
    end
    current = {}
    st.window.x, st.window.y = 460, 310
    teacher = teacher or a.teacherLap
    lapStart[lapIndex] = lapStart[lapIndex] or clock
  end,
  afterDraw = function(a, st, s, lapIndex)
    count = count + 1
    clock = clock + s.dt
    for i = playsSeen + 1, #st.plays do
      says[#says + 1] = string.format('[%s,%s,%s]', num(clock), str(st.plays[i].clip), str(SPOKEN[st.plays[i].clip] or st.plays[i].clip))
    end
    playsSeen = #st.plays
    if count % EVERY ~= 0 or not a.track then return end
    local track = a.track
    local n = track.n
    local cell = (math.floor(s.pos * n) % n) + 1
    local p0, p1 = track.points[cell], track.points[(cell % n) + 1]
    local dx, dz = p1.x - p0.x, p1.z - p0.z
    local len = math.sqrt(dx * dx + dz * dz)
    local off = s.offLeftM or 0
    local x, z = s.x - dz / len * off, s.z + dx / len * off
    local gx, gz = x, z
    if teacher then gx, gz = ghostAt(track, s.t) end
    local g = a.gauge
    frames[#frames + 1] = string.format('[%s,%d,%d,%s,%s,%.3f,%s,%s,%s,%.2f,%.2f,%s,%.2f,%.2f,%s,[%s]]',
      num(clock), lapIndex, U.round(s.t), num(x), num(z), math.atan2(dz, dx), num(gx), num(gz),
      num(s.v), s.gas, s.brake, num(g and g.vRef or s.v), g and g.refGas or 0, g and g.refBrake or 0,
      a.benchDeltaMs and tostring(U.round(a.benchDeltaMs)) or 'null', table.concat(current, ','))
  end,
  onLap = function(a, _, lapNumber, lapMs)
    local f = a.lesson.focus
    local c = f and a.track.corners[f.k]
    local lv = a.level
    lapRows[#lapRows + 1] = string.format('{"n":%d,"ms":%d,"t0":%s,"focus":%s,"vs":%s,"level":%s}', lapNumber, U.round(lapMs),
      num(lapStart[lapNumber] or 0),
      f and str(c.name .. ': ' .. S.remedy[f.id].short) or 'null',
      str(S.benchmark[a.coachLabel] or '-'), lv and str(S.level[lv.id]) or 'null')
  end,
})
assert(not app.lastError, app.lastError)

-- Track geometry and the teacher's pedals along it, for the scene.
local pts, zone = {}, {}
local n = world.n
for i = 1, n, 2 do
  local p = world.points[i]
  pts[#pts + 1] = num(p.x) .. ',' .. num(p.z)
  local z = 'c'
  if teacher.brake[i] > 0.1 then z = 'b' elseif teacher.gas[i] >= 0.9 then z = 'g' end
  zone[#zone + 1] = z
end
local corners = {}
for _, c in ipairs(world.corners) do
  local apex = world.points[c.apexCell]
  corners[#corners + 1] = string.format('{"name":%s,"dir":%s,"sev":%s,"from":%d,"to":%d,"x":%s,"z":%s}',
    str(c.name), str(c.dir), str(c.severity), math.floor((c.startCell - 1) / 2), math.floor((c.endCell - 1) / 2),
    num(apex.x), num(apex.z))
end

local out = {
  '{"fps":', num(60 / EVERY), ',"version":', str(app.version), ',"lengthM":', num(world.lengthM),
  ',"teacherMs":', tostring(U.round(teacher.timeMs)),
  ',"carMs":', tostring(U.round(Story.carLimitMs(world))),
  ',"hud":[460,310]',
  ',"palette":[', table.concat(paletteList, ','), ']',
  ',"track":[', table.concat(pts, ','), ']',
  ',"zone":', str(table.concat(zone)),
  ',"corners":[', table.concat(corners, ','), ']',
  ',"laps":[', table.concat(lapRows, ','), ']',
  ',"says":[', table.concat(says, ','), ']',
  ',"calls":[', table.concat(dictList, ','), ']',
  ',"frames":[', table.concat(frames, ','), ']}',
}
local f = assert(realIo.open(target, 'w'))
f:write(table.concat(out))
f:close()
print(string.format('%s: %d frames, %d distinct drawing calls, %d spoken clips, %d laps', target, #frames, dictN, #says, #lapRows))
