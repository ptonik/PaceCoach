-- The teacher: watches other cars of the same model (usually AI opponents),
-- records their laps, and keeps the fastest clean one as the benchmark.
-- Pure logic: no game API, standard Lua only.

local Recorder = require('src/recorder')

local Teacher = {}
Teacher.__index = Teacher

-- n: grid size, lapCfg = config.lap, cfg = config.teacher
function Teacher.new(n, lapCfg, cfg)
  local self = setmetatable({}, Teacher)
  self.n, self.lapCfg, self.cfg = n, lapCfg, cfg
  self.cars = {}
  self.count = 0
  self.lapsSeen = 0
  self.best = nil
  return self
end

-- Feeds one frame of one watched car.
-- s: a recorder sample plus { inPit = bool, wheelsOut = number }
-- Returns a lap when this car has just set a new fastest clean lap.
function Teacher:feed(key, s)
  local car = self.cars[key]
  if not car then
    if self.count >= self.cfg.maxCars then return nil end
    car = { rec = Recorder.new(self.n, self.lapCfg) }
    self.cars[key] = car
    self.count = self.count + 1
  end
  local done = car.rec:feed(s)
  if s.inPit then
    car.rec:invalidate('pit')
  elseif (s.wheelsOut or 0) > self.lapCfg.maxWheelsOut then
    car.rec:invalidate('offtrack')
  end
  if done and done.valid then
    self.lapsSeen = self.lapsSeen + 1
    if not self.best or done.timeMs < self.best.timeMs - self.cfg.improveMs then
      done.source = 'ai'
      self.best = done
      return done
    end
  end
  return nil
end

-- Forget a car (it left, or the session restarted).
function Teacher:reset()
  self.cars, self.count = {}, 0
end

-- Picks the benchmark for the brake cue and the corner targets.
--   teacher: lap recorded from another car, or nil
--   import:  lap from a file a friend sent, or nil
--   own:     the player's best lap, or nil
-- Returns lap, label ('teacher' | 'friend' | 'you'), or nil when only the
-- player's own lap exists: a beginner's own lap is not a good guide for where
-- to brake, so the cautious track-shape estimate stays in charge until there
-- is something better.
function Teacher.choose(teacher, import, own, importLabel)
  local lap, label
  if teacher then lap, label = teacher, 'teacher' end
  if import and (not lap or import.timeMs < lap.timeMs) then lap, label = import, importLabel or 'friend' end
  if lap and own and own.timeMs < lap.timeMs then return own, 'you' end
  return lap, label
end

return Teacher
