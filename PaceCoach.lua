-- PaceCoach: co-driver and driving coach for Assetto Corsa (CSP Lua app).
-- This file only wires CSP's callbacks to the app; the logic lives in src/.

local ok, App = pcall(require, 'src/app')

if not ok then
  -- The app could not even load. Say so in every window instead of showing
  -- nothing, and write it to the CSP log.
  local message = 'PaceCoach could not start: ' .. tostring(App)
  pcall(function() ac.log(message) end)
  local lines = {}
  for line in message:gmatch('[^\n]+') do
    while #line > 90 do
      lines[#lines + 1] = line:sub(1, 90)
      line = line:sub(91)
    end
    lines[#lines + 1] = line
  end
  local function show()
    for _, line in ipairs(lines) do ui.text(line) end
  end
  script.windowMain, script.windowMap, script.windowPanel = show, show, show
  function script.update() end
  function script.draw3D() end
  return
end

-- Called by CSP every frame.
function script.update(dt)
  App.update(dt)
end

-- Window functions named in manifest.ini.
function script.windowMain(dt)
  App.drawHud(dt)
end

function script.windowMap(dt)
  App.drawMap(dt)
end

function script.windowPanel(dt)
  App.drawPanel(dt)
end

-- 3D drawing on the track, named under [RENDER_CALLBACKS] in manifest.ini.
function script.draw3D()
  App.draw3D()
end
