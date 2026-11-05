-- Road Trip: your Jellyfin server. Sign in once (password or Quick Connect), browse the
-- libraries, play music and audiobooks in the background (MusicService.java), and video in
-- Road Trip's own screen (Panel.java), next to the map while a route is on. Video is covered
-- while the car moves; the sound keeps playing.

local lg = love.graphics
local T = require("lang").T

local M = {}
local android, config, ui, json, app

local AUDIO = { Audio = true, AudioBook = true }
local VIDEO = { Movie = true, Episode = true, Video = true, MusicVideo = true, TvChannel = true }

M.stack = {}         -- what's open: { { title, key, req, items?, busy?, err?, page } }
M.login = { server = "", user = "", pass = "", focus = nil, busy = false, err = nil, qc = nil }
M.music = { state = "idle" }  -- from MusicService
M.video = nil        -- { item, title } while a video is open
M.split = true       -- video next to the map
M.search = { text = "", typing = false }

local pending = {}
local images = {}
local imgDownloads = 0
local lastPoll = 0

----------------------------------------------------------------------------------------------
-- talking to the server

local function server() return config.get("jfServer") or "" end
local function token() return config.get("jfToken") end
local function uid() return config.get("jfUserId") end

local function deviceId()
  local d = config.get("jfDevice")
  if not d then
    d = string.format("roadtrip-%08x%04x", math.random(0, 0x7fffffff), math.random(0, 0xffff))
    config.set("jfDevice", d)
  end
  return d
end

local function authHeader(withToken)
  local h = string.format('MediaBrowser Client="Road Trip", Device="Car", DeviceId="%s", Version="0.1"', deviceId())
  if withToken and token() then h = h .. string.format(', Token="%s"', token()) end
  return h
end

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function request(method, path, body, handler, base)
  local h = authHeader(true)
  local id = android.httpRequest(method, (base or server()) .. path,
    { Authorization = h, ["X-Emby-Authorization"] = h, Accept = "application/json" },
    body and json.encode(body) or nil)
  if type(id) == "number" then pending[id] = handler end
end

