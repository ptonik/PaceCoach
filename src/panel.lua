-- The panel you open in the pits: track map and corner list, laps, mistakes,
-- settings, and diagnostics (including the API self-test).

local G = require('src/gfx')
local S = require('src/strings')
local U = require('src/util')
local Sim = require('src/sim')
local Map = require('src/map')
local Voice = require('src/voice')
local Mistakes = require('src/mistakes')
local Markers = require('src/markers')

local Panel = { tab = 'Track' }
local TABS = { 'Track', 'Teacher', 'Laps', 'Mistakes', 'Settings', 'Diagnostics' }
local C = G.colors

local REASONS = {
  offtrack = 'more than two wheels left the track',
  pit = 'pit lane',
  jump = 'the car was moved',
  cut = 'the game marked it invalid',
  timing = 'timing data was incomplete',
}
Panel.REASONS = REASONS

local function line(text, color)
  if color and Sim.has['ui.textColored'] then
    ui.textColored(text, color)
  else
    ui.text(text)
  end
end

local function paragraph(text, widthPx)
  for _, l in ipairs(U.wrapText(text, math.max(20, math.floor(widthPx / 7.2)))) do
    ui.text(l)
  end
end

local function gap()
  if Sim.has['ui.offsetCursorY'] then ui.offsetCursorY(6) else ui.text(' ') end
end

local function speedText(kmh, mph)
  if mph then return string.format('%d mph', U.round(kmh * 0.621371)) end
  return string.format('%d km/h', U.round(kmh))
end

