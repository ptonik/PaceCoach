-- Draws the HUD and the map to an SVG file, so the layout can be looked at
-- without the game. Fonts differ from the game's, so treat it as a sketch.
--   luajit tests/render_hud.lua out.svg

local here = (arg and arg[0] or ''):match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/?.lua;' .. here .. '/?.lua;' .. package.path

local config = require('src/config')
local Track = require('src/track')
local Synth = require('synth')
local Fake = require('fake_game')

local points = Synth.line(Synth.rectangle(), 1000)
local world = Track.build(points, { cfg = config.track, leftSign = 1 })
local samples, lapMs = Synth.drive(world, { latG = 1.0, brakeG = 0.7, accelG = 0.35, vmaxMs = 70, laps = 4 })
local aiSamples = Synth.drive(world, { latG = 1.3, brakeG = 1.2, accelG = 0.45, vmaxMs = 70, laps = 7 })

Fake.unload()
local state = Fake.install({ track = world, appDir = root, others = { { model = 'test_car' } } })
state.officialLapMs = lapMs
dofile(root .. '/PaceCoach.lua')
local app = package.loaded['src/app']

-- Recording versions of the drawing calls.
local out, ox, oy, path = {}, 0, 0, {}
local function css(c)
  return string.format('rgb(%d,%d,%d)', math.min(255, c.r * 255), math.min(255, c.g * 255),
    math.min(255, c.b * 255)), c.mult
end
local function esc(s) return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
rawset(ui, 'drawRectFilled', function(a, b, color, rounding)
  local fill, alpha = css(color)
  out[#out + 1] = string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="%s" fill-opacity="%.2f"/>',
    ox + a.x, oy + a.y, b.x - a.x, b.y - a.y, rounding or 0, fill, alpha)
end)
rawset(ui, 'drawLine', function(a, b, color, thickness)
  local stroke, alpha = css(color)
  out[#out + 1] = string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-opacity="%.2f" stroke-width="%.1f"/>',
    ox + a.x, oy + a.y, ox + b.x, oy + b.y, stroke, alpha, thickness or 1)
end)
rawset(ui, 'drawCircleFilled', function(p, radius, color)
  local fill, alpha = css(color)
  out[#out + 1] = string.format('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s" fill-opacity="%.2f"/>',
    ox + p.x, oy + p.y, radius, fill, alpha)
end)
rawset(ui, 'dwriteDrawText', function(text, size, pos, color)
  local fill, alpha = css(color or rgbm(1, 1, 1, 1))
  out[#out + 1] = string.format('<text x="%.1f" y="%.1f" font-size="%.1f" fill="%s" fill-opacity="%.2f">%s</text>',
    ox + pos.x, oy + pos.y + size * 0.95, size, fill, alpha, esc(text))
end)
rawset(ui, 'pathClear', function() path = {} end)
rawset(ui, 'pathLineTo', function(p) path[#path + 1] = string.format('%.1f,%.1f', ox + p.x, oy + p.y) end)
rawset(ui, 'pathStroke', function(color, closed, thickness)
  local stroke, alpha = css(color)
  out[#out + 1] = string.format('<%s points="%s" fill="none" stroke="%s" stroke-opacity="%.2f" stroke-width="%.1f" stroke-linejoin="round"/>',
    closed and 'polygon' or 'polyline', table.concat(path, ' '), stroke, alpha, thickness)
  path = {}
end)

local shots = 0
local function shot(label, w, h, draw)
  local col, row = shots % 2, math.floor(shots / 2)
  ox, oy = 30 + col * 500, 50 + row * 330
  out[#out + 1] = string.format('<text x="%d" y="%d" font-size="14" fill="#9aa">%s</text>', ox, oy - 12, esc(label))
  out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#556" stroke-dasharray="4 4"/>', ox, oy, w, h)
  state.window.x, state.window.y = w, h
  draw()
  shots = shots + 1
end
local function hud(label) shot(label, 460, 260, function() script.windowMain(0.016) end) end

local want = { estimate = true, target = true, throttle = true, coach = true, advanced = true }
local t1 = world.corners[1]
for i, s in ipairs(samples) do
  state.frame = i
  local extra
  local m = s.pos * world.lengthM
  if app.benchLabel == 'teacher' and s.lapCount == 2 and m > t1.apexM - 15 and m < t1.endM + 40 then
    extra = { gas = 0 }                                   -- late on the throttle out of T1
  end
  Fake.drive(s, extra)
  Fake.driveOther(1, aiSamples[i] or aiSamples[#aiSamples])
  script.update(s.dt)
  local card = app.card
  if card and card.ready then
    if want.estimate and not app.benchmark and card.corner.index == 2 and not card.cue
        and card.distBrakeM and card.distBrakeM < 70 then
      want.estimate = nil
      hud('Before a teacher exists: cautious estimate')
    elseif want.target and app.benchLabel == 'teacher' and card.corner.index == 2 and not card.cue
        and card.distBrakeM and card.distBrakeM < 70 and card.distBrakeM > 25 then
      want.target = nil
      hud('With a teacher: real gear and speed target')
    elseif want.throttle and card.cue == 'throttle' then
      want.throttle = nil
      hud('Late on the throttle')
    elseif want.coach and app.tip and app.tip.body and app.tip.body:find('too early', 1, true)
        and app.clock < app.tip.untilT then
      want.coach = nil
      hud('Feedback after a corner')
    elseif want.advanced and app.benchLabel == 'teacher' and s.lapCount == 3 and card.corner.index == 6
        and not card.cue and card.distBrakeM and card.distBrakeM < 30 then
      want.advanced = nil
      app.settings.beginner = false
      hud('Advanced HUD: deltas and pedals against the teacher')
      app.settings.beginner = true
      shot('Map window', 280, 280, function() script.windowMap(0.016) end)
    end
  end
end

local svg = {
  '<svg xmlns="http://www.w3.org/2000/svg" width="1040" height="1040" font-family="Segoe UI, Helvetica, Arial, sans-serif">',
  '<rect width="1040" height="1040" fill="#3d4a3f"/>',
  table.concat(out, '\n'),
  '</svg>',
}
local target = arg and arg[1] or 'hud.svg'
local f = assert(Fake.realIo.open(target, 'w'))
f:write(table.concat(svg, '\n'))
f:close()
print('wrote ' .. target .. ' with ' .. shots .. ' views; app error: ' .. tostring(app.lastError))
