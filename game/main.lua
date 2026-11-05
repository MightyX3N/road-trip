-- Road Trip launcher — step 1: home screen with your real apps.

local android = require("android")
local config = require("config")
local ui = require("ui")

local lg = love.graphics

local DESIGN_H = 720
local RAIL, TOP = 112, 72
local LONG_PRESS = 0.6

local W, H = 1280, 720 -- virtual size (H is always 720; W follows the screen's shape)

local state = {
  screen = "home",
  apps = {},
  icons = {}, -- file name -> { img, modtime }
  page = 1,
  pageX = 0, -- animated page position (0 = first page)
  isHome = true,
  error = nil,
  dirty = true, -- redraw needed
}

local press -- active touch: { x, y, t, id, moved, grid, done }

----------------------------------------------------------------------------------------------
-- data
----------------------------------------------------------------------------------------------

local function refreshApps()
  love.filesystem.createDirectory("icons")
  local dir = love.filesystem.getSaveDirectory() .. "/icons"
  local apps, err = android.getApps(dir)
  if not apps then
    state.error = err
    return
  end
  table.sort(apps, function(a, b) return a.label:lower() < b.label:lower() end)
  state.apps = apps
  state.error = nil
  local home = android.isDefaultHome()
  state.isHome = home ~= false
  state.dirty = true
end

local function iconFor(app)
  if not app.icon then return nil end
  local path = "icons/" .. app.icon
  local info = love.filesystem.getInfo(path)
  if not info then return nil end
  local cached = state.icons[app.icon]
  if cached and cached.modtime == info.modtime then return cached.img end
  local ok, img = pcall(lg.newImage, path, { mipmaps = true })
  if not ok then return nil end
  img:setFilter("linear", "linear")
  state.icons[app.icon] = { img = img, modtime = info.modtime }
  return img
end

----------------------------------------------------------------------------------------------
-- layout
----------------------------------------------------------------------------------------------

local function showBanner()
  return android.isAndroid and not state.isHome and not config.get("homeHintDismissed")
end

local function gridLayout()
  local x0, cw = RAIL, W - RAIL
  local top = TOP + (showBanner() and 104 or 0)
  local bottom = H - 44
  local cols = math.max(3, math.min(6, math.floor((cw - 48) / 220)))
  local rows = math.max(2, math.min(4, math.floor((bottom - top) / 230)))
  local cellW, cellH = (cw - 48) / cols, (bottom - top) / rows
  local radius = math.min(64, cellW * 0.3, cellH * 0.3)
  return {
    x0 = x0, cw = cw, top = top, bottom = bottom,
    cols = cols, rows = rows, per = cols * rows,
    cellW = cellW, cellH = cellH, r = radius,
  }
end

local function pageCount(g)
  return math.max(1, math.ceil(#state.apps / g.per))
end

----------------------------------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------------------------------

local function drawTopBar()
  local x0 = RAIL
  ui.rect(ui.c.line, x0, TOP - 1, W - x0, 1)
  local time = os.date("%H:%M")
  local date = os.date("%a ") .. tonumber(os.date("%d")) .. os.date(" %b")
  local th = ui.fontHeight("bold", 30)
  ui.text(time, "bold", 30, ui.c.text, x0 + 32, (TOP - th) / 2)
  local tw = ui.textWidth(time, "bold", 30)
  ui.text(date, "semibold", 17, ui.c.muted, x0 + 32 + tw + 16, (TOP - th) / 2 + 11)
  if state.error then
    local msg = ui.fit(state.error, "semibold", 15, W - x0 - 400)
    ui.text(msg, "semibold", 15, ui.hex("F09A8A"), x0, (TOP - 20) / 2, "right", W - x0 - 32)
  end
end

local RAIL_ITEMS = {
  { screen = "home", label = "Home", icon = "home" },
  { screen = "widgets", label = "Widgets", icon = "widgets" },
  { screen = "media", label = "Media", icon = "media" },
}

local function drawRail()
  ui.rect(ui.c.rail, 0, 0, RAIL, H)
  ui.rect(ui.c.line, RAIL - 1, 0, 1, H)
  for i, item in ipairs(RAIL_ITEMS) do
    local x, y = 12, 20 + (i - 1) * 98
    local on = state.screen == item.screen
    local color = on and ui.c.accent or ui.c.muted
    if on then ui.rect(ui.c.accentBg, x, y, 88, 88, 20) end
    ui.icon(item.icon, x + 29, y + 16, 30, color)
    ui.text(item.label, "semibold", 13, color, x, y + 56, "center", 88)
    ui.hit({ kind = "rail", screen = item.screen }, x, y, 88, 88)
  end
  local vy = H - 20 - 72
  ui.ring(ui.c.accent, RAIL / 2, vy + 36, 35, 2)
  ui.icon("mic", RAIL / 2 - 15, vy + 21, 30, ui.c.accent)
  ui.hit({ kind = "voice" }, RAIL / 2 - 36, vy, 72, 72)
end

local function drawBanner()
  if not showBanner() then return end
  local x, y, w, h = RAIL + 24, TOP + 20, W - RAIL - 48, 72
  ui.rect(ui.c.card, x, y, w, h, 20)
  ui.text("Road Trip isn't your home app yet", "bold", 19, ui.c.text, x + 24, y + 14)
  ui.text("Set it so the Home button opens it", "semibold", 15, ui.c.muted, x + 24, y + 40)
  local bw = ui.textWidth("Set as home app", "bold", 16) + 44
  local bx = x + w - 64 - bw - 12
  ui.rect(ui.c.accent, bx, y + 12, bw, 48, 24)
  ui.text("Set as home app", "bold", 16, ui.c.onAccent, bx, y + 24, "center", bw)
  ui.hit({ kind = "setHome" }, bx, y + 12, bw, 48)
  ui.icon("close", x + w - 52, y + 24, 24, ui.c.muted, 2.2)
  ui.hit({ kind = "dismissBanner" }, x + w - 64, y + 8, 56, 56)
end

local function drawTile(app, cx, cy, r, pressed)
  ui.circle(pressed and ui.c.tileOn or ui.c.tile, cx, cy, r)
  ui.ring(pressed and ui.c.accent or ui.c.ring, cx, cy, r, 2)
  local img = iconFor(app)
  local size = r * 1.3
  if img then
    lg.setColor(1, 1, 1, 1)
    lg.draw(img, cx - size / 2, cy - size / 2, 0, size / img:getWidth(), size / img:getHeight())
  else
    local letter = app.label:sub(1, 1):upper()
    ui.text(letter, "bold", math.floor(r * 0.7), ui.c.accent, cx - r, cy - ui.fontHeight("bold", math.floor(r * 0.7)) / 2, "center", r * 2)
  end
  local maxW = r * 2 + 48
  local label = ui.fit(app.label, "semibold", 19, maxW)
  ui.text(label, "semibold", 19, ui.c.text2, cx - maxW / 2, cy + r + 12, "center", maxW)
end

local function drawGrid()
  local g = gridLayout()
  local pages = pageCount(g)
  local s = ui.S
  lg.setScissor(g.x0 * s, 0, g.cw * s, H * s)
  local first = math.max(1, math.floor(state.pageX) + 1)
  for p = first, math.min(pages, first + 1) do
    local offset = (p - 1 - state.pageX) * g.cw
    for slot = 1, g.per do
      local app = state.apps[(p - 1) * g.per + slot]
      if not app then break end
      local col = (slot - 1) % g.cols
      local row = math.floor((slot - 1) / g.cols)
      local cx = g.x0 + 24 + (col + 0.5) * g.cellW + offset
      local cy = g.top + (row + 0.5) * g.cellH - 14
      local id = press and press.id
      local pressed = id and id.kind == "tile" and id.app == app and not press.moved
      drawTile(app, cx, cy, g.r, pressed)
      if math.abs(offset) < 1 then
        ui.hit({ kind = "tile", app = app }, cx - g.cellW / 2, cy - g.r - 8, g.cellW, g.r * 2 + 48)
      end
    end
  end
  lg.setScissor()

  if pages > 1 then
    local total = (pages - 1) * 16 + 28
    local x = g.x0 + (g.cw - total) / 2
    local cur = math.floor(state.pageX + 0.5) + 1
    for p = 1, pages do
      local wDot = p == cur and 28 or 6
      ui.rect(p == cur and ui.c.text2 or ui.c.dim, x, H - 28, wDot, 6, 3)
      x = x + wDot + 10
    end
  end
end

local function drawPlaceholder(label)
  local th = ui.fontHeight("semibold", 19)
  ui.text(label, "semibold", 19, ui.c.muted, RAIL, (H + TOP - th) / 2, "center", W - RAIL)
end

function love.draw()
  ui.beginFrame()
  lg.push()
  lg.scale(ui.S)
  if state.screen == "home" then
    drawBanner()
    drawGrid()
  elseif state.screen == "widgets" then
    drawPlaceholder("Widgets are coming in a later update")
  else
    drawPlaceholder("Media is coming in a later update")
  end
  drawTopBar()
  drawRail()
  lg.pop()
end

----------------------------------------------------------------------------------------------
-- input (touch arrives as mouse events on Android too)
----------------------------------------------------------------------------------------------

local function activate(id)
  if id.kind == "tile" then
    local ok, err = android.launch(id.app)
    if not ok then state.error = err or ("Couldn't open " .. id.app.label) end
  elseif id.kind == "rail" then
    state.screen = id.screen
  elseif id.kind == "voice" then
    android.voice()
  elseif id.kind == "setHome" then
    android.openHomeSettings()
  elseif id.kind == "dismissBanner" then
    config.set("homeHintDismissed", true)
  end
  state.dirty = true
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  local vx, vy = x / ui.S, y / ui.S
  local g = gridLayout()
  press = {
    x = vx, y = vy, t = love.timer.getTime(),
    id = ui.hitAt(vx, vy),
    moved = false,
    grid = state.screen == "home" and vx > g.x0 and vy > g.top,
    startPage = state.pageX,
  }
end

function love.mousemoved(x, y)
  if not press or press.done then return end
  local vx, vy = x / ui.S, y / ui.S
  local dx = vx - press.x
  if math.abs(dx) > 12 or math.abs(vy - press.y) > 12 then press.moved = true end
  if press.grid and press.moved then
    local g = gridLayout()
    local maxX = pageCount(g) - 1
    local pos = press.startPage - dx / g.cw
    -- resist past the first and last page
    if pos < 0 then pos = pos * 0.3 elseif pos > maxX then pos = maxX + (pos - maxX) * 0.3 end
    state.pageX = pos
  end
end

function love.mousereleased(x, y, button)
  if button ~= 1 or not press then return end
  local p = press
  press = nil
  if p.done then return end
  local vx, vy = x / ui.S, y / ui.S
  if p.moved then
    if p.grid then
      local g = gridLayout()
      local dx = vx - p.x
      local dt = math.max(0.016, love.timer.getTime() - p.t)
      local fling = math.abs(dx) / dt > 600
      local target = math.floor(p.startPage + 0.5)
      if dx < -80 or (fling and dx < 0) then target = target + 1
      elseif dx > 80 or (fling and dx > 0) then target = target - 1 end
      state.page = math.max(1, math.min(pageCount(g), target + 1))
    end
  else
    local id = ui.hitAt(vx, vy)
    if id and p.id and id.kind == p.id.kind and id.app == p.id.app and id.screen == p.id.screen then
      activate(id)
    end
  end
  state.dirty = true
end

function love.keypressed(key)
  -- Android's back button arrives as "escape"; a home screen ignores it.
  if key == "escape" and not android.isAndroid then love.event.quit() end
end

----------------------------------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------------------------------

local function layout(w, h)
  local s = h / DESIGN_H
  ui.setScale(s)
  W, H = w / s, DESIGN_H
  state.dirty = true
end

function love.load()
  config.load()
  ui.setAccent(config.get("accent"))
  lg.setBackgroundColor(ui.c.bg)
  layout(lg.getDimensions())
  refreshApps()
end

function love.resize(w, h) layout(w, h) end

function love.focus(f)
  if f then refreshApps() end -- coming back from an app: catch installs, removals, home changes
end

function love.update(dt)
  -- long press on an app opens its Android info page (uninstall, permissions)
  if press and not press.moved and not press.done and press.id and press.id.kind == "tile"
    and love.timer.getTime() - press.t > LONG_PRESS then
    press.done = true
    android.openAppInfo(press.id.app)
    state.dirty = true
  end

  -- settle the page position
  local g = gridLayout()
  state.page = math.max(1, math.min(pageCount(g), state.page))
  if not (press and press.grid and press.moved) then
    local target = state.page - 1
    local d = target - state.pageX
    if math.abs(d) < 0.001 then
      state.pageX = target
    else
      state.pageX = state.pageX + d * math.min(1, dt * 14)
    end
  end
end

-- Draw only when something changed, so the launcher idles quietly on the car box.
function love.run()
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
  if love.timer then love.timer.step() end
  local lastMinute

  return function()
    love.event.pump()
    for name, a, b, c, d, e, f in love.event.poll() do
      if name == "quit" then
        if not love.quit or not love.quit() then return a or 0 end
      end
      love.handlers[name](a, b, c, d, e, f)
      state.dirty = true
    end

    local dt = love.timer.step()
    love.update(dt)

    local minute = os.date("%H:%M")
    if minute ~= lastMinute then
      lastMinute = minute
      state.dirty = true
    end

    local animating = press ~= nil or math.abs((state.page - 1) - state.pageX) > 0.001
    if (state.dirty or animating) and lg.isActive() then
      lg.origin()
      lg.clear(lg.getBackgroundColor())
      love.draw()
      lg.present()
      state.dirty = false
    end

    love.timer.sleep(animating and 0.001 or 0.05)
  end
end
