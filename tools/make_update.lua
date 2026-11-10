-- Writes update.txt: the list of files (with sizes and checksums) that the
-- app's updater downloads from GitHub. Run it before every commit that
-- changes anything the game loads:
--   luajit tools/make_update.lua "One line about what is new"
-- The test suite fails if update.txt is out of date.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/?.lua;' .. package.path

local Updater = require('src/updater')
local config = require('src/config')

local M = {}

-- Only what the game needs: no tests, tools, docs or installer.
local function wanted(path)
  return path == 'manifest.ini' or path == 'icon.png' or path == 'sounds/index.lua'
    or path:match('^PaceCoach[%w%-_]*%.lua$') ~= nil
    or path:match('^src/[%w_]+%.lua$') ~= nil
    or path:match('^sounds/[%w_]+%.wav$') ~= nil
end

local function read(path)
  local f = io.open(root .. '/' .. path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

-- The files to ship, sorted, as { path =, data = }.
function M.files()
  local list = {}
  local pipe = assert(io.popen('cd "' .. root .. '" && git ls-files --cached --others --exclude-standard'))
  for line in pipe:lines() do
    if wanted(line) then
      local data = read(line)
      if data then list[#list + 1] = { path = line, data = data } end
    end
  end
  pipe:close()
  table.sort(list, function(a, b) return a.path < b.path end)
  return list
end

function M.build(notes)
  local files = M.files()
  return Updater.encode(config.version, notes, files), #files
end

-- The notes line of the update.txt that is on disk now.
function M.currentNotes()
  local text = read('update.txt')
  return text and text:match('\nnotes=([^\r\n]*)') or nil, text
end

if arg and arg[0] and arg[0]:match('make_update%.lua$') then
  local notes = arg[1] or M.currentNotes() or ''
  local text, count = M.build(notes)
  local f = assert(io.open(root .. '/update.txt', 'wb'))
  f:write(text)
  f:close()
  print(string.format('update.txt: version %s, %d files, %d bytes to download',
    config.version, count, Updater.parse(text).bytes))
end

return M
