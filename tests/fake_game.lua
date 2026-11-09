-- A stand-in for the CSP Lua environment, for smoke-testing the whole app
-- without the game.
--
-- It is deliberately STRICT: it defines only the functions and fields that
-- were verified against the CSP SDK, and raises an error for anything else.
-- So if the app calls something outside that list, the smoke test fails here
-- instead of in the game.

local Fake = {}

local function strict(name, tbl)
  return setmetatable(tbl, {
    __index = function(_, k)
      error(name .. '.' .. tostring(k) .. ' is not in the verified API list', 2)
    end,
  })
end

local function isNum(v) return type(v) == 'number' and v == v and math.abs(v) < 1e7 end
local function isVec2(v) return type(v) == 'table' and isNum(v.x) and isNum(v.y) end
local function isColor(c) return type(c) == 'table' and c.isColor == true end
local function need(cond, what)
  if not cond then error('bad argument: ' .. what, 3) end
end

-- opts:
--   track      a Track built from the synthetic line (world geometry)
--   mirror     true to describe the same world in a mirrored coordinate system
--   remove     list of 'ac.x' / 'ui.x' / 'car.x' / 'sim.x' / 'wheel.x' / 'io.x' names to leave out
--   noLine     true if the track has no ideal line
--   store      table used as the file system (path -> text), shared between sessions
--   others     list of other cars: { { model = 'test_car', ai = true }, ... }
--   renderThrows  true to make 3D drawing raise an error
function Fake.install(opts)
  opts = opts or {}
  local track = opts.track
  local mx = opts.mirror and -1 or 1
  local removed = {}
  for _, name in ipairs(opts.remove or {}) do removed[name] = true end
  local state = {
    logs = {}, plays = {}, texts = {}, calls = 0, store = opts.store or {},
    jumpCallbacks = {}, sessionCallbacks = {}, click = nil, dirs = {},
  }
  Fake.state = state

  local function keep(prefix, tbl)
    local out = {}
    for k, v in pairs(tbl) do
      if not removed[prefix .. k] then out[k] = v end
    end
    return out
  end

  -- Basic types ---------------------------------------------------------------
  _G.vec2 = function(x, y) return { x = x or 0, y = y or 0 } end
  _G.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
  _G.rgbm = function(r, g, b, m)
    need(isNum(r) and isNum(g) and isNum(b) and isNum(m), 'rgbm needs four numbers')
    return { r = r, g = g, b = b, mult = m, isColor = true }
  end
  _G.script = {}

  -- World ---------------------------------------------------------------------
  local function lineAt(progress)
    local n = track.n
    local f = (progress % 1) * n
    local i0 = (math.floor(f) % n) + 1
    local i1 = (i0 % n) + 1
    local a, b, t = track.points[i0], track.points[i1], f - math.floor(f)
    local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    return x, z, dx / len, dz / len
  end

  local function newCar(isAI)
    local w = {}
    for i = 0, 3 do
      w[i] = strict('wheel', keep('wheel.', { slipRatio = 0, slipAngle = 0, position = vec3() }))
    end
    local c = strict('car', keep('car.', {
      speedKmh = 0, gas = 0, brake = 0, splinePosition = 0, position = vec3(),
      lapTimeMs = 0, lapCount = 0, steer = 0, gear = 1, rpm = 3000,
      velocity = vec3(), look = vec3(1, 0, 0), acceleration = vec3(),
      wheelsOutside = 0, isInPitlane = false, isInPit = false, absInAction = false,
      previousLapTimeMs = 0, isLastLapValid = true, bestLapTimeMs = 0,
      wheels = w, isAIControlled = isAI == true,
    }))
    return c, w
  end
  local car, wheels = newCar(false)
  state.car = car
  state.others = {}
  for i, o in ipairs(opts.others or {}) do
    local c, w = newCar(o.ai ~= false)
    state.others[i] = { car = c, wheels = w, model = o.model or 'test_car' }
  end
  local sim = strict('sim', keep('sim.', {
    trackLengthM = track.lengthM, isPaused = false, isReplayActive = false,
    carsCount = 1 + #state.others,
  }))
  state.sim = sim

  -- Moves a fake car to a synthetic sample. extra: fields to override.
  local function place(car, wheels, s, extra)
    local x, z, dx, dz = lineAt(s.pos)
    local leftX, leftZ = -dz, dx                -- left of travel in the synthetic world
    local function set(tbl, key, value) if rawget(tbl, key) ~= nil then tbl[key] = value end end
    set(car, 'speedKmh', s.v)
    set(car, 'gas', s.gas)
    set(car, 'brake', s.brake)
    set(car, 'splinePosition', s.pos)
    set(car, 'position', vec3(x * mx, 0, z))
    set(car, 'lapTimeMs', s.t)
    set(car, 'steer', s.steer)
    set(car, 'gear', s.gear)
    set(car, 'velocity', vec3(dx * s.speedMs * mx, 0, dz * s.speedMs))
    set(car, 'look', vec3(dx * mx, 0, dz))
    local kappa = math.abs(track.curv[(math.floor(s.pos * track.n) % track.n) + 1])
    set(car, 'acceleration', vec3(s.speedMs * s.speedMs * kappa / 9.81, 0, 0))
    -- Back to normal each frame; `extra` below overrides for this frame only.
    set(car, 'wheelsOutside', 0)
    set(car, 'isInPitlane', false)
    set(car, 'isInPit', false)
    set(car, 'absInAction', false)
    if rawget(car, 'lapCount') ~= nil and car.lapCount ~= s.lapCount then
      set(car, 'previousLapTimeMs', state.officialLapMs or 0)
      car.lapCount = s.lapCount
    end
    for i = 0, 3 do
      local side = (i % 2 == 0) and 1 or -1     -- wheels 0 and 2 are on the left
      local fore = (i < 2) and 1.3 or -1.3
      set(wheels[i], 'position', vec3((x + dx * fore + leftX * 0.8 * side) * mx, 0,
        z + dz * fore + leftZ * 0.8 * side))
      set(wheels[i], 'slipRatio', 0)
      set(wheels[i], 'slipAngle', 1)
    end
    for key, value in pairs(extra or {}) do
      if key == 'slipRatio' then
        for i = 0, 3 do set(wheels[i], 'slipRatio', value[i + 1]) end
      else
        set(car, key, value)
      end
    end
  end
  function Fake.drive(s, extra) place(car, wheels, s, extra) end
  function Fake.driveOther(index, s, extra)
    local o = state.others[index]
    place(o.car, o.wheels, s, extra)
  end

  -- ac ------------------------------------------------------------------------
  local folderId = strict('ac.FolderID', keep('ac.FolderID.', {
    ACDocuments = 'docs', ScriptOrigin = 'origin', ACAppsLua = 'apps',
  }))
  local audio = strict('ac.AudioEvent', {
    fromFile = function(params, reverb)
      need(type(params) == 'table' and type(params.filename) == 'string', 'AudioEvent params')
      need(params.use3D == false and params.loop == false, 'AudioEvent flags')
      need(reverb == false, 'AudioEvent reverb flag')
      local clip = params.filename:match('([%w_]+)%.wav$')
      need(clip, 'AudioEvent file name: ' .. params.filename)
      local f = io.open(params.filename, 'rb')
      need(f, 'sound file does not exist: ' .. params.filename)
      f:close()
      local event = { volume = 1, cameraInteriorMultiplier = 0.25 }
      function event:start() state.plays[#state.plays + 1] = { clip = clip, frame = state.frame, volume = self.volume } end
      function event:stop() state.stopped = (state.stopped or 0) + 1 end
      return event
    end,
  })
  _G.ac = strict('ac', keep('ac.', {
    getCar = function(i)
      need(type(i) == 'number', 'car index')
      if state.noCar then return nil end
      if i == 0 then return car end
      return state.others[i] and state.others[i].car or nil
    end,
    getTrackAISplineSides = function(p) need(isNum(p), 'progress') return vec2(4, 6) end,
    getSim = function() return sim end,
    trackProgressToWorldCoordinate = function(p)
      need(isNum(p), 'progress')
      if opts.noLine then return vec3(0, 0, 0) end
      local x, z = lineAt(p)
      return vec3(x * mx, 0, z)
    end,
    hasTrackSpline = function() return not opts.noLine end,
    getTrackFullID = function(sep) need(type(sep) == 'string', 'separator') return 'ks_synthetic' .. sep .. 'rect' end,
    getTrackID = function() return 'ks_synthetic' end,
    getCarID = function(i)
      need(type(i) == 'number', 'car index')
      if i == 0 then return 'test_car' end
      return state.others[i] and state.others[i].model or nil
    end,
    getFolder = function(id)
      need(id == 'docs' or id == 'origin' or id == 'apps', 'folder id')
      if id == 'docs' then return 'C:/Users/me/Documents/Assetto Corsa' end
      if id == 'origin' then return opts.appDir end
      return 'C:/AC/apps/lua'
    end,
    FolderID = folderId,
    storage = function(defaults)
      need(type(defaults) == 'table', 'storage defaults')
      state.settings = defaults
      return defaults
    end,
    AudioEvent = audio,
    onCarJumped = function(i, cb) need(i == 0 and type(cb) == 'function', 'onCarJumped') state.jumpCallbacks[#state.jumpCallbacks + 1] = cb end,
    onSessionStart = function(cb) need(type(cb) == 'function', 'onSessionStart') state.sessionCallbacks[#state.sessionCallbacks + 1] = cb end,
    log = function(msg) state.logs[#state.logs + 1] = tostring(msg) end,
  }))

  -- render --------------------------------------------------------------------
  local function isVec3(v) return type(v) == 'table' and isNum(v.x) and isNum(v.y) and isNum(v.z) end
  state.quads = 0
  if not removed['render'] then
    _G.render = strict('render', keep('render.', {
      quad = function(p1, p2, p3, p4, color)
        if opts.renderThrows then error('render.quad exploded') end
        need(isVec3(p1) and isVec3(p2) and isVec3(p3) and isVec3(p4), 'quad corners')
        need(p1 ~= p2 and p2 ~= p3 and p3 ~= p4 and p1 ~= p3 and p1 ~= p4 and p2 ~= p4, 'quad corners must be separate objects')
        need(isColor(color), 'quad colour')
        state.quads = state.quads + 1
      end,
      setBlendMode = function(mode) need(mode == 'alpha', 'blend mode') end,
      setDepthMode = function(mode) need(mode == 'readonly', 'depth mode') end,
      BlendMode = strict('render.BlendMode', { AlphaBlend = 'alpha' }),
      DepthMode = strict('render.DepthMode', { ReadOnly = 'readonly', Off = 'off', Normal = 'normal' }),
    }))
  else
    _G.render = nil
  end

  -- io (the real library plus CSP's helpers, backed by an in-memory store) ----
  local fio = {}
  for k, v in pairs(Fake.realIo) do fio[k] = v end
  if not removed['io.save'] then
    fio.save = function(path, text)
      need(type(path) == 'string' and type(text) == 'string', 'io.save')
      if state.diskFull then return false end
      state.store[path] = text
      return true
    end
  end
  if not removed['io.load'] then
    fio.load = function(path) need(type(path) == 'string', 'io.load') return state.store[path] end
  end
  if not removed['io.createDir'] then
    fio.createDir = function(path) state.dirs[#state.dirs + 1] = path return true end
  end
  _G.io = fio

  -- ui ------------------------------------------------------------------------
  local win = vec2(460, 260)
  state.window = win
  local function count() state.calls = state.calls + 1 end
  local function text(str)
    need(type(str) == 'string' and str ~= '', 'text must be a non-empty string')
    state.texts[#state.texts + 1] = str
  end
  _G.ui = strict('ui', keep('ui.', {
    windowSize = function() return vec2(win.x, win.y) end,
    drawRectFilled = function(p1, p2, color, rounding)
      count()
      need(isVec2(p1) and isVec2(p2) and p1 ~= p2, 'rect corners')
      need(isColor(color), 'rect colour')
      need(rounding == nil or isNum(rounding), 'rect rounding')
    end,
    drawLine = function(p1, p2, color, thickness)
      count()
      need(isVec2(p1) and isVec2(p2) and p1 ~= p2, 'line ends')
      need(isColor(color) and (thickness == nil or isNum(thickness)), 'line style')
    end,
    drawCircleFilled = function(p, radius, color, segments)
      count()
      need(isVec2(p) and isNum(radius) and isColor(color), 'circle')
      need(segments == nil or isNum(segments), 'circle segments')
    end,
    dwriteDrawText = function(str, size, pos, color)
      count()
      text(str)
      need(isNum(size) and size > 0 and isVec2(pos), 'text size / position')
      need(color == nil or isColor(color), 'text colour')
    end,
    measureDWriteText = function(str, size)
      need(type(str) == 'string' and isNum(size), 'measure text')
      local wide = select(2, str:gsub('[%u%dmwMW]', ''))
      return vec2((wide * 0.66 + (#str - wide) * 0.5) * size, size * 1.2)
    end,
    pathClear = function() state.path = 0 end,
    pathLineTo = function(p) need(isVec2(p), 'path point') state.path = (state.path or 0) + 1 end,
    pathStroke = function(color, closed, thickness)
      count()
      need(isColor(color) and type(closed) == 'boolean' and isNum(thickness), 'path stroke')
      need((state.path or 0) >= 2, 'path needs at least two points')
      state.path = 0
    end,
    text = function(str) count() text(str) end,
    textColored = function(str, color) count() text(str) need(isColor(color), 'text colour') end,
    button = function(label)
      need(type(label) == 'string' and label ~= '', 'button label')
      if state.click == label then
        state.click = nil
        return true
      end
      return false
    end,
    sameLine = function() end,
    separator = function() end,
    checkbox = function(label, checked)
      need(type(label) == 'string' and type(checked) == 'boolean', 'checkbox')
      if state.click == label then
        state.click = nil
        return true
      end
      return false
    end,
    slider = function(label, value, lo, hi, format)
      need(type(label) == 'string' and isNum(value) and isNum(lo) and isNum(hi), 'slider')
      need(type(format) == 'string', 'slider format')
      return value, false
    end,
    getCursor = function() return vec2(8, 40) end,
    offsetCursorY = function(v) need(isNum(v), 'cursor offset') end,
    availableSpaceX = function() return win.x - 16 end,
  }))

  return state
end

Fake.realIo = io

-- Unloads the app so the next dofile() starts a fresh "session".
function Fake.unload()
  for name in pairs(package.loaded) do
    if name:match('^src/') or name:match('^sounds/') then package.loaded[name] = nil end
  end
end

return Fake
