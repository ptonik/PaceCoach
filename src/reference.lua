-- Saves and loads laps and the learned grip for one car + track pair.
-- Uses its own plain-text format so the exact same code runs in the tests and
-- in the game. File access is injected; this module never touches `io`.
--
-- File layout:
--   PACECOACH 1
--   track=...
--   car=...
--   n=2000
--   grip.lat=1.02,1.05,0,0
--   grip.brake=1.1
--   [lap best]
--   timeMs=83456
--   source=player
--   t=0,12,25,...        (one line per channel, values as scaled integers)

local U = require('src/util')

local Reference = {}
Reference.__index = Reference

local ORDER = { 't', 'v', 'gas', 'brake', 'steer', 'gear', 'x', 'z' }
local SCALE = { t = 1, v = 10, gas = 100, brake = 100, steer = 10, gear = 1, x = 100, z = 100 }

-- deps: { dir = folder, save = function(path, text) -> bool, load = function(path) -> text | nil }
function Reference.new(deps)
  local self = setmetatable({}, Reference)
  self.dir, self.save, self.load = deps.dir, deps.save, deps.load
  return self
end

function Reference:path(trackId, carId)
  return self.dir .. '/' .. U.safeName(trackId) .. '__' .. U.safeName(carId) .. '.txt'
end

