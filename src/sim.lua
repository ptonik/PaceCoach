-- The only module that reads game state. Everything else gets plain Lua
-- tables from here, so a wrong or missing API name can be fixed in one place.
--
-- Nothing optional is assumed to exist: selfTest() probes every field and
-- function once, and the per-frame readers only touch what was found.

local Sim = {
  has = {},        -- name -> true for everything the self-test found
  report = {},     -- rows for the Diagnostics tab
  fatal = nil,     -- text listing missing essentials, or nil
  tested = false,
}

local sqrt, abs = math.sqrt, math.abs

-- Reads obj[name] without raising if it does not exist.
local function field(obj, name)
  if obj == nil then return false, nil end
  local ok, v = pcall(function() return obj[name] end)
  if ok and v ~= nil then return true, v end
  return false, nil
end
Sim.field = field

function Sim.log(message)
  local ok, fn = field(ac, 'log')
  if ok then pcall(fn, 'PaceCoach: ' .. tostring(message)) end
end

local CAR_ESSENTIAL = { 'speedKmh', 'gas', 'brake', 'splinePosition', 'position', 'lapTimeMs', 'lapCount' }
local CAR_OPTIONAL = {
  'steer', 'gear', 'rpm', 'velocity', 'look', 'acceleration', 'wheelsOutside',
  'isInPitlane', 'isInPit', 'absInAction', 'previousLapTimeMs', 'isLastLapValid',
  'bestLapTimeMs', 'wheels', 'isAIControlled',
}
local WHEEL_OPTIONAL = { 'slipRatio', 'slipAngle', 'position' }
local SIM_ESSENTIAL = { 'trackLengthM' }
local SIM_OPTIONAL = { 'isPaused', 'isReplayActive', 'carsCount' }
local AC_ESSENTIAL = { 'getCar', 'getSim' }
local AC_OPTIONAL = {
  'trackProgressToWorldCoordinate', 'hasTrackSpline', 'getTrackFullID', 'getTrackID',
  'getCarID', 'getFolder', 'FolderID', 'storage', 'AudioEvent', 'onCarJumped',
  'onSessionStart', 'log', 'getTrackAISplineSides', 'unloadApp',
}
local WEB_OPTIONAL = { 'get' }
local RENDER_OPTIONAL = { 'quad', 'setBlendMode', 'setDepthMode', 'BlendMode', 'DepthMode' }
local IO_OPTIONAL = { 'save', 'load', 'createDir' }
local UI_ESSENTIAL = {
  'windowSize', 'drawRectFilled', 'drawLine', 'dwriteDrawText', 'text',
}
local UI_OPTIONAL = {
  'measureDWriteText', 'drawCircleFilled', 'pathClear', 'pathLineTo', 'pathStroke',
  'textColored', 'button', 'sameLine', 'checkbox', 'slider', 'separator',
  'getCursor', 'offsetCursorY', 'availableSpaceX',
}

