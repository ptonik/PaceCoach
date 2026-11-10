-- Ties everything together: reads the game each frame, feeds the logic
-- modules, and hands the results to the HUD, the map and the panel.

local config = require('src/config')
local U = require('src/util')
local S = require('src/strings')
local Track = require('src/track')
local Grip = require('src/grip')
local Recorder = require('src/recorder')
local Pilot = require('src/pilot')
local Mistakes = require('src/mistakes')
local Reference = require('src/reference')
local Metrics = require('src/metrics')
local Targets = require('src/targets')
local Coach = require('src/coach')
local Teacher = require('src/teacher')
local Live = require('src/live')
local Lesson = require('src/lesson')
local Updater = require('src/updater')
local Limit = require('src/limit')
local Report = require('src/report')
local Spotter = require('src/spotter')
local Stint = require('src/stint')
local Licence = require('src/licence')
local Sim = require('src/sim')
local Settings = require('src/settings')
local Voice = require('src/voice')
local G = require('src/gfx')
local Map = require('src/map')
local Hud = require('src/hud')
local Panel = require('src/panel')
local Markers = require('src/markers')

local App = {
  version = config.version,
  state = 'init',          -- init | sampling | ready | noline | incompatible
  clock = 0,
  settings = Settings.defaults,
  settingsPersist = false,
  car = {}, sim = {},
  laps = {}, lapNumber = 0,
  mistakeCounts = {}, cornerMistakes = {}, tipShownAt = {},
  cornerResults = {},      -- corner index -> latest coach result
  others = {},             -- indices of other cars of the same model
  errorCount = 0,
  liveCounts = {},         -- live cue id -> times spoken this session
  history = {},            -- one entry per earlier session with this car and track
}

local rs, ms, ts, other = {}, {}, {}, {}   -- reusable sample tables
local popts, mopts, liveIn = {}, {}, {}
local traffic = {}                          -- reusable: where the other cars are

-- Errors --------------------------------------------------------------------

local function traceback(err)
  local trace = (debug and debug.traceback) and debug.traceback('', 2) or ''
  return tostring(err) .. trace
end

local seen = {}
local function guard(name, fn, ...)
  local ok, err = xpcall(fn, traceback, ...)
  if not ok then
    local first = tostring(err):match('^[^\n]*') or 'unknown error'
    App.lastError = name .. ': ' .. first
    App.errorCount = App.errorCount + 1
    if not seen[first] then
      seen[first] = true
      Sim.log('error in ' .. name .. ': ' .. tostring(err))
    end
  end
  return ok
end

-- Tips and toasts -----------------------------------------------------------

local function showTip(tip, seconds)
  local current = App.tip
  if current and App.clock < current.untilT and (current.rank or 99) < (tip.rank or 99)
      and App.clock - current.at < 2 then
    return                              -- something more important just appeared
  end
  tip.at = App.clock
  tip.untilT = App.clock + (seconds or config.hud.tipShowS)
  App.tip = tip
end

-- The corner a cell belongs to, counting its approach and exit.
local function cornerNear(track, cell)
  local n = track.n
  local before, after = U.round(120 / track.cellM), U.round(60 / track.cellM)
  for _, c in ipairs(track.corners) do
    local from = U.wrapIndex(c.startCell - before, n)
    local span = U.forward(from, c.endCell, n) + after
    if U.forward(from, cell, n) <= span then return c end
  end
  return nil
end

-- The instruction for the next attempt at a corner, from the cause of the loss.
local function remedyText(id, value)
  local r = S.remedy[id]
  if not r then return nil end
  if r.step then return string.format(r.text, Lesson.stepM(value, config.lesson)) end
  if r.value then return string.format(r.text, U.round(value or 0)) end
  return r.text
end
App.remedyText = remedyText

-- The coaching stage: 1 foundations, 2 technique, 3 the limit. From the pace
-- level when there is one, otherwise from the training steps.
local function coachingTier()
  local level = App.level
  if level then return (level.index <= 2 and 1) or (level.index <= 4 and 2) or 3 end
  return App.lesson and App.lesson:stageTier() or 1
end

-- Benchmark -----------------------------------------------------------------

-- Decides which lap guides the brake cue and the corner targets, and which
-- lap the post-corner feedback compares against.
local function refreshBenchmark()
  local lap, label = Teacher.choose(App.teacherLap, App.importLap, App.best, App.importLabel)
  App.benchmark, App.benchLabel = lap, label
  if App.state ~= 'ready' then return end

  -- The limit lap: what this car could do on the line of the fastest real
  -- lap, with the best grip anyone has shown in it. Once you are the fastest
  -- real lap yourself, it becomes the benchmark, so the coaching never ends
  -- at "you beat the teacher".
  App.limitLap, App.level = nil, nil
  local base = lap or App.best
  if base then
    guard('limit lap', function()
      local env = Limit.envelope(App.track, { base, App.teacherLap, App.importLap, App.best }, App.grip,
        config.limit, config.grip, config.track)
      App.limitEnv, App.limitGripVersion = env, App.grip.version
      App.limitLap = Limit.build(App.track, base, env, config.limit, config.track)
    end)
  end
  if lap then
    if App.limitLap and App.best and (App.teacherLap or App.importLap) then
      App.level = Limit.level(App.best.timeMs, App.limitLap.timeMs, config.limit.levels)
    end
    if label == 'you' and App.limitLap then
      lap, label = App.limitLap, 'limit'
      App.benchmark, App.benchLabel = lap, label
    end
  end
  App.benchPlan = lap and Targets.build(App.track, lap, App.segs, config.targets, config.metrics) or nil
  App.ownPlan = nil
  if not lap and App.best then
    -- Driving alone: the coach compares you with the limit lap built on your
    -- own best lap, which asks every corner for the grip you showed in your
    -- best one. The brake cue stays with the cautious estimate.
    App.ownPlan = Targets.build(App.track, App.limitLap or App.best, App.segs, config.targets, config.metrics)
  end
  App.coachPlan = App.benchPlan or App.ownPlan
  App.coachLabel = label or (App.ownPlan and (App.limitLap and 'limit' or 'own') or nil)
  App.cuePlan = App.benchPlan or App.plan
  App.pilot:setPlan(App.cuePlan)
  App.live:setPlan(App.coachPlan)
  -- Losses against one benchmark do not compare with losses against another.
  if App.coachLabel ~= App.lessonLabel then
    App.lessonLabel = App.coachLabel
    App.lesson:rebase()
  end
  App.lesson.allowPush = App.coachPlan ~= nil
  App.tier = coachingTier()
  App.lesson.tier = App.tier
