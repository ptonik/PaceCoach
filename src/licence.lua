-- The licence ladder: a plain list of what a driver has to show, in order,
-- to go from never having driven the track to being ready for a long race.
-- Each grade asks for pace AND for the ability to repeat it cleanly, because
-- that is what racing asks for. Pure logic: standard Lua only.

local Licence = {}

-- stats = {
--   cleanStreak   most clean laps in a row
--   windowStreak  most laps in a row within the window of the best lap
--   paceRatio     best lap / limit lap (nil when there is nothing to measure against)
--   stepsDone     how many of the five training steps are done
-- }
-- grades: config.licence.grades, lowest first. Each grade lists the minimums
-- to hold it: { id =, clean =, window =, pace =, steps = }.
-- Returns { index =, id =, next = { id =, reqs = { { key =, have =, need =, done = } } } }.
function Licence.evaluate(stats, grades)
  local function reqs(g)
    local list, all = {}, true
    local function add(key, have, need, done)
      list[#list + 1] = { key = key, have = have, need = need, done = done }
      if not done then all = false end
    end
    if g.clean then add('clean', stats.cleanStreak or 0, g.clean, (stats.cleanStreak or 0) >= g.clean) end
    if g.steps then add('steps', stats.stepsDone or 0, g.steps, (stats.stepsDone or 0) >= g.steps) end
    if g.pace then add('pace', stats.paceRatio, g.pace, stats.paceRatio ~= nil and stats.paceRatio <= g.pace) end
    if g.window then add('window', stats.windowStreak or 0, g.window, (stats.windowStreak or 0) >= g.window) end
    return list, all
  end
  local index = 1
  for i = 2, #grades do
    local _, ok = reqs(grades[i])
    if not ok then break end
    index = i
  end
  local out = { index = index, id = grades[index].id }
  if grades[index + 1] then
    out.next = { id = grades[index + 1].id, reqs = (reqs(grades[index + 1])) }
  end
  return out
end

return Licence
