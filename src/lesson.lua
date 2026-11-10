-- The lesson plan. A real coach does not list everything that went wrong:
-- they pick the one corner that costs the most, give one instruction for it,
-- watch the next attempts, and move on once it is fixed.
-- This module keeps the history of every corner across laps and does that.
-- It also works out the session's numbers: ideal lap, consistency, skill
-- scores and the training steps. Pure logic: no game API, standard Lua only.

local Lesson = {}
Lesson.__index = Lesson

-- Results that are not a cause one can give an instruction for.
local NO_REMEDY = { ok = true, gain = true, slower = true }

-- What a driver has to get right before anything else is worth working on.
local FOUNDATION = { offTrack = true, brakeLate = true, brakeEarly = true, noBrake = true, wide = true }
-- What only makes sense once the basics are steady.
local ADVANCED = { noTrail = true, tooMuchLock = true }

Lesson.STAGES = { 'clean', 'braking', 'speed', 'exits', 'consistency' }

function Lesson.new(cornerCount, cfg)
  local self = setmetatable({}, Lesson)
  self.m, self.cfg = cornerCount, cfg
  self.lapTimes = {}                 -- valid lap times of this session, ms
  self.lapCount, self.validCount, self.cleanStreak = 0, 0, 0
  self.stageDone = {}
  self:rebase()
  return self
end

-- Forgets what happened in the corners. Called when the benchmark changes,
-- because losses against the old one do not compare with the new one.
function Lesson:rebase()
  self.corners = {}
  for k = 1, self.m do self.corners[k] = { passes = {}, count = 0 } end
  self.focus = nil
  self.fixed = {}
  self.parked = {}
  self.pushed = {}                   -- corner -> pass count when it was last pushed
  self.steadied = {}                 -- corner -> pass count until which it is left alone
  self.passTotal = 0
end

local function median(values)
  local sorted = {}
  for i, v in ipairs(values) do sorted[i] = v end
  table.sort(sorted)
  local count = #sorted
  if count == 0 then return nil end
  if count % 2 == 1 then return sorted[(count + 1) / 2] end
  return (sorted[count / 2] + sorted[count / 2 + 1]) / 2
end

