-- Small helpers. Pure Lua only: this file must run unchanged outside the game.

local U = {}

function U.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function U.lerp(a, b, t)
  return a + (b - a) * t
end

function U.round(x)
  return math.floor(x + 0.5)
end

-- Wraps an angle in radians to (-pi, pi].
function U.wrapAngle(a)
  local twoPi = 2 * math.pi
  a = a % twoPi
  if a > math.pi then a = a - twoPi end
  return a
end

-- 1-based circular index.
function U.wrapIndex(i, n)
  return ((i - 1) % n) + 1
end

-- Forward distance in cells from a to b on a loop of n cells (0 .. n-1).
function U.forward(a, b, n)
  return (b - a) % n
end

-- Splits text into lines of at most maxChars characters, breaking at spaces.
function U.wrapText(text, maxChars)
  local lines, line = {}, ''
  for word in tostring(text):gmatch('%S+') do
    if line == '' then
      line = word
    elseif #line + 1 + #word <= maxChars then
      line = line .. ' ' .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if line ~= '' then lines[#lines + 1] = line end
  return lines
end

-- 83456 -> "1:23.456"
function U.formatLap(ms)
  if not ms or ms <= 0 then return '-:--.---' end
  ms = U.round(ms)
  local minutes = math.floor(ms / 60000)
  local seconds = (ms - minutes * 60000) / 1000
  return string.format('%d:%06.3f', minutes, seconds)
end

-- 420 -> "+0.42", -1234 -> "-1.23"
function U.formatDelta(ms)
  if not ms then return '' end
  local s = ms / 1000
  if s >= 0 then return string.format('+%.2f', s) end
  return string.format('-%.2f', -s)
end

-- Makes a string safe to use as a file name.
function U.safeName(s)
  return (tostring(s or 'unknown'):gsub('[^%w%-_]', '_'))
end

return U
