-- Road Trip: bridge to the Java side (LauncherBridge.java) through LuaJIT FFI + JNI.
-- On desktop it returns stub data so the UI can be worked on in plain LÖVE.

local ffi = require("ffi")
local utf8 = require("utf8")

local M = { isAndroid = love.system.getOS() == "Android" }

----------------------------------------------------------------------------------------------
-- JSON (small, strict enough for our own bridge traffic)
----------------------------------------------------------------------------------------------

local json = { array = {} } -- setmetatable({}, json.array) marks an empty table as []
M.json = json

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encString(s)
  local out = {}
  local ok = pcall(function()
    for _, cp in utf8.codes(s) do
      local ch
      if cp == 34 or cp == 92 or cp < 0x20 then
        ch = escapes[string.char(cp)] or string.format("\\u%04x", cp)
      elseif cp < 0x80 then
        ch = string.char(cp)
      elseif cp < 0x10000 then
        ch = string.format("\\u%04x", cp)
      else
        local v = cp - 0x10000
        ch = string.format("\\u%04x\\u%04x", 0xD800 + math.floor(v / 0x400), 0xDC00 + v % 0x400)
      end
      out[#out + 1] = ch
    end
  end)
  if not ok then
    -- invalid UTF-8: keep ASCII, drop the rest
    local clean = s:gsub('[%z\1-\31"\\\128-\255]', function(c)
      if escapes[c] then return escapes[c] end
      if c:byte() < 32 then return string.format("\\u%04x", c:byte()) end
      return ""
    end)
    return '"' .. clean .. '"'
  end
  return '"' .. table.concat(out) .. '"'
end

local function enc(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif t == "string" then return encString(v)
  elseif t == "table" then
    local parts = {}
    if rawget(v, 1) ~= nil or (next(v) == nil and getmetatable(v) == json.array) then
      for i = 1, #v do parts[i] = enc(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, val in pairs(v) do
      parts[#parts + 1] = encString(tostring(k)) .. ":" .. enc(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("json: can't encode " .. t)
end

function json.encode(v) return enc(v) end

local unescape = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

function json.decode(str)
  local pos = 1
  local function fail(m) error(("json: %s at %d"):format(m, pos), 0) end
  local function ws() pos = str:find("[^ \t\r\n]", pos) or #str + 1 end

  local function readString()
    pos = pos + 1
    local buf = {}
    while true do
      local s = str:find('["\\]', pos)
      if not s then fail("unterminated string") end
      buf[#buf + 1] = str:sub(pos, s - 1)
      if str:sub(s, s) == '"' then
        pos = s + 1
        return table.concat(buf)
      end
      local c = str:sub(s + 1, s + 1)
      if c == "u" then
        local cp = tonumber(str:sub(s + 2, s + 5), 16) or fail("bad \\u escape")
        pos = s + 6
        if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos, pos + 1) == "\\u" then
          local lo = tonumber(str:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        if cp >= 0xD800 and cp <= 0xDFFF then cp = 0xFFFD end
        buf[#buf + 1] = utf8.char(cp)
      else
        buf[#buf + 1] = unescape[c] or fail("bad escape")
        pos = s + 2
      end
    end
  end

  local value
  function value()
    ws()
    local c = str:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local t = {}
      ws()
      if str:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        ws()
        if str:sub(pos, pos) ~= '"' then fail("expected key") end
        local k = readString()
        ws()
        if str:sub(pos, pos) ~= ":" then fail("expected ':'") end
        pos = pos + 1
        t[k] = value()
        ws()
        local d = str:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1
      local t, n = setmetatable({}, json.array), 0
      ws()
      if str:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        n = n + 1
        t[n] = value()
        ws()
        local d = str:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif c == '"' then
      return readString()
    elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    end
    local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then fail("unexpected character") end
    pos = e + 1
    return tonumber(str:sub(s, e))
  end

  local ok, res = pcall(value)
  if not ok then return nil, res end
  return res
end

----------------------------------------------------------------------------------------------
-- JNI
----------------------------------------------------------------------------------------------

local sdl, J, bridgeCls, callMid

-- Slots in the JNINativeInterface function table (stable since JNI 1.1).
local SLOTS = {
  ExceptionDescribe       = { 16,  "void (*)(void*)" },
  ExceptionClear          = { 17,  "void (*)(void*)" },
  NewGlobalRef            = { 21,  "void* (*)(void*, void*)" },
  DeleteLocalRef          = { 23,  "void (*)(void*, void*)" },
  GetObjectClass          = { 31,  "void* (*)(void*, void*)" },
  GetMethodID             = { 33,  "void* (*)(void*, void*, const char*, const char*)" },
  CallObjectMethodA       = { 36,  "void* (*)(void*, void*, void*, const rt_jvalue*)" },
  GetStaticMethodID       = { 113, "void* (*)(void*, void*, const char*, const char*)" },
  CallStaticObjectMethodA = { 116, "void* (*)(void*, void*, void*, const rt_jvalue*)" },
  NewStringUTF            = { 167, "void* (*)(void*, const char*)" },
  GetStringUTFChars       = { 169, "const char* (*)(void*, void*, uint8_t*)" },
  ReleaseStringUTFChars   = { 170, "void (*)(void*, void*, const char*)" },
  ExceptionCheck          = { 228, "uint8_t (*)(void*)" },
}

if M.isAndroid then
  ffi.cdef [[
    typedef union { uint8_t z; int8_t b; uint16_t c; int16_t s; int32_t i; int64_t j; float f; double d; void *l; } rt_jvalue;
    void *SDL_GetAndroidJNIEnv(void);   /* SDL3, LÖVE 12 */
    void *SDL_GetAndroidActivity(void);
    void *SDL_AndroidGetJNIEnv(void);   /* SDL2, LÖVE 11.5 (inside liblove.so) */
    void *SDL_AndroidGetActivity(void);
  ]]
end

local getEnv, getActivity

-- LÖVE 12 ships SDL3 as its own library; LÖVE 11.5 links SDL2 into liblove.so.
local function loadSDL()
  local ok, lib = pcall(ffi.load, "SDL3")
  if ok and pcall(function() return lib.SDL_GetAndroidJNIEnv end) then
    sdl = lib
    getEnv = function() return lib.SDL_GetAndroidJNIEnv() end
    getActivity = function() return lib.SDL_GetAndroidActivity() end
    return
  end
  for _, name in ipairs({ "love", "SDL2" }) do
    local ok2, lib2 = pcall(ffi.load, name)
    if ok2 and pcall(function() return lib2.SDL_AndroidGetJNIEnv end) then
      sdl = lib2
      getEnv = function() return lib2.SDL_AndroidGetJNIEnv() end
      getActivity = function() return lib2.SDL_AndroidGetActivity() end
      return
    end
  end
  error("couldn't find SDL's Android functions")
end

local function env()
  local e = getEnv()
  if e == nil then error("no JNI environment") end
  if not J then
    local vt = ffi.cast("void***", e)[0]
    J = {}
    for name, slot in pairs(SLOTS) do J[name] = ffi.cast(slot[2], vt[slot[1]]) end
  end
  return e
end

local function check(e, what)
  if J.ExceptionCheck(e) ~= 0 then
    J.ExceptionDescribe(e)
    J.ExceptionClear(e)
    error("java exception: " .. what, 2)
  end
end

-- FindClass on SDL's native thread only sees system classes, so load ours through the
-- activity's class loader instead.
local function init()
  loadSDL()
  local e = env()
  local act = getActivity()
  if act == nil then error("no activity") end
  local actCls = J.GetObjectClass(e, act)
  local getLoader = J.GetMethodID(e, actCls, "getClassLoader", "()Ljava/lang/ClassLoader;")
  check(e, "getClassLoader id")
  local loader = J.CallObjectMethodA(e, act, getLoader, nil)
  check(e, "getClassLoader")
  local loaderCls = J.GetObjectClass(e, loader)
  local loadClass = J.GetMethodID(e, loaderCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
  check(e, "loadClass id")
  local name = J.NewStringUTF(e, "app.roadtrip.LauncherBridge")
  local args = ffi.new("rt_jvalue[1]")
  args[0].l = name
  local cls = J.CallObjectMethodA(e, loader, loadClass, args)
  check(e, "loadClass LauncherBridge")
  bridgeCls = J.NewGlobalRef(e, cls)
  callMid = J.GetStaticMethodID(e, bridgeCls, "call",
    "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  check(e, "call id")
  for _, ref in ipairs({ name, cls, loaderCls, loader, actCls, act }) do J.DeleteLocalRef(e, ref) end
end

local function javaCall(method, args)
  if not bridgeCls then
    local ok, err = pcall(init)
    if not ok then return nil, "bridge init failed: " .. tostring(err) end
  end
  local e = env()
  local act = getActivity()
  local jm = J.NewStringUTF(e, method)
  local ja = J.NewStringUTF(e, json.encode(args or {}))
  local v = ffi.new("rt_jvalue[3]")
  v[0].l, v[1].l, v[2].l = act, jm, ja
  local res = J.CallStaticObjectMethodA(e, bridgeCls, callMid, v)
  local threw = J.ExceptionCheck(e) ~= 0
  if threw then J.ExceptionDescribe(e) J.ExceptionClear(e) end
  local s
  if res ~= nil then
    local chars = J.GetStringUTFChars(e, res, nil)
    s = ffi.string(chars)
    J.ReleaseStringUTFChars(e, res, chars)
    J.DeleteLocalRef(e, res)
  end
  J.DeleteLocalRef(e, ja)
  J.DeleteLocalRef(e, jm)
  if act ~= nil then J.DeleteLocalRef(e, act) end
  if threw or not s then return nil, "java exception in " .. method end
  local r, err = json.decode(s)
  if not r then return nil, err end
  if not r.ok then return nil, r.error end
  return r.data
end

----------------------------------------------------------------------------------------------
-- Desktop stub
----------------------------------------------------------------------------------------------

local stubApps = { "Maps", "Music", "Phone", "Messages", "Podcasts", "Calendar", "Weather",
  "Settings", "Camera", "Files", "Waze", "Radio", "Clock", "Contacts", "Browser" }

local stubFetches = {}

local function stubCall(method, args)
  if method == "getApps" then
    if args and args.known == 1 then return { version = 1 } end
    local list = setmetatable({}, json.array)
    for i, label in ipairs(stubApps) do
      list[i] = { pkg = "com.example." .. label:lower(), activity = "Main", label = label }
    end
    return { version = 1, apps = list }
  elseif method == "isDefaultHome" then
    return true
  elseif method == "guardStatus" then
    return { serviceOn = false, enabled = true, stock = { "com.example.stocklauncher" } }
  elseif method == "homePresses" then
    return 0
  elseif method == "fetch" then
    stubFetches[#stubFetches + 1] = args.url
    return #stubFetches
  elseif method == "download" then
    stubFetches[#stubFetches + 1] = "download:" .. args.url
    return #stubFetches
  elseif method == "locationStart" then
    return true
  elseif method == "location" then
    return { permission = true, fix = { lat = 55.6761, lon = 12.5683, accuracy = 8, speed = -1, bearing = -1, ageMs = 500, provider = "stub" } }
  elseif method == "fetchResult" then
    local url = stubFetches[args.id] or ""
    if url:find("^download:") then return { done = true, ok = false, error = "no downloads on desktop" } end
    if url:find("photon") then
      return { done = true, ok = true, body = '{"features":[{"geometry":{"coordinates":[12.5681,55.6737]},"properties":{"name":"Tivoli Gardens","street":"Vesterbrogade","city":"Copenhagen","country":"Denmark"}},{"geometry":{"coordinates":[12.6,55.7]},"properties":{"name":"Nyhavn","city":"Copenhagen","country":"Denmark"}}]}' }
    end
    if url:find("routed%-car") then
      return { done = true, ok = true, body = '{"code":"Ok","routes":[{"distance":2400,"duration":420,"geometry":"_ibagBsz`pVvJtL","legs":[{"steps":[{"distance":1200,"duration":200,"name":"Vesterbrogade","maneuver":{"type":"depart","modifier":"straight","location":[12.5683,55.6761]}},{"distance":1200,"duration":220,"name":"Bernstorffsgade","maneuver":{"type":"turn","modifier":"right","location":[12.565,55.672]}},{"distance":0,"duration":0,"name":"","maneuver":{"type":"arrive","location":[12.5681,55.6737]}}]}]},{"distance":2700,"duration":480,"geometry":"_ibagBsz`pVvJtL","legs":[{"steps":[]}]}]}' }
    end
    if url:find("geocoding") then
      return { done = true, ok = true, body = '{"results":[{"name":"Copenhagen","admin1":"Capital Region","country":"Denmark","latitude":55.68,"longitude":12.57},{"name":"Copenhagen","admin1":"New York","country":"United States","latitude":43.89,"longitude":-75.67}]}' }
    end
    return { done = true, ok = true, body = '{"current":{"temperature_2m":7.4,"weather_code":3,"is_day":1},"daily":{"temperature_2m_max":[9.1],"temperature_2m_min":[3.2]}}' }
  elseif method == "calendar" then
    local now = os.time() * 1000
    return { permission = true, events = { { title = "Pick up groceries", begin = now + 25 * 60000, ["end"] = now + 55 * 60000, allDay = false, location = "" } } }
  elseif method == "diagnostics" then
    return { defaultHome = "app.roadtrip/app.roadtrip.RoadTripActivity",
      watched = { "com.android.launcher3/com.android.launcher3.uioverlays.QuickstepLauncher" },
      guard = { "08:00:01  com.android.launcher3/RecentsActivity  -> recents, left alone" }, nav = {} }
  elseif method == "navStatus" then
    return { active = true, pkg = "com.google.android.apps.maps", app = "Maps", title = "300 m",
      text = "Turn right onto Main Street", sub = "14:51 · 19 min · 12 km" }
  elseif method == "mediaStatus" then
    return { access = true, current = { pkg = "com.example.music", app = "Music", title = "Desert Highway",
      artist = "The Long Drives", album = "Mile Markers", durationMs = 241000, positionMs = 84000,
      playing = true, speed = 1, canPrev = true, canNext = true, canSeek = true } }
  elseif method == "updateStatus" then
    return { state = "none", current = 0, currentName = "desktop", latest = 0, latestName = "", notes = "", progress = 0 }
  end
  print("[android stub]", method, json.encode(args or {}))
  return true
end

----------------------------------------------------------------------------------------------
-- API
----------------------------------------------------------------------------------------------

function M.call(method, args)
  if not M.isAndroid then return stubCall(method, args) end
  return javaCall(method, args)
end

-- returns { version, apps? }; apps is left out when `known` is already the current version
function M.getApps(iconDir, known) return M.call("getApps", { iconDir = iconDir, iconSize = 192, known = known or -1 }) end
function M.launch(app) return M.call("launch", { pkg = app.pkg, activity = app.activity }) end
function M.isDefaultHome() return M.call("isDefaultHome") end
function M.openHomeSettings() return M.call("openHomeSettings") end
function M.openAppInfo(app) return M.call("openAppInfo", { pkg = app.pkg }) end
function M.voice() return M.call("voice") end
function M.guardStatus() return M.call("guardStatus") end
-- what's playing in any app (needs notification access); album art lands in artDir
function M.mediaStatus(artDir) return M.call("mediaStatus", { artDir = artDir }) end
function M.mediaCommand(action, posMs) return M.call("mediaCommand", { action = action, posMs = posMs }) end
function M.openMediaAccess() return M.call("openMediaAccess") end
-- the nav app's turn-by-turn notification (same notification access); turn arrow lands in dir
function M.navStatus(dir) return M.call("navStatus", { dir = dir }) end
-- background HTTPS GET: fetch() returns an id, fetchResult(id) -> { done, ok, body?, error? }
function M.fetch(url) return M.call("fetch", { url = url }) end
function M.fetchResult(id) return M.call("fetchResult", { id = id }) end
-- background download to an absolute path; poll with fetchResult(id)
function M.download(url, path) return M.call("download", { url = url, path = path }) end
-- position: locationStart() asks for permission and starts listening; location() -> { permission, fix? }
function M.locationStart() return M.call("locationStart") end
function M.location() return M.call("location") end
-- calendar: { permission, events = { { title, begin, end, allDay, location } } } (times in ms)
function M.calendar() return M.call("calendar") end
function M.calendarAllow() return M.call("calendarAllow") end
function M.calendarOpen(at) return M.call("calendarOpen", { at = at }) end
-- what the guard saw and did, plus raw nav notifications; shown in Settings → Diagnostics
function M.diagnostics() return M.call("diagnostics") end
-- how many times Home was pressed while Road Trip was running (only ever goes up)
function M.homePresses() return M.call("homePresses") end
function M.setGuardEnabled(on) return M.call("setGuardEnabled", { on = on }) end
function M.openStockLauncher() return M.call("openStockLauncher", { pauseMs = 120000 }) end
function M.openAccessibilitySettings() return M.call("openAccessibilitySettings") end
-- updates run on Java threads; poll updateStatus() for state/progress
function M.updateStatus() return M.call("updateStatus") end
function M.updateCheck(wifiOnly) return M.call("updateCheck", { wifiOnly = wifiOnly }) end
function M.updateDownload() return M.call("updateDownload") end
function M.updateInstall() return M.call("updateInstall") end

return M
