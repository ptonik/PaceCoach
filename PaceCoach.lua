-- PaceCoach: co-driver and driving coach for Assetto Corsa (CSP Lua app).
-- This file only wires CSP's callbacks to the app; the logic lives in src/.

local App = require('src/app')

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
