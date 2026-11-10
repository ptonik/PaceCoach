-- User settings, kept by CSP between sessions (ac.storage).
-- Falls back to a plain table if storage is unavailable.

local Sim = require('src/sim')

local Settings = {}

Settings.defaults = {
  beginner = true,      -- one piece of information at a time
  gamepad = false,      -- loosens steering-based checks
  voice = true,         -- spoken corner callouts
  voiceVolume = 0.8,
  brakeSound = true,    -- sound at the brake cue
  brakeBeep = false,    -- beep instead of the word "brake"
  leadS = 0.2,          -- extra warning before the brake cue, seconds
  callLeadS = 3.5,      -- how long before braking a corner is called
  mph = false,
  swapLR = false,       -- escape hatch if left and right come out mirrored
  showTips = true,
  mapOnHud = false,
  throttleSound = true, -- say "throttle" when you are late back on the power
  line3d = true,        -- driving line on the track (needs a benchmark lap)
  ghostPedals = true,   -- your pedals beside the benchmark's (advanced HUD)
  liveCoach = true,     -- coaching while you drive: brake harder, ease off, wait...
  turnCue = true,       -- say "turn in" at the benchmark's turn-in point
  lineCue = true,       -- say "move left / right" when off the line before a corner
  lessons = true,       -- pick a focus corner and remind you of it
  praise = true,        -- say so when a corner goes well
  paceBar = true,       -- speed against the benchmark, right now
  autoCheck = true,     -- look for a new version when the app starts
  autoInstall = true,   -- download and install it without asking
}

function Settings.load()
  local copy = {}
  for k, v in pairs(Settings.defaults) do copy[k] = v end
  if Sim.has['ac.storage'] then
    local ok, stored = pcall(ac.storage, copy)
    if ok and stored ~= nil then return stored, true end
  end
  return copy, false
end

return Settings