-- Probes the API. Returns true once the car exists and the test has run.
function Sim.selfTest()
  local report, has, missing = {}, {}, {}
  local function row(name, ok, essential)
    report[#report + 1] = { name = name, ok = ok, essential = essential }
    if ok then has[name] = true elseif essential then missing[#missing + 1] = name end
  end
  local function group(prefix, obj, names, essential)
    for _, name in ipairs(names) do
      row(prefix .. name, (field(obj, name)), essential)
    end
  end

  group('ac.', ac, AC_ESSENTIAL, true)
  group('ac.', ac, AC_OPTIONAL, false)
  group('io.', io, IO_OPTIONAL, false)
  group('ui.', ui, UI_ESSENTIAL, true)
  group('ui.', ui, UI_OPTIONAL, false)
  row('vec2', type(vec2) ~= 'nil', true)
  row('rgbm', type(rgbm) ~= 'nil', true)
  row('vec3', type(vec3) ~= 'nil', false)
  local renderLib = rawget(_G, 'render')
  group('render.', renderLib, RENDER_OPTIONAL, false)
  group('web.', rawget(_G, 'web'), WEB_OPTIONAL, false)
  if has['render.BlendMode'] then
    row('render.BlendMode.AlphaBlend', (field(renderLib.BlendMode, 'AlphaBlend')), false)
  end
  if has['render.DepthMode'] then
    row('render.DepthMode.ReadOnly', (field(renderLib.DepthMode, 'ReadOnly')), false)
  end

  local car
  if has['ac.getCar'] then
    local ok, c = pcall(ac.getCar, 0)
    if ok then car = c end
  end
  if not car then
    Sim.report, Sim.has = report, has
    return false                      -- car not there yet: try again next frame
  end
  group('car.', car, CAR_ESSENTIAL, true)
  group('car.', car, CAR_OPTIONAL, false)
  if has['car.wheels'] then
    local ok, wheel = pcall(function() return car.wheels[0] end)
    if ok and wheel ~= nil then
      group('wheel.', wheel, WHEEL_OPTIONAL, false)
    end
  end

  local sim
  if has['ac.getSim'] then
    local ok, s = pcall(ac.getSim)
    if ok then sim = s end
  end
  group('sim.', sim, SIM_ESSENTIAL, true)
  group('sim.', sim, SIM_OPTIONAL, false)

  -- Does the audio constructor exist?
  if has['ac.AudioEvent'] then
    row('ac.AudioEvent.fromFile', (field(ac.AudioEvent, 'fromFile')), false)
  end
  if has['ac.FolderID'] then
    row('ac.FolderID.ACDocuments', (field(ac.FolderID, 'ACDocuments')), false)
    row('ac.FolderID.ScriptOrigin', (field(ac.FolderID, 'ScriptOrigin')), false)
  end

  Sim.report, Sim.has = report, has
  Sim.fatal = (#missing > 0) and table.concat(missing, ', ') or nil
  Sim.tested = true
  return true
end

-- Per-frame car snapshot written into `out` (a table the caller keeps).
-- Returns out, or nil when there is no car.
function Sim.readCar(out, dt)
  local car = ac.getCar(0)
  if not car then return nil end
  local has = Sim.has

  out.pos = car.splinePosition
  out.speedKmh = car.speedKmh
  out.speedMs = out.speedKmh / 3.6
  out.gas, out.brake = car.gas, car.brake
  local p = car.position
  out.x, out.y, out.z = p.x, p.y, p.z
  out.lapTimeMs = tonumber(car.lapTimeMs) or 0
  out.lapCount = tonumber(car.lapCount) or 0

  out.steer = has['car.steer'] and car.steer or nil
  out.gear = has['car.gear'] and (tonumber(car.gear) or 0) or 0
  out.wheelsOut = has['car.wheelsOutside'] and (tonumber(car.wheelsOutside) or 0) or 0
  out.inPitlane = has['car.isInPitlane'] and car.isInPitlane == true or false
  out.inPit = has['car.isInPit'] and car.isInPit == true or false
  out.abs = has['car.absInAction'] and car.absInAction == true or false
  out.previousLapTimeMs = has['car.previousLapTimeMs'] and tonumber(car.previousLapTimeMs) or nil
  out.lastLapValid = nil
  if has['car.isLastLapValid'] then out.lastLapValid = car.isLastLapValid == true end

  out.lookX, out.lookZ = nil, nil
  -- Angle between where the car points and where it is going (spin detection),
  -- and lateral g. Yaw rate x speed stands in when the game gives no g reading.
  out.velAngleDeg, out.latG = nil, nil
  if has['car.look'] then
    local look = car.look
    local lx, lz = look.x, look.z
    local lm = sqrt(lx * lx + lz * lz)
    if lm > 0.01 then
      lx, lz = lx / lm, lz / lm
      out.lookX, out.lookZ = lx, lz
      if has['car.velocity'] then
        local vel = car.velocity
        local vx, vz = vel.x, vel.z
        local vm = sqrt(vx * vx + vz * vz)
        if vm > 2 then
          local dot = (vx * lx + vz * lz) / vm
          if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
          out.velAngleDeg = math.deg(math.acos(dot))
        else
          out.velAngleDeg = 0
        end
      end
      if out.prevLookX and dt and dt > 0 then
        local cross = out.prevLookX * lz - out.prevLookZ * lx
        if cross > 1 then cross = 1 elseif cross < -1 then cross = -1 end
        out.latG = abs(math.asin(cross)) / dt * out.speedMs / 9.81
      end
      out.prevLookX, out.prevLookZ = lx, lz
    end
  end
  if has['car.acceleration'] then out.latG = abs(car.acceleration.x) end

  out.slipRatio = out.slipRatio or {}
  out.slipAngle = out.slipAngle or {}
  out.hasSlipRatio = has['wheel.slipRatio'] == true
  out.hasSlipAngle = has['wheel.slipAngle'] == true
  if out.hasSlipRatio or out.hasSlipAngle then
    local wheels = car.wheels
    for i = 0, 3 do
      local w = wheels[i]
      if out.hasSlipRatio then out.slipRatio[i + 1] = w.slipRatio end
      if out.hasSlipAngle then out.slipAngle[i + 1] = w.slipAngle end
    end
  end
  return out
end

function Sim.readSim(out)
  local sim = ac.getSim()
  local has = Sim.has
  out.trackLengthM = sim.trackLengthM
  out.paused = has['sim.isPaused'] and sim.isPaused == true or false
  out.replay = has['sim.isReplayActive'] and sim.isReplayActive == true or false
  return out
end

-- Which way is "left" in world coordinates? Measured from the front wheels:
-- wheel 0 is front-left and wheel 1 is front-right in Assetto Corsa.
-- Returns +1 / -1 for track.lua, or nil when it cannot be measured.
function Sim.leftSign()
  local has = Sim.has
  if not (has['wheel.position'] and has['car.look']) then return nil end
  local ok, sign = pcall(function()
    local car = ac.getCar(0)
    local fl, fr, look = car.wheels[0].position, car.wheels[1].position, car.look
    local leftX, leftZ = fl.x - fr.x, fl.z - fr.z
    local cross = look.x * leftZ - look.z * leftX
    if abs(cross) < 1e-3 then return nil end
    return (cross > 0) and 1 or -1
  end)
  if ok then return sign end
  return nil
end

-- True / false when the game can say whether the track has an ideal line,
-- nil when it cannot (the caller then judges by the sampled points).
function Sim.hasLine()
  if not Sim.has['ac.trackProgressToWorldCoordinate'] then return false end
  if Sim.has['ac.hasTrackSpline'] then
    local ok, v = pcall(ac.hasTrackSpline)
    if ok then return v == true end
  end
  return nil
end

-- World position of the ideal line at progress 0..1, or nil.
function Sim.linePoint(progress)
  local ok, p = pcall(ac.trackProgressToWorldCoordinate, progress)
  if ok and p then return p.x, p.y, p.z end
  return nil
end

function Sim.trackId()
  if Sim.has['ac.getTrackFullID'] then
    local ok, id = pcall(ac.getTrackFullID, '-')
    if ok and id and id ~= '' then return tostring(id) end
  end
  if Sim.has['ac.getTrackID'] then
    local ok, id = pcall(ac.getTrackID)
    if ok and id and id ~= '' then return tostring(id) end
  end
  return 'unknown_track'
end

function Sim.carId()
  if Sim.has['ac.getCarID'] then
    local ok, id = pcall(ac.getCarID, 0)
    if ok and id and id ~= '' then return tostring(id) end
  end
  return 'unknown_car'
end

local function folder(name)
  if not (Sim.has['ac.getFolder'] and Sim.has['ac.FolderID']) then return nil end
  local okId, id = field(ac.FolderID, name)
  if not okId then return nil end
  local ok, path = pcall(ac.getFolder, id)
  if ok and type(path) == 'string' and path ~= '' then return path end
  return nil
end

-- Folder of the app itself (for the sound files).
function Sim.appDir()
  local dir = folder('ScriptOrigin')
  if dir then return dir end
  local apps = folder('ACAppsLua')
  if apps then return apps .. '/PaceCoach' end
  return 'apps/lua/PaceCoach'
end

-- Folder for saved laps: Documents/Assetto Corsa/PaceCoach, so that
-- replacing the app folder with a new version does not wipe your laps.
function Sim.dataDir()
  local docs = folder('ACDocuments')
  local dir = docs and (docs .. '/PaceCoach') or (Sim.appDir() .. '/data')
  if Sim.has['io.createDir'] then pcall(io.createDir, dir) end
  return dir
end

function Sim.saveFile(path, text)
  if not Sim.has['io.save'] then return false end
  local ok, result = pcall(io.save, path, text)
  return ok and result ~= false
end

function Sim.loadFile(path)
  if not Sim.has['io.load'] then return nil end
  local ok, text = pcall(io.load, path)
  if ok and type(text) == 'string' and text ~= '' then return text end
  return nil
end

-- Updates -------------------------------------------------------------------

-- Starts a download. callback(err, status, body) is called later.
-- Returns false when this CSP build cannot download at all.
function Sim.httpGet(url, callback)
  if not Sim.has['web.get'] then return false end
  local ok = pcall(web.get, url, function(err, response)
    local status, body
    if response ~= nil then
      pcall(function() status, body = response.status, response.body end)
    end
    if err == nil and status == nil then err = 'no response' end
    -- This runs outside the app's own error boundary, so it gets one here.
    local okCall, why = pcall(callback, err, tonumber(status), body)
    if not okCall then Sim.log('download handler failed: ' .. tostring(why)) end
  end)
  return ok
end

function Sim.makeDir(path)
  if Sim.has['io.createDir'] then pcall(io.createDir, path) end
end

-- Unloads the app, so that CSP loads it afresh (with new files) the next
-- time one of its windows is opened. Returns false if that is not possible.
function Sim.unloadApp()
  if not Sim.has['ac.unloadApp'] then return false end
  return (pcall(ac.unloadApp))
end

-- Seconds since 1970, for the progress history. nil if the clock is not there.
function Sim.now()
  local ok, t = pcall(os.time)
  if ok and type(t) == 'number' then return t end
  return nil
end

-- "2026-11-10" for a time from Sim.now(), or nil.
function Sim.dateText(at)
  if type(at) ~= 'number' then return nil end
  local ok, text = pcall(os.date, '%Y-%m-%d', at)
  if ok and type(text) == 'string' then return text end
  return nil
end

-- Other cars ----------------------------------------------------------------

function Sim.carCount()
  if Sim.has['sim.carsCount'] then
    local ok, count = pcall(function() return ac.getSim().carsCount end)
    if ok and tonumber(count) then return tonumber(count) end
  end
  return 1
end

-- Indices of other cars of the same model as the player's, at most `limit`.
function Sim.sameModelCars(carId, limit)
  local list = {}
  if not Sim.has['ac.getCarID'] then return list end
  for i = 1, Sim.carCount() - 1 do
    local ok, id = pcall(ac.getCarID, i)
    if ok and id ~= nil and tostring(id) == carId then
      list[#list + 1] = i
      if #list >= limit then break end
    end
  end
  return list
end

-- A lighter snapshot of another car, for recording its laps.
function Sim.readOther(index, out)
  local ok, car = pcall(ac.getCar, index)
  if not ok or not car then return nil end
  local has = Sim.has
  out.pos = car.splinePosition
  out.speedKmh = car.speedKmh
  out.gas, out.brake = car.gas, car.brake
  local p = car.position
  out.x, out.z = p.x, p.z
  out.lapTimeMs = tonumber(car.lapTimeMs) or 0
  out.lapCount = tonumber(car.lapCount) or 0
  out.steer = has['car.steer'] and car.steer or 0
  out.gear = has['car.gear'] and (tonumber(car.gear) or 0) or 0
  out.wheelsOut = has['car.wheelsOutside'] and (tonumber(car.wheelsOutside) or 0) or 0
  out.inPit = (has['car.isInPitlane'] and car.isInPitlane == true)
    or (has['car.isInPit'] and car.isInPit == true) or false
  out.isAI = has['car.isAIControlled'] and car.isAIControlled == true or false
  return out
end

-- Where every other car is, for the spotter. Fills `list` (reusing its
-- tables) and returns how many entries are in use.
function Sim.readTraffic(list, limit)
  local count = 0
  for i = 1, math.min(Sim.carCount() - 1, limit) do
    local ok, car = pcall(ac.getCar, i)
    if ok and car then
      count = count + 1
      local o = list[count]
      if not o then
        o = {}
        list[count] = o
      end
      local p = car.position
      o.x, o.z = p.x, p.z
      o.inPit = (Sim.has['car.isInPitlane'] and car.isInPitlane == true)
        or (Sim.has['car.isInPit'] and car.isInPit == true) or false
    end
  end
  return count
end

-- Distance from the ideal line to the left and right track edges, in metres.
function Sim.trackSides(progress)
  if not Sim.has['ac.getTrackAISplineSides'] then return nil end
  local ok, sides = pcall(ac.getTrackAISplineSides, progress)
  if ok and sides ~= nil then
    local okX, l, r = pcall(function() return sides.x, sides.y end)
    if okX and type(l) == 'number' and type(r) == 'number' and l > 0 and r > 0 then return l, r end
  end
  return nil
end

function Sim.onJump(callback)
  if Sim.has['ac.onCarJumped'] then pcall(ac.onCarJumped, 0, callback) end
end

function Sim.onSessionStart(callback)
  if Sim.has['ac.onSessionStart'] then pcall(ac.onSessionStart, callback) end
end

return Sim
