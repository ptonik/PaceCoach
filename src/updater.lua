-- Finds and installs a newer version of the app from its GitHub repository.
-- Pure logic: the network and the file system are injected, so the same code
-- runs in the tests and in the game.
--
-- The repository holds a small list, update.txt, written by
-- tools/make_update.lua:
--   PACECOACH-UPDATE 1
--   version=0.4.0
--   notes=One line about what is new
--   file=<bytes> <checksum> <path>
--
-- An update is all-or-nothing as far as that is possible: every file is
-- downloaded and checked against its size and checksum first, and only when
-- all of them are right is anything written to the app folder. Writing is a
-- separate step (apply), so the app can wait until the car is standing still.

local Updater = {}
Updater.__index = Updater

-- Adler-32 checksum of a string. It catches damaged or cut-off downloads;
-- it is not a security measure (HTTPS is what protects the download).
function Updater.checksum(data)
  local a, b = 1, 0
  local byte = string.byte
  for i = 1, #data do
    a = (a + byte(data, i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

-- "0.4.1" -> { 0, 4, 1 }, or nil.
function Updater.parseVersion(text)
  local parts = {}
  for item in tostring(text or ''):gmatch('[^.]+') do
    local num = tonumber(item:match('^%d+'))
    if not num then return nil end
    parts[#parts + 1] = num
  end
  if #parts == 0 then return nil end
  return parts
end

-- True when version `a` is newer than version `b`.
function Updater.newer(a, b)
  local pa, pb = Updater.parseVersion(a), Updater.parseVersion(b)
  if not pa or not pb then return false end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- A path the updater is willing to write: inside the app folder, plain names.
function Updater.safePath(path)
  if type(path) ~= 'string' or path == '' or #path > 120 then return false end
  if path:find('[^%w%-_./]') then return false end
  if path:find('%.%.') or path:sub(1, 1) == '/' or path:sub(1, 1) == '.' then return false end
  if path:find('//') or path:sub(-1) == '/' then return false end
  return true
end

-- Reads update.txt. Returns { version =, notes =, files = { { path, size, sum } }, bytes = },
-- or nil and a reason. limits = { maxFiles =, maxBytes = }
function Updater.parse(text, limits)
  if type(text) ~= 'string' or not text:match('^PACECOACH%-UPDATE 1') then
    return nil, 'not an update list'
  end
  limits = limits or {}
  local out = { files = {}, bytes = 0 }
  for line in text:gmatch('[^\r\n]+') do
    local key, value = line:match('^(%w+)=(.*)$')
    if key == 'version' then
      out.version = value
    elseif key == 'notes' then
      out.notes = value
    elseif key == 'file' then
      local size, sum, path = value:match('^(%d+) (%x+) (.+)$')
      if not size or not Updater.safePath(path) then return nil, 'bad entry in the update list' end
      out.files[#out.files + 1] = { path = path, size = tonumber(size), sum = tonumber(sum, 16) }
      out.bytes = out.bytes + tonumber(size)
    end
  end
  if not Updater.parseVersion(out.version) then return nil, 'the update list has no version' end
  if #out.files == 0 then return nil, 'the update list is empty' end
  if #out.files > (limits.maxFiles or 200) or out.bytes > (limits.maxBytes or 2e7) then
    return nil, 'the update list is unreasonably large'
  end
  return out
end

-- Writes update.txt for a set of files. files: list of { path =, data = }.
function Updater.encode(version, notes, files)
  local out = { 'PACECOACH-UPDATE 1', 'version=' .. tostring(version) }
  if notes and notes ~= '' then out[#out + 1] = 'notes=' .. tostring(notes):gsub('[\r\n]', ' ') end
  for _, f in ipairs(files) do
    out[#out + 1] = string.format('file=%d %08x %s', #f.data, Updater.checksum(f.data), f.path)
  end
  return table.concat(out, '\n') .. '\n'
end

-- deps = {
--   get   = function(url, callback(err, status, body))   starts a download
--   save  = function(path, data) -> true on success
--   load  = function(path) -> data or nil   (optional: lets unchanged files be skipped)
--   mkdir = function(path)
--   base  = URL prefix ending in '/', list = name of the list file,
--   dir   = the app's own folder, current = installed version,
--   limits = { maxFiles =, maxBytes = } }
function Updater.new(deps)
  local self = setmetatable({}, Updater)
  self.deps = deps
  -- idle | checking | current | available | downloading | ready | writing | done | failed
  self.state = 'idle'
  self.progress, self.total = 0, 0
  return self
end

function Updater:busy()
  return self.state == 'checking' or self.state == 'downloading' or self.state == 'ready'
    or self.state == 'writing'
end

function Updater:_fail(reason)
  self.state, self.error, self.bodies = 'failed', reason, nil
end

-- Asks the repository which version it holds.
function Updater:check()
  if self:busy() or self.state == 'done' then return false end
  local deps = self.deps
  self.state, self.error = 'checking', nil
  local started = deps.get(deps.base .. deps.list, function(err, status, body)
    if self.state ~= 'checking' then return end
    if err or status ~= 200 or type(body) ~= 'string' then
      self:_fail('could not reach GitHub (' .. tostring(err or status) .. ')')
      return
    end
    local list, why = Updater.parse(body, deps.limits)
    if not list then
      self:_fail(why)
      return
    end
    self.remote = list
    self.state = Updater.newer(list.version, deps.current) and 'available' or 'current'
  end)
  if started == false then self:_fail('downloads are not available') end
  return true
end

-- Call every frame while an update is being fetched. Each call does one
-- small piece of work: it checks whether the next file is already on disk
-- unchanged (then it is skipped), or starts its download.
function Updater:pump()
  if self.state ~= 'downloading' or self.waiting then return end
  local deps, files = self.deps, self.remote.files
  local i = self.at
  local file = files[i]
  if not file then
    self.state = 'ready'           -- everything is here and checked; apply() installs it
    return
  end
  local have = deps.load and deps.load(deps.dir .. '/' .. file.path)
  if type(have) == 'string' and #have == file.size and Updater.checksum(have) == file.sum then
    self.bodies[i] = false
    self.skipped = self.skipped + 1
    self.progress, self.at = i, i + 1
    return
  end
  self.waiting = true
  local started = deps.get(deps.base .. file.path, function(err, status, body)
    self.waiting = false
    if self.state ~= 'downloading' then return end
    if err or status ~= 200 or type(body) ~= 'string' then
      self:_fail('could not download ' .. file.path .. ' (' .. tostring(err or status) .. ')')
    elseif #body ~= file.size or Updater.checksum(body) ~= file.sum then
      self:_fail(file.path .. ' arrived damaged. Nothing was changed.')
    else
      self.bodies[i] = body
      self.progress, self.at = i, i + 1
    end
  end)
  if started == false then
    self.waiting = false
    self:_fail('downloads are not available')
  end
end

-- Every byte value once: written and read back before an update is
-- installed, to be sure this game build stores sound files unharmed.
local function probeData()
  local bytes = {}
  for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
  return table.concat(bytes)
end

function Updater:_write()
  local deps, files = self.deps, self.remote.files
  self.state = 'writing'
  if deps.load then
    local probe, blob = deps.dir .. '/update-check.bin', probeData()
    if not deps.save(probe, blob) or deps.load(probe) ~= blob then
      self:_fail('this game build cannot store the files safely. Nothing was changed; update by hand from GitHub.')
      return
    end
    deps.save(probe, 'ok')
  end
  local made = {}
  for _, f in ipairs(files) do
    local at = 1
    while true do
      local slash = f.path:find('/', at, true)
      if not slash then break end
      local dir = f.path:sub(1, slash - 1)
      if not made[dir] then
        made[dir] = true
        deps.mkdir(deps.dir .. '/' .. dir)
      end
      at = slash + 1
    end
  end
  -- Files in sub-folders first, the entry files in the app's own folder last,
  -- so a failure half way leaves the old entry point in place.
  for pass = 1, 2 do
    for i, f in ipairs(files) do
      local nested = f.path:find('/', 1, true) ~= nil
      if nested == (pass == 1) and self.bodies[i] then
        if not deps.save(deps.dir .. '/' .. f.path, self.bodies[i]) then
          self:_fail('could not write ' .. f.path
            .. '. Install this version by hand from GitHub to be safe.')
          return
        end
      end
    end
  end
  self.bodies = nil
  self.installed = self.remote.version
  self.state = 'done'
end

-- Writes a downloaded update into the app folder. Returns true when done.
function Updater:apply()
  if self.state ~= 'ready' then return false end
  self:_write()
  return self.state == 'done'
end

-- Starts fetching the version found by check(). Call pump() every frame
-- from then on; when the state reaches 'ready', call apply() to install it.
function Updater:install()
  if self.state ~= 'available' then return false end
  self.state, self.error = 'downloading', nil
  self.bodies, self.progress, self.total = {}, 0, #self.remote.files
  self.at, self.waiting, self.skipped = 1, false, 0
  return true
end

return Updater
