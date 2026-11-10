-- All text shown on screen. Pure data.

return {
  severity = {
    hairpin = 'HAIRPIN',
    tight = 'TIGHT',
    medium = 'MEDIUM',
    fast = 'FAST',
    kink = 'KINK',
  },
  severityLower = {
    hairpin = 'hairpin',
    tight = 'tight',
    medium = 'medium',
    fast = 'fast',
    kink = 'kink',
  },
  dir = { left = 'LEFT', right = 'RIGHT' },
  dirLower = { left = 'left', right = 'right' },

  cue = { brake = 'BRAKE', lift = 'LIFT', throttle = 'THROTTLE' },

  gears = { 'R', 'N', '1st', '2nd', '3rd', '4th', '5th', '6th', '7th', '8th', '9th' },

  benchmark = { teacher = 'teacher', friend = 'friend', you = 'your best', own = 'your best' },

  -- Post-corner feedback. %d is filled with metres or speed.
  coach = {
    gain = 'Faster than the benchmark here.',
    offTrack = 'Off the track. Brake a little earlier and get it clean first.',
    brakeEarly = 'Braking %d m too early.',
    brakeLate = 'Braked %d m too late and missed the corner.',
    noBrake = 'No brake needed here: a lift is enough.',
    overSlow = 'Too slow mid-corner: %s under the target. Come off the brake sooner.',
    gasLift = 'On the throttle too early: you had to lift again.',
    throttleLate = 'Back on the throttle %d m late.',
    coast = '%d m of coasting. Brake later, or get back on the power.',
    wide = '%d m wide of the line at the apex.',
    exitSlow = 'Slow exit: %s down. Straighten the wheel and squeeze the throttle.',
    slower = 'Slower through here, with no single cause.',
  },

  -- Who the live coach compares you with, as it reads in a sentence.
  who = { teacher = 'the teacher', friend = 'your friend', you = 'your best lap', own = 'your best lap' },

  -- Live coaching: the word on the card, the clip that is spoken, the colour
  -- of the card and a one-line reason. %s is filled from `who`.
  live = {
    brakeHarder = { text = 'BRAKE HARDER', clip = 'brake_harder', tone = 'brake',
      hint = 'More speed than %s had here.' },
    easeOff = { text = 'EASE OFF', clip = 'ease_off', tone = 'lift',
      hint = 'Already slower than %s here: release.' },
    tooEarly = { text = 'TOO EARLY', clip = 'too_early', tone = 'lift',
      hint = 'Braking comes later here. Wait for the call.' },
    noBrake = { text = 'NO BRAKE', clip = 'tip_lift', tone = 'lift',
      hint = 'A lift off the throttle is enough here.' },
    turnIn = { text = 'TURN IN', clip = 'turn_in', tone = 'info', hint = '' },
    wait = { text = 'WAIT', clip = 'wait', tone = 'lift',
      hint = 'Not yet: wait until the car is turned.' },
    fullThrottle = { text = 'FULL THROTTLE', clip = 'full_throttle', tone = 'throttle',
      hint = 'The exit is open: all the way down.' },
    stayFlat = { text = 'STAY FLAT', clip = 'stay_flat', tone = 'throttle',
      hint = 'Keep it flat until the brake call.' },
    moveLeft = { text = 'MOVE LEFT', clip = 'move_left', tone = 'info',
      hint = 'The line for this corner is further left.' },
    moveRight = { text = 'MOVE RIGHT', clip = 'move_right', tone = 'info',
      hint = 'The line for this corner is further right.' },
  },

  -- The lesson plan: the instruction for the next attempt at a corner.
  -- %d is a distance in metres where there is one.
  remedy = {
    brakeEarly = { text = 'Brake about %d m later.', short = 'brake later', clip = 'tip_brake_later', step = true },
    brakeLate = { text = 'Brake about %d m earlier.', short = 'brake earlier', clip = 'tip_brake_earlier', step = true },
    offTrack = { text = 'Keep it on the track: brake a little earlier.', short = 'brake earlier', clip = 'tip_brake_earlier' },
    noBrake = { text = 'No brake here: just lift off the throttle.', short = 'just lift', clip = 'tip_lift' },
    overSlow = { text = 'Carry more speed: come off the brake sooner.', short = 'carry more speed', clip = 'tip_more_speed' },
    gasLift = { text = 'Wait for the exit, then one smooth squeeze of throttle.', short = 'be patient with the throttle', clip = 'tip_patience' },
    throttleLate = { text = 'Get back on the throttle sooner.', short = 'earlier on the throttle', clip = 'tip_throttle_earlier' },
    coast = { text = 'No coasting: brake later, then straight back to the throttle.', short = 'no coasting', clip = 'tip_no_coast' },
    wide = { text = 'Get closer to the inside at the apex.', short = 'hit the apex', clip = 'tip_apex' },
    exitSlow = { text = 'Straighten the wheel and use full throttle on the way out.', short = 'full throttle on the exit', clip = 'tip_exit' },
  },

  lesson = {
    focus = 'FOCUS',
    focusTitle = 'Focus corner',
    none = 'No focus corner yet. Drive a lap or two and the coach picks one.',
    noBenchmark = 'The lesson plan needs something to compare you with: a teacher lap, or one clean lap of your own.',
    better = 'Better. Now do it again.',
    good = 'That is it. Now make it stick.',
    sorted = '%s sorted',
    fixed = 'Sorted. Well done.',
    parked = 'This one is stubborn. Leave it for now and come back to it.',
    worse = 'Not this time. Same plan next lap.',
    same = 'About the same. Same plan next lap.',
    nextUp = 'Next: %s, %s.',
    lapWorst = 'Biggest loss: %s, %s s.',
    lapFocus = 'Next lap, %s: %s',
    lapKeep = 'Keep working on %s: %s',
    lapClean = 'No big losses left. String clean laps together.',
    ideal = 'Ideal lap',
    idealWhy = 'the best you have driven through every part of the track, added up',
  },

  skills = {
    order = { 'braking', 'speed', 'exits', 'line', 'consistency' },
    braking = 'Braking points',
    speed = 'Corner speed',
    exits = 'Exits',
    line = 'Line',
    consistency = 'Consistency',
  },

  -- Training steps: a name and a progress line (%d of %d).
  stage = {
    clean = { name = 'Stay on the track', line = '%d of %d clean laps in a row' },
    braking = { name = 'Brake at the right place', line = '%d of %d brake points within 15 m' },
    speed = { name = 'Carry the speed', line = '%d of %d corners within 5 km/h of the target' },
    exits = { name = 'Get on the power', line = '%d of %d exits on time and up to speed' },
    consistency = { name = 'Be consistent', line = '%d of %d laps within half a second' },
  },

  update = {
    off = 'Checking for updates is switched off.',
    idle = 'Not checked yet.',
    checking = 'Looking for a new version...',
    current = 'You have the latest version.',
    available = 'Version %s is available.',
    downloading = 'Downloading %d of %d...',
    ready = 'Downloaded. It installs as soon as the car is standing still.',
    writing = 'Installing...',
    done = 'Version %s is installed. It is used from the next time you start the game.',
    failed = 'Update failed: %s',
    noWeb = 'This CSP build cannot download files. Update by hand from GitHub.',
    toast = 'PaceCoach %s is available',
    toastBody = 'Open PaceCoach Panel, Settings tab, and press Update now.',
    doneToast = 'PaceCoach %s installed',
    doneBody = 'It is used from the next time you start the game.',
  },

  status = {
    loading = 'Reading the track...',
    noLine = 'This track has no ideal line. Corner callouts are unavailable here.',
    noCorners = 'No corners found on this track.',
    incompatible = 'This CSP version is missing something PaceCoach needs. Open the Panel, Diagnostics tab.',
    error = 'PaceCoach hit an error. Open the Panel, Diagnostics tab.',
    estimate = 'est.',
    now = 'NOW',
    exit = 'EXIT',
    thenWord = 'then',
    newBest = 'New best lap',
    firstBest = 'Reference lap saved',
    teacherReady = 'Teacher lap recorded',
    teacherBody = 'Brake points, gears and corner speeds now come from this lap.',
    teacherDerived = ' Its pedals were worked out from its speed, because the game did not provide them.',
    teacherBeaten = 'You beat the teacher. Your own best lap is now the benchmark.',
  },

  -- Mistakes: a short title and a plain-language "why and what to do".
  tips = {
    spin = {
      title = 'Spin',
      why = 'The rear overtook the front. It usually starts with too much speed or a sudden input. Next time through, brake a little earlier and be gentle with your feet.',
    },
    offtrack = {
      title = 'Off track',
      why = 'Nearly always caused by arriving too fast. Brake earlier here next lap, make the corner cleanly, then add speed back a little at a time.',
    },
    lockup = {
      title = 'Locked brakes',
      why = 'A locked tyre slides instead of gripping, so you stop later and cannot steer. Press a little less hard, and ease off the pedal as the car slows.',
    },
    abs = {
      title = 'ABS working hard',
      why = 'You are asking for more braking than the tyres can give. Aim for firm pressure just below the point where ABS starts to pulse.',
    },
    wheelspin = {
      title = 'Wheelspin on exit',
      why = 'Too much throttle for the grip available. Squeeze the pedal in gradually as you straighten the wheel.',
    },
    understeer = {
      title = 'Understeer: the front is sliding',
      why = 'You arrived too fast or turned too hard. More steering will not help. Slow a touch more before turning, and unwind the wheel until the front grips again.',
    },
    oversteer = {
      title = 'The rear is stepping out',
      why = 'The back tyres lost grip. Come off the brake more smoothly and be gentler with the throttle. Steer into the slide early and calmly.',
    },
    coast = {
      title = 'Coasting',
      why = 'The car is neither slowing nor accelerating, so time is slipping away. Brake a little later and stay on the brake until you turn in, then go back to the throttle.',
    },
    sawing = {
      title = 'Busy hands',
      why = 'Lots of small steering corrections unsettle the car. Try one smooth turn in, hold it, and one smooth unwind.',
    },
  },
}