end

-- A lap from outside: a friend's file, or one shared through the repository.
-- The faster of the two counts.
function App.pickImport()
  local lap, label = App.friendLap, 'friend'
  if App.sharedLap and (not lap or App.sharedLap.timeMs < lap.timeMs) then lap, label = App.sharedLap, 'shared' end
  App.importLap, App.importLabel = lap, lap and label or nil
end

-- What the licence ladder looks at: the best this driver has shown with
-- this car on this track, in this session or an earlier one.
function App.licenceStats()
  local stats = { cleanStreak = 0, windowStreak = 0, stepsDone = 0 }
  for _, entry in ipairs(App.history) do
    stats.cleanStreak = math.max(stats.cleanStreak, entry.clean or 0)
    stats.windowStreak = math.max(stats.windowStreak, entry.window or 0)
    stats.stepsDone = math.max(stats.stepsDone, entry.steps or 0)
    if entry.pace and (not stats.paceRatio or entry.pace / 1000 < stats.paceRatio) then stats.paceRatio = entry.pace / 1000 end
  end
  if App.stint then
    stats.cleanStreak = math.max(stats.cleanStreak, App.stint.bestClean)
    stats.windowStreak = math.max(stats.windowStreak, App.stint.bestStreak)
  end
  if App.lesson then
    local done = 0
    for _, st in ipairs(App.lesson:stages()) do
      if st.done then done = done + 1 end
    end
    stats.stepsDone = math.max(stats.stepsDone, done)
  end
  if App.level and (not stats.paceRatio or App.level.ratio < stats.paceRatio) then stats.paceRatio = App.level.ratio end
  return stats
end

-- Start-up ------------------------------------------------------------------