function Reference.encode(data)
  local out = { 'PACECOACH 1' }
  out[#out + 1] = 'track=' .. tostring(data.track)
  out[#out + 1] = 'car=' .. tostring(data.car)
  out[#out + 1] = 'n=' .. tostring(data.n)
  if data.grip then
    local lat = {}
    for i, v in ipairs(data.grip.lat or {}) do lat[i] = string.format('%.3f', v) end
    out[#out + 1] = 'grip.lat=' .. table.concat(lat, ',')
    out[#out + 1] = 'grip.brake=' .. string.format('%.3f', data.grip.brake or 0)
  end
  local names = {}
  for name in pairs(data.laps or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local lap = data.laps[name]
    out[#out + 1] = '[lap ' .. name .. ']'
    out[#out + 1] = 'timeMs=' .. string.format('%d', U.round(lap.timeMs or 0))
    out[#out + 1] = 'source=' .. tostring(lap.source or 'player')
    for _, ch in ipairs(ORDER) do
      local scale, src, vals = SCALE[ch], lap[ch], {}
      for i = 1, lap.n do vals[i] = string.format('%d', U.round((src[i] or 0) * scale)) end
      out[#out + 1] = ch .. '=' .. table.concat(vals, ',')
    end
  end
  return table.concat(out, '\n') .. '\n'
end

local function numbers(text, scale)
  local arr = {}
  for item in text:gmatch('[^,]+') do
    local v = tonumber(item)
    if not v then return nil end
    arr[#arr + 1] = v / scale
  end
  return arr
end

-- Returns data, or nil and a reason.
function Reference.decode(text)
  if type(text) ~= 'string' or not text:match('^PACECOACH 1') then
    return nil, 'not a PaceCoach file'
  end
  local data = { laps = {} }
  local lap
  for line in text:gmatch('[^\r\n]+') do
    local name = line:match('^%[lap ([%w_]+)%]$')
    if name then
      lap = { source = 'player' }
      data.laps[name] = lap
    else
      local key, value = line:match('^([%w%.]+)=(.*)$')
      if key and lap then
        if key == 'timeMs' then
          lap.timeMs = tonumber(value)
        elseif key == 'source' then
          lap.source = value
        elseif SCALE[key] then
          lap[key] = numbers(value, SCALE[key])
        end
      elseif key == 'track' then
        data.track = value
      elseif key == 'car' then
        data.car = value
      elseif key == 'n' then
        data.n = tonumber(value)
      elseif key == 'grip.lat' then
        data.grip = data.grip or {}
        data.grip.lat = numbers(value, 1) or {}
      elseif key == 'grip.brake' then
        data.grip = data.grip or {}
        data.grip.brake = tonumber(value)
      end
    end
  end
  if not data.n then return nil, 'missing grid size' end
  -- Drop laps that are damaged or were recorded on another grid.
  for name, l in pairs(data.laps) do
    local ok = l.timeMs ~= nil
    for _, ch in ipairs(ORDER) do
      if type(l[ch]) ~= 'table' or #l[ch] ~= data.n then ok = false end
    end
    if ok then
      l.n, l.valid, l.complete = data.n, true, true
    else
      data.laps[name] = nil
    end
  end
  return data
end

-- Loads the file for a car + track pair. Always returns a usable table.
-- Laps recorded on a different grid size are discarded; grip is kept.
function Reference:loadCombo(trackId, carId, n)
  local fresh = { track = trackId, car = carId, n = n, laps = {} }
  local text = self.load(self:path(trackId, carId))
  if not text then return fresh, 'no file yet' end
  local data, err = Reference.decode(text)
  if not data then return fresh, err end
  fresh.grip = data.grip
  if data.n == n then fresh.laps = data.laps end
  return fresh
end

function Reference:saveCombo(data)
  return self.save(self:path(data.track, data.car), Reference.encode(data)) and true or false
end

-- A lap sent by a faster friend: their lap file for the same car and track,
-- renamed to end in .teacher.txt. Returns a lap or nil.
function Reference:importPath(trackId, carId)
  return self.dir .. '/' .. U.safeName(trackId) .. '__' .. U.safeName(carId) .. '.teacher.txt'
end

function Reference:loadImport(trackId, carId, n)
  local text = self.load(self:importPath(trackId, carId))
  if not text then return nil end
  local data = Reference.decode(text)
  if not data or data.n ~= n then return nil end
  local lap, fastest = nil, math.huge
  for _, l in pairs(data.laps) do
    if l.timeMs and l.timeMs < fastest then lap, fastest = l, l.timeMs end
  end
  if lap then lap.source = 'friend' end
  return lap
end

-- Progress history: one line of numbers per session for a car + track pair.
--   PACECOACH-HISTORY 1
--   at=1731234567 best=83456 bench=80123 laps=12 valid=9 braking=72 ...
function Reference:historyPath(trackId, carId)
  return self.dir .. '/' .. U.safeName(trackId) .. '__' .. U.safeName(carId) .. '.history.txt'
end

local HISTORY_KEYS = {
  'at', 'best', 'bench', 'laps', 'valid', 'ideal', 'fixed',
  'braking', 'speed', 'exits', 'line', 'consistency', 'pace',
}

function Reference.encodeHistory(list)
  local out = { 'PACECOACH-HISTORY 1' }
  for _, entry in ipairs(list) do
    local parts = {}
    for _, key in ipairs(HISTORY_KEYS) do
      local v = entry[key]
      if type(v) == 'number' and v == v then parts[#parts + 1] = key .. '=' .. string.format('%d', U.round(v)) end
    end
    if #parts > 0 then out[#out + 1] = table.concat(parts, ' ') end
  end
  return table.concat(out, '\n') .. '\n'
end

function Reference.decodeHistory(text)
  local list = {}
  if type(text) ~= 'string' or not text:match('^PACECOACH%-HISTORY 1') then return list end
  local first = true
  for line in text:gmatch('[^\r\n]+') do
    if first then
      first = false
    else
      local entry, any = {}, false
      for key, value in line:gmatch('(%w+)=(%-?%d+)') do
        entry[key], any = tonumber(value), true
      end
      if any then list[#list + 1] = entry end
    end
  end
  return list
end

function Reference:loadHistory(trackId, carId)
  return Reference.decodeHistory(self.load(self:historyPath(trackId, carId)))
end

function Reference:saveHistory(trackId, carId, list, keep)
  while keep and #list > keep do table.remove(list, 1) end
  return self.save(self:historyPath(trackId, carId), Reference.encodeHistory(list)) and true or false
end

-- The session written up for a person to read (see report.lua).
function Reference:reportPath(trackId, carId)
  return self.dir .. '/' .. U.safeName(trackId) .. '__' .. U.safeName(carId) .. '.report.txt'
end

function Reference:saveReport(trackId, carId, text)
  return self.save(self:reportPath(trackId, carId), text) and true or false
end

-- Learned grip belongs to the car, not the track, and lives in its own small
-- file so it can be saved often without rewriting whole laps.
function Reference:gripPath(carId)
  return self.dir .. '/car__' .. U.safeName(carId) .. '.grip.txt'
end

function Reference:saveGrip(carId, grip)
  local text = Reference.encode({ track = '-', car = carId, n = 0, grip = grip, laps = {} })
  return self.save(self:gripPath(carId), text) and true or false
end

function Reference:loadGrip(carId)
  local text = self.load(self:gripPath(carId))
  if not text then return nil end
  local data = Reference.decode(text)
  return data and data.grip or nil
end

return Reference
