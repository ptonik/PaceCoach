-- The panel you open in the pits: the coach's lesson plan and your numbers,
-- track map and corner list, teacher, laps, mistakes, settings, and
-- diagnostics (including the API self-test).

local G = require('src/gfx')
local S = require('src/strings')
local U = require('src/util')
local Sim = require('src/sim')
local Map = require('src/map')
local Voice = require('src/voice')
local Mistakes = require('src/mistakes')
local Markers = require('src/markers')
local config = require('src/config')

local Panel = { tab = 'Coach' }
local TABS = { 'Coach', 'Track', 'Teacher', 'Laps', 'Mistakes', 'Settings', 'Diagnostics' }
Panel.TABS = TABS
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

-- 0..100 as a ten-step bar made of plain characters (any font can draw it).
local function bar(value)
  local filled = U.round(U.clamp(value, 0, 100) / 10)
  return '[' .. string.rep('#', filled) .. string.rep('.', 10 - filled) .. ']'
end

local function historyLine(index, entry, previous)
  local parts = { 'Session ' .. index }
  local date = Sim.dateText(entry.at)
  if date then parts[#parts + 1] = date end
  if entry.best then
    local text = 'best ' .. U.formatLap(entry.best)
    if previous and previous.best then
      text = text .. ' (' .. U.formatDelta(entry.best - previous.best) .. ')'
    end
    parts[#parts + 1] = text
  end
  if entry.best and entry.bench then
    parts[#parts + 1] = U.formatDelta(entry.best - entry.bench) .. ' s to the benchmark'
  end
  if entry.pace then parts[#parts + 1] = string.format('%.1f%% of the limit', entry.pace / 10) end
  if entry.laps then
    parts[#parts + 1] = string.format('%d laps, %d clean', entry.laps, entry.valid or 0)
  end
  return table.concat(parts, '   ')
end

-- Speed through corner k on the last pass, against the benchmark: the
-- picture a coach would put in front of you. Red strips underneath show
-- where each of the two was on the brake.
local trace = {}
local function traceChart(app, k, W)
  local plan = app.coachPlan
  local ref, got = plan and plan.exitSlices[k], app.lastPass and app.lastPass[k]
  if not (ref and got and Sim.has['ui.getCursor'] and Sim.has['ui.offsetCursorY']) then return end
  local cur = ui.getCursor()
  local x0, y0, w, h = cur.x, cur.y, W - cur.x * 2, 104
  local count = math.min(ref.count, got.count)
  local total = ref.dist[count]
  if w < 160 or count < 8 or not total or total <= 0 then return end
  local vmin, vmax = math.huge, -math.huge
  for j = 1, count do
    vmin = math.min(vmin, ref.v[j], got.v[j])
    vmax = math.max(vmax, ref.v[j], got.v[j])
  end
  if vmax - vmin < 1 then vmax = vmin + 1 end
  G.rect(x0, y0, x0 + w, y0 + h, C.cardBg, 4)
  local left, right, top, bottom = x0 + 8, x0 + w - 8, y0 + 20, y0 + h - 16
  local step = math.max(1, math.floor(count / 110))
  local function line(sl, color, thickness)
    local n = 0
    for j = 1, count, step do
      n = n + 1
      trace[n * 2 - 1] = left + (right - left) * sl.dist[j] / total
      trace[n * 2] = bottom - (bottom - top) * (sl.v[j] - vmin) / (vmax - vmin)
    end
    G.polyline(trace, n, color, thickness, false)
  end
  local function brakes(sl, y, color)
    for j = 1, count - step, step do
      if sl.brake[j] > 0.1 then
        G.rect(left + (right - left) * sl.dist[j] / total, y,
          left + (right - left) * sl.dist[math.min(count, j + step)] / total, y + 3, color, 0)
      end
    end
  end
  line(ref, C.cyan, 1.5)
  line(got, C.white, 2)
  brakes(ref, y0 + h - 12, C.pedalDimRed)
  brakes(got, y0 + h - 7, C.red)
  local name = app.track.corners[k] and app.track.corners[k].name or ''
  G.text(string.format('%s speed: white you, blue %s. %d to %d km/h', name, S.benchmark[app.coachLabel] or 'benchmark',
    U.round(vmin), U.round(vmax)), 11, x0 + 8, y0 + 4, C.dim)
  ui.offsetCursorY(h + 8)
end

local function coachTab(app, W)
  local lesson = app.lesson
  if app.state == 'noline' then
    paragraph(S.status.noLine, W)
    return
  end
  if not (app.track and lesson) then
    ui.text(S.status.loading)
    return
  end
  local corners = app.track.corners

  if not app.coachPlan then
    line('No lesson plan yet.', C.orange)
    paragraph(S.lesson.noBenchmark, W)
    paragraph('The quickest way: start a session with one to three AI opponents in the same car as you. '
      .. 'After a lap or two of theirs the coach has a teacher lap and starts working with you.', W)
  else
    line('Coaching against ' .. (S.who[app.coachLabel] or 'the benchmark')
      .. '   ' .. U.formatLap(app.coachPlan.lap.timeMs), C.green)
    local level = app.level
    if level and app.limitLap then
      line(string.format(S.level.line, S.level[level.id], level.ratio * 100, U.formatLap(app.limitLap.timeMs)), C.cyan)
      if level.nextId then
        ui.text(string.format(S.level.next, S.level[level.nextId], level.nextMs / 1000))
      else
        ui.text(S.level.top)
      end
      line(S.level.why, C.dim)
    end
    gap()
    line(S.lesson.focusTitle, C.dim)
    local f = lesson.focus
    if not app.settings.lessons then
      ui.text('Switched off in Settings.')
    elseif f and corners[f.k] then
      local c = corners[f.k]
      line(string.format('%s  %s %s   typically %s s', c.name, S.severityLower[c.severity],
        S.dirLower[c.dir], U.formatDelta(f.baseMs)), C.cyan)
      paragraph(app.remedyText(f.id, f.value) or '', W)
      for _, how in ipairs(S.howto[f.id] or {}) do paragraph('- ' .. how, W) end
      traceChart(app, f.k, W)
      ui.text(string.format('Attempts: %d   good in a row: %d of %d', f.tries, f.streak,
        config.lesson.masterStreak))
    else
      paragraph(S.lesson.none, W)
    end
    if #lesson.fixed > 0 then
      local parts = {}
      for _, done in ipairs(lesson.fixed) do
        parts[#parts + 1] = string.format('%s (%s to %s s)', corners[done.k] and corners[done.k].name or '?',
          U.formatDelta(done.fromMs), U.formatDelta(done.toMs))
      end
      line('Fixed this session: ' .. table.concat(parts, ', '), C.green)
    end
    gap()

    line('Training steps', C.dim)
    for i, st in ipairs(lesson:stages()) do
      local def = S.stage[st.id]
      line(string.format('%s %d. %s   %s', st.done and '[x]' or '[ ]', i, def.name,
        string.format(def.line, st.have, st.need)), st.done and C.green or C.white)
    end
    gap()

    line('Skills, against ' .. (S.who[app.coachLabel] or 'the benchmark'), C.dim)
    local skills = lesson:skills()
    for _, id in ipairs(S.skills.order) do
      if skills[id] then
        ui.text(string.format('%s  %d   %s', bar(skills[id]), skills[id], S.skills[id]))
      else
        line('[..........]  --   ' .. S.skills[id], C.faint)
      end
    end
    gap()

    local ideal = lesson:ideal()
    if ideal then
      local text = S.lesson.ideal .. '  ' .. U.formatLap(ideal)
      if app.best then text = text .. '   ' .. U.formatDelta(ideal - app.best.timeMs) .. ' s to your best' end
      ui.text(text)
      line('(' .. S.lesson.idealWhy .. ')', C.dim)
    end
    local cons = lesson:consistency()
    if cons then
      ui.text(string.format('Last %d clean laps: %.2f s between fastest and slowest', cons.laps, cons.spreadMs / 1000))
    end
    if ideal or cons then gap() end

    line('Where the time goes (typical loss, biggest first)', C.dim)
    local rows = lesson:ranking()
    if #rows == 0 then line('Nothing driven yet.', C.faint) end
    for _, row in ipairs(rows) do
      local c = corners[row.k]
      local cause = row.id and S.remedy[row.id] and S.remedy[row.id].short or 'fine'
      local color = C.white
      if f and f.k == row.k then
        color = C.cyan
      elseif row.typicalMs < config.lesson.minFocusMs then
        color = C.green
      end
      local text = string.format('%s   %s s   %s   (last %s, best %s, %d passes)', c and c.name or '?',
        U.formatDelta(row.typicalMs), cause, U.formatDelta(row.lastMs), U.formatDelta(row.bestMs), row.passes)
      if row.steady and row.steady.brakeM >= config.lesson.steadyBrakeM then
        text = text .. string.format('   brake point moves %d m', U.round(row.steady.brakeM))
      end
      line(text, color)
    end
    local said = {}
    for id, count in pairs(app.liveCounts) do
      said[#said + 1] = string.format('%s x%d', S.live[id].text:lower(), count)
    end
    if #said > 0 then
      table.sort(said)
      gap()
      line('Said while you drove', C.dim)
      paragraph(table.concat(said, ', '), W)
    end
  end

  if app.reportSaved and app.reference then
    gap()
    line('A report of this session is written after every lap:', C.dim)
    paragraph(app.reference:reportPath(app.trackId, app.carId), W)
  end
  gap()
  line('Sessions with this car and track', C.dim)
  local history = app.history
  if #history == 0 then
    line('This is the first one.', C.faint)
  else
    for i = math.max(1, #history - 7), #history do
      ui.text(historyLine(i, history[i], history[i - 1]))
    end
  end
end

local function updateStatus(app)
  local u = app.updater
  if not u then return S.update.idle end
  local state = u.state
  if state == 'idle' then return app.settings.autoCheck and S.update.idle or S.update.off end
  if state == 'available' then return string.format(S.update.available, u.remote.version) end
  if state == 'downloading' then return string.format(S.update.downloading, math.min(u.progress + 1, u.total), u.total) end
  if state == 'done' then return string.format(S.update.done, tostring(u.installed)) end
  if state == 'failed' then return string.format(S.update.failed, tostring(u.error)) end
  return S.update[state] or state
end
Panel.updateStatus = updateStatus

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
    if label == 'limit' then paragraph(S.status.teacherBeaten, W) end
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
  toggle(app, 'liveCoach', 'Live coaching while I drive (brake harder, ease off, wait...)')
  toggle(app, 'turnCue', 'Say "turn in" at the turn-in point')
  toggle(app, 'lineCue', 'Say "move left / right" when I am off the line before a corner')
  toggle(app, 'lessons', 'Focus corner: one thing to fix at a time')
  toggle(app, 'praise', 'Tell me when a corner goes well')
  slider(app, 'voiceVolume', '##pacecoachVolume', 0, 100, 100, 'Volume: %.0f%%')
  slider(app, 'leadS', '##pacecoachLead', 0, 1, 1, 'Brake cue earlier by: %.2f s')
  slider(app, 'callLeadS', '##pacecoachCall', 2, 6, 1, 'Call corners %.1f s before braking')
  if Sim.has['ui.button'] and ui.button('Test the voice') then
    Voice.say(app.settings.brakeBeep and 'beep' or 'brake', app.settings.voiceVolume, true)
  end
  gap()
  toggle(app, 'line3d', 'Driving line on the track (needs a benchmark lap)')
  toggle(app, 'ghostPedals', 'Pedal bars on the advanced HUD')
  toggle(app, 'paceBar', 'Speed bar against the benchmark')
  gap()
  toggle(app, 'gamepad', 'I use a gamepad, not a wheel')
  toggle(app, 'mph', 'Speeds in mph')
  toggle(app, 'swapLR', 'Swap left and right (only if callouts are mirrored)')
  gap()
  line('Updates', C.dim)
  toggle(app, 'autoCheck', 'Look for a new version when the app starts')
  toggle(app, 'autoInstall', 'Download and install new versions without asking')
  local u = app.updater
  ui.text('Installed: ' .. tostring(app.version) .. '   ' .. updateStatus(app))
  if u and not Sim.has['web.get'] then
    line(S.update.noWeb, C.orange)
  elseif u and Sim.has['ui.button'] then
    if (u.state == 'idle' or u.state == 'current' or u.state == 'failed') and ui.button('Check for updates') then
      u:check()
    end
    if u.state == 'available' and ui.button('Update now') then u:install() end
    if u.state == 'done' and Sim.has['ac.unloadApp'] and ui.button('Reload PaceCoach now') then
      Sim.unloadApp()
    end
  end
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
  ui.text('Voice: ' .. tostring(Voice.status) .. '   clips played: ' .. tostring(Voice.played)
    .. (Voice.missing and ('   missing clip: ' .. Voice.missing) or ''))
  ui.text('Live coach: ' .. ((app.gauge and app.gauge.active) and 'comparing with ' .. tostring(app.coachLabel)
    or 'waiting for a benchmark lap') .. '   update: ' .. updateStatus(app))
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
  if tab == 'Coach' then
    coachTab(app, W)
  elseif tab == 'Track' then
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
