-- Every tunable threshold lives here. Pure data, no game API.
-- These are starting values; they are meant to be tuned after real laps.

return {
  version = '0.2.0',

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
    showS = 4.5,
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
