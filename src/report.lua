-- Writes the session up as plain text: what was driven, where the time
-- goes, what the coach is working on. The file is meant to be read by a
-- person, or pasted to whoever is helping you. Pure logic: it only turns
-- the numbers it is given into lines.

local U = require('src/util')

local Report = {}

local function delta(ms) return U.formatDelta(ms) .. ' s' end

-- d = {
--   version, track, car, date,
--   laps, valid, bestMs, benchLabel, benchMs, limitMs, level = { name, ratio },
--   skills = { { name, value } }, stages = { { name, line, done } },
--   focus = { corner, text, tries }, fixed = { { corner, fromMs, toMs } },
--   corners = { { name, typicalMs, cause, lastMs, bestMs, passes, steadyM } },
--   said = { { text, count } }, mistakes = { { title, count } },
--   grip = { lat = {}, brake = }, missing = { names }, lastError }
function Report.build(d)
  local out = {}
  local function add(text) out[#out + 1] = text or '' end
  add('PaceCoach session report')
  add(string.format('version %s   %s', tostring(d.version), tostring(d.date or '')))
  add(string.format('track %s   car %s', tostring(d.track), tostring(d.car)))
  add()
  add(string.format('Laps: %d, %d clean', d.laps or 0, d.valid or 0))
  if d.bestMs then add('Best lap: ' .. U.formatLap(d.bestMs)) end
  if d.benchMs then
    add(string.format('Benchmark: %s %s%s', tostring(d.benchLabel or 'none'), U.formatLap(d.benchMs),
      d.bestMs and ('   (you: ' .. delta(d.bestMs - d.benchMs) .. ')') or ''))
  else
    add('Benchmark: none yet')
  end
  if d.limitMs then add('Limit lap (estimate): ' .. U.formatLap(d.limitMs)) end
  if d.level then add(string.format('Pace level: %s, %.1f%% of the limit lap', d.level.name, d.level.ratio * 100)) end
  if d.licence then add('Licence: ' .. d.licence) end
  if d.stint then add(d.stint) end

  if d.focus then
    add()
    local tries = d.focus.tries or 0
    add(string.format('Working on: %s. %s (%d %s)', d.focus.corner, d.focus.text or '', tries, tries == 1 and 'try' or 'tries'))
  end
  if d.fixed and #d.fixed > 0 then
    add()
    add('Sorted this session:')
    for _, f in ipairs(d.fixed) do
      add(string.format('  %s   %s to %s', f.corner, delta(f.fromMs), delta(f.toMs)))
    end
  end
  if d.corners and #d.corners > 0 then
    add()
    add('Where the time goes (typical loss, biggest first):')
    for _, c in ipairs(d.corners) do
      local line = string.format('  %-4s %9s   %-28s last %s, best %s, %d passes', c.name, delta(c.typicalMs),
        c.cause or 'fine', delta(c.lastMs), delta(c.bestMs), c.passes or 0)
      if c.steadyM then line = line .. string.format(', brake point moves %d m', U.round(c.steadyM)) end
      add(line)
    end
  end
  if d.skills and #d.skills > 0 then
    add()
    add('Skills (0 to 100):')
    for _, s in ipairs(d.skills) do add(string.format('  %-16s %s', s.name, s.value and tostring(s.value) or '--')) end
  end
  if d.stages and #d.stages > 0 then
    add()
    add('Training steps:')
    for _, s in ipairs(d.stages) do add(string.format('  [%s] %s   %s', s.done and 'x' or ' ', s.name, s.line)) end
  end
  if d.said and #d.said > 0 then
    add()
    add('Said while driving:')
    for _, s in ipairs(d.said) do add(string.format('  %s x%d', s.text, s.count)) end
  end
  if d.mistakes and #d.mistakes > 0 then
    add()
    add('Mistakes:')
    for _, m in ipairs(d.mistakes) do add(string.format('  %s x%d', m.title, m.count)) end
  end
  if d.grip then
    add()
    local lat = {}
    for i, v in ipairs(d.grip.lat or {}) do lat[i] = string.format('%.2f', v) end
    add(string.format('Grip seen: cornering %s g by speed range, braking %.2f g', table.concat(lat, ' / '), d.grip.brake or 0))
  end
  add()
  if d.missing and #d.missing > 0 then
    add('Game features missing on this CSP build: ' .. table.concat(d.missing, ', '))
  else
    add('Self-test: everything the app needs was found.')
  end
  if d.lastError then add('Last error: ' .. tostring(d.lastError)) end
  return table.concat(out, '\n') .. '\n'
end

return Report
