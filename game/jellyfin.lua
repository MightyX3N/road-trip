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
M.search = { text = "", typing = false }

local pending = {}

-- a server (or a router answering at that address) can send anything; never let that crash
local function decode(body)
  if type(body) ~= "string" or body == "" then return nil end
  local ok, v = pcall(json.decode, body)
  if ok and type(v) == "table" then return v end
  return nil
end
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
    local d = r.ok and decode(r.body)
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
      signedIn(r.ok and decode(r.body))
    end)
  end)
end

-- Quick Connect: Road Trip shows a code; you approve it in another Jellyfin app
function M.quickConnect()
  checkServer(function()
    request("POST", "/QuickConnect/Initiate", nil, function(r)
      local d = r.ok and decode(r.body)
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
    local d = r.ok and decode(r.body)
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

-- what this device can play itself; anything else the server converts to H.264 + AAC (HLS)
local function deviceProfile()
  local A = json.array
  return {
    Name = "Road Trip", MaxStreamingBitrate = 20000000, MaxStaticBitrate = 100000000,
    DirectPlayProfiles = { { Container = "mp4,m4v,mkv,webm,mov", Type = "Video",
      VideoCodec = "h264,vp8,vp9", AudioCodec = "aac,mp3,opus,flac,vorbis" } },
    TranscodingProfiles = { { Container = "ts", Type = "Video", VideoCodec = "h264", AudioCodec = "aac,mp3",
      Protocol = "hls", Context = "Streaming", MaxAudioChannels = "2", MinSegments = 1, BreakOnNonKeyFrames = true } },
    ContainerProfiles = setmetatable({}, A), CodecProfiles = setmetatable({}, A),
    SubtitleProfiles = setmetatable({}, A),
  }
end

local function withKey(u)
  local l = u:lower()
  if l:find("api_key=") or l:find("apikey=") then return u end
  return u .. (u:find("?", 1, true) and "&" or "?") .. "api_key=" .. (token() or "")
end

-- the addresses to try, best first: the file as it is (if this device can play it), the
-- server's own conversion, and plain HLS as the last resort
local function videoURLs(it, cb)
  request("POST", "/Items/" .. it.Id .. "/PlaybackInfo?UserId=" .. uid(), {
    UserId = uid(), MaxStreamingBitrate = 20000000, StartTimeTicks = 0, IsPlayback = true,
    AutoOpenLiveStream = true, DeviceProfile = deviceProfile(),
  }, function(r)
    local d = r.ok and decode(r.body)
    local src = d and d.MediaSources and d.MediaSources[1]
    local session = d and d.PlaySessionId or ""
    local srcId = src and src.Id or it.Id
    local urls = {}
    if src and (src.SupportsDirectPlay or src.SupportsDirectStream) then
      urls[#urls + 1] = withKey(server() .. "/Videos/" .. it.Id .. "/stream?static=true&MediaSourceId=" .. urlEncode(srcId)
        .. "&PlaySessionId=" .. urlEncode(session) .. "&DeviceId=" .. deviceId())
    end
    if src and type(src.TranscodingUrl) == "string" and src.TranscodingUrl ~= "" then
      urls[#urls + 1] = withKey(server() .. src.TranscodingUrl)
    end
    urls[#urls + 1] = withKey(server() .. "/Videos/" .. it.Id .. "/master.m3u8?MediaSourceId=" .. urlEncode(srcId)
      .. "&PlaySessionId=" .. urlEncode(session) .. "&DeviceId=" .. deviceId()
      .. "&VideoCodec=h264&AudioCodec=aac,mp3&MaxStreamingBitrate=8000000&TranscodingMaxAudioChannels=2"
      .. "&SegmentContainer=ts&MinSegments=1&BreakOnNonKeyFrames=True")
    cb(urls, session, (not r.ok) and (r.status and ("HTTP " .. r.status) or r.error) or nil)
  end)
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
  local v = { item = it, title = it.Name or "", state = "starting", try = 0, controlsAt = love.timer.getTime() }
  M.video = v
  M.vstat = {}
  videoURLs(it, function(urls, session, infoErr)
    if M.video ~= v then return end
    v.urls, v.session, v.infoErr, v.try = urls, session, infoErr, 1
    android.videoPlay(urls[1], 0)
  end)
end

function M.closeVideo()
  local v = M.video
  if v then
    android.videoCommand("stop")
    -- tell the server it can stop converting
    if v.session and v.session ~= "" then
      request("DELETE", "/Videos/ActiveEncodings?DeviceId=" .. deviceId() .. "&PlaySessionId=" .. urlEncode(v.session), nil, function() end)
    end
  end
  M.video, M.full = nil, false
end

function M.isFull() return M.video ~= nil and M.full end

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

local fetchPoll = 0
local skipFetch = false
function M.update(dt)
  local done = {}
  local now = love.timer.getTime()
  if now - fetchPoll < 0.1 then skipFetch = true else fetchPoll = now skipFetch = false end
  for id in pairs(skipFetch and {} or pending) do
    local r = android.fetchResult(id)
    if type(r) == "table" and r.done then done[#done + 1] = { id, r } end
  end
  for _, d in ipairs(done) do
    local h = pending[d[1]]
    pending[d[1]] = nil
    if h then h(d[2]) end
    app.dirty()
  end
  local qc = M.login.qc
  if qc and now > qc.next then
    qc.next = now + 3
    request("GET", "/QuickConnect/Connect?secret=" .. urlEncode(qc.secret), nil, function(r)
      local d = r.ok and decode(r.body)
      if d and d.Authenticated and M.login.qc == qc then
        M.login.qc = nil
        request("POST", "/Users/AuthenticateWithQuickConnect", { Secret = qc.secret }, function(r2)
          signedIn(r2.ok and decode(r2.body))
        end)
      end
    end)
  end
  local v = M.video
  if v and v.urls and now - (v.polled or 0) > 0.5 then
    v.polled = now
    local st = android.videoStatus()
    if type(st) == "table" then
      local before = M.vstat or {}
      M.vstat = st
      if st.error and st.error ~= "" and (st.url == nil or st.url == v.urls[v.try]) then
        if v.try < #v.urls then
          -- this way didn't work; try the next one from where it got to
          v.errors = v.errors or {}
          v.errors[#v.errors + 1] = st.error
          v.try = v.try + 1
          android.videoPlay(v.urls[v.try], st.positionMs or 0)
          M.vstat = {}
        else
          v.state = "error"
        end
        app.dirty()
      elseif st.state ~= before.state or math.floor((st.positionMs or 0) / 1000) ~= math.floor((before.positionMs or 0) / 1000)
        or st.width ~= before.width then
        v.state = st.state
        app.dirty()
      end
      -- full screen: the controls step aside after a few seconds of playing
      if M.full and v.controls ~= false and st.state == "playing" and now - (v.controlsAt or now) > 5 then
        v.controls = false
        app.dirty()
      end
    end
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
      ui.closeKeyboard()
      M.runSearch()
    elseif field == "server" then M.login.focus = "user"
    elseif field == "user" then M.login.focus = "pass"
    else
      M.login.focus = nil
      ui.closeKeyboard()
      M.signIn()
    end
  end
end

function M.back()
  if M.search.typing or M.login.focus then
    M.search.typing, M.login.focus = false, nil
    ui.closeKeyboard()
    return true
  end
  if M.full then M.full = false return true end
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

local function fmt(ms)
  local t = math.floor((ms or 0) / 1000)
  local h, m = math.floor(t / 3600), math.floor(t / 60) % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, t % 60) end
  return string.format("%d:%02d", m, t % 60)
end

-- the video's own shape inside the room it has (TextureView stretches, so it's sized here)
local function fit(x, y, w, h)
  local st = M.vstat or {}
  local aspect = ((st.width or 0) > 0 and (st.height or 0) > 0) and st.width / st.height or 16 / 9
  local vw, vh = w, w / aspect
  if vh > h then vh, vw = h, h * aspect end
  return math.floor(x + (w - vw) / 2), math.floor(y + (h - vh) / 2), math.floor(vw), math.floor(vh)
end

local function statusLine()
  local v = M.video
  if v.state == "error" then
    local e = (M.vstat and M.vstat.error) or v.infoErr or "?"
    return T("Couldn't play this video ({error})", { error = e }), ui.hex("F09A8A")
  end
  if v.state == "starting" or v.state == "connecting" or v.state == "idle" then return T("Loading…"), ui.c.muted end
  return nil
end

-- play/pause, jump back and forward, the position
local function controls(x, y, w, h)
  local st = M.vstat or {}
  local on = st.state == "playing"
  local bh = h - 8
  ui.rect(ui.c.accent, x, y + 4, bh + 12, bh, bh / 2)
  ui.icon(on and "pause" or "play", x + (bh + 12 - 26) / 2, y + 4 + (bh - 26) / 2, 26, ui.c.onAccent)
  ui.hit({ kind = "jf:vcmd", what = "toggle" }, x, y + 4, bh + 12, bh)
  local bx = x + bh + 24
  bx = bx + ui.pill({ kind = "jf:vjump", d = -10000 }, "−10", bx, y + 4, bh, "off2") + 8
  bx = bx + ui.pill({ kind = "jf:vjump", d = 30000 }, "+30", bx, y + 4, bh, "off2") + 16
  local dur, pos = st.durationMs or 0, st.positionMs or 0
  local label = fmt(pos) .. " / " .. fmt(dur)
  local tw = ui.textWidth(label, "semibold", 15)
  local sw = x + w - tw - 16 - bx
  if dur > 0 and sw > 40 then
    local sy = y + h / 2
    ui.rect(ui.hex("2C2E33"), bx, sy - 3, sw, 6, 3)
    ui.rect(ui.c.accent, bx, sy - 3, sw * math.min(1, pos / dur), 6, 3)
    ui.circle(ui.c.text, bx + sw * math.min(1, pos / dur), sy, 9)
    ui.hit({ kind = "jf:vseek", x = bx, w = sw, dur = dur }, bx, y, sw, h)
  end
  ui.text(label, "semibold", 15, ui.c.muted, x + w - tw, y + (h - ui.fontHeight("semibold", 15)) / 2)
end

-- where the video goes, or nil (virtual units). Lua draws around it; Android draws the picture.
M.rect = nil

-- the Jellyfin tab of the Media screen. drawMapCard draws the map for the split view.
local function drawVideo(x, y, w, h, drawMapCard, navigating)
  local v = M.video
  -- top bar: title, swap, full screen, close
  local bx = x + w - 16
  local cw = ui.textWidth(T("Close"), "bold", 16) + 44
  bx = bx - cw
  ui.pill({ kind = "jf:closeVideo" }, T("Close"), bx, y + 6, 48, "off2")
  local fw = ui.textWidth(T("Full screen"), "bold", 16) + 44
  bx = bx - fw - 10
  ui.pill({ kind = "jf:full" }, T("Full screen"), bx, y + 6, 48, "off2")
  if navigating then
    local sw = ui.textWidth(T("Swap sides"), "bold", 16) + 44
    bx = bx - sw - 10
    ui.pill({ kind = "jf:swap" }, T("Swap sides"), bx, y + 6, 48, "off2")
  end
  ui.text(ui.fit(v.title, "bold", 20, bx - x - 36), "bold", 20, ui.c.text, x + 20, y + 16)
  local top, bottom = y + 64, y + h - 12
  local ax, aw = x + 16, w - 32
  if navigating then
    local mx, mw
    ax, aw, mx, mw = ui.split(x + 16, w - 32, 16, config.get("splitSwap"))
    drawMapCard(mx, top, mw, bottom - top)
  end
  local ch = 60
  local areaH = bottom - top - ch - 8
  ui.rect(ui.hex("000000"), ax, top, aw, areaH, 14)
  local line, col = statusLine()
  if line then ui.textWrap(line, "semibold", 16, col, ax + 20, top + areaH / 2 - 12, aw - 40, 3) end
  local vx, vy, vw, vh = fit(ax, top, aw, areaH)
  if v.state ~= "error" and v.urls then M.rect = { vx, vy, vw, vh } end
  controls(ax, top + areaH + 8, aw, ch)
end

-- full screen: the video over everything; tap it for the controls
function M.drawFull(W, H)
  local v = M.video
  ui.rect(ui.hex("000000"), 0, 0, W, H, 0)
  ui.hit({ kind = "jf:vtap" }, 0, 0, W, H)
  local ch = (v.controls ~= false) and 76 or 0
  local line, col = statusLine()
  if line then ui.textWrap(line, "semibold", 18, col, 40, H / 2 - 14, W - 80, 3) end
  local vx, vy, vw, vh = fit(0, 0, W, H - ch)
  if v.state ~= "error" and v.urls then M.rect = { vx, vy, vw, vh } end
  if ch > 0 then
    local cx, cw = 24, W - 48
    local ew = ui.textWidth(T("Exit full screen"), "bold", 16) + 44
    ui.pill({ kind = "jf:full" }, T("Exit full screen"), W - 24 - ew, H - ch + 10, 56, "off2")
    controls(cx, H - ch + 8, cw - ew - 16, 60)
  end
end

function M.draw(x, y, w, h, drawMapCard, navigating)
  M.rect = nil
  if not M.signedIn() then drawLogin(x, y, w, h) return end
  if M.video then drawVideo(x, y, w, h, drawMapCard, navigating) return end
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
function M.activate(id, vx)
  local k = id.kind
  if k == "jf:field" then
    M.login.focus = id.field
    M.search.typing = false
    ui.openKeyboard()
  elseif k == "jf:signIn" then
    M.login.focus = nil
    ui.closeKeyboard()
    M.signIn()
  elseif k == "jf:qc" then
    M.login.focus = nil
    ui.closeKeyboard()
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
    ui.openKeyboard()
  elseif k == "jf:item" then
    local it = id.item
    if AUDIO[it.Type] then playAudio(id.list, id.index)
    elseif VIDEO[it.Type] then playVideo(it)
    else openItem(it) end
  elseif k == "jf:cmd" then
    android.musicCommand(id.what)
    lastPoll = 0
  elseif k == "jf:closeVideo" then M.closeVideo()
  elseif k == "jf:swap" then config.set("splitSwap", not config.get("splitSwap"))
  elseif k == "jf:full" then
    M.full = not M.full
    if M.video then M.video.controls, M.video.controlsAt = true, love.timer.getTime() end
  elseif k == "jf:vtap" then
    if M.video then
      M.video.controls = M.video.controls == false
      M.video.controlsAt = love.timer.getTime()
    end
  elseif k == "jf:vcmd" then
    android.videoCommand(id.what)
    if M.video then M.video.controlsAt, M.video.polled = love.timer.getTime(), 0 end
  elseif k == "jf:vjump" then
    local st = M.vstat or {}
    android.videoCommand("seek", math.max(0, (st.positionMs or 0) + id.d))
    if M.video then M.video.controlsAt, M.video.polled = love.timer.getTime(), 0 end
  elseif k == "jf:vseek" then
    local f = math.max(0, math.min(1, ((vx or id.x) - id.x) / id.w))
    android.videoCommand("seek", math.floor(f * id.dur))
    if M.video then M.video.controlsAt, M.video.polled = love.timer.getTime(), 0 end
  elseif k == "jf:none" then -- busy
  else
    return false
  end
  app.dirty()
  return true
end

return M
