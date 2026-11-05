-- Road Trip: internet radio. Stations come from Radio Browser (radio-browser.info), a free,
-- community-run directory; the stream plays in RadioService.java so it keeps going while
-- other apps are open. Favorites, the last station and the country live in config.

local lg = love.graphics
local T = require("lang").T

local M = {}
local android, config, ui, json, app -- set by M.init

local FALLBACK_SERVERS = { "de1.api.radio-browser.info", "nl1.api.radio-browser.info", "fi1.api.radio-browser.info", "all.api.radio-browser.info" }
local PAGE_GAP = 10

M.status = { state = "idle" } -- from RadioService: { state, error?, station? }
M.tab = "favs"                -- favs | country | popular | search | countries
M.lists = {}                  -- tab -> { items?, busy, err?, page }
M.search = { text = "", typing = false, dueAt = nil }

local servers, serverAt = nil, 1
local pending = {}            -- fetch id -> handler
local icons = {}              -- station uuid -> { state, img? }
local iconDownloads = 0
local lastPoll = 0

----------------------------------------------------------------------------------------------
-- talking to Radio Browser
----------------------------------------------------------------------------------------------

local function request(id, handler) if type(id) == "number" then pending[id] = handler end end

local function urlEncode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function server()
  local list = servers or FALLBACK_SERVERS
  return list[(serverAt - 1) % #list + 1]
end

-- GET a Radio Browser path; on failure try the next server once
local function api(path, handler, tried)
  request(android.fetch("https://" .. server() .. path), function(r)
    local d = r.ok and json.decode(r.body or "")
    if d == nil and not tried then
      serverAt = serverAt + 1
      return api(path, handler, true)
    end
    handler(d)
  end)
end

-- pick a server from the official list (they ask clients to spread the load this way)
local function findServers()
  request(android.fetch("https://all.api.radio-browser.info/json/servers"), function(r)
    local d = r.ok and json.decode(r.body or "")
    if type(d) == "table" and #d > 0 then
      local seen, list = {}, {}
      for _, s in ipairs(d) do
        if s.name and not seen[s.name] then seen[s.name] = true list[#list + 1] = s.name end
      end
      if #list > 0 then
        servers = list
        serverAt = math.random(#list)
      end
    end
  end)
end

-- Radio Browser's station record -> the compact one Road Trip keeps
local function station(s)
  local url = (s.url_resolved and s.url_resolved ~= "") and s.url_resolved or s.url
  if not url or url == "" or not s.stationuuid then return nil end
  return {
    uuid = s.stationuuid, name = (s.name or "Station"):gsub("^%s+", ""):gsub("%s+$", ""), url = url,
    icon = s.favicon or "", country = s.country or "", cc = s.countrycode or "",
    tags = s.tags or "", codec = s.codec or "", bitrate = tonumber(s.bitrate) or 0,
  }
end

local function stationList(d)
  local out = {}
  if type(d) ~= "table" then return out end
  for _, s in ipairs(d) do
    local st = station(s)
    if st then out[#out + 1] = st end
  end
  return out
end

local function countryCode()
  local cc = config.get("radioCountry")
  if cc and cc ~= "" then return cc end
  local c = android.country()
  if type(c) == "string" and #c == 2 then return c:upper() end
  return "US"
end

local function load(tab, force)
  local l = M.lists[tab]
  if l and (l.busy or (l.items and not force)) then return end
  l = { busy = true, page = 1 }
  M.lists[tab] = l
  local path
  if tab == "country" then
    path = "/json/stations/bycountrycodeexact/" .. countryCode() .. "?hidebroken=true&order=clickcount&reverse=true&limit=90"
  elseif tab == "popular" then
    path = "/json/stations/topclick/90?hidebroken=true"
  elseif tab == "search" then
    local q = M.search.text:gsub("^%s+", ""):gsub("%s+$", "")
    if #q < 2 then l.busy, l.items = false, nil return end
    path = "/json/stations/search?name=" .. urlEncode(q) .. "&hidebroken=true&order=clickcount&reverse=true&limit=60"
  elseif tab == "countries" then
    path = "/json/countries?order=stationcount&reverse=true&hidebroken=true"
  end
  api(path, function(d)
    if M.lists[tab] ~= l then return end
    l.busy = false
    if d == nil then l.err = T("Couldn't reach Radio Browser; check the connection") return end
    if tab == "countries" then
      local out = {}
      for _, c in ipairs(d) do
        if c.iso_3166_1 and c.iso_3166_1 ~= "" and (tonumber(c.stationcount) or 0) > 0 then
          out[#out + 1] = { cc = c.iso_3166_1, name = c.name or c.iso_3166_1, count = tonumber(c.stationcount) or 0 }
        end
      end
      l.items = out
    else
      l.items = stationList(d)
      if tab == "country" and l.items[1] and l.items[1].country ~= "" then
        config.set("radioCountryName", l.items[1].country)
      end
    end
    if #l.items == 0 then l.err = tab == "search" and T("No stations found") or T("Nothing here") end
    app.dirty()
  end)
end

----------------------------------------------------------------------------------------------
-- favorites, playing
----------------------------------------------------------------------------------------------

local function favorites() return config.get("radioFavs") or {} end

function M.isFavorite(st)
  for _, f in ipairs(favorites()) do if f.uuid == st.uuid then return true end end
  return false
end

local function sendList()
  local favs = favorites()
  if #favs == 0 then
    local l = M.lists[M.tab]
    favs = (l and l.items and M.tab ~= "countries") and l.items or {}
  end
  android.radioList(setmetatable({ unpack(favs) }, json.array))
end

local function toggleFavorite(st)
  local out, found = setmetatable({}, json.array), false
  for _, f in ipairs(favorites()) do
    if f.uuid == st.uuid then found = true else out[#out + 1] = f end
  end
  if not found then out[#out + 1] = st end
  config.set("radioFavs", out)
  app.toast(found and T("Removed from radio favorites") or T("Added to radio favorites"))
  sendList()
end

M.toggleFavorite = function(st) toggleFavorite(st) end

-- the most listened stations in your country, for the setup: list (or nil while loading), error
function M.localStations()
  load("country")
  local l = M.lists.country
  return l and l.items, l and l.err, l and l.busy
end

function M.countryName() return config.get("radioCountryName") or countryCode() end

M.logo = function(...) return M._logo(...) end

local function iconPath(st) return "radio/icons/" .. st.uuid end

-- the station's logo, downloaded once; nil until there is one
local function iconFor(st)
  if not st or not st.uuid then return nil end
  local e = icons[st.uuid]
  if e then return e.img end
  e = { state = "new" }
  icons[st.uuid] = e
  local path = iconPath(st)
  local function loadImg()
    local ok, img = pcall(lg.newImage, path)
    if ok and img then
      e.img, e.state = img, "ready"
      img:setFilter("linear", "linear")
    else
      e.state = "failed" -- .ico or .svg: shown as the radio icon
    end
    app.dirty()
  end
  if love.filesystem.getInfo(path) then
    loadImg()
  elseif st.icon and st.icon:find("^https?://") and iconDownloads < 4 then
    iconDownloads = iconDownloads + 1
    love.filesystem.createDirectory("radio/icons")
    request(android.download(st.icon, love.filesystem.getSaveDirectory() .. "/" .. path), function(r)
      iconDownloads = iconDownloads - 1
      if r.ok then loadImg() else e.state = "failed" end
    end)
  elseif st.icon and st.icon:find("^https?://") then
    icons[st.uuid] = nil -- busy; try again on a later frame
  else
    e.state = "failed"
  end
  return nil
end

local function subLine(st)
  local parts = {}
  if st.country and st.country ~= "" then parts[#parts + 1] = st.country end
  local tag = (st.tags or ""):match("^([^,]+)")
  if tag and tag ~= "" then parts[#parts + 1] = tag end
  if (st.bitrate or 0) > 0 then parts[#parts + 1] = T("{n} kbps", { n = st.bitrate }) end
  return table.concat(parts, " · ")
end

function M.play(st)
  if not st then return end
  local art
  local e = icons[st.uuid]
  if e and e.img then art = love.filesystem.getSaveDirectory() .. "/" .. iconPath(st) end
  android.radioPlay({ uuid = st.uuid, name = st.name, url = st.url, art = art, sub = subLine(st),
    lConnecting = T("Connecting…"), lPaused = T("Paused"), lError = T("Can't play this station") })
  M.status = { state = "connecting", station = st }
  config.set("radioLast", st)
  config.set("radioWasPlaying", true)
  sendList()
  -- Radio Browser counts plays to rank stations; they ask apps to report them
  api("/json/url/" .. st.uuid, function() end)
  app.dirty()
end

function M.command(what)
  if what == "toggle" then
    local s = M.status.state
    if s == "idle" or s == "error" then
      M.play(M.current() or config.get("radioLast"))
      return
    end
    what = (s == "playing" or s == "connecting") and "pause" or "play"
  end
  if what == "pause" or what == "stop" then config.set("radioWasPlaying", false) end
  if what == "play" then config.set("radioWasPlaying", true) end
  android.radioCommand(what)
  lastPoll = 0
  app.dirty()
end

-- the station Road Trip is playing (or was, if paused)
function M.current()
  local s = M.status
  if s.station and s.station.uuid then
    -- prefer our own copy: it has the logo and details
    local last = config.get("radioLast")
    if last and last.uuid == s.station.uuid then return last end
    return s.station
  end
  return nil
end

function M.active()
  local s = M.status.state
  return s == "playing" or s == "connecting" or s == "paused" or (s == "error" and M.status.station ~= nil)
end

----------------------------------------------------------------------------------------------
-- life cycle
----------------------------------------------------------------------------------------------

function M.init(deps)
  android, config, ui, json, app = deps.android, deps.config, deps.ui, deps.android.json, deps.app
  findServers()
  sendList()
end

-- after the first frame: play the last station again when the car starts
function M.autoplay()
  if config.get("radioAutoplay") == false then return end
  local last = config.get("radioLast")
  if not last then return end
  local s = android.radioStatus()
  if type(s) == "table" and s.state ~= "idle" then M.status = s return end
  -- a fresh start of the box, or Road Trip restarted while the radio was on
  local up = android.uptime()
  local fresh = type(up) == "number" and up < 10 * 60 * 1000
  if fresh or config.get("radioWasPlaying") then M.play(last) end
end

function M.update(dt, onScreen)
  for id, handler in pairs(pending) do
    local r = android.fetchResult(id)
    if type(r) == "table" and r.done then
      pending[id] = nil
      handler(r)
      app.dirty()
    end
  end
  local now = love.timer.getTime()
  -- what the player is doing: often on the Radio screen, now and then elsewhere
  if now - lastPoll > (onScreen and 0.5 or 2) then
    lastPoll = now
    local s = android.radioStatus()
    if type(s) == "table" then
      local old = M.status
      M.status = s
      if old.state ~= s.state or (old.station and old.station.uuid) ~= (s.station and s.station.uuid) then
        -- next / previous from the steering wheel changes the station in Java
        if s.station and s.station.uuid and (not old.station or old.station.uuid ~= s.station.uuid) then
          local cur = config.get("radioLast")
          if not cur or cur.uuid ~= s.station.uuid then
            for _, list in pairs({ favorites(), (M.lists[M.tab] or {}).items or {} }) do
              for _, st in ipairs(list) do
                if st.uuid == s.station.uuid then config.set("radioLast", st) break end
              end
            end
          end
        end
        app.dirty()
      end
    end
  end
  if M.search.dueAt and now > M.search.dueAt then
    M.search.dueAt = nil
    load("search", true)
  end
end

function M.open()
  if M.tab == "favs" and #favorites() == 0 then M.tab = "country" end
  if M.tab ~= "favs" then load(M.tab) end
end

function M.busy()
  return M.search.typing or M.status.state == "connecting"
end

----------------------------------------------------------------------------------------------
-- text input (search)
----------------------------------------------------------------------------------------------

function M.wantsText() return M.tab == "search" and M.search.typing end

function M.textinput(t)
  M.search.text = M.search.text .. t
  M.search.dueAt = love.timer.getTime() + 0.8
end

function M.keypressed(key)
  local s = M.search
  if key == "backspace" then
    local off = require("utf8").offset(s.text, -1)
    if off then s.text = s.text:sub(1, off - 1) end
    s.dueAt = love.timer.getTime() + 0.8
  elseif key == "return" or key == "kpenter" then
    s.dueAt = nil
    s.typing = false
    love.keyboard.setTextInput(false)
    load("search", true)
  elseif key == "escape" then
    s.typing = false
    love.keyboard.setTextInput(false)
  end
end

function M.back()
  if M.search.typing then
    M.search.typing = false
    love.keyboard.setTextInput(false)
    return true
  end
  if M.tab == "countries" then M.tab = "country" return true end
  return false
end

----------------------------------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------------------------------

local logo
function M._logo(st, x, y, size, r) return logo(st, x, y, size, r) end

function logo(st, x, y, size, r)
  ui.rect(ui.hex("22252A"), x, y, size, size, r)
  local img = iconFor(st)
  if img then
    local inset = size * 0.1
    local s = math.min((size - inset * 2) / img:getWidth(), (size - inset * 2) / img:getHeight())
    lg.setColor(1, 1, 1, 1)
    lg.draw(img, x + (size - img:getWidth() * s) / 2, y + (size - img:getHeight() * s) / 2, 0, s, s)
  else
    local is = size * 0.5
    ui.icon("radio", x + (size - is) / 2, y + (size - is) / 2, is, ui.c.accent, 1.6)
  end
end

local function statusLine()
  local s = M.status
  if s.state == "connecting" then return T("Connecting…"), ui.c.muted end
  if s.state == "playing" then return T("Live"), ui.c.accent end
  if s.state == "paused" then return T("Paused"), ui.c.muted end
  if s.state == "error" then return s.error or T("Can't play this station"), ui.hex("F09A8A") end
  return nil
end

local function toggleSwitch(id, on, x, y)
  ui.rect(on and ui.c.accent or ui.hex("34363B"), x, y, 60, 34, 17)
  ui.circle(ui.c.text, on and (x + 60 - 17) or (x + 17), y + 17, 13)
  ui.hit(id, x - 10, y - 15, 80, 64)
end

local function roundButton(id, icon, cx, cy, r, accent)
  ui.circle(accent and ui.c.accent or ui.c.chip, cx, cy, r)
  local s = r * 0.8
  ui.icon(icon, cx - s / 2, cy - s / 2, s, accent and ui.c.onAccent or ui.c.text2)
  ui.hit(id, cx - r, cy - r, r * 2, r * 2)
end

local function drawPlayer(x, y, w, h)
  ui.rect(ui.c.card, x, y, w, h, 28)
  local st = M.current() or config.get("radioLast")
  local pad = 28
  if not st then
    ui.icon("radio", x + pad, y + pad, 44, ui.c.accent, 1.6)
    ui.text(T("Internet radio"), "bold", 28, ui.c.text, x + pad, y + 96)
    ui.textWrap(T("Pick a station on the right. Star the ones you like to keep them as favorites; steering-wheel next and previous step through them."), "semibold", 16, ui.c.muted, x + pad, y + 140, w - pad * 2, 5)
  else
    local size = math.min(180, w - pad * 2, h * 0.34)
    logo(st, x + pad, y + pad, size, 24)
    local fav = M.isFavorite(st)
    local starX = x + w - pad - 60
    ui.circle(ui.c.chipHi, starX + 30, y + pad + 30, 30)
    ui.icon(fav and "starFill" or "star", starX + 15, y + pad + 15, 30, fav and ui.c.accent or ui.c.muted, 1.8)
    ui.hit({ kind = "radio:fav", station = st }, starX, y + pad, 60, 60)
    local ty = y + pad + size + 22
    ui.text(ui.fit(st.name, "bold", 30, w - pad * 2), "bold", 30, ui.c.text, x + pad, ty)
    ui.text(ui.fit(subLine(st), "semibold", 16, w - pad * 2), "semibold", 16, ui.hex("B8B5AD"), x + pad, ty + 44)
    local line, col = statusLine()
    if line then ui.text(ui.fit(line, "bold", 15, w - pad * 2), "bold", 15, col, x + pad, ty + 74) end

    local s = M.status.state
    local on = s == "playing" or s == "connecting"
    local cy = y + h - 104 - 66
    local cx = x + w / 2
    roundButton({ kind = "radio:cmd", what = "prev" }, "prev", cx - 112, cy, 40)
    roundButton({ kind = "radio:cmd", what = "toggle" }, on and "stop" or "play", cx, cy, 52, true)
    roundButton({ kind = "radio:cmd", what = "next" }, "next", cx + 112, cy, 40)
  end
  -- autoplay switch along the bottom
  local by = y + h - 84
  ui.rect(ui.c.line, x + pad, by, w - pad * 2, 1)
  ui.text(T("Play when the car starts"), "bold", 16, ui.c.text2, x + pad, by + 22)
  ui.text(T("The last station, on start-up"), "semibold", 13, ui.c.muted, x + pad, by + 46)
  toggleSwitch({ kind = "radio:autoplay" }, config.get("radioAutoplay") ~= false, x + w - pad - 60, by + 24)
end

local TABS = {
  { id = "favs", label = "Favorites" },
  { id = "country", label = "Country" },
  { id = "popular", label = "Popular" },
  { id = "search", label = "Search" },
}

local function drawRows(items, x, y, w, h, l, rowFn)
  local rowH = 76
  local per = math.max(1, math.floor((h - 70 + PAGE_GAP) / (rowH + PAGE_GAP)))
  local pages = math.max(1, math.ceil(#items / per))
  l.page = math.max(1, math.min(pages, l.page or 1))
  local first = (l.page - 1) * per + 1
  for i = first, math.min(#items, first + per - 1) do
    rowFn(items[i], x, y + (i - first) * (rowH + PAGE_GAP), w, rowH)
  end
  if pages > 1 then
    local py = y + h - 56
    ui.pill(l.page > 1 and { kind = "radio:page", d = -1 } or nil, T("Previous"), x, py, 56, l.page > 1 and "off2" or "off")
    local label = T("{n} of {total}", { n = l.page, total = pages })
    ui.text(label, "semibold", 15, ui.c.muted, x, py + (56 - ui.fontHeight("semibold", 15)) / 2, "center", w)
    local nw = ui.textWidth(T("Next"), "bold", 16) + 44
    ui.pill(l.page < pages and { kind = "radio:page", d = 1 } or nil, T("Next"), x + w - nw, py, 56, l.page < pages and "off2" or "off")
  end
end

local function stationRow(st, x, y, w, h)
  local cur = M.current()
  local playing = cur and cur.uuid == st.uuid
  ui.rect(playing and ui.c.accentBg or ui.c.card, x, y, w, h, 20)
  logo(st, x + 12, y + 10, h - 20, 14)
  local fav = M.isFavorite(st)
  local tx, tw = x + 12 + h - 20 + 16, w - (h - 20) - 12 - 16 - 76
  ui.text(ui.fit(st.name, "bold", 19, tw), "bold", 19, playing and ui.c.accent or ui.c.text2, tx, y + 13)
  ui.text(ui.fit(subLine(st), "semibold", 14, tw), "semibold", 14, ui.c.muted, tx, y + 43)
  ui.hit({ kind = "radio:play", station = st }, x, y, w - 72, h)
  ui.icon(fav and "starFill" or "star", x + w - 56, y + (h - 30) / 2, 30, fav and ui.c.accent or ui.c.dim, 1.8)
  ui.hit({ kind = "radio:fav", station = st }, x + w - 72, y, 72, h)
end

local function countryRow(c, x, y, w, h)
  local on = c.cc == countryCode()
  ui.rect(on and ui.c.accentBg or ui.c.card, x, y, w, h, 20)
  ui.text(ui.fit(c.name, "bold", 19, w - 180), "bold", 19, on and ui.c.accent or ui.c.text2, x + 24, y + (h - ui.fontHeight("bold", 19)) / 2)
  ui.text(T("{n} stations", { n = c.count }), "semibold", 14, ui.c.muted, x, y + (h - ui.fontHeight("semibold", 14)) / 2, "right", w - 24)
  ui.hit({ kind = "radio:country", country = c }, x, y, w, h)
end

function M.draw(x0, y0, w, h)
  local gap = 24
  local pw = math.min(420, math.floor(w * 0.36))
  drawPlayer(x0 + gap, y0 + gap, pw, h - gap * 2)

  local lx = x0 + gap + pw + gap
  local lw = x0 + w - gap - lx
  local ly = y0 + gap

  -- tabs
  local tx = lx
  for _, t in ipairs(TABS) do
    local label = T(t.label)
    if t.id == "country" then label = config.get("radioCountryName") or countryCode() end
    local on = M.tab == t.id or (t.id == "country" and M.tab == "countries")
    tx = tx + ui.pill({ kind = "radio:tab", tab = t.id }, label, tx, ly, 52, on and "accent" or "off2") + 10
  end
  ly = ly + 52 + 20
  local lh = y0 + h - gap - ly

  if M.tab == "search" then
    local s = M.search
    ui.rect(ui.c.chip, lx, ly, lw, 60, 20)
    if s.typing then
      lg.setColor(ui.c.accent)
      lg.setLineWidth(2)
      lg.rectangle("line", lx, ly, lw, 60, 20, 20, 16)
    end
    ui.icon("search", lx + 18, ly + 18, 24, ui.c.muted, 2.2)
    local blink = s.typing and math.floor(love.timer.getTime() * 2) % 2 == 0
    local shown = s.text ~= "" and s.text or T("Station name")
    ui.text(ui.fit(shown, "semibold", 19, lw - 80) .. (blink and "|" or ""), "semibold", 19,
      s.text ~= "" and ui.c.text or ui.c.dim, lx + 56, ly + (60 - ui.fontHeight("semibold", 19)) / 2)
    ui.hit({ kind = "radio:field" }, lx, ly, lw, 60)
    ly, lh = ly + 76, lh - 76
  elseif M.tab == "country" then
    local name = config.get("radioCountryName") or countryCode()
    ui.text(ui.fit(T("Most listened in {country}", { country = name }), "bold", 15, lw - 200), "bold", 15, ui.c.muted, lx + 4, ly + 12)
    local cw = ui.textWidth(T("Change country"), "bold", 16) + 44
    ui.pill({ kind = "radio:tab", tab = "countries" }, T("Change country"), lx + lw - cw, ly, 44, "off2")
    ly, lh = ly + 60, lh - 60
  end

  local items, l
  if M.tab == "favs" then
    l = M.lists.favs or { page = 1 }
    M.lists.favs = l
    items = favorites()
    if #items == 0 then
      ui.textWrap(T("No favorites yet. Find stations under Country, Popular or Search and tap the star."),
        "semibold", 17, ui.c.muted, lx + 4, ly + 8, lw, 3)
      return
    end
  else
    l = M.lists[M.tab]
    if not l then load(M.tab) l = M.lists[M.tab] end
    if l.busy then ui.text(T("Loading stations…"), "semibold", 17, ui.c.muted, lx + 4, ly + 8) return end
    if l.err and not (l.items and #l.items > 0) then
      ui.text(l.err, "semibold", 17, ui.hex("F09A8A"), lx + 4, ly + 8)
      if M.tab ~= "search" then ui.pill({ kind = "radio:retry" }, T("Try again"), lx, ly + 44, 52, "off2") end
      return
    end
    items = l.items or {}
    if M.tab == "search" and #items == 0 then
      ui.text(T("Type a station's name and press Enter"), "semibold", 17, ui.c.muted, lx + 4, ly + 8)
      return
    end
  end
  drawRows(items, lx, ly, lw, lh, l, M.tab == "countries" and countryRow or stationRow)
end

-- Home's Now playing widget, while the radio is on
function M.drawWidget(x, y, w, h)
  local st = M.current()
  local pad = 22
  ui.rect(ui.c.card, x, y, w, h, 26)
  ui.hit({ kind = "radio:open" }, x, y, w, h)
  ui.text(T("Radio"), "bold", 14, ui.c.muted, x + pad, y + 20)
  local size = 56
  logo(st, x + w - pad - size, y + 16, size, 14)
  local tw = w - pad * 2 - size - 10
  ui.text(ui.fit(st and st.name or T("Radio"), "bold", 24, tw), "bold", 24, ui.c.text, x + pad, y + 50)
  local line, col = statusLine()
  ui.text(ui.fit(line or "", "semibold", 16, tw), "semibold", 16, col or ui.c.muted, x + pad, y + 84)
  local bh = 52
  local by = y + h - pad - bh
  local gap = 10
  local bw = (w - pad * 2 - gap * 2) / 3
  local on = M.status.state == "playing" or M.status.state == "connecting"
  local items = { { "prev", "prev" }, { "toggle", on and "stop" or "play", true }, { "next", "next" } }
  for i, it in ipairs(items) do
    local bx = x + pad + (i - 1) * (bw + gap)
    ui.rect(it[3] and ui.c.accent or ui.hex("22252A"), bx, by, bw, bh, 16)
    local s = 26
    ui.icon(it[2], bx + (bw - s) / 2, by + (bh - s) / 2, s, it[3] and ui.c.onAccent or ui.c.text2)
    ui.hit({ kind = "radio:cmd", what = it[1] }, bx, by, bw, bh)
  end
end

-- returns true when the id was a radio one
function M.activate(id)
  local k = id.kind
  if k == "radio:play" then
    local cur = M.current()
    if cur and cur.uuid == id.station.uuid and (M.status.state == "playing" or M.status.state == "connecting") then
      M.command("pause")
    else
      M.play(id.station)
    end
  elseif k == "radio:fav" then toggleFavorite(id.station)
  elseif k == "radio:cmd" then M.command(id.what)
  elseif k == "radio:tab" then
    M.tab = id.tab
    if id.tab == "search" then
      M.search.typing = true
      love.keyboard.setTextInput(true)
    elseif id.tab ~= "favs" then
      load(id.tab)
    end
    if id.tab ~= "search" and M.search.typing then
      M.search.typing = false
      love.keyboard.setTextInput(false)
    end
  elseif k == "radio:field" then
    M.search.typing = true
    love.keyboard.setTextInput(true)
  elseif k == "radio:page" then
    local l = M.lists[M.tab]
    if l then l.page = (l.page or 1) + id.d end
  elseif k == "radio:retry" then load(M.tab, true)
  elseif k == "radio:country" then
    config.set("radioCountry", id.country.cc)
    config.set("radioCountryName", id.country.name)
    M.lists.country = nil
    M.tab = "country"
    load("country", true)
  elseif k == "radio:autoplay" then
    config.set("radioAutoplay", config.get("radioAutoplay") == false)
  else
    return false
  end
  app.dirty()
  return true
end

return M