local function normalize(addr)
  addr = (addr or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
  if addr ~= "" and not addr:find("^https?://") then addr = "http://" .. addr end
  -- a bare host gets Jellyfin's usual port
  if addr ~= "" and not addr:match("^https?://[^/]+:%d+") and not addr:find("^https://") then
    local host, rest = addr:match("^(http://[^/]+)(.*)$")
    if host then addr = host .. ":8096" .. rest end
  end
  return addr
end

function M.signedIn() return token() ~= nil and uid() ~= nil end

local function signedIn(d)
  if not d or not d.AccessToken or not d.User then
    M.login.busy, M.login.err = false, T("Couldn't sign in; check the name and password")
    return
  end
  config.set("jfToken", d.AccessToken)
  config.set("jfUserId", d.User.Id)
  config.set("jfUser", d.User.Name)
  M.login.busy, M.login.err, M.login.qc, M.login.pass = false, nil, nil, ""
  M.stack = {}
  M.openRoot()
  app.toast(T("Signed in to Jellyfin"))
end

local function checkServer(after)
  local base = normalize(M.login.server)
  if base == "" then M.login.err = T("Type your server's address") return end
  M.login.busy, M.login.err = true, nil
  request("GET", "/System/Info/Public", nil, function(r)
    local d = r.ok and json.decode(r.body or "")
    if not d or not d.Version then
      M.login.busy = false
      M.login.err = T("No Jellyfin server answered at {address}", { address = base })
      return
    end
    config.set("jfServer", base)
    config.set("jfServerName", d.ServerName or base)
    after()
  end, base)
end

function M.signIn()
  checkServer(function()
    request("POST", "/Users/AuthenticateByName", { Username = M.login.user, Pw = M.login.pass }, function(r)
      signedIn(r.ok and json.decode(r.body or ""))
    end)
  end)
end

-- Quick Connect: Road Trip shows a code; you approve it in another Jellyfin app
function M.quickConnect()
  checkServer(function()
    request("POST", "/QuickConnect/Initiate", nil, function(r)
      local d = r.ok and json.decode(r.body or "")
      M.login.busy = false
      if not d or not d.Secret then
        M.login.err = T("Quick Connect isn't switched on for this server")
        return
      end
      M.login.qc = { secret = d.Secret, code = d.Code, next = love.timer.getTime() + 3 }
    end)
  end)
end

function M.signOut()
  config.set("jfToken", nil)
  config.set("jfUserId", nil)
  M.stack = {}
  M.closeVideo()
  android.musicCommand("stop")
end

----------------------------------------------------------------------------------------------
-- browsing

local function itemsPath(q) return "/Users/" .. uid() .. "/Items?" .. q .. "&Fields=PrimaryImageAspectRatio,ParentId&ImageTypeLimit=1&EnableUserData=false" end

local function push(title, path)
  local v = { title = title, path = path, page = 1 }
  M.stack[#M.stack + 1] = v
  v.busy = true
  request("GET", path, nil, function(r)
    v.busy = false
    local d = r.ok and json.decode(r.body or "")
    if not d then v.err = T("Couldn't reach your server") return end
    v.items = d.Items or d
    if #v.items == 0 then v.err = T("Nothing here") end
  end)
end

function M.openRoot()
  if not M.signedIn() then return end
  if #M.stack == 0 then push(config.get("jfServerName") or "Jellyfin", "/Users/" .. uid() .. "/Views") end
end

local function openItem(it)
  local id = it.Id
  local t = it.Type
  if t == "CollectionFolder" or it.CollectionType then
    local ct = it.CollectionType
    if ct == "music" then
      push(it.Name, itemsPath("ParentId=" .. id .. "&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=SortName&Limit=500"))
    elseif ct == "movies" then
      push(it.Name, itemsPath("ParentId=" .. id .. "&IncludeItemTypes=Movie&Recursive=true&SortBy=SortName&Limit=500"))
    elseif ct == "tvshows" then
      push(it.Name, itemsPath("ParentId=" .. id .. "&IncludeItemTypes=Series&Recursive=true&SortBy=SortName&Limit=500"))
    elseif ct == "books" or ct == "audiobooks" then
      push(it.Name, itemsPath("ParentId=" .. id .. "&IncludeItemTypes=AudioBook,Folder&SortBy=SortName&Limit=500"))
    else
      push(it.Name, itemsPath("ParentId=" .. id .. "&SortBy=SortName&Limit=500"))
    end
  elseif t == "Series" then
    push(it.Name, "/Shows/" .. id .. "/Seasons?userId=" .. uid())
  elseif t == "Season" then
    push((it.SeriesName or "") .. " · " .. (it.Name or ""), "/Shows/" .. (it.SeriesId or "") .. "/Episodes?seasonId=" .. id .. "&userId=" .. uid())
  elseif t == "MusicAlbum" then
    push(it.Name, itemsPath("ParentId=" .. id .. "&SortBy=ParentIndexNumber,IndexNumber,SortName"))
  elseif t == "MusicArtist" then
    push(it.Name, itemsPath("ArtistIds=" .. id .. "&IncludeItemTypes=MusicAlbum&Recursive=true&SortBy=ProductionYear,SortName"))
  else
    push(it.Name, itemsPath("ParentId=" .. id .. "&SortBy=SortName&Limit=500"))
  end
end

function M.runSearch()
  local q = M.search.text:gsub("^%s+", ""):gsub("%s+$", "")
  if #q < 2 or not M.signedIn() then return end
  -- a search replaces an earlier search on the stack
  if M.stack[#M.stack] and M.stack[#M.stack].search then M.stack[#M.stack] = nil end
  push(T("Search: {text}", { text = q }), itemsPath("searchTerm=" .. urlEncode(q)
    .. "&Recursive=true&IncludeItemTypes=Audio,MusicAlbum,MusicArtist,Movie,Series,Episode,AudioBook&Limit=60"))
  M.stack[#M.stack].search = true
end

----------------------------------------------------------------------------------------------
-- pictures

local function imagePath(id) return "jf/img/" .. id .. ".jpg" end

local function imageFor(it)
  if not it or not it.Id then return nil end
  local id = it.Id
  local e = images[id]
  if e then return e.img end
  local hasImg = it.ImageTags and it.ImageTags.Primary
  local imgId = id
  if not hasImg and it.AlbumId and it.AlbumPrimaryImageTag then imgId, hasImg = it.AlbumId, true end
  if not hasImg then images[id] = { state = "none" } return nil end
  if imgDownloads >= 4 then return nil end
  e = { state = "loading" }
  images[id] = e
  local path = imagePath(id)
  local function loadImg()
    local ok, img = pcall(lg.newImage, path)
    if ok and img then e.img = img img:setFilter("linear", "linear") end
    app.dirty()
  end
  if love.filesystem.getInfo(path) then loadImg() return e.img end
  imgDownloads = imgDownloads + 1
  love.filesystem.createDirectory("jf/img")
  local url = server() .. "/Items/" .. imgId .. "/Images/Primary?maxHeight=240&quality=80&api_key=" .. (token() or "")
  local rid = android.download(url, love.filesystem.getSaveDirectory() .. "/" .. path)
  if type(rid) == "number" then
    pending[rid] = function(r)
      imgDownloads = imgDownloads - 1
      if r.ok then loadImg() else e.state = "failed" end
    end
  end
  return nil
end

----------------------------------------------------------------------------------------------
-- playing

local function audioURL(it)
  return server() .. "/Audio/" .. it.Id .. "/stream?static=true&api_key=" .. (token() or "")
end

local function videoURL(it)
  -- HLS, so the server can repackage or convert what the car's player can't decode
  return server() .. "/Videos/" .. it.Id .. "/master.m3u8?MediaSourceId=" .. it.Id .. "&DeviceId=" .. deviceId()
    .. "&VideoCodec=h264&AudioCodec=aac,mp3&MaxStreamingBitrate=8000000&TranscodingMaxAudioChannels=2"
    .. "&SegmentContainer=ts&api_key=" .. (token() or "")
end

local function subOf(it)
  local t = it.Type
  if t == "Audio" then
    local a = it.AlbumArtist or (it.Artists and it.Artists[1]) or ""
    return (a ~= "" and (a .. " · ") or "") .. (it.Album or "")
  elseif t == "MusicAlbum" then
    return (it.AlbumArtist or "") .. (it.ProductionYear and (" · " .. it.ProductionYear) or "")
  elseif t == "Episode" then
    local s = it.SeriesName or ""
    if it.ParentIndexNumber and it.IndexNumber then
      s = s .. string.format(" · S%02dE%02d", it.ParentIndexNumber, it.IndexNumber)
    end
    return s
  elseif t == "Movie" or t == "Series" then
    return it.ProductionYear and tostring(it.ProductionYear) or ""
  elseif t == "CollectionFolder" or it.CollectionType then
    return ""
  end
  return t or ""
end

local function playAudio(list, index)
  local tracks = setmetatable({}, json.array)
  local startAt = 0
  for _, it in ipairs(list) do
    if AUDIO[it.Type] then
      if it == list[index] then startAt = #tracks end
      local e = images[it.Id]
      local art = e and e.img and (love.filesystem.getSaveDirectory() .. "/" .. imagePath(it.Id)) or nil
      tracks[#tracks + 1] = { url = audioURL(it), title = it.Name or "", artist = it.AlbumArtist or (it.Artists and it.Artists[1]) or "",
        album = it.Album or "", art = art, id = it.Id }
    end
  end
  if #tracks == 0 then return end
  android.radioCommand("stop")
  android.videoCommand("pause")
  android.musicPlay(tracks, startAt)
  M.music = { state = "connecting", track = tracks[startAt + 1] }
  lastPoll = 0
end

local function playVideo(it)
  android.musicCommand("pause")
  android.radioCommand("pause")
  M.video = { item = it, title = it.Name or "" }
  android.videoPlay(videoURL(it), 0)
end

function M.closeVideo()
  if M.video then android.videoCommand("stop") end
  M.video = nil
end

-- the playing track's picture, if it's been loaded
function M.trackImage()
  local t = M.music.track
  local e = t and t.id and images[t.id]
  return e and e.img or nil
end

function M.musicActive()
  local s = M.music.state
  return s == "playing" or s == "connecting" or s == "paused"
end

----------------------------------------------------------------------------------------------

function M.init(deps)
  android, config, ui, json, app = deps.android, deps.config, deps.ui, deps.android.json, deps.app
  M.login.server = config.get("jfServer") or ""
  M.login.user = config.get("jfUser") or ""
end

function M.update(dt)
  local done = {}
  for id in pairs(pending) do
    local r = android.fetchResult(id)
    if type(r) == "table" and r.done then done[#done + 1] = { id, r } end
  end
  for _, d in ipairs(done) do
    local h = pending[d[1]]
    pending[d[1]] = nil
    if h then h(d[2]) end
    app.dirty()
  end
  local now = love.timer.getTime()
  local qc = M.login.qc
  if qc and now > qc.next then
    qc.next = now + 3
    request("GET", "/QuickConnect/Connect?secret=" .. urlEncode(qc.secret), nil, function(r)
      local d = r.ok and json.decode(r.body or "")
      if d and d.Authenticated and M.login.qc == qc then
        M.login.qc = nil
        request("POST", "/Users/AuthenticateWithQuickConnect", { Secret = qc.secret }, function(r2)
          signedIn(r2.ok and json.decode(r2.body or ""))
        end)
      end
    end)
  end
  if now - lastPoll > 1 then
    lastPoll = now
    local s = android.musicStatus()
    if type(s) == "table" then
      local changed = (s.state ~= M.music.state) or ((s.track or {}).url ~= (M.music.track or {}).url)
      M.music = s
      if changed then app.dirty() end
    end
  end
end

----------------------------------------------------------------------------------------------
-- text input: login fields and search

function M.wantsText() return M.login.focus ~= nil or M.search.typing end

local function edit(field, t)
  if field == "search" then M.search.text = M.search.text .. t
  else M.login[field] = M.login[field] .. t end
end

function M.textinput(t)
  if M.search.typing then edit("search", t) elseif M.login.focus then edit(M.login.focus, t) end
end

function M.keypressed(key)
  local field = M.search.typing and "search" or M.login.focus
  if not field then return end
  local get = function() return field == "search" and M.search.text or M.login[field] end
  local set = function(v) if field == "search" then M.search.text = v else M.login[field] = v end end
  if key == "backspace" then
    local s = get()
    local off = require("utf8").offset(s, -1)
    if off then set(s:sub(1, off - 1)) end
  elseif key == "return" or key == "kpenter" or key == "tab" then
    if field == "search" then
      M.search.typing = false
      love.keyboard.setTextInput(false)
      M.runSearch()
    elseif field == "server" then M.login.focus = "user"
    elseif field == "user" then M.login.focus = "pass"
    else
      M.login.focus = nil
      love.keyboard.setTextInput(false)
      M.signIn()
    end
  end
end

function M.back()
  if M.search.typing or M.login.focus then
    M.search.typing, M.login.focus = false, nil
    love.keyboard.setTextInput(false)
    return true
  end
  if M.video then M.closeVideo() return true end
  if #M.stack > 1 then M.stack[#M.stack] = nil return true end
  return false
end

----------------------------------------------------------------------------------------------
-- drawing

local function field(id, label, value, x, y, w, masked)
  local on = M.login.focus == id
  ui.text(label, "bold", 14, ui.c.muted, x, y)
  ui.rect(ui.c.chip, x, y + 24, w, 56, 18)
  if on then
    lg.setColor(ui.c.accent)
    lg.setLineWidth(2)
    lg.rectangle("line", x, y + 24, w, 56, 18, 18, 16)
  end
  local shown = masked and string.rep("•", require("utf8").len(value) or #value) or value
  local blink = on and math.floor(love.timer.getTime() * 2) % 2 == 0
  ui.text(ui.fit(shown, "semibold", 18, w - 40) .. (blink and "|" or ""), "semibold", 18, ui.c.text, x + 18,
    y + 24 + (56 - ui.fontHeight("semibold", 18)) / 2)
  ui.hit({ kind = "jf:field", field = id }, x, y + 24, w, 56)
end

local function drawLogin(x, y, w, h)
  local cw = math.min(620, w - 48)
  local cx = x + 24
  ui.text(T("Connect your Jellyfin server"), "bold", 28, ui.c.text, cx, y + 8)
  ui.textWrap(T("Your music, audiobooks and videos from home. Use the address you'd type in a browser, like 192.168.1.20:8096."),
    "semibold", 15, ui.c.muted, cx, y + 50, cw, 2)
  local L = M.login
  if L.qc then
    ui.text(T("Quick Connect code"), "bold", 15, ui.c.muted, cx, y + 120)
    ui.text(L.qc.code or "", "bold", 64, ui.c.accent, cx, y + 146)
    ui.textWrap(T("In another Jellyfin app, open Settings → Quick Connect and enter this code. Road Trip signs in by itself."),
      "semibold", 16, ui.c.text2, cx, y + 236, cw, 3)
    ui.pill({ kind = "jf:qcCancel" }, T("Cancel"), cx, y + 320, 52, "off2")
    return
  end
  field("server", T("Server address"), L.server, cx, y + 110, cw)
  field("user", T("User name"), L.user, cx, y + 196, (cw - 16) / 2)
  field("pass", T("Password"), L.pass, cx + (cw + 16) / 2, y + 196, (cw - 16) / 2, true)
  local by = y + 300
  local bw = ui.pill(L.busy and { kind = "jf:none" } or { kind = "jf:signIn" }, L.busy and T("Connecting…") or T("Sign in"), cx, by, 56, "accent")
  ui.pill({ kind = "jf:qc" }, T("Use Quick Connect"), cx + bw + 12, by, 56, "off2")
  if L.err then ui.textWrap(L.err, "semibold", 15, ui.hex("F09A8A"), cx, by + 72, cw, 2) end
end

local function drawRows(v, x, y, w, h)
  local items = v.items or {}
  local rh, gap = 76, 8
  local per = math.max(1, math.floor((h - 64 + gap) / (rh + gap)))
  local pages = math.max(1, math.ceil(#items / per))
  v.page = math.max(1, math.min(pages, v.page or 1))
  local first = (v.page - 1) * per + 1
  for i = first, math.min(#items, first + per - 1) do
    local it = items[i]
    local ry = y + (i - first) * (rh + gap)
    local playing = M.music.track and M.music.track.id == it.Id
    ui.rect(playing and ui.c.accentBg or ui.c.card, x, ry, w, rh, 20)
    ui.rect(ui.hex("22252A"), x + 10, ry + 10, rh - 20, rh - 20, 12)
    local img = imageFor(it)
    if img then
      local s = math.max((rh - 20) / img:getWidth(), (rh - 20) / img:getHeight())
      local ss = ui.S
      lg.setScissor((x + 10) * ss, (ry + 10) * ss, (rh - 20) * ss, (rh - 20) * ss)
      lg.setColor(1, 1, 1, 1)
      lg.draw(img, x + 10 + (rh - 20 - img:getWidth() * s) / 2, ry + 10 + (rh - 20 - img:getHeight() * s) / 2, 0, s, s)
      lg.setScissor()
    else
      local icon = AUDIO[it.Type] and "media" or VIDEO[it.Type] and "play" or "widgets"
      ui.icon(icon, x + 10 + (rh - 20 - 26) / 2, ry + 10 + (rh - 20 - 26) / 2, 26, ui.c.accent, 1.6)
    end
    local tx = x + rh + 8
    ui.text(ui.fit(it.Name or "", "bold", 18, w - rh - 40), "bold", 18, playing and ui.c.accent or ui.c.text2, tx, ry + 13)
    ui.text(ui.fit(subOf(it), "semibold", 14, w - rh - 40), "semibold", 14, ui.c.muted, tx, ry + 43)
    ui.hit({ kind = "jf:item", item = it, list = items, index = i }, x, ry, w, rh)
  end
  if pages > 1 then
    local py = y + h - 56
    ui.pill(v.page > 1 and { kind = "jf:page", d = -1 } or nil, T("Previous"), x, py, 52, v.page > 1 and "off2" or "off")
    ui.text(T("{n} of {total}", { n = v.page, total = pages }), "semibold", 15, ui.c.muted, x, py + 16, "center", w)
    local nw = ui.textWidth(T("Next"), "bold", 16) + 44
    ui.pill(v.page < pages and { kind = "jf:page", d = 1 } or nil, T("Next"), x + w - nw, py, 52, v.page < pages and "off2" or "off")
  end
end

-- the rectangle the video sits in, or nil (in virtual units)
function M.videoRect(x, y, w, h, navigating)
  if not M.video then return nil end
  local top = y + 64
  if M.split and navigating then return x + 16, top, math.floor(w * 0.58) - 24, h - 64 - 16 end
  return x + 16, top, w - 32, h - 64 - 16
end

-- the Jellyfin tab of the Media screen. `map` draws the map card for the split view.
function M.draw(x, y, w, h, drawMapCard, navigating)
  if not M.signedIn() then drawLogin(x, y, w, h) return end
  if M.video then
    -- a bar over the video: title, split/full, close
    ui.text(ui.fit(M.video.title, "bold", 20, w - 420), "bold", 20, ui.c.text, x + 20, y + 14)
    local bx = x + w - 16
    local cw = ui.textWidth(T("Close"), "bold", 16) + 44
    bx = bx - cw
    ui.pill({ kind = "jf:closeVideo" }, T("Close"), bx, y + 6, 48, "off2")
    if navigating then
      local label = M.split and T("Full screen") or T("Next to the map")
      local sw = ui.textWidth(label, "bold", 16) + 44
      bx = bx - sw - 10
      ui.pill({ kind = "jf:split" }, label, bx, y + 6, 48, "off2")
    end
    local vx, vy, vw, vh = M.videoRect(x, y, w, h, navigating)
    ui.rect(ui.hex("000000"), vx, vy, vw, vh, 0) -- under Android's video view
    if M.split and navigating then
      drawMapCard(vx + vw + 16, vy, x + w - 16 - (vx + vw + 16), vh)
    end
    return
  end
  local v = M.stack[#M.stack]
  if not v then M.openRoot() v = M.stack[#M.stack] end
  -- header: back, where you are, search, account
  local hx = x + 16
  if #M.stack > 1 then
    hx = hx + ui.pill({ kind = "jf:back" }, T("Back"), hx, y + 4, 48, "off2") + 12
  end
  local sw = math.min(360, w * 0.32)
  local accW = ui.textWidth(T("Sign out"), "bold", 16) + 44
  ui.text(ui.fit(v and v.title or "", "bold", 20, w - (hx - x) - sw - accW - 60), "bold", 20, ui.c.text, hx, y + 16)
  local sx = x + w - 16 - accW - 12 - sw
  ui.rect(ui.c.chip, sx, y + 2, sw, 52, 18)
  if M.search.typing then
    lg.setColor(ui.c.accent)
    lg.setLineWidth(2)
    lg.rectangle("line", sx, y + 2, sw, 52, 18, 18, 16)
  end
  ui.icon("search", sx + 14, y + 16, 24, ui.c.muted, 2.2)
  local blink = M.search.typing and math.floor(love.timer.getTime() * 2) % 2 == 0
  ui.text(ui.fit(M.search.text ~= "" and M.search.text or T("Search your library"), "semibold", 16, sw - 60) .. (blink and "|" or ""),
    "semibold", 16, M.search.text ~= "" and ui.c.text or ui.c.dim, sx + 48, y + 2 + (52 - ui.fontHeight("semibold", 16)) / 2)
  ui.hit({ kind = "jf:searchField" }, sx, y + 2, sw, 52)
  ui.pill({ kind = "jf:signOut" }, T("Sign out"), x + w - 16 - accW, y + 4, 48, "off2")

  local ly, lh = y + 72, h - 72 - 8
  if not v then return end
  if v.busy then ui.text(T("Loading…"), "semibold", 17, ui.c.muted, x + 20, ly + 8) return end
  if v.err and not (v.items and #v.items > 0) then
    ui.text(v.err, "semibold", 17, ui.c.muted, x + 20, ly + 8)
    return
  end
  drawRows(v, x + 16, ly, w - 32, lh)
end

-- Home's Now playing card while Jellyfin music plays
function M.drawWidget(x, y, w, h)
  local t = M.music.track or {}
  local pad = 22
  ui.rect(ui.c.card, x, y, w, h, 26)
  ui.hit({ kind = "jf:open" }, x, y, w, h)
  ui.text("Jellyfin", "bold", 14, ui.c.muted, x + pad, y + 20)
  ui.text(ui.fit(t.title or "", "bold", 24, w - pad * 2), "bold", 24, ui.c.text, x + pad, y + 50)
  ui.text(ui.fit(t.artist or "", "semibold", 16, w - pad * 2), "semibold", 16, ui.hex("B8B5AD"), x + pad, y + 84)
  local dur = M.music.durationMs or 0
  if dur > 0 then
    local by = y + h - pad - 52 - 18
    ui.rect(ui.hex("2C2E33"), x + pad, by, w - pad * 2, 4, 2)
    ui.rect(ui.c.accent, x + pad, by, (w - pad * 2) * math.min(1, (M.music.positionMs or 0) / dur), 4, 2)
  end
  local bh, gap = 52, 10
  local by = y + h - pad - bh
  local bw = (w - pad * 2 - gap * 2) / 3
  local on = M.music.state == "playing" or M.music.state == "connecting"
  for i, it in ipairs({ { "prev", "prev" }, { "toggle", on and "pause" or "play", true }, { "next", "next" } }) do
    local bx = x + pad + (i - 1) * (bw + gap)
    ui.rect(it[3] and ui.c.accent or ui.hex("22252A"), bx, by, bw, bh, 16)
    ui.icon(it[2], bx + (bw - 26) / 2, by + (bh - 26) / 2, 26, it[3] and ui.c.onAccent or ui.c.text2)
    ui.hit({ kind = "jf:cmd", what = it[1] }, bx, by, bw, bh)
  end
end

-- returns true if it handled the id
function M.activate(id)
  local k = id.kind
  if k == "jf:field" then
    M.login.focus = id.field
    M.search.typing = false
    love.keyboard.setTextInput(true)
  elseif k == "jf:signIn" then
    M.login.focus = nil
    love.keyboard.setTextInput(false)
    M.signIn()
  elseif k == "jf:qc" then
    M.login.focus = nil
    love.keyboard.setTextInput(false)
    M.quickConnect()
  elseif k == "jf:qcCancel" then M.login.qc = nil
  elseif k == "jf:signOut" then M.signOut()
  elseif k == "jf:back" then if #M.stack > 1 then M.stack[#M.stack] = nil end
  elseif k == "jf:page" then
    local v = M.stack[#M.stack]
    if v then v.page = (v.page or 1) + id.d end
  elseif k == "jf:searchField" then
    M.search.typing = true
    M.login.focus = nil
    love.keyboard.setTextInput(true)
  elseif k == "jf:item" then
    local it = id.item
    if AUDIO[it.Type] then playAudio(id.list, id.index)
    elseif VIDEO[it.Type] then playVideo(it)
    else openItem(it) end
  elseif k == "jf:cmd" then
    android.musicCommand(id.what)
    lastPoll = 0
  elseif k == "jf:closeVideo" then M.closeVideo()
  elseif k == "jf:split" then M.split = not M.split
  elseif k == "jf:none" then -- busy
  else
    return false
  end
  app.dirty()
  return true
end

return M
