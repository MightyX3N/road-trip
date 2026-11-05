-- Road Trip launcher: Home (widgets + favorites), Apps (all apps), Media, favorites picker.

local android = require("android")
local config = require("config")
local ui = require("ui")
local map = require("map")

local lg = love.graphics

local DESIGN_H = 720
local RAIL, TOP = 112, 72
local LONG_PRESS = 0.6
local FAV_MIN, FAV_MAX = 3, 5

local W, H = 1280, 720 -- virtual size (H is always 720; W follows the screen's shape)

local state = {
  screen = "home",   -- home | apps | media | favs
  favsMode = "edit", -- favs picker: "setup" (first launch) or "edit"
  apps = {},
  byKey = {},        -- "pkg/activity" -> app
  icons = {},        -- icon file -> { img, modtime }
  pagers = { apps = { page = 1, x = 0 }, favs = { page = 1, x = 0 } },
  pagerArea = {},    -- pager id -> area it was last drawn in
  pick = {},         -- keys being picked in the favorites picker
  menu = nil,        -- open menu: { title, app?, rows = { { label, icon, id, off } } }
  toast = nil,       -- { text, untilT }
  isHome = true,
  guard = { serviceOn = true, enabled = true, stock = {} },
  update = { state = "idle" }, -- from Updater.java: idle|checking|none|available|downloading|ready|permission|error|offline
  manualCheck = false,         -- the user asked; report "up to date" too
  timers = { update = 0, guard = 0, autoCheck = 0, home = 0, media = 0, fetch = 0, slow = 0, diag = 0 },
  media = { access = true },   -- from MediaListener.java: { access, current? }
  nav = { active = false },    -- the nav app's turn-by-turn notification
  weather = nil,               -- { temp, code, isDay, hi, lo, at }
  weatherBusy = false,
  cal = { permission = true, events = {} },
  pending = {},                -- fetch id -> handler
  city = nil,                  -- city search dialog: { text, results?, busy, err? }
  diag = nil,                  -- Settings → Diagnostics data
  navImg = nil,                -- { name, img } for the turn arrow
  mediaAt = 0,                 -- when `media` was read, to move the progress bar between reads
  art = {},                    -- album art file -> image
  homeSeen = nil,              -- last Home-press count from Java
  burstUntil = 0,              -- draw every frame until then (Android settles the screen after resume)
  error = nil,
  dirty = true,
}

local press -- active touch: { x, y, t, id, moved, pager, startX, done }

local function keyOf(app) return app.pkg .. "/" .. (app.activity or "") end

local function toast(text)
  state.toast = { text = text, untilT = love.timer.getTime() + 2.5 }
  state.dirty = true
end

----------------------------------------------------------------------------------------------
-- data
----------------------------------------------------------------------------------------------

local function refreshGuard()
  local g = android.guardStatus()
  if type(g) ~= "table" then return end
  local changed = g.serviceOn ~= state.guard.serviceOn or g.enabled ~= state.guard.enabled
  state.guard = g
  -- came back from Accessibility with the guard now on: close the how-to
  if state.menu and state.menu.restricted and g.serviceOn then
    state.menu = nil
    toast("Keep in front is on")
  end
  if changed then state.dirty = true end
end

local UPDATE_EVERY = 6 * 3600 -- seconds between automatic checks

-- automatic checks are Wi-Fi only and at most every 6 hours; `manual` ignores both
local function checkForUpdate(manual)
  if not android.isAndroid then
    if manual then toast("Updates only work on Android") end
    return
  end
  local last = config.get("lastUpdateCheck") or 0
  if not manual and os.time() - last < UPDATE_EVERY then return end
  config.set("lastUpdateCheck", os.time())
  state.manualCheck = manual
  local wifiOnly = not manual and config.get("updateWifiOnly") ~= false
  if android.updateCheck(wifiOnly) then state.update.state = "checking" end
  if manual then toast("Checking for updates…") end
end

local function pollUpdate()
  local u = android.updateStatus()
  if type(u) ~= "table" then return end
  local before = state.update.state
  local changed = u.state ~= before or u.progress ~= state.update.progress
  state.update = u
  if state.manualCheck and before == "checking" and u.state ~= "checking" then
    state.manualCheck = false
    if u.state == "none" then toast("Road Trip " .. (u.currentName or "") .. " is up to date")
    elseif u.state == "error" then toast("Couldn't check for updates (" .. (u.error or "") .. ")") end
  end
  if changed then state.dirty = true end
end

----------------------------------------------------------------------------------------------
-- media (what's playing in any app)
----------------------------------------------------------------------------------------------

local function pollMedia()
  love.filesystem.createDirectory("art")
  local res = android.mediaStatus(love.filesystem.getSaveDirectory() .. "/art")
  if type(res) ~= "table" then return end
  local a, b = state.media.current, res.current
  local changed = (res.access ~= state.media.access) or ((a == nil) ~= (b == nil))
    or (a and b and (a.title ~= b.title or a.playing ~= b.playing or a.art ~= b.art or a.artist ~= b.artist))
  state.media = res
  state.mediaAt = love.timer.getTime()
  if changed then state.dirty = true end

  love.filesystem.createDirectory("nav")
  local nav = android.navStatus(love.filesystem.getSaveDirectory() .. "/nav")
  if type(nav) == "table" then
    local o = state.nav
    if nav.active ~= o.active or nav.title ~= o.title or nav.text ~= o.text or nav.sub ~= o.sub or nav.icon ~= o.icon then
      state.dirty = true
    end
    state.nav = nav
  end
end

-- nav apps Road Trip knows to offer, in order of preference
local NAV_APPS = { "com.google.android.apps.maps", "com.waze", "net.osmand.plus", "net.osmand",
  "com.here.app.maps", "com.sygic.aura", "cz.seznam.mapy" }

local function installedNavApps()
  local byPkg = {}
  for _, app in ipairs(state.apps) do byPkg[app.pkg] = byPkg[app.pkg] or app end
  local out = {}
  for _, p in ipairs(NAV_APPS) do
    if byPkg[p] then out[#out + 1] = byPkg[p] end
  end
  return out
end

local function navIcon()
  local name = state.nav.icon
  if not name then return nil end
  if state.navImg and state.navImg.name == name then return state.navImg.img end
  local path = "nav/" .. name
  if not love.filesystem.getInfo(path) then return nil end
  local ok, img = pcall(lg.newImage, path)
  if not ok then return nil end
  img:setFilter("linear", "linear")
  state.navImg = { name = name, img = img }
  return img
end

-- position now, moving it along since the last read while playing
local function mediaPos(m)
  local pos = m.positionMs or 0
  if m.playing then pos = pos + (love.timer.getTime() - state.mediaAt) * 1000 * (m.speed or 1) end
  if (m.durationMs or 0) > 0 then pos = math.min(pos, m.durationMs) end
  return math.max(0, pos)
end

local function fmtTime(ms)
  local s = math.floor(ms / 1000)
  local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
  return string.format("%d:%02d", m, s % 60)
end

local function artImage(m)
  if not (m and m.art) then return nil end
  local img = state.art[m.art]
  if img then return img end
  local path = "art/" .. m.art
  if not love.filesystem.getInfo(path) then return nil end
  local ok, loaded = pcall(lg.newImage, path, { mipmaps = true })
  if not ok then return nil end
  loaded:setFilter("linear", "linear")
  state.art = { [m.art] = loaded } -- keep only the current track's art
  return loaded
end

local function mediaCommand(action, posMs)
  local m = state.media.current
  if m then
    -- answer the tap now; the next read confirms it
    if action == "toggle" then m.positionMs, m.playing, state.mediaAt = mediaPos(m), not m.playing, love.timer.getTime()
    elseif action == "seek" then m.positionMs, state.mediaAt = posMs, love.timer.getTime() end
  end
  android.mediaCommand(action, posMs)
  state.timers.media = 0.7 -- read again shortly
  state.dirty = true
end

----------------------------------------------------------------------------------------------
-- weather (Open-Meteo, no account) and calendar
----------------------------------------------------------------------------------------------

local json = android.json
local WEATHER_EVERY = 30 * 60

local function request(url, handler)
  local id = android.fetch(url)
  if type(id) == "number" then state.pending[id] = handler end
  return id
end

local function pollFetches()
  for id, handler in pairs(state.pending) do
    local r = android.fetchResult(id)
    if type(r) == "table" and r.done then
      state.pending[id] = nil
      handler(r)
      state.dirty = true
    end
  end
end

local function urlEncode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- WMO weather codes, as Open-Meteo reports them
local function weatherLook(code, isDay)
  code = code or 3
  if code <= 1 then return code == 0 and "Clear" or "Mostly clear", isDay == 0 and "moon" or "sun" end
  if code == 2 then return "Partly cloudy", "cloud" end
  if code == 3 then return "Cloudy", "cloud" end
  if code == 45 or code == 48 then return "Fog", "fog" end
  if code >= 51 and code <= 57 then return "Drizzle", "rain" end
  if code >= 61 and code <= 67 then return "Rain", "rain" end
  if code >= 71 and code <= 77 then return "Snow", "snow" end
  if code >= 80 and code <= 82 then return "Showers", "rain" end
  if code == 85 or code == 86 then return "Snow showers", "snow" end
  if code >= 95 then return "Thunderstorm", "storm" end
  return "Weather", "cloud"
end

local function refreshWeather(force)
  local place = config.get("weatherPlace")
  if not place or state.weatherBusy then return end
  if not force and state.weather and os.time() - state.weather.at < WEATHER_EVERY then return end
  state.weatherBusy = true
  local url = string.format("https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
    .. "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min"
    .. "&timezone=auto&forecast_days=1", place.lat, place.lon)
  request(url, function(r)
    state.weatherBusy = false
    local d = r.ok and json.decode(r.body or "")
    if d and d.current then
      state.weather = {
        temp = d.current.temperature_2m, code = d.current.weather_code, isDay = d.current.is_day,
        hi = d.daily and d.daily.temperature_2m_max and d.daily.temperature_2m_max[1],
        lo = d.daily and d.daily.temperature_2m_min and d.daily.temperature_2m_min[1],
        at = os.time(),
      }
    end
  end)
end

local function refreshCalendar()
  local c = android.calendar()
  if type(c) == "table" then state.cal = c end
end

local function openCity()
  state.city = { text = "", busy = false }
  love.keyboard.setTextInput(true)
end

local function closeCity()
  state.city = nil
  love.keyboard.setTextInput(false)
end

local function searchCity()
  local c = state.city
  if not c or c.busy or c.text:gsub("%s", "") == "" then return end
  c.busy, c.err, c.results = true, nil, nil
  request("https://geocoding-api.open-meteo.com/v1/search?count=5&language=en&format=json&name=" .. urlEncode(c.text),
    function(r)
      if not state.city then return end
      state.city.busy = false
      local d = r.ok and json.decode(r.body or "")
      if not d then
        state.city.err = "Couldn't search; check the connection"
        return
      end
      state.city.results = d.results or {}
      if #state.city.results == 0 then state.city.err = "No places called that" end
      love.keyboard.setTextInput(false) -- make room for the results
    end)
end

-- Cheap when nothing changed: Java keeps the list and only rebuilds it after an install,
-- removal or update, and returns just a version number otherwise.
local function refreshApps()
  love.filesystem.createDirectory("icons")
  local dir = love.filesystem.getSaveDirectory() .. "/icons"
  local res, err = android.getApps(dir, state.appsVersion)
  if not res then
    state.error = err
    return
  end
  if res.apps then
    local apps = res.apps
    table.sort(apps, function(a, b) return a.label:lower() < b.label:lower() end)
    state.apps = apps
    state.byKey = {}
    for _, app in ipairs(apps) do state.byKey[keyOf(app)] = app end
  end
  state.appsVersion = res.version
  state.error = nil
  state.isHome = android.isDefaultHome() ~= false
  refreshGuard()
  pollUpdate()
  pollMedia()
  refreshCalendar()
  refreshWeather(false)
  state.dirty = true
end

-- saved favorites that are still installed, in order
local function favoriteApps()
  local list = {}
  for _, k in ipairs(config.get("favorites") or {}) do
    local app = state.byKey[k]
    if app then list[#list + 1] = app end
  end
  return list
end

local function isFavorite(app)
  for _, k in ipairs(config.get("favorites") or {}) do
    if k == keyOf(app) then return true end
  end
  return false
end

local function saveFavorites(keys)
  local list = setmetatable({}, android.json.array)
  for i, k in ipairs(keys) do list[i] = k end
  config.set("favorites", list)
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

local function openPicker(mode)
  state.favsMode = mode
  state.pick = {}
  for _, app in ipairs(favoriteApps()) do state.pick[#state.pick + 1] = keyOf(app) end
  state.pagers.favs.page, state.pagers.favs.x = 1, 0
  state.screen = "favs"
end

----------------------------------------------------------------------------------------------
-- shared pieces
----------------------------------------------------------------------------------------------

local function drawAppIcon(app, cx, cy, r)
  local img = iconFor(app)
  local size = r * 1.3
  if img then
    lg.setColor(1, 1, 1, 1)
    lg.draw(img, cx - size / 2, cy - size / 2, 0, size / img:getWidth(), size / img:getHeight())
  else
    local fs = math.max(12, math.floor(r * 0.7))
    ui.text(app.label:sub(1, 1):upper(), "bold", fs, ui.c.accent, cx - r, cy - ui.fontHeight("bold", fs) / 2, "center", r * 2)
  end
end

local function drawTopBar()
  local x0 = RAIL
  ui.rect(ui.c.line, x0, TOP - 1, W - x0, 1)
  local time = os.date("%H:%M")
  local date = os.date("%a ") .. tonumber(os.date("%d")) .. os.date(" %b")
  local th = ui.fontHeight("bold", 30)
  ui.text(time, "bold", 30, ui.c.text, x0 + 32, (TOP - th) / 2)
  local tw = ui.textWidth(time, "bold", 30)
  ui.text(date, "semibold", 17, ui.c.muted, x0 + 32 + tw + 16, (TOP - th) / 2 + 11)
  -- long-press the clock for the guard and launcher controls
  ui.hit({ kind = "clock" }, x0 + 16, 0, tw + ui.textWidth(date, "semibold", 17) + 48, TOP)
  if state.error then
    local msg = ui.fit(state.error, "semibold", 15, W - x0 - 400)
    ui.text(msg, "semibold", 15, ui.hex("F09A8A"), x0, (TOP - 20) / 2, "right", W - x0 - 32)
  end
end

local RAIL_ITEMS = {
  { screen = "home", label = "Home", icon = "home" },
  { screen = "apps", label = "Apps", icon = "widgets" },
  { screen = "map", label = "Map", icon = "map" },
  { screen = "media", label = "Media", icon = "media" },
  { screen = "settings", label = "Settings", icon = "gear" },
}

local function drawRail()
  ui.rect(ui.c.rail, 0, 0, RAIL, H)
  ui.rect(ui.c.line, RAIL - 1, 0, 1, H)
  for i, item in ipairs(RAIL_ITEMS) do
    local x, y = 12, 20 + (i - 1) * 98
    local on = state.screen == item.screen or (item.screen == "settings" and state.screen == "diag")
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

local pill = ui.pill -- shared with map.lua

----------------------------------------------------------------------------------------------
-- paged app grid (Apps screen and the favorites picker)
----------------------------------------------------------------------------------------------

local function gridLayout(area, maxR)
  local cols = math.max(3, math.min(area.maxCols or 6, math.floor((area.w - 48) / (area.cellMin or 220))))
  local rows = math.max(2, math.min(4, math.floor((area.bottom - area.top) / 230)))
  local cellW, cellH = (area.w - 48) / cols, (area.bottom - area.top) / rows
  return {
    x0 = area.x, cw = area.w, top = area.top, bottom = area.bottom,
    cols = cols, rows = rows, per = cols * rows, cellW = cellW, cellH = cellH,
    r = math.min(maxR or 64, cellW * 0.3, cellH * 0.3),
  }
end

local function pageCount(g) return math.max(1, math.ceil(#state.apps / g.per)) end

-- tile(app, cx, cy, r, slotIndex) draws one app; returns nothing
local function drawPagedGrid(pagerId, area, maxR, tile)
  local g = gridLayout(area, maxR)
  local pg = state.pagers[pagerId]
  state.pagerArea[pagerId] = g
  local pages = pageCount(g)
  local s = ui.S
  lg.setScissor(g.x0 * s, g.top * s - 40 * s, g.cw * s, (g.bottom - g.top + 40) * s)
  local first = math.max(1, math.floor(pg.x) + 1)
  for p = first, math.min(pages, first + 1) do
    local offset = (p - 1 - pg.x) * g.cw
    for slot = 1, g.per do
      local app = state.apps[(p - 1) * g.per + slot]
      if not app then break end
      local col = (slot - 1) % g.cols
      local row = math.floor((slot - 1) / g.cols)
      local cx = g.x0 + 24 + (col + 0.5) * g.cellW + offset
      local cy = g.top + (row + 0.5) * g.cellH - 14
      tile(app, cx, cy, g.r)
      if math.abs(offset) < 1 then
        ui.hit({ kind = "tile", app = app, grid = pagerId }, cx - g.cellW / 2, cy - g.r - 8, g.cellW, g.r * 2 + 48)
      end
    end
  end
  lg.setScissor()

  if pages > 1 then
    local total = (pages - 1) * 16 + 28
    local x = g.x0 + (g.cw - total) / 2
    local cur = math.floor(pg.x + 0.5) + 1
    for p = 1, pages do
      local wDot = p == cur and 28 or 6
      ui.rect(p == cur and ui.c.text2 or ui.c.dim, x, g.bottom + 14, wDot, 6, 3)
      x = x + wDot + 10
    end
  end
end

local function pressedTile(app)
  return press and not press.moved and press.id and press.id.kind == "tile" and press.id.app == app
end

----------------------------------------------------------------------------------------------
-- Home
----------------------------------------------------------------------------------------------

local function updateBanner(activeOnly)
  local u = state.update
  local s = u.state
  if s == "downloading" then
    return { title = "Downloading Road Trip " .. (u.latestName or "") .. " · " .. (u.progress or 0) .. "%",
      sub = "Keep using Road Trip; Android will ask to install when it's done" }
  elseif s == "permission" then
    return { title = "Allow Road Trip to install its updates",
      sub = "Switch on \"Allow from this source\", then come back and tap Install",
      button = "Install", id = { kind = "updateInstall" } }
  elseif s == "ready" then
    return { title = "Road Trip " .. (u.latestName or "") .. " is downloaded",
      sub = "Android asks you to confirm; your settings and favorites stay",
      button = "Install", id = { kind = "updateInstall" } }
  elseif s == "error" and (u.latest or 0) > (u.current or 0) then
    return { title = "The update didn't finish", sub = "Check the connection and try again (" .. (u.error or "") .. ")",
      button = "Retry", id = { kind = "updateGo" } }
  elseif s == "available" and not activeOnly and config.get("dismissedUpdate") ~= u.latest then
    local notes = (u.notes and u.notes ~= "") and u.notes or "Tap Update to download and install it"
    return { title = "Road Trip " .. (u.latestName or "") .. " is available", sub = notes,
      button = "Update", id = { kind = "updateGo" }, dismiss = "dismissedUpdate", dismissValue = u.latest }
  end
end

-- one banner at a time: home app, an update in progress, the guard, then a new version
local function currentBanner()
  if not android.isAndroid then return nil end
  if not state.isHome and not config.get("homeHintDismissed") then
    return { title = "Road Trip isn't your home app yet", sub = "Set it so the Home button opens it",
      button = "Set as home app", id = { kind = "setHome" }, dismiss = "homeHintDismissed" }
  end
  local active = updateBanner(true)
  if active then return active end
  -- an update switched it off: say so even if the first-time hint was dismissed
  if not state.guard.serviceOn and state.guard.offByUpdate then
    return { title = "The update switched off Keep in front", sub = "Android does this to sideloaded apps; one switch turns it back on",
      button = "Turn on", id = { kind = "a11y" } }
  end
  if not state.guard.serviceOn and not config.get("guardHintDismissed") then
    return { title = "Keep Road Trip in front", sub = "Stops the box switching back to its own launcher",
      button = "Turn on", id = { kind = "a11y" }, dismiss = "guardHintDismissed" }
  end
  return updateBanner(false)
end

local function drawBanner(b, y)
  local x, w, h = RAIL + 24, W - RAIL - 48, 72
  ui.rect(ui.c.card, x, y, w, h, 20)
  local right = x + w - 24
  if b.dismiss then
    ui.icon("close", x + w - 52, y + 24, 24, ui.c.muted, 2.2)
    ui.hit({ kind = "dismissBanner", key = b.dismiss, value = b.dismissValue }, x + w - 64, y + 8, 56, 56)
    right = x + w - 64
  end
  if b.button then
    local bw = ui.textWidth(b.button, "bold", 16) + 44
    right = right - 12 - bw
    pill(b.id, b.button, right, y + 12, 48, "accent")
  end
  local textW = right - 24 - (x + 24)
  ui.text(ui.fit(b.title, "bold", 19, textW), "bold", 19, ui.c.text, x + 24, y + 14)
  ui.text(ui.fit(b.sub, "semibold", 15, textW), "semibold", 15, ui.c.muted, x + 24, y + 40)
end

-- a widget slot that isn't built yet: says what it will be, without pretending
local function placeholderWidget(x, y, w, h, title, icon, note)
  ui.rect(ui.c.card, x, y, w, h, 26)
  ui.text(title, "bold", 14, ui.c.muted, x + 22, y + 20)
  local big = math.min(64, h * 0.3)
  ui.icon(icon, x + (w - big) / 2, y + (h - big) / 2 - 10, big, ui.c.dim, 1.4)
  if note then
    ui.text(note, "semibold", 14, ui.c.dim, x + 12, y + h - 38, "center", w - 24)
  end
end

-- prev / play-pause / next as three equal buttons
local function transportRow(x, y, w, h, m)
  local gap = 10
  local bw = (w - gap * 2) / 3
  local items = {
    { action = "prev", icon = "prev", on = m.canPrev ~= false },
    { action = "toggle", icon = m.playing and "pause" or "play", accent = true, on = true },
    { action = "next", icon = "next", on = m.canNext ~= false },
  }
  for i, it in ipairs(items) do
    local bx = x + (i - 1) * (bw + gap)
    ui.rect(it.accent and ui.c.accent or ui.hex("22252A"), bx, y, bw, h, 16)
    local s = math.min(26, h * 0.5)
    local col = it.accent and ui.c.onAccent or (it.on and ui.c.text2 or ui.c.dim)
    ui.icon(it.icon, bx + (bw - s) / 2, y + (h - s) / 2, s, col)
    if it.on then ui.hit({ kind = "media", action = it.action }, bx, y, bw, h) end
  end
end

local function navWidget(x, y, w, h)
  ui.rect(ui.c.card, x, y, w, h, 26)
  local nav = state.nav
  local pad = 28

  -- Road Trip navigating by itself
  local g = map.guidance()
  if g then
    ui.hit({ kind = "openMap" }, x, y, w, h)
    ui.text("Navigation · Road Trip", "bold", 14, ui.c.muted, x + pad, y + 24)
    local sq = math.min(132, h * 0.34)
    local sx, sy = x + pad, y + 64
    ui.rect(ui.c.accent, sx, sy, sq, sq, 28)
    ui.icon(g.icon, sx + sq * 0.2, sy + sq * 0.2, sq * 0.6, ui.c.onAccent, 2.4)
    local tx = sx + sq + 28
    local tw = x + w - pad - tx
    ui.text(ui.fit(g.title, "bold", 46, tw), "bold", 46, ui.c.text, tx, sy + 4)
    ui.text(ui.fit(g.text or "", "semibold", 22, tw), "semibold", 22, ui.hex("C9C6BE"), tx, sy + 70)
    local sub = g.arrival .. " arrival · " .. map.fmtDur(g.remTime) .. " · " .. map.fmtDist(g.remaining)
    ui.rect(ui.c.bg, x + 16, y + h - 16 - 64, w - 32, 64, 20)
    ui.text(ui.fit(sub, "bold", 20, w - 72), "bold", 20, ui.c.text, x + 36, y + h - 16 - 64 + (64 - ui.fontHeight("bold", 20)) / 2)
    return
  end

  if nav.active then
    ui.hit({ kind = "openNav", pkg = nav.pkg }, x, y, w, h)
    ui.text(ui.fit("Navigation · " .. (nav.app or ""), "bold", 14, w - pad * 2), "bold", 14, ui.c.muted, x + pad, y + 24)
    -- the nav app's own turn arrow, on an accent square
    local sq = math.min(132, h * 0.34)
    local sx, sy = x + pad, y + 64
    ui.rect(ui.c.accent, sx, sy, sq, sq, 28)
    local img = navIcon()
    if img then
      local s = (sq * 0.7) / math.max(img:getWidth(), img:getHeight())
      lg.setColor(ui.c.onAccent)
      lg.draw(img, sx + (sq - img:getWidth() * s) / 2, sy + (sq - img:getHeight() * s) / 2, 0, s, s)
    else
      ui.icon("turn", sx + sq * 0.18, sy + sq * 0.18, sq * 0.64, ui.c.onAccent, 2.4)
    end
    local tx = sx + sq + 28
    local tw = x + w - pad - tx
    local title = (nav.title and nav.title ~= "") and nav.title or ("Navigating with " .. (nav.app or "your nav app"))
    ui.text(ui.fit(title, "bold", 46, tw), "bold", 46, ui.c.text, tx, sy + 4)
    ui.text(ui.fit(nav.text or "", "semibold", 22, tw), "semibold", 22, ui.hex("C9C6BE"), tx, sy + 70)
    if nav.sub and nav.sub ~= "" then
      ui.rect(ui.c.bg, x + 16, y + h - 16 - 64, w - 32, 64, 20)
      ui.text(ui.fit(nav.sub, "bold", 20, w - 72), "bold", 20, ui.c.text, x + 36, y + h - 16 - 64 + (64 - ui.fontHeight("bold", 20)) / 2)
    end
    return
  end

  ui.icon("pin", x + pad, y + 28, 40, ui.c.accent, 1.6)
  if not state.media.access then
    ui.text("See your next turn here", "bold", 26, ui.c.text, x + pad, y + 92)
    ui.text(ui.fit("Road Trip reads it from your nav app, using the same access as Now playing", "semibold", 16, w - pad * 2),
      "semibold", 16, ui.c.muted, x + pad, y + 132)
    pill({ kind = "mediaAccess" }, "Allow", x + pad, y + h - pad - 56, 56, "accent")
    return
  end
  ui.text("Where to?", "bold", 26, ui.c.text, x + pad, y + 92)
  ui.text(ui.fit("Navigate with Road Trip's map, or your nav app's next turn shows here", "semibold", 16, w - pad * 2),
    "semibold", 16, ui.c.muted, x + pad, y + 132)
  local bx = x + pad
  bx = bx + pill({ kind = "openMapSearch" }, "Search a place", bx, y + h - pad - 56, 56, "accent") + 12
  for i, app in ipairs(installedNavApps()) do
    if i > 1 then break end
    bx = bx + pill({ kind = "openNav", pkg = app.pkg }, "Open " .. app.label, bx, y + h - pad - 56, 56, "off2") + 12
  end
end

local function weatherWidget(x, y, w, h)
  ui.rect(ui.c.card, x, y, w, h, 26)
  ui.hit({ kind = "cityOpen" }, x, y, w, h)
  local place = config.get("weatherPlace")
  local pad = 20
  if not place then
    ui.icon("sun", x + pad, y + pad, 34, ui.c.accent, 1.6)
    ui.textWrap("Set your city to see the weather", "bold", 16, ui.c.text, x + pad, y + 70, w - pad * 2, 3)
    return
  end
  local wx = state.weather
  if not wx then
    ui.icon("cloud", x + pad, y + pad, 34, ui.c.dim, 1.6)
    ui.text(ui.fit(place.name, "semibold", 13, w - pad * 2), "semibold", 13, ui.c.muted, x + pad, y + 64)
    ui.text(state.weatherBusy and "Loading…" or "No data yet", "semibold", 15, ui.c.muted, x + pad, y + h - pad - 22)
    return
  end
  local label, icon = weatherLook(wx.code, wx.isDay)
  ui.icon(icon, x + pad, y + pad, 34, ui.c.accent, 1.6)
  ui.text(ui.fit(place.name, "semibold", 13, w - pad * 2 - 44), "semibold", 13, ui.c.muted, x + pad + 44, y + pad + 9)
  ui.text(string.format("%d°", math.floor((wx.temp or 0) + 0.5)), "bold", 34, ui.c.text, x + pad, y + h - pad - 92)
  ui.text(ui.fit(label, "semibold", 15, w - pad * 2), "semibold", 15, ui.hex("C9C6BE"), x + pad, y + h - pad - 44)
  if wx.hi and wx.lo then
    ui.text(string.format("%d° / %d°", math.floor(wx.hi + 0.5), math.floor(wx.lo + 0.5)), "semibold", 14, ui.c.muted,
      x + pad, y + h - pad - 22)
  end
end

local function sameDay(t1, t2) return os.date("%Y%m%d", t1) == os.date("%Y%m%d", t2) end

local function calendarWidget(x, y, w, h)
  ui.rect(ui.c.card, x, y, w, h, 26)
  local pad = 20
  local cal = state.cal
  if not cal.permission then
    ui.hit({ kind = "calAllow" }, x, y, w, h)
    ui.icon("calendar", x + pad, y + pad, 30, ui.c.accent, 1.6)
    ui.textWrap("See your next event", "bold", 16, ui.c.text, x + pad, y + 66, w - pad * 2, 2)
    pill({ kind = "calAllow" }, "Allow", x + pad, y + h - pad - 44, 44, "accent")
    return
  end
  local e = cal.events and cal.events[1]
  if not e then
    ui.hit({ kind = "calOpen" }, x, y, w, h)
    ui.icon("calendar", x + pad, y + pad, 30, ui.c.dim, 1.6)
    ui.textWrap("Nothing in the next two days", "semibold", 15, ui.c.muted, x + pad, y + 66, w - pad * 2, 3)
    return
  end
  ui.hit({ kind = "calOpen", at = e.begin }, x, y, w, h)
  local now, begin = os.time(), math.floor((e.begin or 0) / 1000)
  local when
  if e.allDay then
    when = sameDay(begin, now) and "Today" or "Tomorrow"
  else
    when = (sameDay(begin, now) and "" or (sameDay(begin, now + 86400) and "Tomorrow " or os.date("%a ", begin)))
      .. os.date("%H:%M", begin)
  end
  ui.text(ui.fit(when, "bold", 14, w - pad * 2), "bold", 14, ui.c.accent, x + pad, y + pad)
  ui.textWrap(e.title ~= "" and e.title or "Event", "bold", 17, ui.c.text, x + pad, y + pad + 30, w - pad * 2, 3)
  local mins = math.floor((begin - now) / 60)
  local rel
  if e.allDay then rel = "All day"
  elseif mins <= 0 then rel = "Now"
  elseif mins < 60 then rel = "In " .. mins .. " min"
  elseif mins < 24 * 60 then rel = "In " .. math.floor(mins / 60 + 0.5) .. " h"
  else rel = "" end
  if rel ~= "" then ui.text(rel, "semibold", 14, ui.c.muted, x + pad, y + h - pad - 20) end
end

local function nowPlayingWidget(x, y, w, h)
  ui.rect(ui.c.card, x, y, w, h, 26)
  local media = state.media
  local m = media.current
  ui.hit({ kind = "openMedia" }, x, y, w, h)
  ui.text(m and ui.fit(m.app or "Now playing", "bold", 14, w - 44) or "Now playing", "bold", 14, ui.c.muted, x + 22, y + 20)
  local pad = 22
  if not media.access then
    ui.text("See what's playing", "bold", 22, ui.c.text, x + pad, y + 56)
    ui.text(ui.fit("in your music and video apps", "semibold", 15, w - pad * 2), "semibold", 15, ui.c.muted, x + pad, y + 88)
    pill({ kind = "mediaAccess" }, "Allow", x + pad, y + h - 22 - 52, 52, "accent")
    return
  end
  if not m then
    ui.text("Nothing playing", "bold", 22, ui.c.text, x + pad, y + 56)
    ui.text(ui.fit("Start music in any app", "semibold", 15, w - pad * 2), "semibold", 15, ui.c.muted, x + pad, y + 88)
    return
  end
  ui.text(ui.fit(m.title ~= "" and m.title or (m.app or ""), "bold", 24, w - pad * 2), "bold", 24, ui.c.text, x + pad, y + 50)
  ui.text(ui.fit(m.artist or "", "semibold", 16, w - pad * 2), "semibold", 16, ui.hex("B8B5AD"), x + pad, y + 84)
  local dur = m.durationMs or 0
  if dur > 0 then
    local by = y + h - 22 - 52 - 18
    ui.rect(ui.hex("2C2E33"), x + pad, by, w - pad * 2, 4, 2)
    ui.rect(ui.c.accent, x + pad, by, (w - pad * 2) * (mediaPos(m) / dur), 4, 2)
  end
  transportRow(x + pad, y + h - 22 - 52, w - pad * 2, 52, m)
end

local function drawFavorites(x, y, w, h)
  ui.rect(ui.c.card, x, y, w, h, 26)
  local favs = favoriteApps()
  local editX = x + w - 14 - 60
  ui.circle(ui.c.chipHi, editX + 30, y + h / 2, 30)
  ui.icon("edit", editX + 18, y + h / 2 - 12, 24, ui.c.muted, 2)
  ui.hit({ kind = "editFavs" }, editX, y + (h - 60) / 2, 60, 60)

  if #favs == 0 then
    if state.firstLoad then return end -- apps not loaded yet
    ui.text("Pick 3 to 5 favorite apps to keep them here", "semibold", 17, ui.c.muted, x + 28, y + (h - ui.fontHeight("semibold", 17)) / 2)
    ui.hit({ kind = "editFavs" }, x, y, w - 90, h)
    return
  end

  -- share the room between pills; labels shorten if they must
  local room = editX - 14 - (x + 14) - 14 * (#favs - 1)
  local each = room / #favs
  local px = x + 14
  local ph = 76
  local py = y + (h - ph) / 2
  for _, app in ipairs(favs) do
    local labelMax = math.max(40, each - (8 + 60 + 12 + 22))
    local label = ui.fit(app.label, "bold", 17, labelMax)
    local pw = math.min(each, 8 + 60 + 12 + ui.textWidth(label, "bold", 17) + 22)
    local down = press and not press.moved and press.id and press.id.kind == "fav" and press.id.app == app
    ui.rect(down and ui.c.tileOn or ui.c.chipHi, px, py, pw, ph, ph / 2)
    ui.circle(ui.c.tile, px + 38, py + ph / 2, 30)
    ui.ring(down and ui.c.accent or ui.c.ring, px + 38, py + ph / 2, 30, 2)
    drawAppIcon(app, px + 38, py + ph / 2, 30)
    ui.text(label, "bold", 17, ui.c.text2, px + 80, py + (ph - ui.fontHeight("bold", 17)) / 2)
    ui.hit({ kind = "fav", app = app }, px, py, pw, ph)
    px = px + pw + 14
  end
end

local function drawHome()
  local y = TOP + 24
  local banner = currentBanner()
  if banner then
    drawBanner(banner, y)
    y = y + 92
  end
  local favH = 104
  local bottom = H - 24 - favH - 16
  local x, w = RAIL + 24, W - RAIL - 48
  local gap = 20
  local colW = (w - gap * 2) / 3
  local rowH = (bottom - y - gap) / 2

  navWidget(x, y, colW * 2 + gap, rowH * 2 + gap)
  local rx = x + (colW + gap) * 2
  nowPlayingWidget(rx, y, colW, rowH)
  local halfW = (colW - gap) / 2
  weatherWidget(rx, y + rowH + gap, halfW, rowH)
  calendarWidget(rx + halfW + gap, y + rowH + gap, halfW, rowH)

  drawFavorites(x, H - 24 - favH, w, favH)
end

----------------------------------------------------------------------------------------------
-- Apps
----------------------------------------------------------------------------------------------

local function drawApps()
  local top = TOP + 24
  local area = { x = RAIL, w = W - RAIL, top = top + 20, bottom = H - 44 }
  drawPagedGrid("apps", area, 64, function(app, cx, cy, r)
    local down = pressedTile(app)
    ui.circle(down and ui.c.tileOn or ui.c.tile, cx, cy, r)
    ui.ring(down and ui.c.accent or ui.c.ring, cx, cy, r, 2)
    drawAppIcon(app, cx, cy, r)
    local maxW = r * 2 + 48
    ui.text(ui.fit(app.label, "semibold", 19, maxW), "semibold", 19, ui.c.text2, cx - maxW / 2, cy + r + 12, "center", maxW)
  end)
end

----------------------------------------------------------------------------------------------
-- Media (now playing)
----------------------------------------------------------------------------------------------

local function drawMedia()
  local media = state.media
  local m = media.current
  local cx0, cw = RAIL, W - RAIL
  local midY = TOP + (H - TOP) / 2

  if not media.access then
    local w, h = 640, 268
    local x, y = cx0 + (cw - w) / 2, midY - h / 2
    ui.rect(ui.c.card, x, y, w, h, 28)
    ui.icon("media", x + 32, y + 34, 40, ui.c.accent, 1.6)
    ui.text("See what's playing", "bold", 28, ui.c.text, x + 32, y + 92)
    ui.text("Road Trip needs notification access to show and control music,", "semibold", 16, ui.hex("B8B5AD"), x + 32, y + 138)
    ui.text("podcasts and video from your apps. It only reads what's playing.", "semibold", 16, ui.hex("B8B5AD"), x + 32, y + 162)
    pill({ kind = "mediaAccess" }, "Allow", x + 32, y + h - 32 - 56, 56, "accent")
    return
  end

  if not m then
    local th = ui.fontHeight("bold", 28)
    ui.text("Nothing is playing", "bold", 28, ui.c.text, cx0, midY - th, "center", cw)
    ui.text("Start music in any app and it shows up here.", "semibold", 17, ui.c.muted, cx0, midY + 12, "center", cw)
    return
  end

  -- artwork
  local size = math.min(420, H - TOP - 88)
  local ax, ay = cx0 + 56, TOP + (H - TOP - size) / 2
  ui.rect(ui.hex("2A2620"), ax, ay, size, size, 28)
  local img = artImage(m)
  if img then
    local inset = 14
    local s = math.min((size - inset * 2) / img:getWidth(), (size - inset * 2) / img:getHeight())
    local iw, ih = img:getWidth() * s, img:getHeight() * s
    lg.setColor(1, 1, 1, 1)
    lg.draw(img, ax + (size - iw) / 2, ay + (size - ih) / 2, 0, s, s)
  else
    local is = size * 0.28
    ui.icon("media", ax + (size - is) / 2, ay + (size - is) / 2, is, ui.c.accent, 1.2)
  end

  -- details
  local x1 = ax + size + 56
  local w1 = W - 56 - x1
  local yy = ay + math.max(0, (size - 340) / 2)
  ui.text(ui.fit("Playing from " .. (m.app or ""), "bold", 15, w1), "bold", 15, ui.c.accent, x1, yy)
  ui.text(ui.fit(m.title ~= "" and m.title or (m.app or ""), "bold", 40, w1), "bold", 40, ui.c.text, x1, yy + 26)
  ui.text(ui.fit(m.artist or "", "semibold", 22, w1), "semibold", 22, ui.hex("B8B5AD"), x1, yy + 84)

  local dur = m.durationMs or 0
  local by = yy + 152
  if dur > 0 then
    local pos = mediaPos(m)
    local frac = pos / dur
    ui.rect(ui.hex("2C2E33"), x1, by, w1, 6, 3)
    ui.rect(ui.c.accent, x1, by, w1 * frac, 6, 3)
    ui.circle(ui.c.text, x1 + w1 * frac, by + 3, 10)
    ui.text(fmtTime(pos), "semibold", 15, ui.c.muted, x1, by + 20)
    ui.text("-" .. fmtTime(dur - pos), "semibold", 15, ui.c.muted, x1, by + 20, "right", w1)
    if m.canSeek then ui.hit({ kind = "seek", x = x1, w = w1, dur = dur }, x1, by - 20, w1, 46) end
  end

  -- controls
  local cy = by + 120
  local total = 88 + 36 + 112 + 36 + 88
  local bx = x1 + (w1 - total) / 2
  local function round(action, icon, r, accent, on)
    local ccx = bx + r
    ui.circle(accent and ui.c.accent or ui.c.chip, ccx, cy, r)
    local s = r * 0.8
    ui.icon(icon, ccx - s / 2, cy - s / 2, s, accent and ui.c.onAccent or (on and ui.c.text2 or ui.c.dim))
    if on then ui.hit({ kind = "media", action = action }, ccx - r, cy - r, r * 2, r * 2) end
    bx = bx + r * 2 + 36
  end
  round("prev", "prev", 44, false, m.canPrev ~= false)
  round("toggle", m.playing and "pause" or "play", 56, true, true)
  round("next", "next", 44, false, m.canNext ~= false)
end

----------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------

local function toggle(id, on, x, y)
  ui.rect(on and ui.c.accent or ui.hex("34363B"), x, y, 60, 34, 17)
  ui.circle(ui.c.text, on and (x + 60 - 17) or (x + 17), y + 17, 13)
  ui.hit(id, x - 10, y - 15, 80, 64)
end

-- rows: { title, sub, button = {label, id, style?}, toggle = {on, id}, swatches = true }
local function settingsCard(title, rows, x, y, w)
  local rowH = #rows > 6 and 72 or 80
  local h = 64 + #rows * rowH + 8
  ui.rect(ui.c.card, x, y, w, h, 26)
  ui.text(title, "bold", 14, ui.c.muted, x + 24, y + 24)
  local ry = y + 56
  for i, r in ipairs(rows) do
    if i > 1 then ui.rect(ui.c.line, x + 24, ry, w - 48, 1) end
    local right = x + w - 24
    local cy = ry + rowH / 2
    if r.button then
      local bw = ui.textWidth(r.button[1], "bold", 16) + 44
      right = right - bw
      pill(r.button[2], r.button[1], right, cy - 24, 48, r.button[3] or "off2")
    elseif r.toggle then
      right = right - 60
      toggle(r.toggle[2], r.toggle[1], right, cy - 17)
    elseif r.swatches then
      local n = #ui.accents
      right = right - (n * 52 - 12)
      for j, a in ipairs(ui.accents) do
        local sx = right + (j - 1) * 52 + 20
        local cur = (config.get("accent") or ""):lower() == a.hex:lower()
        if cur then ui.ring(ui.c.text, sx, cy, 23, 3) end
        ui.circle(ui.hex(a.hex:sub(2)), sx, cy, 18)
        ui.hit({ kind = "accent", hex = a.hex }, sx - 24, cy - 24, 48, 48)
      end
    end
    local tw = right - 20 - (x + 24)
    local ty = r.sub and (cy - 26) or (cy - ui.fontHeight("bold", 18) / 2)
    ui.text(ui.fit(r.title, "bold", 18, tw), "bold", 18, ui.c.text, x + 24, ty)
    if r.sub then ui.text(ui.fit(r.sub, "semibold", 14, tw), "semibold", 14, ui.c.muted, x + 24, cy + 4) end
    ry = ry + rowH
  end
end

local function drawSettings()
  local g = state.guard
  local guardSub, guardRow
  if not g.serviceOn then
    guardSub = g.offByUpdate and "Switched off by the last update" or "Off: the box can switch back to its own launcher"
    guardRow = { title = "Keep in front", sub = guardSub, button = { "Turn on", { kind = "a11y" }, "accent" } }
  else
    guardRow = { title = "Keep in front", sub = g.enabled and "On: Road Trip returns if the box switches launcher" or "Paused",
      toggle = { g.enabled ~= false, { kind = g.enabled and "guardOff" or "guardOn" } } }
  end
  local left = {
    guardRow,
    { title = "Keep in front after updates",
      sub = g.canRestore and "Switches itself back on after each update"
        or "Turn back on by hand, or allow it once with adb (see the website)" },
    { title = "Now playing and navigation",
      sub = state.media.access and "Allowed: reads what's playing and your next turn" or "Needs notification access",
      button = state.media.access and { "Open", { kind = "mediaAccess" } } or { "Allow", { kind = "mediaAccess" }, "accent" } },
    { title = "Calendar", sub = state.cal.permission and "Allowed: your next event shows on Home" or "Show your next event on Home",
      button = not state.cal.permission and { "Allow", { kind = "calAllow" }, "accent" } or nil },
    { title = "Home app", sub = state.isHome and "Road Trip opens when you press Home" or "Road Trip isn't the home app yet",
      button = { "Change", { kind = "setHome" } } },
    { title = "The box's own launcher", sub = "Open it for 2 minutes without Road Trip stepping in",
      button = #(g.stock or {}) > 0 and { "Open", { kind = "stock" } } or nil },
  }
  local u = state.update
  local right = {
    { title = "Favorite apps", sub = #favoriteApps() .. " of " .. FAV_MAX .. " picked", button = { "Edit", { kind = "editFavs" } } },
    { title = "Accent colour", swatches = true },
    { title = "Weather", sub = config.get("weatherPlace") and config.get("weatherPlace").name or "Pick your city",
      button = { config.get("weatherPlace") and "Change" or "Set", { kind = "cityOpen" } } },
    { title = "Updates", sub = "Version " .. ((u.currentName and u.currentName ~= "") and u.currentName or "?"),
      button = { "Check now", { kind = "updateCheckNow" } } },
    { title = "Check for updates on Wi-Fi only", sub = "Automatic checks, every 6 hours",
      toggle = { config.get("updateWifiOnly") ~= false, { kind = "wifiOnly" } } },
    { title = "Diagnostics", sub = "What Keep in front saw and did", button = { "Show", { kind = "diag" } } },
    { title = "About Road Trip", sub = "mightyx3n.github.io/road-trip", button = { "Website", { kind = "site" } } },
  }
  local x, y = RAIL + 24, TOP + 24
  local colW = (W - RAIL - 48 - 20) / 2
  settingsCard("Road Trip on this box", left, x, y, colW)
  settingsCard("Yours", right, x + colW + 20, y, colW)
end

local function drawDiagnostics()
  local d = state.diag or {}
  local x, y = RAIL + 32, TOP + 24
  pill({ kind = "diagBack" }, "Back to Settings", x - 8, y, 48, "off2")
  ui.text("Diagnostics", "bold", 22, ui.c.text, x + 220, y + 10)
  y = y + 68
  ui.text(ui.fit("Default home app: " .. (d.defaultHome or "?"), "semibold", 14, W - x - 32), "semibold", 14, ui.c.text2, x, y)
  local watched = table.concat(d.watched or {}, ", ")
  ui.text(ui.fit("Keep in front watches: " .. (watched ~= "" and watched or "nothing"), "semibold", 14, W - x - 32),
    "semibold", 14, ui.c.text2, x, y + 24)
  y = y + 64
  local colW = (W - x - 32 - 24) / 2
  local function list(title, lines, lx)
    ui.text(title, "bold", 14, ui.c.muted, lx, y)
    local ly = y + 28
    if not lines or #lines == 0 then ui.text("Nothing yet", "semibold", 13, ui.c.dim, lx, ly) end
    for _, line in ipairs(lines or {}) do
      if ly > H - 28 then break end
      ui.text(ui.fit(line, "semibold", 13, colW), "semibold", 13, ui.c.text2, lx, ly)
      ly = ly + 21
    end
  end
  list("Screen changes (newest first)", d.guard, x)
  list("Navigation notifications", d.nav, x + colW + 24)
end

local function drawCityDialog()
  local c = state.city
  if not c then return end
  lg.setColor(0, 0, 0, 0.6)
  lg.rectangle("fill", 0, 0, W, H)
  ui.hit({ kind = "cityBlock" }, 0, 0, W, H)
  local w = math.min(720, W - 80)
  local results = c.results or {}
  local h = 164 + (#results > 0 and (#results * 64 + 12) or 0) + (c.err and 36 or 0)
  local x, y = (W - w) / 2, 32 -- near the top: the keyboard covers the bottom half
  ui.rect(ui.c.card, x, y, w, h, 28)
  ui.hit({ kind = "cityBlock" }, x, y, w, h)
  ui.text("Weather location", "bold", 22, ui.c.text, x + 28, y + 24)
  ui.icon("close", x + w - 52, y + 24, 24, ui.c.muted, 2.2)
  ui.hit({ kind = "cityCancel" }, x + w - 64, y + 12, 56, 56)

  local fx, fy, fw = x + 28, y + 76, w - 56 - 140
  ui.rect(ui.c.bg, fx, fy, fw, 60, 18)
  ui.hit({ kind = "cityField" }, fx, fy, fw, 60)
  local shown = c.text ~= "" and c.text or "Type a city or town"
  local blink = math.floor(love.timer.getTime() * 2) % 2 == 0
  ui.text(ui.fit(shown, "semibold", 19, fw - 40) .. ((c.text ~= "" and blink) and "|" or ""), "semibold", 19,
    c.text ~= "" and ui.c.text or ui.c.dim, fx + 20, fy + (60 - ui.fontHeight("semibold", 19)) / 2)
  pill({ kind = "citySearch" }, c.busy and "…" or "Search", fx + fw + 16, fy + 4, 52, "accent")

  local ry = fy + 76
  if c.err then
    ui.text(c.err, "semibold", 15, ui.hex("F09A8A"), x + 28, ry)
    ry = ry + 36
  end
  for i, r in ipairs(results) do
    local label = r.name .. ((r.admin1 and r.admin1 ~= "") and (", " .. r.admin1) or "") .. (r.country and (", " .. r.country) or "")
    ui.rect(ui.c.chipHi, x + 20, ry, w - 40, 56, 18)
    ui.icon("pin", x + 36, ry + 16, 24, ui.c.accent, 1.8)
    ui.text(ui.fit(label, "bold", 17, w - 120), "bold", 17, ui.c.text2, x + 72, ry + (56 - ui.fontHeight("bold", 17)) / 2)
    ui.hit({ kind = "cityPick", i = i }, x + 20, ry, w - 40, 56)
    ry = ry + 64
  end
end

----------------------------------------------------------------------------------------------
-- Favorites picker (first launch and edit)
----------------------------------------------------------------------------------------------

local function pickIndex(app)
  local k = keyOf(app)
  for i, p in ipairs(state.pick) do
    if p == k then return i end
  end
end

local function drawPicker()
  local px = 56
  local setup = state.favsMode == "setup"
  ui.text(setup and "Welcome to Road Trip" or "Favorite apps", "bold", 15, ui.c.accent, px, 32)
  ui.text("Pick your favorite apps", "bold", 34, ui.c.text, px, 54)
  ui.text("Choose 3 to 5. They sit along the bottom of your home screen, one tap away.", "semibold", 16, ui.c.muted, px, 106)

  local area = { x = px - 24, w = W - px * 2 + 48, top = 150, bottom = H - 120, maxCols = 6, cellMin = 180 }
  drawPagedGrid("favs", area, 54, function(app, cx, cy, r)
    local n = pickIndex(app)
    local down = pressedTile(app)
    ui.circle((n or down) and ui.hex("1E1A13") or ui.c.tile, cx, cy, r)
    ui.ring(n and ui.c.accent or ui.c.ring, cx, cy, r, n and 3 or 2)
    drawAppIcon(app, cx, cy, r)
    if n then
      local bx, by = cx + r * 0.72, cy - r * 0.72
      ui.circle(ui.c.bg, bx, by, 20)
      ui.circle(ui.c.accent, bx, by, 17)
      ui.text(tostring(n), "bold", 16, ui.c.onAccent, bx - 17, by - ui.fontHeight("bold", 16) / 2, "center", 34)
    end
    local maxW = r * 2 + 40
    ui.text(ui.fit(app.label, "semibold", 17, maxW), "semibold", 17, n and ui.c.text or ui.hex("B8B5AD"), cx - maxW / 2, cy + r + 12, "center", maxW)
  end)

  local by = H - 32 - 64
  pill({ kind = "pickerBack" }, setup and "Skip for now" or "Cancel", px - 28, by, 64, nil)
  local count = #state.pick
  local ready = count >= FAV_MIN
  local label = setup and "Continue" or "Done"
  local bw = ui.textWidth(label, "bold", 18) + 72
  local bx = W - px - bw
  pill(ready and { kind = "pickerDone" } or { kind = "pickerNotReady" }, label, bx, by, 64, ready and "primary" or "off")
  local info = count .. " of " .. FAV_MAX .. " picked"
  local iw = ui.textWidth(info, "semibold", 16)
  ui.text(info, "semibold", 16, ui.c.muted, bx - 20 - iw, by + (64 - ui.fontHeight("semibold", 16)) / 2)
end

----------------------------------------------------------------------------------------------
-- long-press menu and toast
----------------------------------------------------------------------------------------------

local function appMenu(app)
  local fav = isFavorite(app)
  local full = not fav and #favoriteApps() >= FAV_MAX
  return {
    title = app.label, app = app,
    rows = {
      { id = { kind = fav and "unfav" or "fav+", app = app }, icon = fav and "close" or "plus",
        label = fav and "Remove from favorites" or (full and "Favorites are full (5)" or "Add to favorites"), off = full },
      { id = { kind = "appInfo", app = app }, icon = "edit", label = "App info" },
    },
  }
end

local function launcherMenu()
  local g = state.guard
  local rows = {}
  if #(g.stock or {}) > 0 then
    rows[#rows + 1] = { id = { kind = "stock" }, icon = "home", label = "Open the box's launcher for 2 minutes" }
  else
    rows[#rows + 1] = { icon = "home", label = "No other launcher found", off = true }
  end
  if not g.serviceOn then
    rows[#rows + 1] = { id = { kind = "a11y" }, icon = "check", label = "Turn on Keep in front" }
  elseif g.enabled then
    rows[#rows + 1] = { id = { kind = "guardOff" }, icon = "close", label = "Keep in front is on · turn off" }
  else
    rows[#rows + 1] = { id = { kind = "guardOn" }, icon = "check", label = "Keep in front is off · turn on" }
  end
  rows[#rows + 1] = { id = { kind = "updateCheckNow" }, icon = "check", label = "Check for updates" }
  rows[#rows + 1] = { id = { kind = "setHome" }, icon = "edit", label = "Default home app" }
  local v = state.update.currentName
  return { title = (v and v ~= "") and ("Road Trip " .. v) or "Road Trip", rows = rows }
end

-- Android 13+ hides accessibility for sideloaded apps behind "Allow restricted settings".
-- Rows don't close the menu, so it's still there when you come back between steps.
local function restrictedMenu()
  return {
    title = "Turn on Keep in front", restricted = true, w = 640,
    rows = {
      { id = { kind = "a11yOpen" }, icon = "check", label = "1 · Accessibility → tap Road Trip once" },
      { id = { kind = "selfInfo" }, icon = "edit", label = "2 · App info → menu → Allow restricted settings" },
      { id = { kind = "a11yOpen" }, icon = "check", label = "3 · Accessibility → switch it on" },
    },
  }
end

local function drawMenu()
  local m = state.menu
  if not m then return end
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 0, 0, W, H)
  ui.hit({ kind = "menuClose" }, 0, 0, W, H)

  local w = m.w or 500
  local h = 108 + #m.rows * 76 + 8
  local x, y = (W - w) / 2, (H - h) / 2
  ui.rect(ui.c.card, x, y, w, h, 28)
  ui.hit({ kind = "menuBody" }, x, y, w, h)
  local tx = x + 28
  if m.app then
    ui.circle(ui.c.tile, x + 56, y + 56, 30)
    ui.ring(ui.c.ring, x + 56, y + 56, 30, 2)
    drawAppIcon(m.app, x + 56, y + 56, 30)
    tx = x + 102
  end
  ui.text(ui.fit(m.title, "bold", 22, x + w - 28 - tx), "bold", 22, ui.c.text, tx, y + 42)

  local ry = y + 108
  for _, row in ipairs(m.rows) do
    local color = row.off and ui.c.dim or ui.c.text2
    ui.rect(ui.c.chipHi, x + 20, ry, w - 40, 64, 18)
    ui.icon(row.icon, x + 40, ry + 20, 24, row.off and ui.c.dim or ui.c.accent, 2)
    ui.text(row.label, "bold", 18, color, x + 82, ry + (64 - ui.fontHeight("bold", 18)) / 2)
    if not row.off and row.id then ui.hit(row.id, x + 20, ry, w - 40, 64) end
    ry = ry + 76
  end
end

local function drawToast()
  local t = state.toast
  if not t then return end
  if love.timer.getTime() > t.untilT then state.toast = nil return end
  local w = ui.textWidth(t.text, "bold", 16) + 48
  local x, y = (W - w) / 2, H - 150
  ui.rect(ui.hex("2C2E33"), x, y, w, 52, 26)
  ui.text(t.text, "bold", 16, ui.c.text, x, y + (52 - ui.fontHeight("bold", 16)) / 2, "center", w)
end

----------------------------------------------------------------------------------------------
-- frame
----------------------------------------------------------------------------------------------

local function drawPlaceholder(label)
  local th = ui.fontHeight("semibold", 19)
  ui.text(label, "semibold", 19, ui.c.muted, RAIL, (H + TOP - th) / 2, "center", W - RAIL)
end

function love.draw()
  ui.beginFrame()
  lg.push()
  lg.scale(ui.S)
  if state.screen == "favs" then
    drawPicker()
  else
    if state.screen == "home" then drawHome()
    elseif state.screen == "apps" then drawApps()
    elseif state.screen == "settings" then drawSettings()
    elseif state.screen == "diag" then drawDiagnostics()
    elseif state.screen == "map" then
      map.drawMap(RAIL, 0, W - RAIL, H)
      map.drawUI(RAIL, 0, W - RAIL, H)
    else drawMedia() end
    if state.screen ~= "map" then drawTopBar() end -- the map runs edge to edge
    drawRail()
  end
  drawMenu()
  drawCityDialog()
  drawToast()
  lg.pop()
  state.drew = true
end

----------------------------------------------------------------------------------------------
-- input (touch arrives as mouse events on Android too)
----------------------------------------------------------------------------------------------

local function launch(app)
  local ok, err = android.launch(app)
  if not ok then state.error = err or ("Couldn't open " .. app.label) end
end

local function togglePick(app)
  local i = pickIndex(app)
  if i then
    table.remove(state.pick, i)
  elseif #state.pick >= FAV_MAX then
    toast("You can pick up to " .. FAV_MAX)
  else
    state.pick[#state.pick + 1] = keyOf(app)
  end
end

local function activate(id, vx)
  local k = id.kind
  if k == "cityBlock" then return
  elseif k == "cityOpen" then openCity()
  elseif k == "cityCancel" then closeCity()
  elseif k == "cityField" then love.keyboard.setTextInput(true)
  elseif k == "citySearch" then searchCity()
  elseif k == "cityPick" then
    local r = state.city and state.city.results and state.city.results[id.i]
    if r then
      config.set("weatherPlace", { name = r.name, country = r.country, lat = r.latitude, lon = r.longitude })
      state.weather = nil
      closeCity()
      refreshWeather(true)
      toast("Weather for " .. r.name)
    end
  elseif k == "calAllow" then
    android.calendarAllow()
  elseif k == "calOpen" then
    android.calendarOpen(id.at)
  elseif k == "diag" then
    state.screen = "diag"
    state.diag = android.diagnostics()
  elseif k == "diagBack" then state.screen = "settings"
  elseif k == "media" then mediaCommand(id.action)
  elseif k == "seek" then
    local frac = math.max(0, math.min(1, ((vx or id.x) - id.x) / id.w))
    mediaCommand("seek", math.floor(frac * id.dur))
  elseif k == "openMedia" then state.screen = "media"
  elseif k == "openNav" then launch({ pkg = id.pkg, label = "the nav app" })
  elseif k == "accent" then
    config.set("accent", id.hex)
    ui.setAccent(id.hex)
  elseif k == "wifiOnly" then config.set("updateWifiOnly", config.get("updateWifiOnly") == false)
  elseif k == "site" then love.system.openURL("https://mightyx3n.github.io/road-trip/")
  elseif k == "mediaAccess" then
    android.openMediaAccess()
    toast("Switch on Road Trip: now playing")
  elseif k == "tile" and id.grid == "favs" then togglePick(id.app)
  elseif k == "tile" or k == "fav" then launch(id.app)
  elseif k:sub(1, 4) == "map:" then map.activate(id)
  elseif k == "openMap" or k == "openMapSearch" then
    state.screen = "map"
    map.open()
    if k == "openMapSearch" then map.openSearch() end
  elseif k == "rail" then
    state.screen = id.screen
    if id.screen == "map" then map.open() end
  elseif k == "voice" then android.voice()
  elseif k == "setHome" then
    state.menu = nil
    android.openHomeSettings()
  elseif k == "dismissBanner" then
    if id.value ~= nil then config.set(id.key, id.value) else config.set(id.key, true) end
  elseif k == "updateGo" then
    if android.updateDownload() then state.update.state = "downloading" end
  elseif k == "updateInstall" then
    android.updateInstall()
  elseif k == "updateCheckNow" then
    state.menu = nil
    checkForUpdate(true)
  elseif k == "a11y" then
    if (state.guard.sdk or 0) >= 33 then
      state.menu = restrictedMenu()
    else
      state.menu = nil
      android.openAccessibilitySettings()
      toast("Find Road Trip: keep in front and turn it on")
    end
  elseif k == "a11yOpen" then
    android.openAccessibilitySettings()
  elseif k == "selfInfo" then
    android.openAppInfo({ pkg = "self" })
  elseif k == "stock" then
    state.menu = nil
    android.openStockLauncher()
  elseif k == "guardOff" or k == "guardOn" then
    android.setGuardEnabled(k == "guardOn")
    state.guard.enabled = k == "guardOn"
    state.menu = nil
    toast(k == "guardOn" and "Keep in front is on" or "Keep in front is off")
  elseif k == "editFavs" then openPicker("edit")
  elseif k == "pickerBack" then
    if state.favsMode == "setup" and config.get("favorites") == nil then saveFavorites({}) end
    state.screen = "home"
  elseif k == "pickerNotReady" then toast("Pick at least " .. FAV_MIN)
  elseif k == "pickerDone" then
    saveFavorites(state.pick)
    state.screen = "home"
  elseif k == "menuClose" then state.menu = nil
  elseif k == "fav+" then
    local keys = {}
    for _, a in ipairs(favoriteApps()) do keys[#keys + 1] = keyOf(a) end
    keys[#keys + 1] = keyOf(id.app)
    saveFavorites(keys)
    state.menu = nil
    toast("Added to favorites")
  elseif k == "unfav" then
    local keys = {}
    for _, a in ipairs(favoriteApps()) do
      if a ~= id.app then keys[#keys + 1] = keyOf(a) end
    end
    saveFavorites(keys)
    state.menu = nil
    toast("Removed from favorites")
  elseif k == "appInfo" then
    state.menu = nil
    android.openAppInfo(id.app)
  end
  state.dirty = true
end

local function burst() state.burstUntil = love.timer.getTime() + 2 end

-- Home button: like any launcher, go to the Home screen and close whatever is open
local function goHome()
  if state.screen == "favs" and state.favsMode == "setup" and config.get("favorites") == nil then
    saveFavorites({})
  end
  state.menu = nil
  if state.city then closeCity() end
  if map.wantsText() then map.back() end
  state.screen = "home"
  state.dirty = true
end

local function sameTarget(a, b)
  return a and b and a.kind == b.kind and a.app == b.app and a.screen == b.screen and a.grid == b.grid
end

local function pagerAt(vx, vy)
  if state.menu then return nil end
  local id = state.screen == "apps" and "apps" or state.screen == "favs" and "favs" or nil
  local g = id and state.pagerArea[id]
  if g and vx > g.x0 and vx < g.x0 + g.cw and vy > g.top - 40 and vy < g.bottom + 30 then return id end
end

function love.mousepressed(x, y, button)
  if button ~= 1 then return end
  local vx, vy = x / ui.S, y / ui.S
  local pager = pagerAt(vx, vy)
  press = {
    x = vx, y = vy, t = love.timer.getTime(),
    id = ui.hitAt(vx, vy),
    moved = false,
    pager = pager,
    startX = pager and state.pagers[pager].x,
  }
end

function love.mousemoved(x, y)
  if not press or press.done then return end
  local vx, vy = x / ui.S, y / ui.S
  local dx = vx - press.x
  if math.abs(dx) > 12 or math.abs(vy - press.y) > 12 then press.moved = true end
  if press.moved and press.id and press.id.kind == "map:pan" then
    map.pan(vx - (press.lastX or press.x), vy - (press.lastY or press.y))
    press.lastX, press.lastY = vx, vy
    state.dirty = true
    return
  end
  if press.pager and press.moved then
    local g = state.pagerArea[press.pager]
    local maxX = pageCount(g) - 1
    local pos = press.startX - dx / g.cw
    if pos < 0 then pos = pos * 0.3 elseif pos > maxX then pos = maxX + (pos - maxX) * 0.3 end
    state.pagers[press.pager].x = pos
  end
end

function love.mousereleased(x, y, button)
  if button ~= 1 or not press then return end
  local p = press
  press = nil
  state.dirty = true
  if p.done then return end
  local vx, vy = x / ui.S, y / ui.S
  if p.moved then
    if p.pager then
      local g = state.pagerArea[p.pager]
      local dx = vx - p.x
      local dt = math.max(0.016, love.timer.getTime() - p.t)
      local fling = math.abs(dx) / dt > 600
      local target = math.floor(p.startX + 0.5)
      if dx < -80 or (fling and dx < 0) then target = target + 1
      elseif dx > 80 or (fling and dx > 0) then target = target - 1 end
      state.pagers[p.pager].page = math.max(1, math.min(pageCount(g), target + 1))
    end
  else
    local id = ui.hitAt(vx, vy)
    if sameTarget(id, p.id) then activate(id, vx) end
  end
end

function love.textinput(t)
  if state.screen == "map" and map.wantsText() then
    map.textinput(t)
    state.dirty = true
    return
  end
  if state.city then
    state.city.text = state.city.text .. t
    state.dirty = true
  end
end

function love.keypressed(key)
  if state.screen == "map" and map.wantsText() then
    map.keypressed(key)
    state.dirty = true
    return
  end
  if state.city then
    if key == "backspace" then
      local u8 = require("utf8")
      local off = u8.offset(state.city.text, -1)
      if off then state.city.text = state.city.text:sub(1, off - 1) end
    elseif key == "return" or key == "kpenter" then
      searchCity()
    elseif key == "escape" then
      closeCity()
    end
    state.dirty = true
    return
  end
  if key ~= "escape" then return end
  -- Android's back button arrives as "escape"
  if state.screen == "diag" then
    state.screen = "settings"
  elseif state.screen == "map" and not state.menu and map.back() then
    -- closed the map's search or route overview
  elseif state.menu then
    state.menu = nil
  elseif state.screen == "favs" then
    activate({ kind = "pickerBack" })
  elseif state.screen ~= "home" then
    state.screen = "home"
  elseif not android.isAndroid then
    love.event.quit()
  end
  state.dirty = true
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
  map.init({ android = android, config = config, ui = ui,
    app = { toast = toast, dirty = function() state.dirty = true end } })
  -- show a frame first, load apps right after (see love.update)
  state.needRefresh, state.firstLoad, state.drew = true, true, false
  burst()
end

function love.resize(w, h) layout(w, h) end

function love.focus(f)
  -- back from an app: draw straight away, then catch installs, removals, home changes
  if f then
    state.needRefresh, state.drew = true, false
    burst()
  end
end

function love.visible(v)
  if v then burst() end
end

function love.update(dt)
  map.update(dt, state.screen == "map")
  if state.needRefresh and state.drew then
    state.needRefresh = false
    refreshApps()
    if state.firstLoad then
      state.firstLoad = false
      local n = android.homePresses()
      state.homeSeen = type(n) == "number" and n or 0
      if config.get("favorites") == nil then openPicker("setup") end
      checkForUpdate(false)
    end
  end

  local t = state.timers
  t.update, t.guard, t.autoCheck, t.home = t.update + dt, t.guard + dt, t.autoCheck + dt, t.home + dt
  -- background downloads (weather, city search)
  t.fetch = t.fetch + dt
  if next(state.pending) and t.fetch > 0.2 then
    t.fetch = 0
    pollFetches()
  end
  -- weather and calendar: check once a minute (weather itself refreshes every 30 minutes)
  t.slow = t.slow + dt
  if t.slow > 60 then
    t.slow = 0
    refreshWeather(false)
    if state.screen == "home" then refreshCalendar() end
  end
  if state.screen == "diag" then
    t.diag = t.diag + dt
    if t.diag > 1 then
      t.diag = 0
      state.diag = android.diagnostics()
      state.dirty = true
    end
  end
  -- what's playing: once a second while it's on screen (Home's widget or Media)
  if state.screen == "home" or state.screen == "media" then
    t.media = t.media + dt
    if t.media > 1 then
      t.media = 0
      pollMedia()
    end
  end
  if state.homeSeen and t.home > 0.25 then
    t.home = 0
    local n = android.homePresses()
    if type(n) == "number" and n ~= state.homeSeen then
      state.homeSeen = n
      goHome()
      burst()
    end
  end
  local us = state.update.state
  if (us == "checking" or us == "downloading") and t.update > 0.5 then
    t.update = 0
    pollUpdate()
  end
  -- turning the guard on happens in Settings; notice it even if no focus event arrives
  if android.isAndroid and not state.guard.serviceOn and t.guard > 3 then
    t.guard = 0
    refreshGuard()
  end
  if t.autoCheck > 60 then
    t.autoCheck = 0
    checkForUpdate(false)
  end

  -- long press: Apps tile -> menu, favorite -> edit favorites
  if press and not press.moved and not press.done and press.id
    and love.timer.getTime() - press.t > LONG_PRESS then
    local id = press.id
    if id.kind == "tile" and id.grid == "apps" then
      press.done = true
      state.menu = appMenu(id.app)
    elseif id.kind == "clock" then
      press.done = true
      state.menu = launcherMenu()
    elseif id.kind == "fav" then
      press.done = true
      openPicker("edit")
    end
    state.dirty = true
  end

  for pid, pg in pairs(state.pagers) do
    local g = state.pagerArea[pid]
    if g then pg.page = math.max(1, math.min(pageCount(g), pg.page)) end
    if not (press and press.pager == pid and press.moved) then
      local d = (pg.page - 1) - pg.x
      if math.abs(d) < 0.001 then pg.x = pg.page - 1 else pg.x = pg.x + d * math.min(1, dt * 14) end
    end
  end
end

local function animating()
  if press or state.toast or state.city or love.timer.getTime() < state.burstUntil then return true end
  if state.screen == "map" and map.busy() then return true end
  for _, pg in pairs(state.pagers) do
    if math.abs((pg.page - 1) - pg.x) > 0.001 then return true end
  end
  return false
end

-- Draw only when something changed, so the launcher idles quietly on the car box.
function love.run()
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
  if love.timer then love.timer.step() end
  local lastMinute

  local lastW, lastH, lastDraw = 0, 0, 0

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

    -- Android resizes the surface after launch (system bars hide) without always sending an
    -- event; re-lay out when the size changes, and redraw at least once a second so a stale,
    -- shifted frame never sits on screen
    local w, h = lg.getDimensions()
    if w ~= lastW or h ~= lastH then
      lastW, lastH = w, h
      layout(w, h)
    end
    local now = love.timer.getTime()
    if now - lastDraw > 1 then state.dirty = true end

    local busy = animating()
    if (state.dirty or busy) and lg.isActive() then
      lg.origin()
      lg.clear(lg.getBackgroundColor())
      love.draw()
      lg.present()
      state.dirty = false
      lastDraw = now
    end

    love.timer.sleep(busy and 0.001 or 0.05)
  end
end
