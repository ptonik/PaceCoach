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
}

local rs, ms, ts, other = {}, {}, {}, {}   -- reusable sample tables
local popts, mopts = {}, {}

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

-- Benchmark -----------------------------------------------------------------

-- Decides which lap guides the brake cue and the corner targets, and which
-- lap the post-corner feedback compares against.
local function refreshBenchmark()
  local lap, label = Teacher.choose(App.teacherLap, App.importLap, App.best)
  App.benchmark, App.benchLabel = lap, label
  if App.state ~= 'ready' then return end
  App.benchPlan = lap and Targets.build(App.track, lap, App.segs, config.targets, config.metrics) or nil
  App.ownPlan = nil
  if not lap and App.best then
    App.ownPlan = Targets.build(App.track, App.best, App.segs, config.targets, config.metrics)
  end
  App.coachPlan = App.benchPlan or App.ownPlan
  App.coachLabel = label or (App.ownPlan and 'own' or nil)
  App.cuePlan = App.benchPlan or App.plan
  App.pilot:setPlan(App.cuePlan)
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
  App.importLap = App.reference:loadImport(App.trackId, App.carId, App.n)
  App.teacher = Teacher.new(App.n, config.lap, config.teacher)
  App.teacher.best = App.teacherLap                 -- only a faster lap replaces a saved one
  App.grip = Grip.new(config.grip, App.reference:loadGrip(App.carId))
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

  local time = U.formatLap(lap.timeMs)
  if not lap.valid then
    showTip({ title = 'Lap ' .. time .. ' does not count',
      body = 'Reason: ' .. (Panel.REASONS[lap.invalid] or tostring(lap.invalid)) .. '.', rank = 50 }, 5)
    return
  end
  local best = App.best
  if not best or lap.timeMs < best.timeMs then
    lap.source = 'player'
    App.best = lap
    App.data.laps.best = lap
    local saved = App.reference:saveCombo(App.data)
    App.lastSave = saved and ('saved ' .. time) or 'could not be saved (see the data folder in Settings)'
    local wasLabel = App.benchLabel
    refreshBenchmark()
    local body = best and ('Faster by ' .. U.formatDelta(best.timeMs - lap.timeMs):sub(2) .. ' s.')
      or 'From now on the HUD can compare you with this lap.'
    if App.benchLabel == 'you' and wasLabel and wasLabel ~= 'you' then
      body = S.status.teacherBeaten
    end
    showTip({ title = (best and S.status.newBest or S.status.firstBest) .. '  ' .. time,
      body = body, good = true, rank = 40 }, 6)
    if App.settings.voice then Voice.say('best_lap', App.settings.voiceVolume) end
  else
    showTip({ title = 'Lap ' .. time,
      body = U.formatDelta(lap.timeMs - best.timeMs) .. ' s to your best.', rank = 60 }, 5)
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
  local res = Coach.judge(ref, got, { wideM = wide, offTrack = offTrack }, config.coach)
  res.corner, res.at = c, App.clock
  res.text = coachText(res, App.settings.mph)
  App.cornerResults[k] = res
  if res.id ~= 'ok' and res.text and App.settings.showTips then
    showTip({ title = c.name .. '  ' .. U.formatDelta(res.lossMs) .. ' s',
      body = res.text, good = res.good, rank = 20 }, config.coach.showS)
  end
end

-- Called when the car leaves the whole segment of corner k: quietly replace
-- the time lost with the figure for the full segment, which includes what a
-- slow exit cost down the following straight.
local function settleCorner(k)
  local plan, res = App.coachPlan, App.cornerResults[k]
  local ref = plan.targets[k]
  if not (res and ref) then return end
  local sl = Metrics.slice(App.track, App.recorder.lap, App.recorder.prev, App.segs[k])
  if sl then res.lossMs = sl.timeMs - ref.timeMs end
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
      App.segIdx, App.exitJudged, App.offInSeg = k, false, false
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

local function step(dt)
  App.clock = App.clock + dt
  Voice.update(dt)
  if App.state == 'init' then
    init()
    return
  end
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
