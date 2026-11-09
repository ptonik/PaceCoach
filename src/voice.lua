-- Plays the co-driver's phrases one after another.
-- Every game call is guarded: if audio does not work on this CSP build the
-- app carries on silently and says so in Diagnostics.

local Sim = require('src/sim')

local Voice = {
  dir = nil,
  index = {},        -- clip name -> length in seconds
  queue = {},
  playing = nil,     -- { clip =, endT = }
  held = {},         -- events kept alive until they have finished
  clock = 0,
  failures = 0,
  disabled = false,
  status = 'not started',
  played = 0,
}

local MAX_QUEUE_AGE_S = 2.5
local GAP_S = 0.05

function Voice.init(dir)
  Voice.dir = dir
  local ok, index = pcall(require, 'sounds/index')
  if ok and type(index) == 'table' then
    Voice.index = index
    Voice.status = 'ready'
  else
    Voice.status = 'sound index missing'
  end
  if not Sim.has['ac.AudioEvent.fromFile'] then
    Voice.disabled = true
    Voice.status = 'audio API not available in this CSP build'
  end
end

local function start(clip, volume)
  local path = Voice.dir .. '/sounds/' .. clip .. '.wav'
  local ok, err = pcall(function()
    local event = ac.AudioEvent.fromFile({ filename = path, use3D = false, loop = false }, false)
    event.cameraInteriorMultiplier = 1
    pcall(function() event.cameraExteriorMultiplier = 1 end)
    pcall(function() event.cameraTrackMultiplier = 1 end)
    event.volume = volume
    event:start()
    Voice.held[#Voice.held + 1] = { event = event, untilT = Voice.clock + (Voice.index[clip] or 1) + 1 }
  end)
  if ok then
    Voice.played = Voice.played + 1
    Voice.status = 'playing'
  else
    Voice.failures = Voice.failures + 1
    Voice.status = 'error: ' .. tostring(err)
    if Voice.failures >= 3 then
      Voice.disabled = true
      Sim.log('voice disabled after repeated errors: ' .. tostring(err))
    end
  end
  return ok
end

-- Queues a clip. urgent = true drops everything waiting and speaks now.
function Voice.say(clip, volume, urgent)
  if Voice.disabled or not Voice.dir then return end
  if urgent then
    Voice.queue = {}
    if Voice.playing then
      local held = Voice.held[#Voice.held]
      if held then pcall(function() held.event:stop() end) end
      Voice.playing = nil
    end
  end
  Voice.queue[#Voice.queue + 1] = { clip = clip, volume = volume or 1, t = Voice.clock }
end

function Voice.update(dt)
  Voice.clock = Voice.clock + dt
  local now = Voice.clock
  if Voice.playing and now >= Voice.playing.endT then Voice.playing = nil end
  for i = #Voice.held, 1, -1 do
    if now >= Voice.held[i].untilT then table.remove(Voice.held, i) end
  end
  while not Voice.playing and #Voice.queue > 0 do
    local item = table.remove(Voice.queue, 1)
    if now - item.t <= MAX_QUEUE_AGE_S and not Voice.disabled then   -- stale calls are dropped
      if start(item.clip, item.volume) then
        Voice.playing = { clip = item.clip, endT = now + (Voice.index[item.clip] or 0.8) + GAP_S }
      end
    end
  end
end

return Voice
