-- The driving HUD: the co-driver card, the brake countdown, and one tip at a time.
-- Everything is laid out for a 460 px wide window and scales with its width.

local G = require('src/gfx')
local S = require('src/strings')
local U = require('src/util')
local config = require('src/config')

local Hud = {}
local C = G.colors

local function wrap(text, size, widthPx)
  return U.wrapText(text, math.max(12, math.floor(widthPx / (size * 0.52))))
end

local function statusCard(text, W, s)
  local size = 16 * s
  local lines = wrap(text, size, W - 28 * s)
  local h = (20 + #lines * 21) * s
  G.rect(0, 0, W, h, C.cardBg, 10 * s)
  for i, line in ipairs(lines) do
    G.text(line, size, 14 * s, (10 + (i - 1) * 21) * s, C.white)
  end
  return h + 6 * s
end

local function distanceText(m)
  if m >= 100 then return string.format('%d m', U.round(m / 10) * 10) end
  return string.format('%d m', U.round(m / 5) * 5)
end

local function speedText(kmh, mph)
  if mph then return string.format('%d mph', U.round(kmh * 0.621371)) end
  return string.format('%d km/h', U.round(kmh))
end
Hud.speedText = speedText

local function gearText(gear)
  return S.gears[(tonumber(gear) or 0) + 2] or tostring(gear)
end
Hud.gearText = gearText

local function cornerWords(c)
  return S.severityLower[c.severity] .. ' ' .. S.dirLower[c.dir]
end

local CUE_BG = { brake = C.brakeBg, lift = C.liftBg, throttle = C.goodBg }

local function cornerCard(app, W, s)
  local card = app.card
  local c = card.corner
  local h = 108 * s
  G.rect(0, 0, W, h, card.cue and CUE_BG[card.cue] or C.cardBg, 10 * s)

  local sevColor = G.severityColor[c.severity] or C.white
  G.cornerArrow(10 * s, 8 * s, 78 * s, c.dir, c.severity, card.cue and C.white or sevColor)

  local x, right = 100 * s, W - 14 * s
  local title = S.severity[c.severity] .. ' ' .. S.dir[c.dir]
  if card.cue then
    -- The cue word takes over the big line; the corner moves to the small one.
    local forCorner = (card.cue ~= 'throttle' and card.brakeFor) or c
    G.text(forCorner.name .. '  ' .. S.severity[forCorner.severity] .. ' ' .. S.dir[forCorner.dir],
      16 * s, x, 7 * s, C.white)
    G.text(S.cue[card.cue], 44 * s, x, 22 * s, C.white)
  else
    G.text(c.name, 16 * s, x, 7 * s, C.dim)
    G.text(title, 28 * s, x, 25 * s, C.white)
    local dist = card.inCorner and S.status.now or distanceText(card.distStartM)
    G.textRight(dist, 26 * s, right, 26 * s, C.white)
  end

  -- Second line: the target for this corner, then what follows it.
  -- With a benchmark the target is real (gear and slowest speed); without
  -- one it is an estimate and only shown on the advanced HUD.
  if not card.cue then
    local target, real = nil, false
    local tg = card.target
    if tg and tg.minKmh then
      target = gearText(tg.gear) .. ' gear, ' .. speedText(tg.minKmh, app.settings.mph)
      real = true
    elseif not app.settings.beginner and card.estKmh and card.estKmh > 0 then
      target = '~' .. speedText(card.estKmh, app.settings.mph) .. ' ' .. S.status.estimate
    end
    local follow
    local nxt = card.nextCorner
    if nxt and (card.nextGapM or math.huge) <= 250 then
      follow = S.status.thenWord .. ' ' .. nxt.name .. ' ' .. cornerWords(nxt)
    end
    local size, tx = 15 * s, x
    if target then
      G.text(target, size, tx, 61 * s, real and C.white or C.dim)
      tx = tx + G.textWidth(target, size) + 14 * s
    end
    if follow and tx + G.textWidth(follow, size) <= right then
      G.text(follow, size, tx, 61 * s, C.dim)
    end
  end

  -- Countdown bar to the brake point, with the distance written beside it.
  local bx0, bx1, by = x, right - 126 * s, 88 * s
  G.rect(bx0, by, bx1, by + 10 * s, C.barBg, 5 * s)
  if card.distBrakeM and card.cue ~= 'throttle' then
    local frac = 1 - U.clamp(card.distBrakeM / config.pilot.brakeBarM, 0, 1)
    local color = (frac > 0.75) and C.red or ((frac > 0.4) and C.orange or C.yellow)
    if card.cue then color = C.white end
    if frac > 0.02 then
      G.rect(bx0, by, bx0 + (bx1 - bx0) * frac, by + 10 * s, color, 5 * s)
    end
    if not card.cue and card.distBrakeM > 0 then
      G.textRight('brake in ' .. distanceText(card.distBrakeM), 14 * s, right, 83 * s, C.dim)
    end
  end
  return h + 6 * s
end

local function deltaRow(app, W, s, y)
  local best, bench = app.best, app.benchmark
  if not best and not bench then return y end
  local h = 30 * s
  G.rect(0, y, W, y + h, C.cardBg, 8 * s)
  local x = 14 * s
  if app.deltaMs then
    G.text(U.formatDelta(app.deltaMs), 20 * s, x, y + 3 * s, (app.deltaMs <= 0) and C.green or C.red)
    G.text('to your best', 12 * s, x + 74 * s, y + 9 * s, C.dim)
    x = x + 160 * s
  end
  if app.benchDeltaMs then
    G.text(U.formatDelta(app.benchDeltaMs), 20 * s, x, y + 3 * s, (app.benchDeltaMs <= 0) and C.green or C.red)
    G.text('to ' .. (S.benchmark[app.benchLabel] or 'benchmark'), 12 * s, x + 74 * s, y + 9 * s, C.dim)
  end
  local shown = best or bench
  G.textRight((best and 'best ' or 'teacher ') .. U.formatLap(shown.timeMs), 14 * s, W - 14 * s, y + 7 * s, C.dim)
  return y + h + 6 * s
end

-- Your pedals above the benchmark's at the same place on the track.
local function pedalRow(app, W, s, y)
  if not app.ghost then return y end
  local h = 40 * s
  G.rect(0, y, W, y + h, C.cardBg, 8 * s)
  local labelW = 64 * s
  local x0 = 14 * s + labelW
  local half = (W - 14 * s - x0 - 10 * s) / 2
  local function bars(rowY, brake, gas, bright)
    local alphaBrake = bright and C.red or C.pedalDimRed
    local alphaGas = bright and C.green or C.pedalDimGreen
    G.rect(x0, rowY, x0 + half, rowY + 9 * s, C.barBg, 3 * s)
    G.rect(x0 + half + 10 * s, rowY, x0 + 2 * half + 10 * s, rowY + 9 * s, C.barBg, 3 * s)
    brake, gas = U.clamp(brake or 0, 0, 1), U.clamp(gas or 0, 0, 1)
    if brake > 0.02 then G.rect(x0, rowY, x0 + half * brake, rowY + 9 * s, alphaBrake, 3 * s) end
    if gas > 0.02 then
      G.rect(x0 + half + 10 * s, rowY, x0 + half + 10 * s + half * gas, rowY + 9 * s, alphaGas, 3 * s)
    end
  end
  G.text('you', 12 * s, 14 * s, y + 4 * s, C.white)
  bars(y + 7 * s, app.car.brake, app.car.gas, true)
  G.text(S.benchmark[app.benchLabel] or 'benchmark', 12 * s, 14 * s, y + 20 * s, C.dim)
  bars(y + 23 * s, app.ghostBrake, app.ghostGas, false)
  return y + h + 6 * s
end

local function tipCard(app, W, s, y)
  local tip = app.tip
  if not tip or app.clock >= tip.untilT then return y end
  local size = 14 * s
  if tip.wrapW ~= W then
    tip.lines = tip.body and wrap(tip.body, size, W - 28 * s) or {}
    tip.wrapW = W
  end
  local h = (34 + #tip.lines * 19) * s
  G.rect(0, y, W, y + h, tip.good and C.goodBg or C.tipBg, 10 * s)
  local title = tip.title
  if tip.where then title = tip.where .. '  ' .. title end
  G.text(title, 18 * s, 14 * s, y + 6 * s, tip.good and C.white or C.yellow)
  for i, line in ipairs(tip.lines) do
    G.text(line, size, 14 * s, y + (32 + (i - 1) * 19) * s, C.white)
  end
  return y + h + 6 * s
end

function Hud.draw(app)
  local win = ui.windowSize()
  local W = win.x
  if W < 60 then return end
  local s = W / 460
  local y

  if app.state == 'incompatible' then
    y = statusCard(S.status.incompatible, W, s)
  elseif app.state == 'init' or app.state == 'sampling' then
    local pct = app.sampleProgress and string.format(' %d%%', U.round(app.sampleProgress * 100)) or ''
    y = statusCard(S.status.loading .. pct, W, s)
  elseif app.state == 'noline' then
    y = statusCard(S.status.noLine, W, s)
  elseif not app.track or #app.track.corners == 0 then
    y = statusCard(S.status.noCorners, W, s)
  elseif app.card and app.card.ready then
    y = cornerCard(app, W, s)
  else
    y = statusCard(S.status.loading, W, s)
  end

  if not app.settings.beginner then
    y = deltaRow(app, W, s, y)
    if app.settings.ghostPedals then y = pedalRow(app, W, s, y) end
  end
  if app.settings.showTips then y = tipCard(app, W, s, y) end

  if app.lastError then
    G.rect(0, y, W, y + 24 * s, C.brakeBg, 6 * s)
    G.text(S.status.error, 13 * s, 10 * s, y + 4 * s, C.white)
  end
end

return Hud
