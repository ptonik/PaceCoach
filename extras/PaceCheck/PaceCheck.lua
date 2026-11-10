-- PaceCheck: a tiny app that reports why PaceCoach shows nothing.
-- It uses only the most basic calls, and guards every one of them.

local lines = {}
local function say(text) lines[#lines + 1] = tostring(text) end
local function try(label, fn)
  local ok, result = pcall(fn)
  if ok then
    say(label .. ': ' .. tostring(result))
  else
    say(label .. ': FAILED  ' .. tostring(result))
  end
  return ok and result or nil
end

say('PaceCheck is running, so CSP Lua apps work on this install.')
try('CSP version', function() return ac.getPatchVersion() end)
try('CSP build', function() return ac.getPatchVersionCode() end)
say(tostring(_VERSION) .. (jit and ('  ' .. tostring(jit.version)) or ''))

local apps = try('Lua apps folder', function() return ac.getFolder(ac.FolderID.ACAppsLua) end)

local function exists(path)
  local ok, result = pcall(io.fileExists, path)
  if ok then return result == true end
  local f = io.open(path, 'rb')
  if f then f:close() return true end
  return false
end

if apps then
  say('')
  say('Folders in it whose name contains "pace":')
  local found = {}
  local ok, err = pcall(function()
    io.scanDir(apps, '*', function(name, attributes)
      if tostring(name):lower():find('pace', 1, true) then found[#found + 1] = tostring(name) end
    end)
  end)
  if not ok then say('  could not list the folder: ' .. tostring(err)) end
  if ok and #found == 0 then say('  none found by listing') end
  for _, name in ipairs(found) do say('  ' .. name) end

  for _, folder in ipairs({ 'PaceCoach', 'PaceCoach-main' }) do
    local base = apps .. '/' .. folder
    say('')
    say(folder .. ':')
    say('  manifest.ini            ' .. (exists(base .. '/manifest.ini') and 'present' or 'MISSING'))
    say('  ' .. folder .. '.lua' .. string.rep(' ', math.max(1, 20 - #folder)) .. (exists(base .. '/' .. folder .. '.lua') and 'present' or 'MISSING'))
    say('  src/app.lua             ' .. (exists(base .. '/src/app.lua') and 'present' or 'MISSING'))
    say('  nested ' .. folder .. '/manifest.ini   ' .. (exists(base .. '/' .. folder .. '/manifest.ini') and 'PRESENT (folder is nested one level too deep)' or 'no'))
    if exists(base .. '/src/app.lua') then
      -- Compile every source file (without running it) to catch syntax errors.
      local files = { folder .. '.lua', 'src/app.lua', 'src/config.lua', 'src/util.lua', 'src/strings.lua',
        'src/track.lua', 'src/grip.lua', 'src/recorder.lua', 'src/pilot.lua', 'src/mistakes.lua',
        'src/reference.lua', 'src/metrics.lua', 'src/targets.lua', 'src/coach.lua', 'src/teacher.lua',
        'src/sim.lua', 'src/settings.lua', 'src/voice.lua', 'src/gfx.lua', 'src/map.lua', 'src/hud.lua',
        'src/panel.lua', 'src/markers.lua', 'src/live.lua', 'src/lesson.lua', 'src/updater.lua',
        'sounds/index.lua' }
      local bad = 0
      for _, file in ipairs(files) do
        local okLoad, chunk, err = pcall(loadfile, base .. '/' .. file)
        if not okLoad then
          say('  cannot check files here: ' .. tostring(chunk))
          bad = -1
          break
        elseif not chunk then
          bad = bad + 1
          say('  PROBLEM in ' .. file .. ': ' .. tostring(err))
        end
      end
      if bad == 0 then say('  all ' .. #files .. ' source files compile') end
      local version = 'unknown'
      pcall(function()
        local f = io.open(base .. '/manifest.ini', 'r')
        if f then
          version = f:read('*a'):match('VERSION%s*=%s*([%d%.]+)') or version
          f:close()
        end
      end)
      say('  version in manifest     ' .. version)
    end
  end
end

say('')
say('Please send a screenshot of this window.')

function script.windowMain()
  for _, line in ipairs(lines) do
    if line == '' then ui.text(' ') else ui.text(line) end
  end
end
