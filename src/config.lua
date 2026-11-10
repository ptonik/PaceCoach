-- Every tunable threshold lives here. Pure data, no game API.
-- These are starting values; they are meant to be tuned after real laps.

return {
  version = '0.6.0',

  grid = {
    cellM = 2,          -- target cell length along the track
    minCells = 1000,
    maxCells = 6000,
  },

  track = {
    headingBaseM = 4,     -- half-length of the chord used to measure heading
    smoothM = 6,          -- curvature moving-average window
    cornerRadiusM = 300,  -- anything tighter than this counts as "turning"
    minAngleDeg = 15,     -- total heading change needed to call it a corner
    mergeGapM = 15,       -- same-direction turns closer than this are one corner
    linkGapM = 40,        -- next corner starting within this distance is "linked"
    hairpinAngleDeg = 135,
    hairpinAngleRadiusM = 35,
    -- severity by minimum radius, first match wins
    severity = {
      { maxRadiusM = 20,        id = 'hairpin' },
      { maxRadiusM = 40,        id = 'tight' },
      { maxRadiusM = 80,        id = 'medium' },
      { maxRadiusM = 150,       id = 'fast' },
      { maxRadiusM = math.huge, id = 'kink' },
    },
  },

  grip = {
    latStartG = 0.9,      -- cautious lateral grip before anything is observed
    brakeStartG = 0.9,
    latMaxG = 3.5,
    brakeMaxG = 4.0,
    latUse = 0.92,        -- fraction of observed peak that is trusted
    brakeUse = 0.85,
    latSmoothS = 0.7,
    brakeSmoothS = 0.4,
    minSpeedKmh = 50,     -- ignore observations below this speed
    spikeG = 6,           -- raw readings above this are crashes, not grip
    changeRatio = 0.04,   -- re-plan when the estimate moves by more than this
    bandsKmh = { 80, 130, 180 },  -- speed bands (aero cars grip more when fast)
    vCapMs = 120,
  },

  pilot = {
    announceLeadS = 4.0,     -- call the corner this long before the brake point
    announceMinM = 60,       -- ...or at the latest this far from turn-in
    reactionS = 0.3,         -- driver reaction time added to the brake cue
    minBrakeDropKmh = 15,    -- smaller speed drops are a "lift", not "brake"
    minLiftDropKmh = 5,
    cueHoldS = 1.0,
    brakeBarM = 200,         -- distance covered by the on-screen countdown bar
    minActiveKmh = 20,       -- below this the co-driver stays quiet
    throttleLowGas = 0.3,    -- "throttle" is only cued if you are below this
    -- Staying with the driver: the next corner is not called while you are
    -- still finishing this one or sorting out a mistake...
    exitHoldM = 15,          -- "finishing" lasts until this far past the corner's end
    urgentS = 1.5,           -- ...unless braking or turn-in is this close
    busySlideDeg = 20,       -- sliding more than this counts as being busy
    busyAfterMistakeS = 1.2, -- quiet time after a lock-up, slide or excursion
    recoverS = 1.0,          -- back under control for this long: call the corner again
    reCueS = 0.8,            -- second "brake" if you pass the benchmark's point unbraked
    brakingOn = 0.1,         -- already on the brake pedal: no need to say "brake"
    liftedGas = 0.2,         -- already off the throttle: no need to say "lift"
    maxBrakeCues = 2,        -- "brake" is said at most this often for one corner
    brakeCueGapS = 1.5,      -- ...and not twice within this time
  },

  -- Measuring a corner (used for the benchmark's targets and for your pass).
  metrics = {
    minSearchPadM = 20,      -- the slowest point may come this far before turn-in
    trailPadM = 15,          -- braking may carry on this far past the slowest point
    brakeOn = 0.1,
    brakeGapCells = 3,       -- a gap this short does not split a braking zone
    gasOn = 0.2,
    gasFull = 0.95,
    liftDrop = 0.25,         -- a throttle drop this big counts as a lift
    exitPadM = 40,
    pedalOff = 0.05,
    coastMinKmh = 40,
  },

  -- Building the braking curve and targets from a benchmark lap.
  targets = {
    fullGas = 0.9,           -- above this (and off the brake) the benchmark is flat out
    brakeOn = 0.05,
    minZoneM = 20,           -- shorter lifts (gear changes) are ignored
    brakeUse = 0.9,          -- fraction of the benchmark's braking you are asked for
    fallbackBrakeG = 0.9,
    minBrakeG = 0.5,
    maxBrakeG = 4.0,
    vCapMs = 120,
  },

  -- Post-corner feedback against the benchmark.
  coach = {
    gainMs = -50,            -- faster than the benchmark by this much: praise
    minLossMs = 80,          -- smaller losses are "fine"
    brakeEarlyM = 10,
    brakeLateM = 10,
    minSlowKmh = 4,
    throttleLateM = 10,
    coastM = 15,
    lineM = 2,
    exitSlowKmh = 5,
    trailMinM = 5,           -- the benchmark keeps braking at least this far into the corner
    trailShortM = 12,        -- ...and you were off the brake this much sooner
    vagueMs = 200,           -- a small loss with no clear cause is not worth a note
    showS = 4.5,
  },

  -- Live coaching: what is said WHILE you drive a corner, against the benchmark.
  live = {
    minKmh = 45,             -- below this the coach says nothing
    gapS = 1.1,              -- quiet time between two live cues
    showS = 1.7,             -- how long a cue stays on the card
    maxPerCorner = 3,        -- live cues per corner, at most (2 on the beginner HUD)
    -- "Brake harder": braking, but not enough to make the corner at the benchmark's speed.
    brakingOn = 0.1,
    hardBrake = 0.85,        -- already braking this hard: nothing more to ask for
    harderRatio = 1.15,      -- needs this much more deceleration than the benchmark did here
    harderMinG = 0.4,
    harderKmh = 4,
    harderHoldS = 0.25,
    minRoomM = 15,           -- no braking advice this close to the slowest point
    -- "Ease off the brake": still braking although already well under the benchmark's speed.
    easeBrake = 0.25,
    easeKmh = 8,
    easeFrac = 0.08,
    easeHoldS = 0.3,
    -- "Too early": braking long before the benchmark's brake point.
    earlyBrake = 0.3,
    earlyM = 25,
    earlyS = 0.7,
    earlyHoldS = 0.25,
    -- "No brake here": braking for a corner the benchmark only lifts for.
    noBrakeAheadM = 80,
    noBrakeHoldS = 0.2,
    -- "Wait": on the throttle mid-corner, well before the benchmark.
    waitGas = 0.6,
    waitRefGas = 0.2,
    waitAheadM = 10,
    waitSlackKmh = 5,        -- only if you are not much slower than the benchmark
    waitHoldS = 0.3,
    -- "Full throttle" / "Stay on the throttle": the benchmark is flat out here and you are not.
    flatRefGas = 0.9,
    flatBehindM = 15,
    flatAheadM = 60,
    liftGas = 0.3,
    partGas = 0.8,
    liftHoldS = 0.5,
    partHoldS = 0.9,
    exitRegionM = 140,
    -- "Move left / right": off the benchmark's line on the way to a corner.
    lineM = 2.5,
    lineAheadM = 150,
    lineAfterExitM = 40,
    lineBeforeTurnM = 10,
    lineHoldS = 0.6,
    -- "Turn in": spoken as you reach the benchmark's turn-in point.
    turnLeadS = 0.25,
    turnFrac = 0.3,          -- turn-in is where the benchmark's steering reaches this share of its peak
    minSteerDeg = 8,         -- a benchmark with less steering than this has no usable steering trace
    turnPadM = 40,
  },

  -- The lesson plan: one corner and one fix at a time, across laps.
  lesson = {
    keepPasses = 6,          -- passes remembered per corner
    medianOf = 3,
    minFocusMs = 120,        -- smaller losses are not worth a lesson
    offTrackMs = 600,        -- an off counts at least this much
    masterMs = 100,          -- fixed when the loss is under this...
    masterFrac = 0.4,        -- ...or under this share of what it was
    masterStreak = 2,        -- ...this many times in a row
    masterFloorMs = 30,      -- the least that counts as "under" when judged at the exit
    parkAfter = 5,           -- no progress after this many tries: move on, come back later
    parkPasses = 4,
    pushTries = 2,           -- passes spent looking for the limit in one corner before moving on
    steadyOf = 3,            -- passes looked at when judging how repeatable a corner is
    steadyBrakeM = 15,       -- a brake point that moves more than this is worth a lesson
    steadyDoneFrac = 0.6,    -- ...until it moves less than this share of that
    steadyTries = 4,
    betterMs = 80,
    stepFrac = 0.5,          -- ask for half the gap at a time
    stepMinM = 5,
    stepMaxM = 25,
    praiseGapS = 12,
    -- Skill scores, 0..100.
    brakePerM = 2.5,
    speedPerKmh = 5,
    throttlePerM = 2.5,
    exitPerKmh = 2.5,
    linePerM = 20,
    consistencyPerS = 50,
    -- Training steps.
    cleanLaps = 3,
    brakeWithinM = 15,
    speedWithinKmh = 5,
    throttleWithinM = 10,
    exitWithinKmh = 5,
    passShare = 0.7,
    consistentLaps = 3,
    consistentMs = 500,
    historyKeep = 40,
  },

  -- The limit lap: the benchmark once the teacher has been beaten.
  limit = {
    latPct = 0.9,            -- share of a lap's cornering that sets "the grip it showed"
    brakePct = 0.9,
    accelPct = 0.8,
    accelBinKmh = 20,
    maxKmh = 400,
    minRadiusM = 300,
    minKmh = 40,
    minLatG = 0.5,
    minBrakeG = 0.5,
    fallbackAccelG = 0.3,
    maxSpeedup = 0.08,       -- never ask for more than this over what was really driven
    steadyM = 24,            -- cornering only counts once it has lasted this long
    bandRise = 1.35,         -- grip may not jump by more than this from one speed range to the next
    vCapMs = 120,
    -- Pace levels: best lap as a share of the limit lap.
    levels = {
      { id = 'rookie', within = math.huge },
      { id = 'novice', within = 1.10 },
      { id = 'club', within = 1.06 },
      { id = 'front', within = 1.03 },
      { id = 'expert', within = 1.015 },
      { id = 'limit', within = 1.005 },
    },
  },

  -- Updates from GitHub.
  update = {
    base = 'https://raw.githubusercontent.com/ptonik/PaceCoach/main/',
    manifest = 'update.txt',
    page = 'https://github.com/ptonik/PaceCoach',
    checkAfterS = 5,         -- seconds after start-up before looking for a new version
    maxFiles = 200,
    maxBytes = 20 * 1024 * 1024,
  },

  teacher = {
    maxCars = 8,             -- other cars watched at once
    improveMs = 100,         -- a new teacher lap must be at least this much faster
    refreshS = 10,           -- how often the list of watched cars is rebuilt
  },

  line3d = {
    aheadM = 260,
    stepCells = 2,
    halfWidthM = 0.22,
    liftM = 0.06,            -- drawn this far above the road
    gateDepthM = 0.7,
    defaultHalfTrackM = 5,
  },

  lap = {
    maxWheelsOut = 2,        -- more wheels than this off track invalidates the lap
    minCoverage = 0.985,
    minLapMs = 20000,
    jumpFraction = 0.05,     -- moving further than this in one frame is a teleport
    officialToleranceMs = 1500,
  },

  mistakes = {
    cooldownS = 8,
    quietAfterSpinS = 4,
    lockup = { brake = 0.5, minKmh = 40, slipRatio = -0.25, holdS = 0.15 },
    abs = { brake = 0.8, holdS = 2.5, cooldownS = 45 },
    wheelspin = { gas = 0.5, minKmh = 15, slipRatio = 0.2, holdS = 0.3 },
    understeer = { minKmh = 50, frontDeg = 9, diffDeg = 3.5, holdS = 0.5 },
    oversteer = { minKmh = 40, rearDeg = 10, diffDeg = 4, holdS = 0.3 },
    spin = { minKmh = 25, angleDeg = 50, holdS = 0.1 },
    offtrack = { wheels = 3, holdS = 0.25 },
    coast = { minKmh = 60, pedal = 0.05, distM = 50 },
    sawing = { minKmh = 60, ampDeg = 12, windowS = 2.5, count = 5 },
  },

  hud = {
    tipShowS = 6,
    repeatS = 20,          -- the same tip is not shown again sooner than this
  },
}