-- Typical loss in corner k over its last few passes, its main cause, that
-- cause's latest value, and the typical loss as it stood at the corner exit.
function Lesson:_score(k)
  local cfg = self.cfg
  local passes = self.corners[k].passes
  local losses, exits, votes, latest = {}, {}, {}, {}
  for i = math.max(1, #passes - cfg.medianOf + 1), #passes do
    local p = passes[i]
    local loss = p.lossMs
    if p.id == 'offTrack' and loss < cfg.offTrackMs then loss = cfg.offTrackMs end
    losses[#losses + 1] = loss
    exits[#exits + 1] = p.exitMs
    if not NO_REMEDY[p.id] then
      votes[p.id] = (votes[p.id] or 0) + 1
      latest[p.id] = { order = i, value = p.value }
    end
  end
  local id, bestVotes, bestOrder
  for name, count in pairs(votes) do
    local order = latest[name].order
    if not bestVotes or count > bestVotes or (count == bestVotes and order > bestOrder) then
      id, bestVotes, bestOrder = name, count, order
    end
  end
  return median(losses) or 0, id, id and latest[id].value or nil, median(exits) or 0
end

-- Picks the next thing to work on: the corner with the biggest typical loss
-- that has a cause we can give an instruction for. Returns the focus or nil.
function Lesson:choose()
  local cfg = self.cfg
  local best
  for k = 1, self.m do
    local c = self.corners[k]
    local resting = self.parked[k] and c.count < self.parked[k]
    if #c.passes > 0 and not resting then
      local score, id, value, exitMs = self:_score(k)
      -- The coaching stage decides what comes first: a beginner's brake
      -- points and line before corner speed, and nothing advanced at all.
      local tier, weight = self.tier or 3, 1
      if id and tier == 1 and ADVANCED[id] then id, value = 'overSlow', nil end
      if id and ((tier == 1 and not FOUNDATION[id]) or (tier == 2 and ADVANCED[id])) then weight = cfg.tierWeight end
      if id and score >= cfg.minFocusMs and (not best or score * weight > best.weighted) then
        best = { k = k, id = id, value = value, firstId = id, baseMs = score, baseExitMs = exitMs,
          weighted = score * weight, tries = 0, streak = 0 }
      end
    end
  end
  if not best and (self.tier or 3) >= 2 then
    -- No big loss anywhere. Is there a corner that is driven differently
    -- every lap? Being repeatable comes before being faster.
    local worst
    for k = 1, self.m do
      local c = self.corners[k]
      local s = self:steadiness(k)
      if s and s.brakeM >= cfg.steadyBrakeM and c.count >= (self.steadied[k] or 0)
          and (not worst or s.brakeM > worst.value) then
        worst = { k = k, id = 'steady', firstId = 'steady', steady = true, value = s.brakeM,
          baseMs = 0, baseExitMs = 0, tries = 0, streak = 0 }
      end
    end
    best = worst
  end
  if not best and self.allowPush and (self.tier or 3) >= 3 then
    -- Nothing is being lost any more. The only way on is to go and find more
    -- grip, one corner at a time: the one not tried for longest, and among
    -- those the one that takes most time.
    local pick, pickAge, pickMs
    for k = 1, self.m do
      local c = self.corners[k]
      if #c.passes > 0 then
        local age = self.passTotal - (self.pushed[k] or -1e9)
        local ms = c.bestSegMs or 0
        if not pick or age > pickAge or (age == pickAge and ms > pickMs) then pick, pickAge, pickMs = k, age, ms end
      end
    end
    if pick then
      best = { k = pick, id = 'push', firstId = 'push', push = true, baseMs = 0, baseExitMs = 0, tries = 0, streak = 0 }
    end
  end
  self.focus = best
  return best
end

-- Records one pass through corner k, judged just past its exit.
--   res: from Coach.judge, detail: from Coach.detail
-- Returns a verdict:
--   { k =, nowMs =, prevMs =, kind = 'first' | 'better' | 'same' | 'worse',
--     focus = true when k is the corner being worked on; kind is then also
--     'good' (that was it) or 'parked' (given up for now, see .next) }
-- Whether a focus corner is finally sorted is decided by settle(), once the
-- whole segment has been driven: a slow exit only shows on the straight.
function Lesson:record(k, res, detail)
  local c = self.corners[k]
  if not c then return nil end
  local cfg = self.cfg
  local prev = c.passes[#c.passes]
  local loss = res.lossMs
  c.passes[#c.passes + 1] = {
    id = res.id, lossMs = loss, exitMs = loss, value = res.value, detail = detail, good = res.good == true,
  }
  if #c.passes > cfg.keepPasses then table.remove(c.passes, 1) end
  c.count = c.count + 1
  self.passTotal = self.passTotal + 1

  local verdict = { k = k, nowMs = loss, prevMs = prev and prev.exitMs or nil, kind = 'first' }
  if prev then
    local change = loss - prev.exitMs
    verdict.kind = (change <= -cfg.betterMs and 'better') or (change >= cfg.betterMs and 'worse') or 'same'
  end

  local f = self.focus
  if f and f.k == k and f.steady then
    -- Working on doing the same thing every lap.
    verdict.focus = true
    f.tries = f.tries + 1
    local s = self:steadiness(k)
    if s then f.value = s.brakeM end
    verdict.kind = 'steadyOn'
    local done = s and f.tries >= 2 and s.brakeM <= cfg.steadyBrakeM * cfg.steadyDoneFrac
    if done or f.tries >= cfg.steadyTries then
      verdict.kind = done and 'steadyDone' or 'parked'
      self.steadied[k] = c.count + cfg.parkPasses
      self.focus = nil
      verdict.next = self:choose()
    end
  elseif f and f.k == k and f.push then
    -- Looking for the limit: a couple of tries here, then on to another corner.
    verdict.focus = true
    f.tries = f.tries + 1
    verdict.kind = (res.id == 'gain') and 'pushGain' or 'pushed'
    if f.tries >= cfg.pushTries or res.id == 'offTrack' then
      self.pushed[k] = self.passTotal
      self.focus = nil
      verdict.next = self:choose()
    end
  elseif f and f.k == k then
    verdict.focus = true
    f.tries = f.tries + 1
    -- Only part of a loss shows by the exit, so the bar is set against what
    -- this corner typically showed there when it was picked.
    local share = math.min(1, f.baseExitMs / math.max(1, f.baseMs))
    local floor = math.max(cfg.masterFloorMs, cfg.masterMs * share)
    local good = res.id ~= 'offTrack' and loss <= math.max(floor, f.baseExitMs * cfg.masterFrac)
    f.judged, f.lastGood = true, good
    if good then
      f.streak = f.streak + 1
      f.everGood = true
      verdict.kind = 'good'
    else
      f.streak = 0
      if not NO_REMEDY[res.id] then f.id, f.value = res.id, res.value end   -- the cause may have moved on
    end
    if good then
      -- settle() has the last word
    elseif f.tries >= cfg.parkAfter then
      self.parked[k] = c.count + cfg.parkPasses
      self.focus = nil
      verdict.kind = 'parked'
      verdict.next = self:choose()
    end
  end
  return verdict
end

-- Called when the car leaves corner k's whole segment (mid-straight to
-- mid-straight): the loss over the full segment replaces the figure measured
-- at the exit, and a clean pass may set the best time for this piece of track.
-- For the focus corner this is also where "that was it" is confirmed or taken
-- back. Returns { kind = 'fixed', k =, fromMs =, toMs =, next = } when the
-- corner is sorted, else nil.
function Lesson:settle(k, segMs, lossMs, clean)
  local c = self.corners[k]
  if not c then return nil end
  local cfg = self.cfg
  local p = c.passes[#c.passes]
  if p and lossMs then p.lossMs = lossMs end
  if clean and segMs and segMs > 0 and (not c.bestSegMs or segMs < c.bestSegMs) then
    c.bestSegMs = segMs
  end
  local f = self.focus
  if not (f and f.k == k and not f.push and not f.steady and f.judged and lossMs) then return nil end
  f.judged = false
  if not f.lastGood then return nil end
  if not clean or lossMs > math.max(cfg.masterMs, f.baseMs * cfg.masterFrac) then
    f.streak = 0                    -- fine at the exit, but the time went on the way out
    if f.tries >= cfg.parkAfter then
      self.parked[k] = c.count + cfg.parkPasses
      self.focus = nil
      return { kind = 'parked', k = k, next = self:choose() }
    end
    return nil
  end
  if f.streak < cfg.masterStreak then return nil end
  self.fixed[#self.fixed + 1] = { k = k, id = f.firstId, fromMs = f.baseMs, toMs = lossMs }
  self.focus = nil
  return { kind = 'fixed', k = k, fromMs = f.baseMs, toMs = lossMs, next = self:choose() }
end

-- Called at the end of every lap. Returns what to tell the driver:
--   { focus =, changed = true if the focus is new, worstK =, worstMs = }
function Lesson:lapDone(timeMs, valid)
  self.lapCount = self.lapCount + 1
  if valid then
    self.validCount = self.validCount + 1
    self.cleanStreak = self.cleanStreak + 1
    self.lapTimes[#self.lapTimes + 1] = timeMs
    if #self.lapTimes > 30 then table.remove(self.lapTimes, 1) end
  else
    self.cleanStreak = 0
  end
  local changed = false
  if self.focus and self.focus.push then
    -- A real loss has appeared (the limit moved): it takes over from exploring.
    local push = self.focus
    self.allowPush, self.focus = false, nil
    local real = self:choose()
    self.allowPush = true
    if real then changed = true else self.focus = push end
  end
  if not self.focus then changed = self:choose() ~= nil end
  local worstK, worstMs
  for k = 1, self.m do
    local passes = self.corners[k].passes
    local p = passes[#passes]
    if p and (not worstMs or p.lossMs > worstMs) then worstK, worstMs = k, p.lossMs end
  end
  return { focus = self.focus, changed = changed, worstK = worstK, worstMs = worstMs }
end

-- How repeatable corner k is: how far the brake point moved over the last
-- few clean passes. Returns { brakeM =, passes = }, or nil with too few.
function Lesson:steadiness(k)
  local cfg = self.cfg
  local passes = self.corners[k].passes
  local lo, hi, used = math.huge, -math.huge, 0
  for i = math.max(1, #passes - cfg.steadyOf + 1), #passes do
    local d = passes[i].detail
    if d and not d.offTrack and d.brakeDiffM then
      used = used + 1
      if d.brakeDiffM < lo then lo = d.brakeDiffM end
      if d.brakeDiffM > hi then hi = d.brakeDiffM end
    end
  end
  if used < cfg.steadyOf then return nil end
  return { brakeM = hi - lo, passes = used }
end

-- How big a step to ask for when a brake point has to move: half the gap,
-- rounded to 5 m. Moving it all at once is how people end up in the gravel.
function Lesson.stepM(gapM, cfg)
  local step = math.floor((gapM or 0) * cfg.stepFrac / 5 + 0.5) * 5
  if step < cfg.stepMinM then step = cfg.stepMinM end
  if step > cfg.stepMaxM then step = cfg.stepMaxM end
  return step
end

-- Every corner driven so far, biggest typical loss first.
function Lesson:ranking()
  local rows = {}
  for k = 1, self.m do
    local c = self.corners[k]
    if #c.passes > 0 then
      local score, id, value = self:_score(k)
      local last = c.passes[#c.passes]
      local best
      for _, p in ipairs(c.passes) do
        if not best or p.lossMs < best then best = p.lossMs end
      end
      rows[#rows + 1] = {
        k = k, typicalMs = score, id = id, value = value, lastMs = last.lossMs, lastId = last.id,
        bestMs = best, passes = c.count, parked = self.parked[k] ~= nil and c.count < self.parked[k],
        steady = self:steadiness(k),
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.typicalMs ~= b.typicalMs then return a.typicalMs > b.typicalMs end
    return a.k < b.k
  end)
  return rows
end

-- The lap you have already driven in pieces: the best clean time through
-- every part of the track, added up. Returns ms, or nil until every part
-- has been driven cleanly at least once.
function Lesson:ideal()
  local total = 0
  for k = 1, self.m do
    local best = self.corners[k].bestSegMs
    if not best then return nil end
    total = total + best
  end
  if self.m == 0 then return nil end
  return total
end

-- Spread of the last few valid laps: { stdMs =, spreadMs =, laps = } or nil.
function Lesson:consistency(count)
  count = count or 5
  local times = self.lapTimes
  if #times < 3 then return nil end
  local from = math.max(1, #times - count + 1)
  local sum, lo, hi, used = 0, math.huge, -math.huge, 0
  for i = from, #times do
    sum, used = sum + times[i], used + 1
    if times[i] < lo then lo = times[i] end
    if times[i] > hi then hi = times[i] end
  end
  local mean, var = sum / used, 0
  for i = from, #times do var = var + (times[i] - mean) ^ 2 end
  return { stdMs = math.sqrt(var / used), spreadMs = hi - lo, laps = used }
end

-- The newest detail of every corner, for the scores and the training steps.
function Lesson:_details()
  local list = {}
  for k = 1, self.m do
    local passes = self.corners[k].passes
    local p = passes[#passes]
    if p and p.detail then list[#list + 1] = p.detail end
  end
  return list
end

local function score(x)
  if x < 0 then return 0 end
  if x > 100 then return 100 end
  return math.floor(x + 0.5)
end

-- Skill scores from 0 to 100, measured against the benchmark on the latest
-- pass through every corner. A score is nil until there is data for it.
function Lesson:skills()
  local cfg = self.cfg
  local sum = { brake = 0, speed = 0, throttle = 0, exit = 0, line = 0, hands = 0 }
  local cnt = { brake = 0, speed = 0, throttle = 0, exit = 0, line = 0, hands = 0 }
  local function add(name, value)
    sum[name], cnt[name] = sum[name] + value, cnt[name] + 1
  end
  for _, d in ipairs(self:_details()) do
    if not d.offTrack then
      if d.brakeDiffM then add('brake', math.abs(d.brakeDiffM)) end
      if d.minDiffKmh then add('speed', math.max(0, -d.minDiffKmh)) end
      if d.throttleDiffM then add('throttle', math.max(0, d.throttleDiffM)) end
      if d.exitDiffKmh then add('exit', math.max(0, d.exitDiffKmh)) end
      if d.wideM then add('line', math.abs(d.wideM)) end
      if d.reversalDiff then add('hands', math.max(0, d.reversalDiff)) end
    end
  end
  local out = {}
  if cnt.brake > 0 then out.braking = score(100 - cfg.brakePerM * sum.brake / cnt.brake) end
  if cnt.speed > 0 then out.speed = score(100 - cfg.speedPerKmh * sum.speed / cnt.speed) end
  if cnt.exit > 0 then
    local late = cnt.throttle > 0 and (sum.throttle / cnt.throttle) or 0
    out.exits = score(100 - cfg.throttlePerM * late - cfg.exitPerKmh * sum.exit / cnt.exit)
  end
  if cnt.line > 0 then out.line = score(100 - cfg.linePerM * sum.line / cnt.line) end
  if cnt.hands > 0 then out.hands = score(100 - cfg.handsPerExtra * sum.hands / cnt.hands) end
  local cons = self:consistency()
  if cons then out.consistency = score(100 - cfg.consistencyPerS * cons.stdMs / 1000) end
  return out
end

-- The training steps, in the order a beginner should take them. Each is
-- { id =, have =, need =, done = }. A step stays done once it was reached.
function Lesson:stages()
  local cfg = self.cfg
  local details = self:_details()
  local driven = #details
  local out = {}
  local function step(id, have, need, ready)
    if ready ~= false and need > 0 and have >= need then self.stageDone[id] = true end
    out[#out + 1] = { id = id, have = math.min(have, need), need = need, done = self.stageDone[id] == true }
  end

  step('clean', self.cleanStreak, cfg.cleanLaps)

  local braking, onPoint, fastEnough, goodExit = 0, 0, 0, 0
  for _, d in ipairs(details) do
    if d.braking then
      braking = braking + 1
      if not d.offTrack and d.brakeDiffM and math.abs(d.brakeDiffM) <= cfg.brakeWithinM then
        onPoint = onPoint + 1
      end
    end
    if not d.offTrack then
      if d.minDiffKmh and d.minDiffKmh >= -cfg.speedWithinKmh then fastEnough = fastEnough + 1 end
      if (d.throttleDiffM or 0) <= cfg.throttleWithinM and (d.exitDiffKmh or 0) <= cfg.exitWithinKmh then
        goodExit = goodExit + 1
      end
    end
  end
  local allDriven = driven >= self.m and self.m > 0
  step('braking', onPoint, math.max(1, math.ceil(braking * cfg.passShare)), allDriven and braking > 0)
  step('speed', fastEnough, math.max(1, math.ceil(self.m * cfg.passShare)), allDriven)
  step('exits', goodExit, math.max(1, math.ceil(self.m * cfg.passShare)), allDriven)

  -- How many of the newest laps sit within the allowed spread of each other.
  local times, run = self.lapTimes, 0
  local lo, hi = math.huge, -math.huge
  for i = #times, 1, -1 do
    lo, hi = math.min(lo, times[i]), math.max(hi, times[i])
    if hi - lo > cfg.consistentMs then break end
    run = run + 1
  end
  step('consistency', run, cfg.consistentLaps)
  return out
end

-- Which coaching stage a driver is at when there is no pace level to go by:
-- 1 until they can string clean laps together, 3 once brake points, corner
-- speed and exits are all in place, 2 in between.
function Lesson:stageTier()
  local done = {}
  for _, st in ipairs(self:stages()) do done[st.id] = st.done end
  if not done.clean then return 1 end
  if done.braking and done.speed and done.exits then return 3 end
  return 2
end

-- The first training step that is not done yet, or nil when all are.
function Lesson:stage()
  for _, st in ipairs(self:stages()) do
    if not st.done then return st end
  end
  return nil
end

-- One line of numbers for the progress history.
function Lesson:summary()
  local skills = self:skills()
  return {
    laps = self.lapCount, valid = self.validCount, ideal = self:ideal(), fixed = #self.fixed,
    braking = skills.braking, speed = skills.speed, exits = skills.exits, line = skills.line, hands = skills.hands,
    consistency = skills.consistency,
  }
end

return Lesson