local function buildTrack(points)
  local sign = Sim.leftSign()
  App.leftMeasured = sign ~= nil
  App.leftSource = sign and 'measured from the front wheels' or 'assumed (could not be measured)'
  sign = sign or 1
  App.swapApplied = App.settings.swapLR == true
  if App.swapApplied then
    sign = -sign
    App.leftSource = App.leftSource .. ', swapped in Settings'
  end
  local track = Track.build(points, { cfg = config.track, leftSign = sign })
  local gameLength = App.sim.trackLengthM or 0
  if track.lengthM < 50
      or (gameLength > 0 and (track.lengthM < gameLength * 0.5 or track.lengthM > gameLength * 1.5)) then
    App.state = 'noline'
    Sim.log(string.format('ideal line rejected: %.0f m against a %.0f m track', track.lengthM, gameLength))
    return
  end
  App.points = points
  App.track = track
  App.segs = Metrics.segments(track)
  App.plan = Track.plan(track, App.grip, config.grip)
  App.planAt = App.clock
  App.pilot = Pilot.new(track, config.pilot)
  App.live = Live.new(track, config.live)
  App.lesson = Lesson.new(#track.corners, config.lesson)
  App.lessonLabel = nil
  App.liveCue, App.gauge = nil, nil
  App.map = Map.prepare(track)
  App.card = nil
  App.segIdx = nil
  App.cornerResults = {}
  App.state = 'ready'
  refreshBenchmark()
end

local function init()
  if not Sim.selfTest() then return end          -- the car is not there yet
  App.settings, App.settingsPersist = Settings.load()
  if Sim.fatal then
    App.state = 'incompatible'
    Sim.log('missing essentials: ' .. Sim.fatal)
    return
  end
  Sim.readSim(App.sim)
  App.trackId, App.carId = Sim.trackId(), Sim.carId()
  local length = tonumber(App.sim.trackLengthM) or 0
  App.n = U.clamp(U.round(length / config.grid.cellM), config.grid.minCells, config.grid.maxCells)
  App.recorder = Recorder.new(App.n, config.lap)
  App.mistakes = Mistakes.new(config.mistakes)
  App.dataDir = Sim.dataDir()
  App.reference = Reference.new({ dir = App.dataDir, save = Sim.saveFile, load = Sim.loadFile })
  App.data = App.reference:loadCombo(App.trackId, App.carId, App.n)
  App.best = App.data.laps.best
  App.teacherLap = App.data.laps.teacher
  App.friendLap = App.reference:loadImport(App.trackId, App.carId, App.n)
  App.sharedLap = App.reference:loadShared(App.trackId, App.carId, App.n)
  App.pickImport()
  App.teacher = Teacher.new(App.n, config.lap, config.teacher)
  App.teacher.best = App.teacherLap                 -- only a faster lap replaces a saved one
  App.grip = Grip.new(config.grip, App.reference:loadGrip(App.carId))
  App.history = App.reference:loadHistory(App.trackId, App.carId)
  App.spotter = Spotter.new(config.spotter)
  App.stint = Stint.new(config.stint)
  App.licence = Licence.evaluate(App.licenceStats(), config.licence.grades)
  App.licenceIdx = App.licence.index
  App.updater = Updater.new({
    get = Sim.httpGet, save = Sim.saveFile, load = Sim.loadFile, mkdir = Sim.makeDir,
    base = config.update.base, list = config.update.manifest,
    dir = Sim.appDir(), current = config.version, limits = config.update,
  })
  Voice.init(Sim.appDir())
  Sim.onJump(function() App.jumped = true end)
  Sim.onSessionStart(function() App.restarted = true end)
  if Sim.hasLine() == false then
    App.state = 'noline'
  else
    App.samplePoints, App.sampleProgress = {}, 0
    App.state = 'sampling'
  end
  refreshBenchmark()
  Sim.log(string.format('started on %s with %s, %d cells', App.trackId, App.carId, App.n))
end

-- Reads the ideal line a few hundred points per frame, so nothing stutters.
local function sample()
  local n, points = App.n, App.samplePoints
  local from = #points + 1
  for i = from, math.min(n, from + 399) do
    local x, y, z = Sim.linePoint((i - 1) / n)
    if not x then
      App.state = 'noline'
      return
    end
    points[i] = { x = x, y = y, z = z }
  end
  App.sampleProgress = #points / n
  if #points >= n then buildTrack(points) end
end

-- Laps ----------------------------------------------------------------------

-- What the coach says at the end of a lap: where the most time went, and
-- the one thing to work on next.
local function lessonLine(sum, brief)
  if not (sum and App.track and App.coachPlan and App.settings.lessons) then return nil end
  local corners = App.track.corners
  local parts = {}
  if not brief and sum.worstK and sum.worstMs and sum.worstMs >= config.lesson.minFocusMs then
    parts[#parts + 1] = string.format(S.lesson.lapWorst, corners[sum.worstK].name, U.formatDelta(sum.worstMs))
  end
  local f = sum.focus
  local text = f and remedyText(f.id, f.value)
  if text then
    parts[#parts + 1] = string.format(sum.changed and S.lesson.lapFocus or S.lesson.lapKeep, corners[f.k].name, text)
  elseif sum.worstK then
    parts = { S.lesson.lapClean }
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ' ')
end

-- Everything the session report needs, as plain values.
function App.reportData()
  local lesson, corners = App.lesson, App.track and App.track.corners or {}
  local d = {
    version = App.version, track = App.trackId, car = App.carId, date = Sim.dateText(Sim.now()),
    laps = App.lapNumber, valid = App.validLaps or 0, bestMs = App.best and App.best.timeMs,
    benchLabel = S.benchmark[App.benchLabel or App.coachLabel or ''], limitMs = App.limitLap and App.limitLap.timeMs,
    benchMs = App.benchmark and App.benchmark.timeMs, lastError = App.lastError,
    skills = {}, stages = {}, fixed = {}, corners = {}, said = {}, mistakes = {}, missing = {},
  }
  if App.level then d.level = { name = S.level[App.level.id], ratio = App.level.ratio } end
  if App.licence then d.licence = S.licence[App.licence.id] end
  if App.stint then
    d.stint = string.format(S.stint.line, App.stint.streak, App.stint.bestStreak, App.stint.clean, App.stint.bestClean)
  end
  if lesson then
    local skills = lesson:skills()
    for _, id in ipairs(S.skills.order) do d.skills[#d.skills + 1] = { name = S.skills[id], value = skills[id] } end
    for _, st in ipairs(lesson:stages()) do
      d.stages[#d.stages + 1] = { name = S.stage[st.id].name, done = st.done,
        line = string.format(S.stage[st.id].line, st.have, st.need) }
    end
    local f = lesson.focus
    if f and corners[f.k] then
      d.focus = { corner = corners[f.k].name, text = remedyText(f.id, f.value), tries = f.tries }
    end
    for _, done in ipairs(lesson.fixed) do
      d.fixed[#d.fixed + 1] = { corner = corners[done.k] and corners[done.k].name or '?', fromMs = done.fromMs, toMs = done.toMs }
    end
    for _, row in ipairs(lesson:ranking()) do
      d.corners[#d.corners + 1] = {
        name = corners[row.k] and corners[row.k].name or '?', typicalMs = row.typicalMs,
        cause = row.id and S.remedy[row.id] and S.remedy[row.id].short or nil,
        lastMs = row.lastMs, bestMs = row.bestMs, passes = row.passes,
        steadyM = row.steady and row.steady.brakeM >= config.lesson.steadyBrakeM and row.steady.brakeM or nil,
      }
    end
  end
  for id, count in pairs(App.liveCounts) do d.said[#d.said + 1] = { text = S.live[id].text:lower(), count = count } end
  table.sort(d.said, function(a, b) return a.text < b.text end)
  for _, id in ipairs(Mistakes.PRIORITY) do
    if App.mistakeCounts[id] then d.mistakes[#d.mistakes + 1] = { title = S.tips[id].title, count = App.mistakeCounts[id] } end
  end
  if App.limitEnv then d.grip = { lat = App.limitEnv.lat, brake = App.limitEnv.brake } end
  for _, row in ipairs(Sim.report) do
    if not row.ok then d.missing[#d.missing + 1] = row.name end
  end
  return d
end

-- Keeps the last few laps of this session on disk, so they can be replayed
-- and looked at afterwards. Each lap is turned into text once.
function App.logLap(lap)
  App.logChunks = App.logChunks or {}
  local chunks = App.logChunks
  chunks[#chunks + 1] = Reference.encodeLap(string.format('lap%03d', App.lapNumber), lap)
  while #chunks > config.lap.logKeep do table.remove(chunks, 1) end
  App.reference:saveSession({ track = App.trackId, car = App.carId, n = App.n,
    left = App.track and App.track.leftSign or 1 }, chunks)
end

-- Keeps one line of numbers per session, so progress shows across days.
local function saveHistory()
  if not App.lesson then return end
  local entry = App.session
  if not entry then
    entry = { at = Sim.now() }
    App.session = entry
    App.history[#App.history + 1] = entry
  end
  for key, value in pairs(App.lesson:summary()) do entry[key] = value end
  entry.laps, entry.valid = App.lapNumber, App.validLaps or 0
  entry.best = App.sessionBestMs
  entry.pace = App.level and (App.level.ratio * 1000) or nil
  entry.window, entry.clean = App.stint.bestStreak, App.stint.bestClean
  local steps = 0
  for _, st in ipairs(App.lesson:stages()) do
    if st.done then steps = steps + 1 end
  end
  entry.steps = steps
  entry.bench = App.benchmark and App.benchmark.timeMs or nil
  App.reference:saveHistory(App.trackId, App.carId, App.history, config.lesson.historyKeep)
  App.reportSaved = App.reference:saveReport(App.trackId, App.carId, Report.build(App.reportData()))
end

local function finishLap(lap, s)
  if not lap.complete then return end            -- out-laps and part laps are not listed
  local official = s.previousLapTimeMs
  if official and official > 0
      and math.abs(official - lap.timeMs) <= config.lap.officialToleranceMs then
    lap.timeMs = official
  end
  if s.lastLapValid == false and lap.valid then
    lap.valid, lap.invalid = false, 'cut'
  end
  App.lapNumber = App.lapNumber + 1
  App.laps[#App.laps + 1] = {
    number = App.lapNumber, timeMs = lap.timeMs, valid = lap.valid, reason = lap.invalid,
  }
  if #App.laps > 30 then table.remove(App.laps, 1) end
  if lap.valid then
    App.validLaps = (App.validLaps or 0) + 1
    if not App.sessionBestMs or lap.timeMs < App.sessionBestMs then App.sessionBestMs = lap.timeMs end
  end
  if App.lesson then
    App.tier = coachingTier()
    App.lesson.tier = App.tier
  end
  if App.settings.sessionLog then guard('session log', App.logLap, lap) end
  local lessonSum = App.lesson and App.lesson:lapDone(lap.timeMs, lap.valid) or nil

  -- The stint: how many laps in a row have been close to the best one.
  local bestMs = App.best and App.best.timeMs or nil
  if lap.valid and (not bestMs or lap.timeMs < bestMs) then bestMs = lap.timeMs end
  local stint = App.stint:lap(lap.timeMs, lap.valid, bestMs)
  App.stintLast = stint
  local racing
  if stint.milestone then
    racing = string.format('%d laps in a row in the window.', stint.milestone)
  elseif stint.broke then
    racing = string.format(S.stint.broke, stint.broke)
  elseif stint.inWindow and stint.streak >= 2 then
    racing = string.format(S.stint.inWindow, stint.streak)
  end
  if App.level then App.levelNow = App.level end
  local licence = Licence.evaluate(App.licenceStats(), config.licence.grades)
  local licenceUp = licence.index > (App.licenceIdx or 1)
  App.licence, App.licenceIdx = licence, math.max(App.licenceIdx or 1, licence.index)
  if licenceUp then
    racing = string.format(S.licence.up, S.licence[licence.id]) .. '.' .. (racing and (' ' .. racing) or '')
  end
  -- One note has to carry all of this at speed: when there is racing news,
  -- the lesson part shrinks to the one thing to do next.
  local advice = lessonLine(lessonSum, racing ~= nil)
  local function withAdvice(body)
    if racing then body = racing .. ' ' .. body end
    return advice and (body .. ' ' .. advice) or body
  end
  if App.settings.voice and App.settings.praise then
    if stint.milestone then Voice.say('streak_' .. stint.milestone, App.settings.voiceVolume, false, 6) end
    if licenceUp then Voice.say('licence_up', App.settings.voiceVolume, false, 8) end
  end
  guard('history', saveHistory)

  local time = U.formatLap(lap.timeMs)
  if not lap.valid then
    showTip({ title = 'Lap ' .. time .. ' does not count',
      body = withAdvice('Reason: ' .. (Panel.REASONS[lap.invalid] or tostring(lap.invalid)) .. '.'), rank = 50 },
      advice and 8 or 5)
    return
  end
  local best = App.best
  if not best or lap.timeMs < best.timeMs then
    lap.source = 'player'
    App.best = lap
    App.data.laps.best = lap
    local saved = App.reference:saveCombo(App.data)
    App.lastSave = saved and ('saved ' .. time) or 'could not be saved (see the data folder in Settings)'
    local wasLabel, wasLevel = App.benchLabel, App.levelIdx
    refreshBenchmark()
    local body = best and ('Faster by ' .. U.formatDelta(best.timeMs - lap.timeMs):sub(2) .. ' s.')
      or 'From now on the HUD can compare you with this lap.'
    if App.benchLabel == 'limit' and wasLabel and wasLabel ~= 'limit' then
      body = S.status.teacherBeaten
    end
    local level = App.level
    local levelUp = level and wasLevel and level.index > wasLevel
    if level then App.levelIdx = level.index end
    if levelUp then
      body = string.format(S.level.up, S.level[level.id]) .. '. ' .. body
    end
    showTip({ title = (best and S.status.newBest or S.status.firstBest) .. '  ' .. time,
      body = withAdvice(body), good = true, rank = 40 }, advice and 8 or 6)
    if App.settings.voice then
      Voice.say('best_lap', App.settings.voiceVolume)
      if levelUp then Voice.say('level_up', App.settings.voiceVolume, false, 4) end
    end
  else
    -- More grip found since the limit lap was worked out: it moves up.
    if App.benchLabel == 'limit' and App.grip.version ~= App.limitGripVersion then refreshBenchmark() end
    showTip({ title = 'Lap ' .. time,
      body = withAdvice(U.formatDelta(lap.timeMs - best.timeMs) .. ' s to your best.'), rank = 60 },
      advice and 8 or 5)
  end
end

-- Teacher -------------------------------------------------------------------

local function onTeacherLap(lap)
  local derived = false
  if not Metrics.pedalsLookReal(lap) then
    Metrics.derivePedals(lap)
    derived = true
  end
  App.teacherLap = lap
  App.teacherDerived = derived
  App.data.laps.teacher = lap
  local saved = App.reference:saveCombo(App.data)
  App.lastSave = saved and ('saved teacher lap ' .. U.formatLap(lap.timeMs))
    or 'could not be saved (see the data folder in Settings)'
  refreshBenchmark()
  showTip({ title = S.status.teacherReady .. '  ' .. U.formatLap(lap.timeMs),
    body = S.status.teacherBody .. (derived and S.status.teacherDerived or ''),
    good = true, rank = 30 }, 7)
  if App.settings.voice then Voice.say('teacher_ready', App.settings.voiceVolume) end
end

-- Records the laps of other cars of the same model.
local function watchOthers(dt)
  if App.clock - (App.othersAt or -1e9) > config.teacher.refreshS then
    App.othersAt = App.clock
    App.others = Sim.sameModelCars(App.carId, config.teacher.maxCars)
  end
  for _, index in ipairs(App.others) do
    local o = Sim.readOther(index, other)
    if o and o.pos == o.pos then
      if o.pos < 0 or o.pos >= 1 then o.pos = o.pos % 1 end
      ts.pos, ts.t, ts.lapCount, ts.dt = o.pos, o.lapTimeMs, o.lapCount, dt
      ts.v, ts.gas, ts.brake, ts.steer = o.speedKmh, o.gas, o.brake, o.steer
      ts.gear, ts.x, ts.z = o.gear, o.x, o.z
      ts.inPit, ts.wheelsOut = o.inPit, o.wheelsOut
      local lap = App.teacher:feed(index, ts)
      if lap then onTeacherLap(lap) end
    end
  end
end

-- Coach ---------------------------------------------------------------------

local function coachText(res, mph)
  local template = S.coach[res.id]
  if not template then return nil end
  if res.id == 'busyHands' or res.id == 'tooMuchLock' then
    return string.format(template, U.round(res.value or 0))
  end
  if res.id == 'overSlow' or res.id == 'exitSlow' then
    local speed = mph and string.format('%d mph', U.round(res.value * 0.621371))
      or string.format('%d km/h', U.round(res.value))
    return string.format(template, speed)
  end
  if res.value then return string.format(template, U.round(res.value)) end
  return template
end
App.coachText = coachText

-- Called just past the exit of corner k: measure it and say the one thing
-- that mattered most, while the corner is still fresh.
local function judgeCorner(k)
  local plan = App.coachPlan
  local seg, ref, refSlice = plan.exitSegs[k], plan.exitTargets[k], plan.exitSlices[k]
  local offTrack = App.offInSeg == true
  if not (seg and ref) then return end
  local lapNow = App.recorder.lap
  if lapNow.invalid == 'pit' or lapNow.invalid == 'jump' then return end
  local sl = Metrics.slice(App.track, lapNow, App.recorder.prev, seg)
  if not sl then return end
  local c = App.track.corners[k]
  local got = Metrics.measure(sl, App.track, c, seg, config.metrics)
  local left = Metrics.lateral(sl, refSlice, ref.minJ, App.track.leftSign)
  local wide = (c.dir == 'left') and -left or left      -- outside of a left-hander is the right
  local gamepad = App.settings.gamepad == true
  local res = Coach.judge(ref, got, { wideM = wide, offTrack = offTrack, gamepad = gamepad }, config.coach)
  res.corner, res.at = c, App.clock
  res.text = coachText(res, App.settings.mph)
  App.cornerResults[k] = res
  App.lastPass = App.lastPass or {}
  App.lastPass[k] = sl                       -- for the speed trace in the panel
  if App.trafficInSeg then
    -- A corner taken in traffic says nothing about how you drive it alone:
    -- it is left out of the lesson plan, and nobody is told off for it.
    res.traffic = true
    return
  end

  local verdict = App.lesson:record(k, res,
    Coach.detail(ref, got, { wideM = wide, offTrack = offTrack, gamepad = gamepad }))
  res.verdict = verdict
  local say = App.settings.voice and App.settings.praise
  local vol = App.settings.voiceVolume
  local title = c.name .. '  ' .. U.formatDelta(res.lossMs) .. ' s'

  if verdict and verdict.focus and App.settings.lessons then
    -- The corner being worked on: always say how this attempt went.
    if verdict.prevMs then title = title .. '  (was ' .. U.formatDelta(verdict.prevMs) .. ')' end
    local kind, body, good = verdict.kind, res.text, res.good
    if kind == 'steadyOn' then
      body, good = remedyText('steady', App.lesson.focus and App.lesson.focus.value) or res.text, false
    elseif kind == 'pushed' or kind == 'pushGain' or kind == 'steadyDone' then
      body, good = S.lesson[kind], true
      local nxt = verdict.next
      if nxt and S.remedy[nxt.id] then
        body = body .. ' ' .. string.format(S.lesson.nextUp, App.track.corners[nxt.k].name, S.remedy[nxt.id].short)
      end
      if kind == 'pushGain' and say then Voice.say('nice', vol, false, 1.5) end
    elseif kind == 'parked' then
      body, good = S.lesson.parked, false
      local nxt = verdict.next
      if nxt and S.remedy[nxt.id] then
        body = body .. ' ' .. string.format(S.lesson.nextUp, App.track.corners[nxt.k].name, S.remedy[nxt.id].short)
      end
    elseif kind == 'good' then
      body, good = S.lesson.good, true
      if say then Voice.say('thats_it', vol, false, 1.5) end
    elseif kind == 'better' then
      local again = App.lesson.focus and remedyText(App.lesson.focus.id, App.lesson.focus.value)
      body, good = S.lesson.better .. (again and (' ' .. again) or ''), true
      if say then Voice.say('better', vol, false, 1.5) end
    elseif not body then
      body = S.lesson[kind] or S.lesson.same
    end
    App.praiseAt = App.clock
    if App.settings.showTips then
      showTip({ title = title, body = body, good = good, rank = 15 }, config.coach.showS + 1)
    end
    return
  end

  -- Any other corner: a word of praise when it went well after going badly.
  if say and offTrack == false and App.clock - (App.praiseAt or -1e9) >= config.lesson.praiseGapS then
    local recovered = res.good and verdict and verdict.prevMs and verdict.prevMs >= config.lesson.minFocusMs
    if res.id == 'gain' or recovered then
      App.praiseAt = App.clock
      Voice.say(res.id == 'gain' and 'nice' or 'good', vol, false, 1.5)
    end
  end
  local vague = res.id == 'slower' and res.lossMs < config.coach.vagueMs
  if res.id ~= 'ok' and not vague and res.text and App.settings.showTips then
    showTip({ title = title, body = res.text, good = res.good, rank = 20 }, config.coach.showS)
  end
end

-- Called when the car leaves the whole segment of corner k: quietly replace
-- the time lost with the figure for the full segment, which includes what a
-- slow exit cost down the following straight.
local function settleCorner(k)
  local plan, res = App.coachPlan, App.cornerResults[k]
  local ref = plan.targets[k]
  if not (res and ref) or res.traffic then return end
  local sl = Metrics.slice(App.track, App.recorder.lap, App.recorder.prev, App.segs[k])
  if not sl then return end
  res.lossMs = sl.timeMs - ref.timeMs
  local verdict = App.lesson:settle(k, sl.timeMs, res.lossMs, res.id ~= 'offTrack')
  if not (verdict and App.settings.lessons) then return end
  -- The corner being worked on is sorted (or put aside): say so, and name the next one.
  local corners = App.track.corners
  local fixed = verdict.kind == 'fixed'
  local body = fixed and S.lesson.fixed or S.lesson.parked
  local nxt = verdict.next
  if nxt and S.remedy[nxt.id] then
    body = body .. ' ' .. string.format(S.lesson.nextUp, corners[nxt.k].name, S.remedy[nxt.id].short)
  end
  local title = corners[k].name
  if fixed then
    title = string.format(S.lesson.sorted, corners[k].name) .. '  ' .. U.formatDelta(verdict.fromMs)
      .. ' to ' .. U.formatDelta(verdict.toMs) .. ' s'
    App.praiseAt = App.clock
  end
  if App.settings.showTips then
    showTip({ title = title, body = body, good = fixed, rank = 15 }, config.coach.showS + 2)
  end
  if fixed and App.settings.voice and App.settings.praise then Voice.say('fixed', App.settings.voiceVolume, false, 2) end
end

-- One frame -----------------------------------------------------------------

local function frame(dt)
  local s = Sim.readCar(App.car, dt)
  if not s then return end
  Sim.readSim(App.sim)
  if App.sim.paused or App.sim.replay then return end
  if s.pos ~= s.pos then return end              -- NaN guard
  if s.pos < 0 or s.pos >= 1 then s.pos = s.pos % 1 end

  if App.restarted or App.jumped then
    App.recorder:restart(App.jumped and 'jump' or nil)
    if App.pilot then App.pilot:reset() end
    if App.live then App.live:reset() end
    App.liveCue = nil
    if App.restarted then App.teacher:reset() end
    App.restarted, App.jumped, App.pendingLap, App.segIdx = false, false, nil, nil
  end
  if App.state == 'ready' and (App.settings.swapLR == true) ~= App.swapApplied then
    buildTrack(App.points)
  elseif App.state == 'ready' and not App.leftMeasured
      and App.clock - (App.leftTriedAt or 0) > 2 then
    App.leftTriedAt = App.clock
    if Sim.leftSign() then buildTrack(App.points) end
  end

  local inPits = s.inPitlane or s.inPit
  local driving = s.speedKmh > 20 and not inPits

  -- Record the lap.
  rs.pos, rs.t, rs.lapCount, rs.dt = s.pos, s.lapTimeMs, s.lapCount, dt
  rs.v, rs.gas, rs.brake, rs.steer = s.speedKmh, s.gas, s.brake, s.steer or 0
  rs.gear, rs.x, rs.z = s.gear, s.x, s.z
  local done = App.recorder:feed(rs)
  if inPits and not App.wasInPits then App.stint:pit() end
  App.wasInPits = inPits

  -- The spotter: cars alongside, and traffic close ahead.
  App.spot = nil
  if App.settings.spotter and App.track and s.lookX and not inPits then
    local count = Sim.readTraffic(traffic, config.spotter.maxCars)
    if count > 0 then
      local spot, calls = App.spotter:update(s, traffic, count, App.track.leftSign, dt)
      App.spot = spot
      if spot.traffic then App.trafficInSeg = true end
      for _, ev in ipairs(calls) do
        local def = S.spot[ev.id]
        if App.settings.voice then
          Voice.say(def.clip, App.settings.voiceVolume, ev.id ~= 'clear', 1)
        end
      end
    end
  end

  if inPits then
    App.recorder:invalidate('pit')
  elseif s.wheelsOut > config.lap.maxWheelsOut then
    App.recorder:invalidate('offtrack')
    App.offInSeg = true
  end
  if done then App.pendingLap = { lap = done, at = App.clock + 0.25 } end
  if App.pendingLap and App.clock >= App.pendingLap.at then
    local lap = App.pendingLap.lap
    App.pendingLap = nil
    finishLap(lap, s)
  end

  watchOthers(dt)

  -- Delta to your best lap and to the benchmark; the benchmark's pedals here.
  App.deltaMs, App.benchDeltaMs, App.ghost = nil, nil, nil
  local current = App.recorder.lap
  local timed = s.lapTimeMs > 0 and current.filled > 5
    and (not current.invalid or current.invalid == 'offtrack')
  if timed and App.best then
    App.deltaMs = Recorder.deltaMs(App.best, s.pos, s.lapTimeMs)
  end
  local guide = App.benchmark
  if guide then
    if timed and guide ~= App.best then
      App.benchDeltaMs = Recorder.deltaMs(guide, s.pos, s.lapTimeMs)
    end
    App.ghostBrake = Recorder.valueAt(guide, 'brake', s.pos)
    App.ghostGas = Recorder.valueAt(guide, 'gas', s.pos)
    App.ghost = true
  end

  -- Learn grip, and re-plan the estimate when it has moved.
  local trusted = driving and s.wheelsOut <= config.lap.maxWheelsOut and (s.velAngleDeg or 0) < 20
  App.grip:feed(dt, s.speedMs, s.latG or 0, s.brake, trusted)
  if App.state == 'ready' and App.grip.version ~= App.plan.gripVersion
      and App.clock - App.planAt > 2 then
    App.plan = Track.plan(App.track, App.grip, config.grip)
    App.planAt = App.clock
    App.cuePlan = App.benchPlan or App.plan
    App.pilot:setPlan(App.cuePlan)
    App.gripDirty = true
  end
  if App.gripDirty and App.clock - (App.gripSavedAt or 0) > 30 then
    App.gripDirty, App.gripSavedAt = false, App.clock
    App.reference:saveGrip(App.carId, App.grip:export())
  end

  local ready = App.state == 'ready' and #App.track.corners > 0
  local cell = ready and Track.cellAt(App.track, s.pos) or nil

  -- Is the driver busy with trouble right now? The co-driver waits if so,
  -- and calls the corner again once they are back under control.
  local serious = s.wheelsOut > config.lap.maxWheelsOut
    or (s.speedKmh > 25 and (s.velAngleDeg or 0) > config.pilot.busySlideDeg)
  if serious then App.lost, App.steadyT = true, 0 end
  local busy = serious or (App.clock - (App.troubleAt or -1e9)) < config.pilot.busyAfterMistakeS
  if App.lost and not serious then
    App.steadyT = (App.steadyT or 0) + dt
    if App.steadyT >= config.pilot.recoverS and s.speedKmh > 30 then
      App.lost = false
      if App.pilot then App.pilot:reorient() end
    end
  end

  -- Co-driver.
  local vol = App.settings.voiceVolume
  if ready then
    popts.leadS, popts.gas, popts.brake = App.settings.leadS, s.gas, s.brake
    popts.callLeadS, popts.busy = App.settings.callLeadS, busy
    local card, events = App.pilot:update(s.pos, inPits and 0 or s.speedMs, dt, popts)
    App.card = card
    for _, ev in ipairs(events) do
      if ev.kind == 'corner' then
        if App.settings.voice then
          Voice.say(ev.corner.severity .. '_' .. ev.corner.dir, vol)
          for _, c in ipairs(ev.chain or {}) do Voice.say('then_' .. c.dir, vol) end
          -- The corner being worked on gets its instruction with the call.
          local f = App.settings.lessons and App.coachPlan and App.lesson.focus or nil
          local r = f and S.remedy[f.id]
          if r then
            local here = f.k == ev.corner.index
            for _, c in ipairs(ev.chain or {}) do here = here or f.k == c.index end
            if here then Voice.say(r.clip, vol, false, 5) end
          end
        end
      elseif ev.kind == 'brake' then
        if App.settings.brakeSound then
          Voice.say(App.settings.brakeBeep and 'beep' or 'brake', vol, true)
        end
      elseif ev.kind == 'throttle' then
        if App.settings.throttleSound then Voice.say('throttle', vol, true) end
      end
    end
  end

  -- The live coach: compares the car with the benchmark at this very point
  -- and speaks up while there is still time to do something about it.
  App.gauge = nil
  if ready and App.coachPlan then
    local li = liveIn
    li.cell, li.pos, li.v, li.gas, li.brake = cell, s.pos, s.speedKmh, s.gas, s.brake
    li.x, li.z = s.x, s.z
    li.busy = busy or inPits or not driving or App.settings.liveCoach ~= true
      or (App.spot ~= nil and App.spot.traffic)
    li.pilotCue = App.card and App.card.cue or nil
    li.turnCue, li.lineCue = App.settings.turnCue, App.settings.lineCue
    li.maxPerCorner = math.min(App.settings.beginner and 2 or config.live.maxPerCorner, App.tier or 1)
    local gauge, said = App.live:update(li, dt)
    App.gauge = gauge
    for _, ev in ipairs(said) do
      local def = S.live[ev.id]
      App.liveCue = { id = ev.id, def = def, corner = ev.corner, untilT = App.clock + config.live.showS }
      App.liveCounts[ev.id] = (App.liveCounts[ev.id] or 0) + 1
      if App.settings.voice then Voice.say(def.clip, vol, ev.urgent, 0.7) end
    end
  end

  -- Feedback against the benchmark (or your own best), given just past the
  -- exit of each corner.
  if ready and App.coachPlan then
    local n = App.track.n
    local k = Metrics.segmentAt(App.segs, cell, n)
    local was = App.segIdx
    if k ~= was then
      if was and k and driving and k == (was % #App.segs) + 1 then
        if not App.exitJudged then judgeCorner(was) end
        settleCorner(was)
      end
      App.segIdx, App.exitJudged, App.offInSeg, App.trafficInSeg = k, false, false, false
    end
    local es = k and App.coachPlan.exitSegs[k]
    if es and driving and was == k and not App.exitJudged
        and U.forward(App.segs[k].from, cell, n) >= es.cells then
      App.exitJudged = true
      judgeCorner(k)
    end
  end

  -- Mistakes.
  if driving then
    ms.v, ms.gas, ms.brake, ms.steer = s.speedKmh, s.gas, s.brake, s.steer
    ms.wheelsOut, ms.abs, ms.velAngleDeg = s.wheelsOut, s.abs, s.velAngleDeg
    ms.slipRatio = s.hasSlipRatio and s.slipRatio or nil
    ms.slipAngle = s.hasSlipAngle and s.slipAngle or nil
    mopts.gamepad = App.settings.gamepad == true
    local ids = App.mistakes:update(ms, dt, mopts)
    if #ids > 0 then
      local corner = App.track and cornerNear(App.track, Track.cellAt(App.track, s.pos)) or nil
      for _, id in ipairs(ids) do
        App.mistakeCounts[id] = (App.mistakeCounts[id] or 0) + 1
        if corner then
          local per = App.cornerMistakes[corner.name] or {}
          App.cornerMistakes[corner.name] = per
          per[id] = (per[id] or 0) + 1
        end
      end
      local id = Mistakes.mostImportant(ids)
      local rank = 1
      for i, name in ipairs(Mistakes.PRIORITY) do
        if name == id then rank = i end
      end
      if rank <= 5 then App.troubleAt = App.clock end      -- spin, off, lock-up, slide
      -- Spins and excursions always show; lesser tips are not repeated at once.
      local lastShown = App.tipShownAt[id]
      if rank <= 2 or not lastShown or App.clock - lastShown >= config.hud.repeatS then
        App.tipShownAt[id] = App.clock
        showTip({ title = S.tips[id].title, body = S.tips[id].why,
          where = corner and corner.name or nil, rank = rank })
      end
    end
  end
end

-- Shared laps -----------------------------------------------------------------

-- Asks the repository for a fast lap of this car on this track. Most
-- combinations have none, and that is fine.
function App.fetchSharedLap()
  local name = U.safeName(App.trackId) .. '__' .. U.safeName(App.carId) .. '.txt'
  Sim.httpGet(config.update.base .. config.update.laps .. name, function(err, status, body)
    if err or status ~= 200 or type(body) ~= 'string' then return end
    local lap = Reference.fastest(body, App.n, 'shared')
    if not lap or (App.sharedLap and App.sharedLap.timeMs <= lap.timeMs) then return end
    App.sharedLap = lap
    Sim.saveFile(App.reference:sharedPath(App.trackId, App.carId), body)
    App.pickImport()
    refreshBenchmark()
    showTip({ title = S.status.sharedReady .. '  ' .. U.formatLap(lap.timeMs), body = S.status.sharedBody,
      good = true, rank = 35 }, 7)
  end)
end

-- Updates -------------------------------------------------------------------

-- Looks for a new version once, a few seconds after start-up, and tells the
-- driver when the state of an update changes.
local function watchUpdate()
  local u = App.updater
  if not u then return end
  if not App.updateAsked and App.clock >= config.update.checkAfterS then
    App.updateAsked = true
    if App.settings.autoCheck and Sim.has['web.get'] then u:check() end
    if App.settings.sharedLaps and App.trackId then App.fetchSharedLap() end
  end
  u:pump()
  if u.state == 'ready' then
    -- Writing a few megabytes can cost a frame or two: never do it at speed.
    local s = App.car
    if (s.speedKmh or 0) < 5 or s.inPit or s.inPitlane then u:apply() end
  end
  if u.state == App.updateState then return end
  App.updateState = u.state
  if u.state == 'available' then
    if App.settings.autoInstall then
      u:install()
    else
      showTip({ title = string.format(S.update.toast, u.remote.version), body = S.update.toastBody,
        good = true, rank = 70 }, 8)
    end
  elseif u.state == 'done' then
    showTip({ title = string.format(S.update.doneToast, u.installed), body = S.update.doneBody,
      good = true, rank = 70 }, 10)
  elseif u.state == 'failed' then
    Sim.log('update: ' .. tostring(u.error))
  end
end

local function step(dt)
  App.clock = App.clock + dt
  Voice.update(dt)
  if App.state == 'init' then
    init()
    return
  end
  watchUpdate()
  if App.state == 'incompatible' then return end
  if App.state == 'sampling' then sample() end
  frame(dt)
end

-- Entry points called from PaceCoach.lua ------------------------------------

function App.update(dt)
  if type(dt) ~= 'number' or dt ~= dt or dt < 0 then dt = 0 end
  if dt > 0.25 then dt = 0.25 end
  guard('update', step, dt)
end

-- If a window fails to draw, show the reason as plain text instead of an
-- empty (and, for the HUD, invisible) window.
local function showError(where)
  pcall(function()
    ui.text('PaceCoach could not draw the ' .. where .. '.')
    local message = tostring(App.lastError or 'unknown error')
    while #message > 0 do
      ui.text(message:sub(1, 90))
      message = message:sub(91)
    end
    ui.text('See Documents/Assetto Corsa/logs/custom_shaders_patch.log')
  end)
end

function App.drawHud()
  if not guard('hud', Hud.draw, App) then showError('HUD') end
end

local function mapWindow()
  local win = ui.windowSize()
  if App.map then
    local highlight = App.card and App.card.ready and App.card.corner.index or nil
    Map.draw(App.map, 0, 0, win.x, win.y, App.car.x, App.car.z, highlight, 13)
  else
    G.text((App.state == 'noline') and 'No ideal line on this track.' or S.status.loading,
      14, 8, 8, G.colors.dim)
  end
end

function App.drawMap()
  if not guard('map', mapWindow) then showError('map') end
end

function App.drawPanel()
  if not guard('panel', Panel.draw, App) then showError('panel') end
end

function App.draw3D()
  guard('3d', Markers.draw, App)
end

return App
