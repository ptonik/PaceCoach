-- Compares one pass through a corner with the benchmark and picks the single
-- most useful thing to say about it. Pure logic: no game API, standard Lua.
--
-- Causes are checked in the order they happen in a corner, because an early
-- mistake causes the later ones: a braking error comes before a slow apex,
-- which comes before a late throttle.

local Coach = {}

-- ref, got: results of Metrics.measure for the benchmark and for this pass.
-- extra: { wideM = metres outside the benchmark line at the slowest point,
--          offTrack = bool }
-- cfg = config.coach
-- Returns { lossMs =, id =, value =, good = bool }.
-- ids: gain, ok, offTrack, brakeLate, brakeEarly, noBrake, noTrail, overSlow,
--      gasLift, throttleLate, coast, wide, exitSlow, slower
function Coach.judge(ref, got, extra, cfg)
  extra = extra or {}
  local loss = got.timeMs - ref.timeMs
  local res = { lossMs = loss, good = false }

  if extra.offTrack then
    res.id = 'offTrack'
    return res
  end
  if loss <= cfg.gainMs then
    res.id, res.good = 'gain', true
    return res
  end
  if loss < cfg.minLossMs then
    res.id, res.good = 'ok', true
    return res
  end

  local minDiff = got.minKmh - ref.minKmh                      -- negative: slower
  local brakeDiff                                              -- positive: braked earlier
  if ref.brakeRelM and got.brakeRelM then brakeDiff = ref.brakeRelM - got.brakeRelM end

  if not ref.brakeRelM and got.brakeRelM and got.peakBrake > 0.3 then
    res.id = 'noBrake'
  elseif brakeDiff and brakeDiff <= -cfg.brakeLateM and minDiff <= -cfg.minSlowKmh then
    res.id, res.value = 'brakeLate', -brakeDiff
  elseif brakeDiff and brakeDiff >= cfg.brakeEarlyM then
    res.id, res.value = 'brakeEarly', brakeDiff
  elseif ref.brakeEndRelM and got.brakeEndRelM and ref.brakeEndRelM >= cfg.trailMinM
      and ref.brakeEndRelM - got.brakeEndRelM >= cfg.trailShortM and minDiff <= -cfg.minSlowKmh then
    -- The benchmark carries the brake into the corner; this pass let go early.
    res.id, res.value = 'noTrail', ref.brakeEndRelM - got.brakeEndRelM
  elseif minDiff <= -cfg.minSlowKmh then
    res.id, res.value = 'overSlow', -minDiff
  elseif got.lifts > ref.lifts then
    res.id = 'gasLift'
  elseif ref.throttleRelM and got.throttleRelM
      and got.throttleRelM - ref.throttleRelM >= cfg.throttleLateM then
    res.id, res.value = 'throttleLate', got.throttleRelM - ref.throttleRelM
  elseif got.coastM - ref.coastM >= cfg.coastM then
    res.id, res.value = 'coast', got.coastM - ref.coastM
  elseif extra.wideM and extra.wideM >= cfg.lineM then
    res.id, res.value = 'wide', extra.wideM
  elseif ref.exitKmh - got.exitKmh >= cfg.exitSlowKmh then
    res.id, res.value = 'exitSlow', ref.exitKmh - got.exitKmh
  else
    res.id = 'slower'
  end
  return res
end

-- The same comparison as plain numbers, for the lesson plan and the skill
-- scores. A field is nil when it cannot be measured in this corner.
--   brakeDiffM     positive: braked earlier than the benchmark
--   minDiffKmh     negative: slower at the slowest point
--   throttleDiffM  positive: back on the throttle later
--   exitDiffKmh    positive: slower at the exit
function Coach.detail(ref, got, extra)
  extra = extra or {}
  local d = {
    lossMs = got.timeMs - ref.timeMs,
    braking = ref.brakeRelM ~= nil,
    minDiffKmh = got.minKmh - ref.minKmh,
    exitDiffKmh = ref.exitKmh - got.exitKmh,
    wideM = extra.wideM,
    offTrack = extra.offTrack == true,
  }
  if ref.brakeRelM and got.brakeRelM then d.brakeDiffM = ref.brakeRelM - got.brakeRelM end
  if ref.throttleRelM and got.throttleRelM then d.throttleDiffM = got.throttleRelM - ref.throttleRelM end
  return d
end

return Coach