local function trackTab(app, W)
  if app.state == 'noline' then
    paragraph(S.status.noLine, W)
    return
  end
  if not app.track then
    ui.text(S.status.loading)
    return
  end
  if app.map and Sim.has['ui.getCursor'] and Sim.has['ui.offsetCursorY'] then
    local cur = ui.getCursor()
    local h = math.min(320, math.max(160, W * 0.6))
    local highlight = app.card and app.card.ready and app.card.corner.index or nil
    Map.draw(app.map, cur.x, cur.y, W - cur.x * 2, h, app.car.x, app.car.z, highlight, 12)
    ui.offsetCursorY(h + 8)
  end
  line(string.format('%d corners, %.0f m. Colour shows how sharp each one is.',
    #app.track.corners, app.track.lengthM), C.dim)
  gap()
  for _, c in ipairs(app.track.corners) do
    local est = c.vTargetMs and ('about ' .. speedText(c.vTargetMs * 3.6, app.settings.mph)) or ''
    line(string.format('%s   %s %s   radius %d m, turns %d deg   %s',
      c.name, S.severityLower[c.severity], S.dirLower[c.dir],
      U.round(c.minRadiusM), U.round(c.angleDeg), est),
      G.severityColor[c.severity])
  end
  gap()
  paragraph('Speeds are cautious estimates. They rise as the app sees how much grip this car really has.', W)
end

local function gearText(gear)
  return S.gears[(tonumber(gear) or 0) + 2] or tostring(gear)
end

local function teacherTab(app, W)
  local label, bench = app.benchLabel, app.benchmark
  if bench then
    line('Benchmark: ' .. (S.benchmark[label] or tostring(label)) .. '   ' .. U.formatLap(bench.timeMs), C.green)
    if bench.pedals == 'derived' or (label == 'teacher' and app.teacherDerived) then
      paragraph('Its pedals were worked out from its speed, because the game did not provide them.', W)
    end
    if app.best and bench ~= app.best then
      ui.text('Your best ' .. U.formatLap(app.best.timeMs) .. '   gap '
        .. U.formatDelta(app.best.timeMs - bench.timeMs) .. ' s')
    end
    if label == 'you' then paragraph(S.status.teacherBeaten, W) end
  else
    line('No teacher lap yet.', C.orange)
    paragraph('To get one, start a session with one to three AI opponents in the same car as you '
      .. '(in Content Manager: Drive, then a Weekend, Race or Track Day with opponents). '
      .. 'The app records their laps while you drive and keeps the fastest clean one. '
      .. 'It usually needs one or two of their laps.', W)
    paragraph('Until then the brake cue is a cautious estimate from the shape of the track'
      .. (app.ownPlan and ', and corner feedback compares you with your own best lap.' or '.'), W)
  end
  gap()
  line(string.format('Watching %d other car(s) of this model. Clean laps seen: %d.',
    #app.others, app.teacher and app.teacher.lapsSeen or 0), C.dim)
  ui.text('Line on the track: ' .. tostring(Markers.status))
  gap()
  local plan = app.coachPlan
  if not (plan and app.track) then return end

  line('Your last pass through each corner, against ' .. (S.benchmark[app.coachLabel] or 'the benchmark'), C.dim)
  local total, counted = 0, 0
  for k, c in ipairs(app.track.corners) do
    local res = app.cornerResults[k]
    if res then
      total, counted = total + res.lossMs, counted + 1
      line(string.format('%s   %s s   %s', c.name, U.formatDelta(res.lossMs), res.text or 'Fine.'),
        res.good and C.green or C.white)
    else
      line(c.name .. '   not driven yet', C.faint)
    end
  end
  if counted > 0 then
    ui.text(string.format('Total over %d corner(s): %s s', counted, U.formatDelta(total)))
  end
  gap()
  line('Targets from the benchmark', C.dim)
  for k, c in ipairs(app.track.corners) do
    local tg = plan.targets[k]
    if tg then
      local brake = 'no braking'
      if tg.brakeRelM and tg.brakeRelM < 0 then
        brake = string.format('brake %d m before the corner', U.round(-tg.brakeRelM))
      elseif tg.brakeRelM then
        brake = string.format('brake %d m into the corner', U.round(tg.brakeRelM))
      end
      ui.text(string.format('%s   %s, %s gear, %s', c.name, brake, gearText(tg.gear),
        speedText(tg.minKmh, app.settings.mph)))
    end
  end
end

local function lapsTab(app, W)
  if app.best then
    line('Best lap  ' .. U.formatLap(app.best.timeMs), C.green)
  else
    paragraph('No reference lap yet. Complete one clean lap (no more than two wheels off the track) and it becomes your reference.', W)
  end
  gap()
  if #app.laps == 0 then
    line('No laps this session yet.', C.dim)
    return
  end
  for i = #app.laps, 1, -1 do
    local lap = app.laps[i]
    local text = string.format('Lap %d   %s', lap.number, U.formatLap(lap.timeMs))
    if lap.valid then
      if app.best and lap.timeMs > app.best.timeMs then
        text = text .. '   ' .. U.formatDelta(lap.timeMs - app.best.timeMs)
      end
      line(text, C.white)
    else
      line(text .. '   does not count: ' .. (REASONS[lap.reason] or tostring(lap.reason)), C.dim)
    end
  end
end

local function mistakesTab(app, W)
  local any = false
  for _, id in ipairs(Mistakes.PRIORITY) do
    local count = app.mistakeCounts[id]
    if count then
      any = true
      line(string.format('%s   x%d', S.tips[id].title, count), C.yellow)
      paragraph(S.tips[id].why, W)
      gap()
    end
  end
  if not any then
    paragraph('Nothing recorded yet. Mistakes such as locked brakes, wheelspin or running off the track are listed here with a short explanation.', W)
    return
  end
  line('Where they happened', C.dim)
  local names = {}
  for name in pairs(app.cornerMistakes) do names[#names + 1] = name end
  table.sort(names, function(a, b)
    return (tonumber(a:match('%d+')) or 0) < (tonumber(b:match('%d+')) or 0)
  end)
  for _, name in ipairs(names) do
    local parts = {}
    for _, id in ipairs(Mistakes.PRIORITY) do
      local count = app.cornerMistakes[name][id]
      if count then parts[#parts + 1] = string.format('%s x%d', S.tips[id].title:lower(), count) end
    end
    ui.text(name .. '   ' .. table.concat(parts, ', '))
  end
end

local function toggle(app, key, label)
  if Sim.has['ui.checkbox'] and ui.checkbox(label, app.settings[key] == true) then
    app.settings[key] = not app.settings[key]
  end
end

local function slider(app, key, id, lo, hi, scale, format)
  if not Sim.has['ui.slider'] then return end
  local old = app.settings[key] * scale
  local value = ui.slider(id, old, lo, hi, format)
  if type(value) == 'number' and value ~= old then app.settings[key] = value / scale end
end

local function settingsTab(app, W)
  toggle(app, 'beginner', 'Beginner HUD (one thing at a time)')
  toggle(app, 'showTips', 'Show mistake tips')
  toggle(app, 'voice', 'Spoken corner callouts')
  toggle(app, 'brakeSound', 'Sound at the brake cue')
  toggle(app, 'brakeBeep', 'Use a beep instead of the word "brake"')
  toggle(app, 'throttleSound', 'Say "throttle" when I am late back on the power')
  slider(app, 'voiceVolume', '##pacecoachVolume', 0, 100, 100, 'Volume: %.0f%%')
  slider(app, 'leadS', '##pacecoachLead', 0, 1, 1, 'Brake cue earlier by: %.2f s')
  slider(app, 'callLeadS', '##pacecoachCall', 2, 6, 1, 'Call corners %.1f s before braking')
  if Sim.has['ui.button'] and ui.button('Test the voice') then
    Voice.say(app.settings.brakeBeep and 'beep' or 'brake', app.settings.voiceVolume, true)
  end
  gap()
  toggle(app, 'line3d', 'Driving line on the track (needs a benchmark lap)')
  toggle(app, 'ghostPedals', 'Pedal bars on the advanced HUD')
  gap()
  toggle(app, 'gamepad', 'I use a gamepad, not a wheel')
  toggle(app, 'mph', 'Speeds in mph')
  toggle(app, 'swapLR', 'Swap left and right (only if callouts are mirrored)')
  gap()
  if not app.settingsPersist then
    line('Settings cannot be saved on this CSP build; they reset each session.', C.orange)
  end
  paragraph('Saved laps: ' .. tostring(app.dataDir or 'not set'), W)
end

local function diagnosticsTab(app, W)
  line('PaceCoach ' .. tostring(app.version) .. '   state: ' .. tostring(app.state), C.white)
  if Sim.fatal then
    line('Missing essentials: ' .. Sim.fatal, C.red)
  end
  if app.lastError then
    line('Last error:', C.red)
    paragraph(app.lastError, W)
  end
  ui.text('Track: ' .. tostring(app.trackId) .. '   Car: ' .. tostring(app.carId))
  if app.track then
    ui.text(string.format('Line: %d cells, %.0f m (game says %.0f m), %d corners',
      app.track.n, app.track.lengthM, app.sim.trackLengthM or 0, #app.track.corners))
  end
  ui.text('Left/right: ' .. tostring(app.leftSource or 'not measured yet'))
  if app.grip then
    local g = app.grip
    ui.text(string.format('Grip estimate: lateral %.2f / %.2f / %.2f / %.2f g, braking %.2f g',
      g.lat[1], g.lat[2], g.lat[3], g.lat[4], g.brake))
  end
  ui.text('Voice: ' .. tostring(Voice.status) .. '   clips played: ' .. tostring(Voice.played))
  ui.text(string.format('Other cars of this model: %d   benchmark: %s   line on track: %s',
    #app.others, tostring(app.benchLabel or 'none'), tostring(Markers.status)))
  ui.text('Lap file: ' .. tostring(app.lastSave or 'nothing saved yet'))
  gap()

  line('Live values (they should change as you drive)', C.dim)
  local s = app.car
  if s.pos then
    ui.text(string.format('position %.4f   speed %.0f km/h   throttle %.2f   brake %.2f',
      s.pos, s.speedKmh or 0, s.gas or 0, s.brake or 0))
    ui.text(string.format('steer %s deg   gear %s   lap time %s   laps %s   wheels off %s',
      s.steer and string.format('%.0f', s.steer) or 'n/a', tostring(s.gear),
      U.formatLap(s.lapTimeMs), tostring(s.lapCount), tostring(s.wheelsOut)))
    ui.text(string.format('lateral g %s   slide angle %s   pit lane %s',
      s.latG and string.format('%.2f', s.latG) or 'n/a',
      s.velAngleDeg and string.format('%.0f deg', s.velAngleDeg) or 'n/a',
      tostring(s.inPitlane)))
    if s.hasSlipRatio then
      ui.text(string.format('wheel slip  FL %.2f  FR %.2f  RL %.2f  RR %.2f',
        s.slipRatio[1], s.slipRatio[2], s.slipRatio[3], s.slipRatio[4]))
    end
  else
    ui.text('No car data yet.')
  end
  gap()

  line('API self-test', C.dim)
  local missing = 0
  for _, row in ipairs(Sim.report) do
    if not row.ok then
      missing = missing + 1
      line('missing   ' .. row.name .. (row.essential and '   (essential)' or '   (optional)'),
        row.essential and C.red or C.orange)
    end
  end
  if missing == 0 then
    line(string.format('All %d checks passed.', #Sim.report), C.green)
  else
    line(string.format('%d of %d checks passed.', #Sim.report - missing, #Sim.report), C.dim)
  end
end

function Panel.draw(app)
  local win = ui.windowSize()
  local W = win.x
  if Sim.has['ui.button'] and Sim.has['ui.sameLine'] then
    for i, name in ipairs(TABS) do
      if i > 1 then ui.sameLine() end
      if ui.button((Panel.tab == name) and ('[ ' .. name .. ' ]') or name) then Panel.tab = name end
    end
    if Sim.has['ui.separator'] then ui.separator() end
  else
    Panel.tab = 'Diagnostics'
  end
  local tab = Panel.tab
  if app.state == 'init' or app.state == 'incompatible' then tab = 'Diagnostics' end
  if tab == 'Track' then
    trackTab(app, W)
  elseif tab == 'Teacher' then
    teacherTab(app, W)
  elseif tab == 'Laps' then
    lapsTab(app, W)
  elseif tab == 'Mistakes' then
    mistakesTab(app, W)
  elseif tab == 'Settings' then
    settingsTab(app, W)
  else
    diagnosticsTab(app, W)
  end
end

return Panel
