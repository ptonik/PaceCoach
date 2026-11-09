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

  status = {
    loading = 'Reading the track...',
    noLine = 'This track has no ideal line. Corner callouts are unavailable here.',
    noCorners = 'No corners found on this track.',
    incompatible = 'This CSP version is missing something PaceCoach needs. Open the Panel, Diagnostics tab.',
    error = 'PaceCoach hit an error. Open the Panel, Diagnostics tab.',
    estimate = 'est.',
    now = 'NOW',
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
