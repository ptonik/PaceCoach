-- The lead car. At a track day the instructor drives ahead and you follow
-- their line and their brake lights. This works out where that car is: the
-- benchmark lap, a fixed time ahead of wherever you are now. It is tied to
-- your position, so it never drives away; it shows what the benchmark does
-- in the next second or so. Pure logic: standard Lua only.

local Ghost = {}

-- lap: the benchmark lap, cell: the driver's cell (1..n), leadS: seconds ahead.
-- Returns the ghost's cell (1..n) and whether it is braking there, or nil.
function Ghost.locate(lap, cell, leadS)
  local n, t = lap.n, lap.t
  local lapMs = lap.timeMs
  if not (lapMs and lapMs > 0 and t[cell]) then return nil end
  local want = t[cell] + leadS * 1000
  local wrapped = want >= lapMs
  if wrapped then want = want - lapMs end
  -- Time rises with the cell index: find the last cell reached by then.
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if t[mid] <= want then lo = mid else hi = mid - 1 end
  end
  if not wrapped and lo < cell then lo = cell end       -- never behind the driver
  return lo, (lap.brake[lo] or 0) > 0.1
end

-- Position and direction of travel at a cell of the lap.
-- Returns x, z, fx, fz (unit vector), or nil where the lap does not move.
function Ghost.pose(lap, cell)
  local n = lap.n
  local a, b = ((cell - 2) % n) + 1, (cell % n) + 1
  local dx, dz = lap.x[b] - lap.x[a], lap.z[b] - lap.z[a]
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-6 then return nil end
  return lap.x[cell], lap.z[cell], dx / len, dz / len
end

return Ghost
