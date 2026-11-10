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
  local h = (36 + #lines * 21) * s
  G.rect(0, 0, W, h, C.cardBg, 10 * s)
  G.text('PaceCoach ' .. config.version, 12 * s, 14 * s, 8 * s, C.dim)
  for i, line in ipairs(lines) do
    G.text(line, size, 14 * s, (26 + (i - 1) * 21) * s, C.white)
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

local CUE_BG = { brake = C.brakeBg, lift = C.liftBg, throttle = C.goodBg, info = C.infoBg }

local function cornerCard(app, W, s)
  local card = app.card
  local c = card.corner
  local h = 108 * s
  -- A live coaching cue takes the card over for a moment, unless the
  -- co-driver's own brake or throttle call is up.
  local live = app.liveCue
  if card.cue or not (live and app.clock < live.untilT) then live = nil end
  local bg = C.cardBg
  if card.cue then
    bg = CUE_BG[card.cue] or C.cardBg
  elseif live then
    bg = CUE_BG[live.def.tone] or C.cardBg
  end
  G.rect(0, 0, W, h, bg, 10 * s)

  local shown = live and live.corner or c
  local sevColor = G.severityColor[shown.severity] or C.white
  G.cornerArrow(10 * s, 8 * s, 78 * s, shown.dir, shown.severity, (card.cue or live) and C.white or sevColor)

  local x, right = 100 * s, W - 14 * s
  local title = S.severity[c.severity] .. ' ' .. S.dir[c.dir]
  if live then
    G.text(shown.name .. '  ' .. S.severity[shown.severity] .. ' ' .. S.dir[shown.dir], 16 * s, x, 7 * s, C.white)
    local size = G.fitSize(live.def.text, 44 * s, right - x)
    G.text(live.def.text, size, x, 22 * s + (44 * s - size) * 0.5, C.white)
    local hint = live.def.hint
    if hint and hint ~= '' then
      hint = string.format(hint, S.who[app.coachLabel] or 'the benchmark')
      G.text(hint, G.fitSize(hint, 13 * s, right - x), x, 68 * s, C.white)
    end
  elseif card.cue then
    -- The cue word takes over the big line; the corner moves to the small one.
    local forCorner = (card.cue ~= 'throttle' and card.brakeFor) or c
    G.text(forCorner.name .. '  ' .. S.severity[forCorner.severity] .. ' ' .. S.dir[forCorner.dir],
      16 * s, x, 7 * s, C.white)
    G.text(S.cue[card.cue], 44 * s, x, 22 * s, C.white)
  else
    G.text(c.name, 16 * s, x, 7 * s, C.dim)
    G.text(title, 28 * s, x, 25 * s, C.white)
    local dist = distanceText(card.distStartM)
    if card.phase == 'exit' then
      dist = S.status.exit
    elseif card.inCorner then
      dist = S.status.now
    end
    G.textRight(dist, 26 * s, right, 26 * s, C.white)
  end

  -- Second line: the target for this corner, then what follows it.
  -- With a benchmark the target is real (gear and slowest speed); without
  -- one it is an estimate and only shown on the advanced HUD.
  if not card.cue and not live then
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
    if nxt and card.phase == 'exit' then
      follow = S.status.thenWord .. ' ' .. nxt.name .. ' ' .. cornerWords(nxt)
        .. ' in ' .. distanceText(card.nextGapM or 0)
    elseif nxt and (card.nextGapM or math.huge) <= 250 then
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

  -- The spotter: a red edge on the side where a car is alongside.
  local spot = app.spot
  if spot and spot.left then G.rect(0, 0, 9 * s, h, C.red, 4 * s) end
  if spot and spot.right then G.rect(W - 9 * s, 0, W, h, C.red, 4 * s) end

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
    if not card.cue and not live and card.distBrakeM > 0 then
      G.textRight('brake in ' .. distanceText(card.distBrakeM), 14 * s, right, 83 * s, C.dim)
    end
  end
  return h + 6 * s
end

-- The corner ahead as a strip, from a little before the brake point to the
-- exit: the benchmark's braking (red) and throttle (green) as shapes to
-- follow, your own pedals drawn over them as you go, marks for Brake, Turn
-- in, Apex and eXit, and a white line where the car is now.
local function cornerStrip(app, W, s, y)
  local plan, k = app.coachPlan, app.segIdx
  if not (app.settings.cornerStrip and plan and k and app.track) then return y end
  local sl, tg, seg = plan.exitSlices[k], plan.exitTargets[k], app.segs[k]
  if not (sl and tg and seg) then return y end
  local track = app.track
  local n = track.n
  local cell = (math.floor((app.car.pos or 0) * n) % n) + 1
  local jCar = U.forward(seg.from, cell, n) + 1
  local j0 = math.max(1, (tg.brakeStartJ or tg.sJ) - math.floor(120 / track.cellM))
  local j1 = sl.count
  if jCar < j0 or jCar > j1 or j1 - j0 < 8 then return y end
  local span = sl.dist[j1] - sl.dist[j0]
  if span <= 0 then return y end

  local h = 70 * s
  G.rect(0, y, W, y + h, C.cardBg, 8 * s)
  local left, right = 14 * s, W - 14 * s
  local function X(j) return left + (right - left) * (sl.dist[j] - sl.dist[j0]) / span end
  local laneH = 17 * s
  local brakeTop, gasTop = y + 18 * s, y + 18 * s + laneH + 5 * s
  G.rect(left, brakeTop, right, brakeTop + laneH, C.barBg, 2 * s)
  G.rect(left, gasTop, right, gasTop + laneH, C.barBg, 2 * s)

  -- The benchmark's shapes.
  local step = math.max(1, math.ceil((j1 - j0) / 64))
  for j = j0, j1 - 1, step do
    local x0, x1 = X(j), X(math.min(j1, j + step))
    local b, g = sl.brake[j] or 0, sl.gas[j] or 0
    if b > 0.03 then G.rect(x0, brakeTop + laneH * (1 - b), x1, brakeTop + laneH, C.pedalDimRed, 0) end
    if g > 0.03 then G.rect(x0, gasTop + laneH * (1 - g), x1, gasTop + laneH, C.pedalDimGreen, 0) end
  end

  -- Your own pedals so far: a bright bar at the level of your foot.
  local lap = app.recorder and app.recorder.lap
  if lap then
    local thick = 1.5 * s
    for j = j0, math.min(jCar, j1) - 1, step do
      local c0 = sl.cell[j]
      local b, g = lap.brake[c0], lap.gas[c0]
      if b then
        local x0, x1 = X(j), X(math.min(j1, j + step))
        local yb = brakeTop + laneH * (1 - U.clamp(b, 0, 1))
        local yg = gasTop + laneH * (1 - U.clamp(g or 0, 0, 1))
        G.rect(x0, math.max(brakeTop, yb - thick), x1, math.min(brakeTop + laneH, yb + thick), C.white, 0)
        G.rect(x0, math.max(gasTop, yg - thick), x1, math.min(gasTop + laneH, yg + thick), C.white, 0)
      end
    end
  end

  -- Marks, and where the car is.
  local function mark(j, letter)
    if not j or j < j0 or j > j1 then return end
    local x = X(j)
    G.rect(x - 0.5 * s, y + 14 * s, x + 0.5 * s, gasTop + laneH, C.faint, 0)
    G.text(letter, 11 * s, x - 3 * s, y + 2 * s, C.dim)
  end
  local info = app.live and app.live.info[k]
  mark(tg.brakeStartJ, 'B')
  mark(info and info.turnCell and (U.forward(seg.from, info.turnCell, n) + 1) or tg.sJ, 'T')
  mark(tg.minJ, 'A')
  mark(tg.eJ, 'X')
  local xCar = X(math.min(jCar, j1))
  G.rect(xCar - s, y + 14 * s, xCar + s, gasTop + laneH + 2 * s, C.white, 0)

  -- The number that matters most: the slowest speed, before and after.
  local note
  if jCar <= tg.minJ then
    note = 'target ' .. speedText(tg.minKmh, app.settings.mph)
  elseif lap and lap.v[tg.minCell] then
    local diff = lap.v[tg.minCell] - tg.minKmh
    note = string.format('apex %+d %s', U.round(app.settings.mph and diff * 0.621371 or diff), app.settings.mph and 'mph' or 'km/h')
  end
  if note then G.text(note, 12 * s, left, y + 2 * s, C.white) end
  return y + h + 6 * s
end

-- The instruction for the corner being worked on, shown while it is the
-- next corner.
local function focusRow(app, W, s, y)
  local f = app.settings.lessons and app.coachPlan and app.lesson and app.lesson.focus
  local card = app.card
  if not (f and card and card.ready and card.phase ~= 'exit' and card.corner.index == f.k) then return y end
  local text = app.remedyText(f.id, f.value)
  if not text then return y end
  local h = 28 * s
  G.rect(0, y, W, y + h, C.focusBg, 8 * s)
  G.text(S.lesson.focus, 13 * s, 14 * s, y + 7 * s, C.cyan)
  local tx = 14 * s + G.textWidth(S.lesson.focus, 13 * s) + 12 * s
  local size = G.fitSize(text, 15 * s, W - 14 * s - tx)
  G.text(text, size, tx, y + 5 * s + (15 * s - size) * 0.5, C.white)
  return y + h + 6 * s
end

-- Speed against the benchmark at this very point of the track: the bar
-- grows to the right in green when you are faster, to the left in red when
-- you are slower.
local PACE_FULL_KMH = 30
local function paceRow(app, W, s, y)
  local g = app.gauge
  if not (g and g.active and g.dv and app.settings.paceBar) then return y end
  if (app.car.speedKmh or 0) < 30 then return y end
  local h = 24 * s
  G.rect(0, y, W, y + h, C.cardBg, 8 * s)
  G.text('vs ' .. (S.benchmark[app.coachLabel] or 'benchmark'), 12 * s, 14 * s, y + 5 * s, C.dim)
  local x0, x1 = 112 * s, W - 98 * s
  local mid = (x0 + x1) / 2
  local top, bottom = y + 9 * s, y + 15 * s
  G.rect(x0, top, x1, bottom, C.barBg, 3 * s)
  local frac = U.clamp(g.dv / PACE_FULL_KMH, -1, 1)
  local color = C.dim
  if frac > 0.07 then
    color = C.green
    G.rect(mid, top, mid + (x1 - mid) * frac, bottom, color, 3 * s)
  elseif frac < -0.07 then
    color = C.red
    G.rect(mid + (mid - x0) * frac, top, mid, bottom, color, 3 * s)
  end
  G.rect(mid - s, y + 5 * s, mid + s, y + 19 * s, C.white, 0)
  local diff = app.settings.mph and (g.dv * 0.621371) or g.dv
  G.textRight(string.format('%+d %s', U.round(diff), app.settings.mph and 'mph' or 'km/h'),
    14 * s, W - 14 * s, y + 4 * s, color)
  return y + h + 6 * s
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

  if app.card and app.card.ready and app.state == 'ready' then
    y = cornerStrip(app, W, s, y)
    y = focusRow(app, W, s, y)
    y = paceRow(app, W, s, y)
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
