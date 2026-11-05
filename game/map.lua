-- Road Trip: the map. OpenFreeMap vector tiles drawn in Road Trip's own style, your
-- position, place search (Photon), routes and turn-by-turn (FOSSGIS OSRM), all keyless.
--
-- Everything slow happens in the background: tiles download on Java threads and are
-- decoded one per frame; searches and routes are polled.

local lg = love.graphics
local T = require("lang").T

local M = {}
local android, config, ui, json, app -- set by M.init

local TILE = 512       -- tile size in pixels at its own zoom
local MAXZ = 14        -- OpenFreeMap's deepest zoom; closer views scale z14 up
local MAX_TILES = 80   -- decoded tiles kept in memory
local TILEJSON = "https://tiles.openfreemap.org/planet"
local PHOTON = "https://photon.komoot.io/api/?limit=6&q="
local OSRM = "https://routing.openstreetmap.de/routed-car/route/v1/driving/"

local hex = function(h) return ui.hex(h) end
local listening = false -- location updates started (needs permission first)
local COL -- colours, filled in init (ui.hex needs ui)

M.view = { lat = 55.6761, lon = 12.5683, zoom = 15, rot = 0, follow = true }
M.mode = "browse" -- browse | search | overview | nav
M.fix = nil       -- latest position { lat, lon, accuracy, speed, bearing, ageMs }
M.permission = true
M.search = nil    -- { text, results?, busy, err?, dueAt? }
M.routes = nil    -- route choices for the overview
M.sel = 1
M.dest = nil      -- { name, sub, lat, lon }
M.nav = nil       -- active guidance

local tiles, tileCount, frame = {}, 0, 0
local tileURL, tileVer
local pending = {} -- request id -> handler
local queue = {}   -- tiles waiting to be decoded
local dlCount = 0
local zoomTarget
local lastLocPoll = 0
-- which way you're heading, smoothed: the map turns so the road ahead points up
M.heading = 0          -- degrees from north, what the map shows
local headingFix       -- the fix the last computed heading came from (for fixes without a bearing)
local lastHeadingFix
local headingTarget = 0
local moving = false

----------------------------------------------------------------------------------------------
-- geometry helpers
----------------------------------------------------------------------------------------------

local function project(lat, lon, z)
  local n = TILE * 2 ^ z
  local s = math.max(-0.9999, math.min(0.9999, math.sin(math.rad(lat))))
  return (lon + 180) / 360 * n, (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * n
end

local function unproject(x, y, z)
  local n = TILE * 2 ^ z
  local lon = x / n * 360 - 180
  local lat = math.deg(2 * math.atan(math.exp(math.pi * (1 - 2 * y / n))) - math.pi / 2)
  return lat, lon
end

local function haversine(lat1, lon1, lat2, lon2)
  local r = 6371000
  local p1, p2 = math.rad(lat1), math.rad(lat2)
  local dp, dl = p2 - p1, math.rad(lon2 - lon1)
  local a = math.sin(dp / 2) ^ 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ^ 2
  return 2 * r * math.asin(math.min(1, math.sqrt(a)))
end

-- metres in a local flat frame around lat0, for point-to-segment work
local function toLocal(lat, lon, lat0)
  return math.rad(lon) * 6371000 * math.cos(math.rad(lat0)), math.rad(lat) * 6371000
end

M.project, M.unproject, M.haversine = project, unproject, haversine

----------------------------------------------------------------------------------------------
-- Mapbox Vector Tile decoding (protobuf, just the parts we draw)
----------------------------------------------------------------------------------------------

local byte, floor = string.byte, math.floor

local function varint(s, p)
  local r, m = 0, 1
  while true do
    local b = byte(s, p)
    p = p + 1
    if b < 128 then return r + b * m, p end
    r = r + (b - 128) * m
    m = m * 128
  end
end

local function skip(s, p, wt)
  if wt == 0 then local _ _, p = varint(s, p) return p end
  if wt == 1 then return p + 8 end
  if wt == 2 then local len len, p = varint(s, p) return p + len end
  if wt == 5 then return p + 4 end
  error("mvt: wire type " .. wt)
end

local function zigzag(n) if n % 2 == 0 then return n / 2 end return -(n + 1) / 2 end

local function packed(s, p, e)
  local out, n = {}, 0
  while p < e do
    local v
    v, p = varint(s, p)
    n = n + 1
    out[n] = v
  end
  return out
end

local function decodeValue(s, p, e)
  local v
  while p < e do
    local key
    key, p = varint(s, p)
    local f, wt = floor(key / 8), key % 8
    if f == 1 and wt == 2 then
      local len
      len, p = varint(s, p)
      v = s:sub(p, p + len - 1)
      p = p + len
    elseif (f == 4 or f == 5) and wt == 0 then v, p = varint(s, p)
    elseif f == 6 and wt == 0 then local n n, p = varint(s, p) v = zigzag(n)
    elseif f == 7 and wt == 0 then local n n, p = varint(s, p) v = n ~= 0
    else p = skip(s, p, wt) end
  end
  return v
end

-- layers in `want`, each { name, extent, features = { { type, tags, geom } } }
local function decodeTile(s, want)
  local layers = {}
  local p, e = 1, #s + 1
  while p < e do
    local key
    key, p = varint(s, p)
    local f, wt = floor(key / 8), key % 8
    if f == 3 and wt == 2 then
      local len
      len, p = varint(s, p)
      local le = p + len
      local name, extent, keys, values, raw = nil, 4096, {}, {}, {}
      local q = p
      while q < le do
        local k2
        k2, q = varint(s, q)
        local f2, w2 = floor(k2 / 8), k2 % 8
        if w2 == 2 then
          local l2
          l2, q = varint(s, q)
          if f2 == 1 then name = s:sub(q, q + l2 - 1)
          elseif f2 == 2 then raw[#raw + 1] = { q, q + l2 }
          elseif f2 == 3 then keys[#keys + 1] = s:sub(q, q + l2 - 1)
          elseif f2 == 4 then values[#values + 1] = decodeValue(s, q, q + l2) end
          q = q + l2
        elseif w2 == 0 then
          local v
          v, q = varint(s, q)
          if f2 == 5 then extent = v end
        else q = skip(s, q, w2) end
      end
      if name and want[name] then
        local feats = {}
        for i, r in ipairs(raw) do
          local fp, fe = r[1], r[2]
          local typ, tags, geom = 0, nil, nil
          while fp < fe do
            local k3
            k3, fp = varint(s, fp)
            local f3, w3 = floor(k3 / 8), k3 % 8
            if f3 == 2 and w3 == 2 then local l3 l3, fp = varint(s, fp) tags = packed(s, fp, fp + l3) fp = fp + l3
            elseif f3 == 3 and w3 == 0 then typ, fp = varint(s, fp)
            elseif f3 == 4 and w3 == 2 then local l3 l3, fp = varint(s, fp) geom = packed(s, fp, fp + l3) fp = fp + l3
            else fp = skip(s, fp, w3) end
          end
          local t = {}
          if tags then
            for j = 1, #tags - 1, 2 do
              local kk = keys[tags[j] + 1]
              if kk then t[kk] = values[tags[j + 1] + 1] end
            end
          end
          feats[i] = { type = typ, tags = t, geom = geom or {} }
        end
        layers[name] = { name = name, extent = extent, features = feats }
      end
      p = le
    else
      p = skip(s, p, wt)
    end
  end
  return layers
end

-- command stream -> list of parts (lines or rings), coordinates in tile units
local function geometryParts(cmds)
  local parts, cur, x, y, i, n = {}, nil, 0, 0, 1, #cmds
  while i <= n do
    local c = cmds[i]
    i = i + 1
    local id, count = c % 8, floor(c / 8)
    if id == 1 or id == 2 then
      for _ = 1, count do
        if i + 1 > n then break end
        x = x + zigzag(cmds[i])
        y = y + zigzag(cmds[i + 1])
        i = i + 2
        if id == 1 then
          cur = { x, y }
          parts[#parts + 1] = cur
        elseif cur then
          cur[#cur + 1] = x
          cur[#cur + 1] = y
        end
      end
    end -- 7 = ClosePath: rings close implicitly
  end
  return parts
end

local function simplify(pts, tol)
  if #pts <= 4 then return pts end
  local out = { pts[1], pts[2] }
  local lx, ly = pts[1], pts[2]
  local t2 = tol * tol
  for i = 3, #pts - 2, 2 do
    local dx, dy = pts[i] - lx, pts[i + 1] - ly
    if dx * dx + dy * dy >= t2 then
      out[#out + 1], out[#out + 2] = pts[i], pts[i + 1]
      lx, ly = pts[i], pts[i + 1]
    end
  end
  out[#out + 1], out[#out + 2] = pts[#pts - 1], pts[#pts]
  return out
end

local function ringArea(r)
  local a = 0
  for i = 1, #r - 1, 2 do
    local j = i + 2
    if j > #r then j = 1 end
    a = a + r[i] * r[j + 1] - r[j] * r[i + 1]
  end
  return a / 2
end

M.decodeTile, M.geometryParts = decodeTile, geometryParts -- for tests

----------------------------------------------------------------------------------------------
-- tiles: download, decode, turn into meshes
----------------------------------------------------------------------------------------------

local WANT = { water = true, landcover = true, park = true, transportation = true }

-- road classes, least important first so major roads draw on top; widths in px at z16
local ROADS = {
  { classes = { service = true, track = true }, w = 4, col = "1F2427" },
  { classes = { minor = true }, w = 6, col = "262C30" },
  { classes = { tertiary = true }, w = 8, col = "2B3237" },
  { classes = { secondary = true }, w = 9, col = "2F363C" },
  { classes = { primary = true }, w = 11, col = "343C42" },
  { classes = { trunk = true, motorway = true }, w = 13, col = "3D454C" },
}

local function roadGroup(class)
  for i, g in ipairs(ROADS) do
    if g.classes[class] then return i end
  end
end

-- vertices for the default mesh format: x, y, u, v, r, g, b, a
local function vtx(out, x, y) out[#out + 1] = { x, y, 0, 0, 1, 1, 1, 1 } end

local function addPolygon(out, ring)
  if #ring < 6 then return end
  local ok, tris = pcall(love.math.triangulate, ring)
  if not ok then return end
  for _, t in ipairs(tris) do
    vtx(out, t[1], t[2]) vtx(out, t[3], t[4]) vtx(out, t[5], t[6])
  end
end

local function addLine(out, pts, hw)
  for i = 1, #pts - 3, 2 do
    local x1, y1, x2, y2 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0 then
      local ux, uy = dx / len, dy / len
      local nx, ny = -uy * hw, ux * hw
      local e = hw * 0.9 -- run past each end a little so corners have no gaps
      local ax, ay, bx, by = x1 - ux * e, y1 - uy * e, x2 + ux * e, y2 + uy * e
      vtx(out, ax + nx, ay + ny) vtx(out, bx + nx, by + ny) vtx(out, bx - nx, by - ny)
      vtx(out, ax + nx, ay + ny) vtx(out, bx - nx, by - ny) vtx(out, ax - nx, ay - ny)
    end
  end
end

local function mesh(verts)
  if #verts < 3 then return nil end
  return lg.newMesh(verts, "triangles", "static")
end

-- shapes from decoded layers, kept so meshes can be rebuilt when the zoom bucket changes
local function shapesFrom(layers, extent)
  local tol = extent / 512 -- about a pixel at the tile's own zoom
  local sh = { water = {}, holes = {}, green = {}, roads = {} }
  for i = 1, #ROADS do sh.roads[i] = {} end
  local function polys(layer, dst)
    if not layer then return end
    for _, f in ipairs(layer.features) do
      if f.type == 3 then
        for _, r in ipairs(geometryParts(f.geom)) do
          local s = simplify(r, tol)
          if ringArea(s) >= 0 then dst[#dst + 1] = s else sh.holes[#sh.holes + 1] = s end
        end
      end
    end
  end
  polys(layers.water, sh.water)
  polys(layers.park, sh.green)
  if layers.landcover then
    for _, f in ipairs(layers.landcover.features) do
      local c = f.tags.class
      if f.type == 3 and (c == "wood" or c == "grass" or c == "forest") then
        for _, r in ipairs(geometryParts(f.geom)) do
          local s = simplify(r, tol)
          if ringArea(s) >= 0 then sh.green[#sh.green + 1] = s end
        end
      end
    end
  end
  if layers.transportation then
    for _, f in ipairs(layers.transportation.features) do
      local g = f.type == 2 and roadGroup(f.tags.class)
      if g then
        for _, l in ipairs(geometryParts(f.geom)) do sh.roads[g][#sh.roads[g] + 1] = simplify(l, tol) end
      end
    end
  end
  return sh
end

local function buildMeshes(t, zb)
  local sh = t.shapes
  local unitsPerPx = t.extent / (TILE * 2 ^ (zb - t.z))
  local widthScale = 2 ^ ((zb - 16) * 0.55)
  local water, holes, green = {}, {}, {}
  for _, r in ipairs(sh.water) do addPolygon(water, r) end
  for _, r in ipairs(sh.holes) do addPolygon(holes, r) end
  for _, r in ipairs(sh.green) do addPolygon(green, r) end
  local roads = {}
  for i, g in ipairs(ROADS) do
    local v = {}
    local hw = g.w * widthScale * unitsPerPx / 2
    for _, l in ipairs(sh.roads[i]) do addLine(v, l, hw) end
    roads[i] = mesh(v)
  end
  t.meshes = { water = mesh(water), holes = mesh(holes), green = mesh(green), roads = roads }
  t.zb = zb
end

local function tileKey(z, x, y) return z .. "/" .. x .. "/" .. y end
local function tilePath(z, x, y) return "tiles/" .. (tileVer or "v") .. "/" .. z .. "/" .. x .. "/" .. y .. ".pbf" end

local function request(id, handler) if type(id) == "number" then pending[id] = handler end end

local function evict()
  if tileCount <= MAX_TILES then return end
  local oldestK, oldest
  for k, t in pairs(tiles) do
    if t.state == "ready" and (not oldest or t.used < oldest.used) then oldestK, oldest = k, t end
  end
  if oldestK then
    tiles[oldestK] = nil
    tileCount = tileCount - 1
  end
end

-- the tile if it's ready to draw; otherwise starts getting it
local function getTile(z, x, y, zb)
  local k = tileKey(z, x, y)
  local t = tiles[k]
  if not t then
    t = { z = z, x = x, y = y, state = "new", used = frame }
    tiles[k] = t
    tileCount = tileCount + 1
    evict()
  end
  t.used = frame
  if t.state == "new" or (t.state == "failed" and love.timer.getTime() > t.retryAt) then
    if love.filesystem.getInfo(tilePath(z, x, y)) then
      t.state = "queued"
      queue[#queue + 1] = t
    elseif tileURL and dlCount < 6 then
      t.state = "downloading"
      dlCount = dlCount + 1
      local url = tileURL:gsub("{z}", z):gsub("{x}", x):gsub("{y}", y)
      local path = tilePath(z, x, y)
      love.filesystem.createDirectory(path:match("^(.*)/"))
      request(android.download(url, love.filesystem.getSaveDirectory() .. "/" .. path), function(r)
        dlCount = dlCount - 1
        if r.ok then
          t.state = "queued"
          queue[#queue + 1] = t
        else
          t.state, t.retryAt = "failed", love.timer.getTime() + 20
        end
      end)
    end
  end
  if t.state == "ready" then
    if t.zb ~= zb then buildMeshes(t, zb) end
    return t
  end
end

local function decodeNext()
  local t = table.remove(queue, 1)
  if not t then return end
  local data = love.filesystem.read(tilePath(t.z, t.x, t.y))
  if not data then t.state, t.retryAt = "failed", love.timer.getTime() + 20 return end
  if byte(data, 1) == 0x1f and byte(data, 2) == 0x8b then
    local ok, raw = pcall(love.data.decompress, "string", "gzip", data)
    if not ok then t.state, t.retryAt = "failed", love.timer.getTime() + 60 return end
    data = raw
  end
  local ok, layers = pcall(decodeTile, data, WANT)
  if not ok then
    print("map: tile decode failed " .. tostring(layers))
    t.state, t.retryAt = "failed", love.timer.getTime() + 600
    return
  end
  local extent = 4096
  for _, l in pairs(layers) do extent = l.extent end
  t.extent = extent
  t.shapes = shapesFrom(layers, extent)
  t.state = "ready"
  app.dirty()
end

----------------------------------------------------------------------------------------------
-- routes and turn instructions
----------------------------------------------------------------------------------------------

-- Google's encoded polyline, at 1e6 precision (OSRM's polyline6)
local function decodePolyline(str, precision)
  local f = 10 ^ (precision or 6)
  local pts, lat, lon, i, n = {}, 0, 0, 1, #str
  while i <= n do
    local result, shift, b = 0, 0, 0
    repeat
      b = byte(str, i) - 63
      i = i + 1
      result = result + (b % 32) * 2 ^ shift
      shift = shift + 5
    until b < 32 or i > n
    lat = lat + ((result % 2 == 1) and -(result + 1) / 2 or result / 2)
    result, shift = 0, 0
    if i > n then break end
    repeat
      b = byte(str, i) - 63
      i = i + 1
      result = result + (b % 32) * 2 ^ shift
      shift = shift + 5
    until b < 32 or i > n
    lon = lon + ((result % 2 == 1) and -(result + 1) / 2 or result / 2)
    pts[#pts + 1] = { lat / f, lon / f }
  end
  return pts
end
M.decodePolyline = decodePolyline

local function instruction(st)
  local name = (st.name and st.name ~= "") and st.name or nil
  local m = st.modifier or ""
  local t = st.type
  -- "X" or "X onto <street>", each as its own sentence so languages can order the words
  local function act(plain, withName)
    if name then return T(withName, { street = name }) end
    return T(plain)
  end
  if t == "arrive" then return T("Arrive at your destination") end
  if t == "depart" then return name and T("Head along {street}", { street = name }) or T("Start the route") end
  if t == "roundabout" or t == "rotary" or t == "roundabout turn" then
    if name then return T("At the roundabout, take exit {n} onto {street}", { n = st.exit or 1, street = name }) end
    return T("At the roundabout, take exit {n}", { n = st.exit or 1 })
  end
  if t == "merge" then return act("Merge", "Merge onto {street}") end
  if t == "on ramp" then return act("Take the ramp", "Take the ramp onto {street}") end
  if t == "off ramp" then return act("Take the exit", "Take the exit onto {street}") end
  if t == "fork" then
    if m:find("left") then return act("Keep left", "Keep left onto {street}") end
    return act("Keep right", "Keep right onto {street}")
  end
  if m == "uturn" then return act("Make a U-turn", "Make a U-turn onto {street}") end
  if m == "straight" or t == "continue" or t == "new name" then return act("Continue", "Continue onto {street}") end
  if m == "left" then return act("Turn left", "Turn left onto {street}") end
  if m == "right" then return act("Turn right", "Turn right onto {street}") end
  if m == "slight left" then return act("Turn slightly left", "Turn slightly left onto {street}") end
  if m == "slight right" then return act("Turn slightly right", "Turn slightly right onto {street}") end
  if m == "sharp left" then return act("Turn sharp left", "Turn sharp left onto {street}") end
  if m == "sharp right" then return act("Turn sharp right", "Turn sharp right onto {street}") end
  return act("Continue", "Continue onto {street}")
end

local function arrowIcon(st)
  local m, t = st.modifier or "", st.type
  if t == "arrive" then return "pin" end
  if t == "roundabout" or t == "rotary" or t == "roundabout turn" then return "roundabout" end
  if m == "uturn" then return "uturn" end
  if m:find("left") then return m:find("slight") and "slightLeft" or "turnLeft" end
  if m:find("right") then return m:find("slight") and "slightRight" or "turn" end
  return "straight"
end
M.instruction, M.arrowIcon = instruction, arrowIcon

local function fmtDist(m)
  if m < 1000 then
    local r = m < 100 and 10 or 50
    return string.format("%d m", math.floor(m / r + 0.5) * r)
  end
  if m < 10000 then return string.format("%.1f km", m / 1000) end
  return string.format("%d km", math.floor(m / 1000 + 0.5))
end

local function fmtDur(s)
  local mins = math.floor(s / 60 + 0.5)
  if mins < 60 then return T("{n} min", { n = mins }) end
  return T("{h} h {m} min", { h = math.floor(mins / 60), m = string.format("%02d", mins % 60) })
end
M.fmtDist, M.fmtDur = fmtDist, fmtDur

-- OSRM route -> { coords, cum, distance, duration, steps }
local function parseRoute(r)
  local coords = decodePolyline(r.geometry or "", 6)
  if #coords < 2 then return nil end
  local cum = { 0 }
  for i = 2, #coords do
    cum[i] = cum[i - 1] + haversine(coords[i - 1][1], coords[i - 1][2], coords[i][1], coords[i][2])
  end
  local steps, idx = {}, 1
  for _, leg in ipairs(r.legs or {}) do
    for _, s in ipairs(leg.steps or {}) do
      local mv = s.maneuver or {}
      local loc = mv.location or {}
      local lon, lat = loc[1], loc[2]
      -- where on the line this step starts: nearest point from here on
      if lat and lon then
        local best, bestD = idx, math.huge
        for i = idx, math.min(#coords, idx + 4000) do
          local dl, dn = coords[i][1] - lat, coords[i][2] - lon
          local d = dl * dl + dn * dn
          if d < bestD then best, bestD = i, d end
        end
        idx = best
      end
      steps[#steps + 1] = {
        type = mv.type, modifier = mv.modifier, exit = mv.exit, name = s.name or "",
        at = cum[idx], lat = lat, lon = lon,
      }
    end
  end
  return { coords = coords, cum = cum, distance = r.distance or cum[#cum], duration = r.duration or 0, steps = steps }
end

local function routeURL(fromLat, fromLon, toLat, toLon)
  return string.format("%s%.6f,%.6f;%.6f,%.6f?overview=full&geometries=polyline6&steps=true&alternatives=true",
    OSRM, fromLon, fromLat, toLon, toLat)
end

-- fit the view to show a whole route
local function fitRoute(route, w, h)
  local minLat, maxLat, minLon, maxLon = 90, -90, 180, -180
  for _, c in ipairs(route.coords) do
    minLat, maxLat = math.min(minLat, c[1]), math.max(maxLat, c[1])
    minLon, maxLon = math.min(minLon, c[2]), math.max(maxLon, c[2])
  end
  local z = 17
  while z > 3 do
    local x1, y1 = project(maxLat, minLon, z)
    local x2, y2 = project(minLat, maxLon, z)
    if (x2 - x1) < w * 0.8 and (y2 - y1) < h * 0.8 then break end
    z = z - 0.25
  end
  local cx, cy = project(maxLat, minLon, z)
  local dx, dy = project(minLat, maxLon, z)
  M.view.lat, M.view.lon = unproject((cx + dx) / 2, (cy + dy) / 2, z)
  M.view.zoom, M.view.rot, M.view.follow = z, 0, false
  zoomTarget = nil
end

-- from: where to start; defaults to your position. Without one yet, the request waits for
-- the first fix (or for "From the map's centre" in the route panel).
local function requestRoutes(lat, lon, from)
  local f = from or M.fix
  if not f then
    M.waitingFix = { lat = lat, lon = lon }
    M.routesBusy = false
    app.dirty()
    return
  end
  M.waitingFix = nil
  M.routesBusy = true
  local id = android.fetch(routeURL(f.lat, f.lon, lat, lon))
  request(id, function(r)
    M.routesBusy = false
    local d = r.ok and json.decode(r.body or "")
    if not d or d.code ~= "Ok" or not d.routes or #d.routes == 0 then
      app.toast(d and d.message or T("Couldn't find a route"))
      return
    end
    local list = {}
    for _, rr in ipairs(d.routes) do
      local p = parseRoute(rr)
      if p then list[#list + 1] = p end
    end
    if #list == 0 then app.toast(T("Couldn't find a route")) return end
    if not M.dest then return end -- cancelled meanwhile
    if M.mode == "nav" and M.nav then
      -- a re-route: swap in the new line, keep going
      M.nav.route, M.nav.idx, M.nav.off = list[1], 1, 0
      app.toast(T("New route"))
    else
      M.routes, M.sel, M.mode = list, 1, "overview"
      M.wantFit = true
    end
    app.dirty()
  end)
end

----------------------------------------------------------------------------------------------
-- guidance
----------------------------------------------------------------------------------------------

local function startNav()
  local route = M.routes and M.routes[M.sel]
  if not route then return end
  M.nav = { route = route, idx = 1, along = 0, off = 0, offCount = 0, lastReroute = -math.huge, arrivedAt = nil }
  M.mode = "nav"
  M.view.follow, M.view.zoom, zoomTarget = true, 16.5, nil
  -- remember the destination
  local recents = config.get("mapRecents") or {}
  local out = setmetatable({ M.dest }, json.array)
  for _, r in ipairs(recents) do
    if #out >= 6 then break end
    if not (r.lat == M.dest.lat and r.lon == M.dest.lon) then out[#out + 1] = r end
  end
  config.set("mapRecents", out)
end

local function endNav()
  M.nav, M.routes, M.dest, M.waitingFix = nil, nil, nil, nil
  M.mode = "browse"
  M.view.rot, M.view.follow = 0, true
end

local function updateNav()
  local n, f = M.nav, M.fix
  if not (n and f) then return end
  local r = n.route
  local c = r.coords
  local lat0 = f.lat
  local px, py = toLocal(f.lat, f.lon, lat0)
  local bestI, bestD, bestT = n.idx, math.huge, 0
  for i = math.max(1, n.idx - 10), math.min(#c - 1, n.idx + 400) do
    local ax, ay = toLocal(c[i][1], c[i][2], lat0)
    local bx, by = toLocal(c[i + 1][1], c[i + 1][2], lat0)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
    local qx, qy = ax + t * dx - px, ay + t * dy - py
    local d = qx * qx + qy * qy
    if d < bestD then bestI, bestD, bestT = i, d, t end
  end
  n.idx = bestI
  n.off = math.sqrt(bestD)
  n.along = r.cum[bestI] + bestT * (r.cum[bestI + 1] - r.cum[bestI])
  local now = love.timer.getTime()

  -- off the route for three fixes in a row: ask for a new one (FOSSGIS allows 1/s; we wait 15 s)
  if n.off > 50 and (f.accuracy or 99) < 40 then n.offCount = n.offCount + 1 else n.offCount = 0 end
  if n.offCount >= 3 and now - n.lastReroute > 15 and M.dest then
    n.lastReroute, n.offCount = now, 0
    requestRoutes(M.dest.lat, M.dest.lon)
  end

  local remaining = math.max(0, r.distance - n.along)
  if remaining < 25 and not n.arrivedAt then n.arrivedAt = now end
end

-- what's next, for the turn card and Home's Navigation widget
function M.guidance()
  local n = M.nav
  if not n then return nil end
  local r = n.route
  local next, after
  for i, s in ipairs(r.steps) do
    if s.type ~= "depart" and s.at > n.along + 3 then
      next, after = s, r.steps[i + 1]
      break
    end
  end
  local remaining = math.max(0, r.distance - n.along)
  local remTime = r.distance > 0 and r.duration * remaining / r.distance or 0
  local g = {
    arrived = n.arrivedAt ~= nil,
    remaining = remaining, remTime = remTime,
    arrival = os.date("%H:%M", os.time() + math.floor(remTime)),
    dest = M.dest and M.dest.name or "",
  }
  if g.arrived or not next then
    g.title, g.text, g.icon = T("You've arrived"), g.dest, "pin"
  else
    g.title = fmtDist(next.at - n.along)
    g.text = instruction(next)
    g.icon = arrowIcon(next)
    if after and after.type ~= "arrive" then 
      local nx = instruction(after)
      if require("lang").code == "en" then nx = nx:gsub("^%u", string.lower) end
      g.then_ = T("Then {next}", { next = nx })
    end
  end
  return g
end

----------------------------------------------------------------------------------------------
-- search
----------------------------------------------------------------------------------------------

local function urlEncode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function runSearch()
  local s = M.search
  if not s or s.busy then return end
  local q = s.text:gsub("^%s+", ""):gsub("%s+$", "")
  if #q < 2 then s.results = nil return end
  s.busy, s.err, s.dueAt = true, nil, nil
  local url = PHOTON .. urlEncode(q)
  if M.fix then url = url .. string.format("&lat=%.4f&lon=%.4f", M.fix.lat, M.fix.lon) end
  local asked = s.text
  request(android.fetch(url), function(r)
    if M.search ~= s then return end
    s.busy = false
    local d = r.ok and json.decode(r.body or "")
    if not d then s.err = T("Couldn't search; check the connection") return end
    local list = {}
    for _, f in ipairs(d.features or {}) do
      local p, g = f.properties or {}, f.geometry or {}
      local co = g.coordinates or {}
      if co[1] and co[2] then
        local name = p.name or p.street or T("Place")
        local subParts = {}
        if p.street and p.name ~= p.street then
          subParts[#subParts + 1] = p.street .. (p.housenumber and (" " .. p.housenumber) or "")
        end
        if p.city and p.city ~= name then subParts[#subParts + 1] = p.city end
        if p.country then subParts[#subParts + 1] = p.country end
        list[#list + 1] = { name = name, sub = table.concat(subParts, ", "), lat = co[2], lon = co[1] }
      end
    end
    s.results = list
    if #list == 0 then s.err = T("Nothing found") end
    if s.text ~= asked then s.dueAt = love.timer.getTime() + 0.3 end -- typed more meanwhile
    app.dirty()
  end)
end

function M.openSearch()
  M.mode = "search"
  M.search = { text = "", busy = false }
  love.keyboard.setTextInput(true)
end

local function closeSearch()
  M.search = nil
  love.keyboard.setTextInput(false)
  M.mode = M.routes and "overview" or "browse"
end

local function choose(place)
  M.dest = place
  M.search = nil
  love.keyboard.setTextInput(false)
  requestRoutes(place.lat, place.lon)
  M.mode = "overview"
  M.routes = nil
end

function M.wantsText() return M.search ~= nil end

function M.textinput(t)
  M.search.text = M.search.text .. t
  M.search.dueAt = love.timer.getTime() + 0.6 -- search once typing pauses
end

function M.keypressed(key)
  local s = M.search
  if key == "backspace" then
    local off = require("utf8").offset(s.text, -1)
    if off then s.text = s.text:sub(1, off - 1) end
    s.dueAt = love.timer.getTime() + 0.6
  elseif key == "return" or key == "kpenter" then
    s.dueAt = nil
    runSearch()
  elseif key == "escape" then
    closeSearch()
  end
end

----------------------------------------------------------------------------------------------
-- updating
----------------------------------------------------------------------------------------------

function M.init(deps)
  android, config, ui, json, app = deps.android, deps.config, deps.ui, deps.android.json, deps.app
  COL = {
    bg = hex("15191A"), water = hex("132029"), green = hex("17221B"),
    route = ui.c.accent, casing = hex("0E0F11"), alt = hex("3A3C41"),
  }
  for _, g in ipairs(ROADS) do g.color = hex(g.col) end
  local last = config.get("mapLast")
  if last then M.view.lat, M.view.lon = last.lat, last.lon end
end

-- called when the Map screen opens: start location, get the tile address
function M.open()
  listening = android.locationStart() == true
  if not tileURL then
    request(android.fetch(TILEJSON), function(r)
      local d = r.ok and json.decode(r.body or "")
      local t = d and d.tiles and d.tiles[1]
      if t then
        tileURL = t
        tileVer = t:match("/planet/([^/]+)/") or "v"
        app.dirty()
      end
    end)
  end
end

function M.update(dt, onScreen)
  frame = frame + 1
  for id, handler in pairs(pending) do
    local r = android.fetchResult(id)
    if type(r) == "table" and r.done then
      pending[id] = nil
      handler(r)
      app.dirty()
    end
  end
  if onScreen then decodeNext() end

  local now = love.timer.getTime()
  if (onScreen or M.nav or M.waitingFix) and now - lastLocPoll > 0.5 then
    lastLocPoll = now
    local s = android.location()
    if type(s) == "table" then
      M.permission = s.permission
      if s.permission and not listening then listening = android.locationStart() == true end
      local f = s.fix
      if f and (not M.fix or f.lat ~= M.fix.lat or f.lon ~= M.fix.lon) then
        M.fix = f
        if M.nav then updateNav() end
        if M.waitingFix and M.dest then requestRoutes(M.waitingFix.lat, M.waitingFix.lon) end
        app.dirty()
      end
    end
  end

  -- which way the car is going: GPS bearing while moving, else from how far it moved
  local f = M.fix
  if f and f ~= lastHeadingFix then
    lastHeadingFix = f
    local spd = f.speed or -1
    if spd > 1.5 and (f.bearing or -1) >= 0 then
      headingTarget, headingFix, moving = f.bearing, f, true
    elseif headingFix then
      local d = haversine(headingFix.lat, headingFix.lon, f.lat, f.lon)
      if d > 12 and d > (f.accuracy or 0) then
        local y = math.sin(math.rad(f.lon - headingFix.lon)) * math.cos(math.rad(f.lat))
        local x = math.cos(math.rad(headingFix.lat)) * math.sin(math.rad(f.lat))
          - math.sin(math.rad(headingFix.lat)) * math.cos(math.rad(f.lat)) * math.cos(math.rad(f.lon - headingFix.lon))
        headingTarget, headingFix = (math.deg((math.atan2 or math.atan)(y, x)) + 360) % 360, f
        moving = spd < 0 or spd > 1.5
      end
    else
      headingFix = f
    end
    if spd >= 0 and spd < 0.8 then moving = false end
  end
  local target = config.get("mapNorthUp") and 0 or headingTarget
  local hd = ((target - M.heading + 540) % 360) - 180
  M.turning = math.abs(hd) > 0.5
  if math.abs(hd) > 0.05 then M.heading = (M.heading + hd * math.min(1, dt * 2)) % 360 end
  -- follow the car: centre on it, turned the way it's going (or north up, if chosen)
  if f and M.view.follow then
    local k = math.min(1, dt * 4)
    M.view.lat = M.view.lat + (f.lat - M.view.lat) * k
    M.view.lon = M.view.lon + (f.lon - M.view.lon) * k
    M.view.rot = M.heading
  end
  if zoomTarget then
    local d = zoomTarget - M.view.zoom
    if math.abs(d) < 0.01 then M.view.zoom, zoomTarget = zoomTarget, nil
    else M.view.zoom = M.view.zoom + d * math.min(1, dt * 8) end
  end
  if M.search and M.search.dueAt and now > M.search.dueAt then runSearch() end
  -- arrived: finish 20 s later, whether or not new positions come in
  if M.nav and M.nav.arrivedAt and now - M.nav.arrivedAt > 20 then
    endNav()
    app.dirty()
  end
end

-- keep drawing every frame while something moves
function M.busy()
  return zoomTarget ~= nil or #queue > 0 or M.nav ~= nil or (M.view.follow and M.fix ~= nil and M.mode ~= "overview")
end

function M.pan(dx, dy)
  local v = M.view
  local a = math.rad(v.rot)
  local rx = dx * math.cos(a) + dy * math.sin(a)
  local ry = -dx * math.sin(a) + dy * math.cos(a)
  local cx, cy = project(v.lat, v.lon, v.zoom)
  v.lat, v.lon = unproject(cx - rx, cy - ry, v.zoom)
  v.follow = false
  config.data.mapLast = { lat = v.lat, lon = v.lon } -- saved on the next config write
end

----------------------------------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------------------------------

local function drawMesh(m, sx, sy, k)
  if m then lg.draw(m, sx, sy, 0, k, k) end
end

local function routePoints(route, cx, cy, z)
  local pts = {}
  for _, c in ipairs(route.coords) do
    local x, y = project(c[1], c[2], z)
    pts[#pts + 1] = x - cx
    pts[#pts + 1] = y - cy
  end
  return pts
end

local function drawRouteLine(pts, width, color, casing)
  if #pts < 4 then return end
  lg.setLineJoin("bevel")
  if casing then
    lg.setColor(casing)
    lg.setLineWidth(width + 8)
    lg.line(pts)
  end
  lg.setColor(color)
  lg.setLineWidth(width)
  lg.line(pts)
end

-- the map itself, filling x0..x0+w, y0..y0+h (virtual units)
function M.drawMap(x0, y0, w, h, opts)
  local S = ui.S
  local v = (opts and opts.view) or M.view
  lg.setScissor(x0 * S, y0 * S, w * S, h * S)
  ui.rect(COL.bg, x0, y0, w, h)
  local z = v.zoom
  local zs = math.max(0, math.min(MAXZ, math.floor(z)))
  local zb = math.max(10, math.min(18, math.floor(z + 0.5)))
  local cx, cy = project(v.lat, v.lon, z)
  local tsz = TILE * 2 ^ (z - zs)
  local ax = x0 + w / 2
  -- looking ahead: the car sits lower on the screen while it's guided or driving heading-up
  local ahead = M.mode == "nav" or (v.follow ~= false and moving and not config.get("mapNorthUp"))
  local ay = y0 + h * (ahead and 0.66 or 0.5)

  lg.push()
  lg.translate(ax, ay)
  lg.rotate(-math.rad(v.rot))
  local r = math.sqrt(w * w + h * h)
  local n = 2 ^ zs
  local tx0, tx1 = math.floor((cx - r) / tsz), math.floor((cx + r) / tsz)
  local ty0, ty1 = math.max(0, math.floor((cy - r) / tsz)), math.min(n - 1, math.floor((cy + r) / tsz))
  local list = {}
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do
      local t = getTile(zs, tx % n, ty, zb)
      if t and t.meshes then list[#list + 1] = { t = t, sx = tx * tsz - cx, sy = ty * tsz - cy } end
    end
  end
  -- layer by layer across all tiles, so a road on one tile never hides under the next tile's water
  for _, it in ipairs(list) do
    local k = tsz / it.t.extent
    lg.setColor(COL.water) drawMesh(it.t.meshes.water, it.sx, it.sy, k)
    lg.setColor(COL.bg) drawMesh(it.t.meshes.holes, it.sx, it.sy, k)
    lg.setColor(COL.green) drawMesh(it.t.meshes.green, it.sx, it.sy, k)
  end
  for gi, g in ipairs(ROADS) do
    lg.setColor(g.color)
    for _, it in ipairs(list) do drawMesh(it.t.meshes.roads[gi], it.sx, it.sy, tsz / it.t.extent) end
  end

  -- routes: alternatives grey, the chosen or active one in the accent colour
  COL.route = ui.c.accent
  if M.mode == "overview" and M.routes then
    for i, rt in ipairs(M.routes) do
      if i ~= M.sel then drawRouteLine(routePoints(rt, cx, cy, z), 8, COL.alt) end
    end
    local rt = M.routes[M.sel]
    if rt then drawRouteLine(routePoints(rt, cx, cy, z), 12, COL.route, COL.casing) end
  elseif M.nav then
    drawRouteLine(routePoints(M.nav.route, cx, cy, z), 16, COL.route, COL.casing)
  end

  -- destination pin
  local dest = M.dest
  if dest and (M.mode == "overview" or M.mode == "nav") then
    local dx, dy = project(dest.lat, dest.lon, z)
    lg.push()
    lg.translate(dx - cx, dy - cy)
    lg.rotate(math.rad(v.rot)) -- keep the pin upright
    ui.circle(ui.c.text, 0, -30, 16)
    lg.setColor(ui.c.text)
    lg.polygon("fill", -12, -20, 12, -20, 0, 0)
    ui.circle(ui.c.bg, 0, -30, 6)
    lg.pop()
  end

  -- you
  local f = M.fix
  if f then
    local fx, fy = project(f.lat, f.lon, z)
    lg.push()
    lg.translate(fx - cx, fy - cy)
    local acc = (f.accuracy or 0) / (78271.517 * math.cos(math.rad(f.lat)) / 2 ^ z)
    if acc > 26 then
      lg.setColor(ui.c.accent[1], ui.c.accent[2], ui.c.accent[3], 0.14)
      lg.circle("fill", 0, 0, math.min(acc, 400), 48)
    end
    ui.circle(ui.c.text, 0, 0, 20)
    if (f.bearing or -1) >= 0 and (f.speed or -1) > 1 then
      lg.rotate(math.rad(f.bearing))
      lg.setColor(ui.c.bg)
      lg.polygon("fill", 0, -12, 9, 9, 0, 4, -9, 9)
    else
      ui.circle(ui.c.accent, 0, 0, 10)
    end
    lg.pop()
  end
  lg.pop()
  lg.setScissor()

  if M.wantFit and M.routes and not opts then
    M.wantFit = nil
    fitRoute(M.routes[M.sel], w - 540, h) -- leave room for the side panel
    local cx2, cy2 = project(M.view.lat, M.view.lon, M.view.zoom)
    M.view.lat, M.view.lon = unproject(cx2 - 270, cy2, M.view.zoom) -- centre in the free area
    app.dirty()
  end
end

local drawTurnCard -- defined with the Map screen UI below

-- rounded corners for a map drawn in a card: fill the corners outside the radius
local function cornerMasks(x, y, w, h, r, col)
  lg.setColor(col)
  local steps = 8
  local corners = {
    { x, y, x + r, y + r, math.pi, 1.5 * math.pi },
    { x + w, y, x + w - r, y + r, 1.5 * math.pi, 2 * math.pi },
    { x + w, y + h, x + w - r, y + h - r, 0, 0.5 * math.pi },
    { x, y + h, x + r, y + h - r, 0.5 * math.pi, math.pi },
  }
  for _, c in ipairs(corners) do
    local px, py, cx, cy, a0, a1 = c[1], c[2], c[3], c[4], c[5], c[6]
    local lx, ly = cx + math.cos(a0) * r, cy + math.sin(a0) * r
    for i = 1, steps do
      local a = a0 + (a1 - a0) * i / steps
      local nx, ny = cx + math.cos(a) * r, cy + math.sin(a) * r
      lg.polygon("fill", px, py, lx, ly, nx, ny)
      lx, ly = nx, ny
    end
  end
end

local homeView = { lat = 0, lon = 0, zoom = 15.5, rot = 0 }

-- Home's map card: your position (or the active route), with the turn card on top while
-- Road Trip guides you. Returns true when it drew guidance.
function M.drawWidget(x, y, w, h, radius)
  local v
  if M.nav and M.view.follow then
    v = M.view
  else
    local f = M.fix
    homeView.lat = f and f.lat or M.view.lat
    homeView.lon = f and f.lon or M.view.lon
    homeView.zoom = M.nav and 16 or 15.5
    homeView.follow = true
    homeView.rot = M.heading
    v = homeView
  end
  M.drawMap(x, y, w, h, { view = v })
  cornerMasks(x, y, w, h, radius or 26, ui.c.bg)
  local g = M.guidance()
  if g then
    local cw = math.min(500, w - 32)
    drawTurnCard(g, x + 16, y + 16, cw)
    local by = y + h - 16 - 64
    ui.rect(ui.c.bg, x + 16, by, w - 32, 64, 20)
    local sub = T("{time} arrival", { time = g.arrival }) .. " · " .. fmtDur(g.remTime) .. " · " .. fmtDist(g.remaining)
    ui.text(ui.fit(sub, "bold", 20, w - 72), "bold", 20, ui.c.text, x + 36, by + (64 - ui.fontHeight("bold", 20)) / 2)
    return true
  end
  return false
end

-- a round 64x64 map button
local function mapButton(id, icon, x, y)
  ui.rect(ui.c.bg, x, y, 64, 64, 20)
  ui.icon(icon, x + 19, y + 19, 26, ui.c.text2, 2.2)
  ui.hit(id, x, y, 64, 64)
end

local function attribution(x, y, w)
  ui.text(ui.fit(T("© OpenFreeMap © OpenMapTiles · data © OpenStreetMap contributors · routes FOSSGIS OSRM"), "semibold", 12, w),
    "semibold", 12, hex("5A5C61"), x, y)
end

function drawTurnCard(g, x, y, w)
  ui.rect(ui.c.bg, x, y, w, 140, 26)
  ui.rect(ui.c.accent, x + 18, y + 18, 104, 104, 24)
  ui.icon(g.icon or "straight", x + 18 + 22, y + 18 + 22, 60, ui.c.onAccent, 2.4)
  local tx, tw = x + 18 + 104 + 18, w - 104 - 18 * 3
  ui.text(ui.fit(g.title, "bold", 42, tw), "bold", 42, ui.c.text, tx, y + 18)
  ui.text(ui.fit(g.text or "", "semibold", 19, tw), "semibold", 19, hex("C9C6BE"), tx, y + 72)
  if g.then_ then ui.text(ui.fit(g.then_, "semibold", 15, tw), "semibold", 15, hex("77756F"), tx, y + 100) end
end

function M.drawUI(x0, y0, w, h)
  ui.hit({ kind = "map:pan" }, x0, y0, w, h) -- dragging the map (anything drawn later wins)
  local mode = M.mode
  local right = x0 + w - 20 - 64

  if mode == "browse" then
    local bw = math.min(460, w - 140)
    ui.rect(ui.c.bg, x0 + 20, y0 + 20, bw, 68, 22)
    ui.icon("search", x0 + 42, y0 + 42, 24, ui.c.muted, 2.2)
    ui.text(T("Where to?"), "bold", 20, ui.c.text2, x0 + 80, y0 + 20 + (68 - ui.fontHeight("bold", 20)) / 2)
    ui.hit({ kind = "map:search" }, x0 + 20, y0 + 20, bw, 68)
    if not M.permission then
      ui.rect(ui.c.card, x0 + 20, y0 + 104, bw, 72, 20)
      ui.text(T("Allow location to see where you are"), "bold", 16, ui.c.text, x0 + 40, y0 + 128)
      ui.pill({ kind = "map:allow" }, T("Allow"), x0 + 20 + bw - 110, y0 + 116, 48, "accent")
    elseif not M.fix then
      ui.text(T("Waiting for your location…"), "semibold", 15, ui.c.muted, x0 + 26, y0 + 102)
    end
  end

  if mode == "browse" or mode == "nav" then
    mapButton({ kind = "map:zoom", d = 1 }, "plus", right, y0 + 20)
    mapButton({ kind = "map:zoom", d = -1 }, "minus", right, y0 + 96)
    -- compass: shows north; tap to switch between heading-up and north-up
    ui.rect(ui.c.bg, right, y0 + 172, 64, 64, 20)
    lg.push()
    lg.translate(right + 32, y0 + 172 + 32)
    lg.rotate(-math.rad(M.view.rot))
    lg.setColor(hex("E86F5A"))
    lg.polygon("fill", 0, -20, 7, 0, -7, 0)
    lg.setColor(ui.c.text2)
    lg.polygon("fill", 0, 20, 7, 0, -7, 0)
    lg.pop()
    ui.hit({ kind = "map:compass" }, right, y0 + 172, 64, 64)
    if not M.view.follow and M.fix then mapButton({ kind = "map:recenter" }, "locate", right, y0 + 248) end
  end

  if mode == "nav" then
    local g = M.guidance()
    if g then
      drawTurnCard(g, x0 + 20, y0 + 20, math.min(500, w - 140))
      local by = y0 + h - 20 - 92
      ui.rect(ui.c.bg, x0 + 20, by, w - 40, 92, 26)
      ui.text(g.arrival, "bold", 30, ui.c.text, x0 + 46, by + 14)
      ui.text(T("Arrival"), "semibold", 14, ui.c.muted, x0 + 46, by + 56)
      ui.rect(hex("2A2C31"), x0 + 170, by + 22, 1, 48)
      ui.text(fmtDur(g.remTime), "bold", 24, ui.c.text, x0 + 196, by + 18)
      ui.text(fmtDist(g.remaining), "semibold", 14, ui.c.muted, x0 + 196, by + 56)
      local endW = ui.textWidth(T("End"), "bold", 18) + 72
      local ex = x0 + w - 20 - 14 - endW
      ui.text(ui.fit(g.dest, "bold", 18, ex - 24 - (x0 + 340)), "bold", 18, ui.c.text, x0 + 340, by + 22)
      attribution(x0 + 340, by + 56, ex - 24 - (x0 + 340))
      ui.rect(hex("2A1C1A"), ex, by + 14, endW, 64, 32)
      ui.text(T("End"), "bold", 18, hex("F09A8A"), ex, by + 14 + (64 - ui.fontHeight("bold", 18)) / 2, "center", endW)
      ui.hit({ kind = "map:end" }, ex, by + 14, endW, 64)
      if M.nav.off > 50 then
        ui.text(T("Off the route"), "bold", 15, hex("F09A8A"), x0 + 26, y0 + 172)
      end
    end
  elseif mode == "browse" then
    attribution(x0 + 20, y0 + h - 28, w - 40)
  end

  if mode == "search" then
    local pw = math.min(560, w - 40)
    local px, py, ph = x0 + 20, y0 + 20, h - 40
    ui.rect(ui.c.bg, px, py, pw, ph, 28)
    ui.hit({ kind = "map:block" }, px, py, pw, ph)
    local s = M.search
    local fw = pw - 44 - 76
    ui.rect(ui.c.chip, px + 22, py + 22, fw, 64, 20)
    lg.setColor(ui.c.accent)
    lg.setLineWidth(2)
    lg.rectangle("line", px + 22, py + 22, fw, 64, 20, 20, 16)
    ui.hit({ kind = "map:field" }, px + 22, py + 22, fw, 64)
    ui.icon("search", px + 40, py + 42, 24, ui.c.muted, 2.2)
    local blink = math.floor(love.timer.getTime() * 2) % 2 == 0
    local shown = s.text ~= "" and s.text or T("Where to?")
    ui.text(ui.fit(shown, "semibold", 20, fw - 80) .. ((s.text ~= "" and blink) and "|" or ""), "semibold", 20,
      s.text ~= "" and ui.c.text or ui.c.dim, px + 76, py + 22 + (64 - ui.fontHeight("semibold", 20)) / 2)
    mapButton({ kind = "map:closeSearch" }, "close", px + pw - 22 - 64, py + 22)

    local ry = py + 104
    local items, heading
    if s.results then
      items = s.results
    elseif s.text == "" then
      items, heading = config.get("mapRecents") or {}, T("Recent")
    end
    if s.busy then ui.text(T("Searching…"), "semibold", 15, ui.c.muted, px + 24, ry) ry = ry + 30 end
    if s.err then ui.text(s.err, "semibold", 15, hex("F09A8A"), px + 24, ry) ry = ry + 30 end
    if heading and #items > 0 then ui.text(heading, "bold", 14, ui.c.muted, px + 24, ry) ry = ry + 30 end
    for i, it in ipairs(items or {}) do
      if ry + 76 > py + ph - 12 then break end
      ui.rect(i == 1 and s.results and hex("1E1A13") or ui.c.card, px + 16, ry, pw - 32, 76, 20)
      ui.circle(hex("22252A"), px + 16 + 40, ry + 38, 22)
      ui.icon("pin", px + 16 + 28, ry + 26, 24, ui.c.accent, 1.8)
      local textW = pw - 32 - 90 - 90
      ui.text(ui.fit(it.name or "", "bold", 18, textW), "bold", 18, ui.c.text2, px + 16 + 76, ry + 14)
      ui.text(ui.fit(it.sub or "", "semibold", 14, textW), "semibold", 14, ui.c.muted, px + 16 + 76, ry + 44)
      if M.fix and it.lat then
        local dist = fmtDist(haversine(M.fix.lat, M.fix.lon, it.lat, it.lon))
        ui.text(dist, "bold", 15, hex("B8B5AD"), px + 16, ry + 28, "right", pw - 32 - 18)
      end
      ui.hit({ kind = "map:pick", place = it }, px + 16, ry, pw - 32, 76)
      ry = ry + 84
    end
  end

  if mode == "overview" then
    local pw = math.min(500, w - 40)
    local px, py, ph = x0 + 20, y0 + 20, h - 40
    ui.rect(ui.c.bg, px, py, pw, ph, 28)
    ui.hit({ kind = "map:block" }, px, py, pw, ph)
    local d = M.dest or {}
    ui.text(ui.fit(d.name or "", "bold", 28, pw - 120), "bold", 28, ui.c.text, px + 26, py + 26)
    ui.text(ui.fit(d.sub or "", "semibold", 15, pw - 120), "semibold", 15, ui.c.muted, px + 26, py + 68)
    mapButton({ kind = "map:cancel" }, "close", px + pw - 26 - 64, py + 22)
    local ry = py + 110
    if M.waitingFix then
      ui.text(M.permission and T("Waiting for your location…") or T("Road Trip needs location access to find routes from you"),
        "semibold", 17, ui.c.muted, px + 26, ry)
      ui.text(T("Or start the route from the middle of the map:"), "semibold", 15, ui.c.muted, px + 26, ry + 40)
      ui.pill({ kind = "map:fromCentre" }, T("From the map's centre"), px + 26, ry + 76, 56, "accent")
      if not M.permission then ui.pill({ kind = "map:allow" }, T("Allow location"), px + 26, ry + 146, 56, "off2") end
    elseif M.routesBusy or not M.routes then
      ui.text(T("Finding routes…"), "semibold", 17, ui.c.muted, px + 26, ry)
    else
      local fastest = math.huge
      for _, rt in ipairs(M.routes) do fastest = math.min(fastest, rt.duration) end
      for i, rt in ipairs(M.routes) do
        if i > 3 then break end
        local on = i == M.sel
        ui.rect(on and hex("1E1A13") or ui.c.card, px + 20, ry, pw - 40, 92, 22)
        if on then
          lg.setColor(ui.c.accent)
          lg.setLineWidth(2)
          lg.rectangle("line", px + 20, ry, pw - 40, 92, 22, 22, 16)
        end
        ui.text(fmtDur(rt.duration), "bold", 26, ui.c.text, px + 42, ry + 14)
        ui.text(fmtDist(rt.distance) .. " · " .. T("arrive {time}", { time = os.date("%H:%M", os.time() + math.floor(rt.duration)) }),
          "semibold", 15, ui.c.muted, px + 42, ry + 56)
        local tag = rt.duration <= fastest + 1 and T("Fastest") or ("+" .. fmtDur(rt.duration - fastest))
        ui.text(tag, "bold", 15, on and ui.c.accent or ui.c.muted, px + 20, ry + 36, "right", pw - 40 - 22)
        ui.hit({ kind = "map:sel", i = i }, px + 20, ry, pw - 40, 92)
        ry = ry + 104
      end
      local sy = py + ph - 26 - 72 - 26
      ui.rect(ui.c.accent, px + 26, sy, pw - 52, 72, 36)
      ui.icon("navArrow", px + pw / 2 - 64, sy + 22, 28, ui.c.onAccent, 2.4)
      ui.text(T("Start"), "bold", 22, ui.c.onAccent, px + pw / 2 - 28, sy + (72 - ui.fontHeight("bold", 22)) / 2)
      ui.hit({ kind = "map:start" }, px + 26, sy, pw - 52, 72)
    end
    attribution(px + 26, py + ph - 30, pw - 52)
  end
end

function M.activate(id)
  local k = id.kind
  if k == "map:search" or k == "map:field" then
    if not M.search then M.openSearch() else love.keyboard.setTextInput(true) end
  elseif k == "map:closeSearch" then closeSearch()
  elseif k == "map:pick" then choose(id.place)
  elseif k == "map:sel" then M.sel = id.i M.wantFit = true
  elseif k == "map:start" then startNav()
  elseif k == "map:cancel" then endNav()
  elseif k == "map:end" then endNav()
  elseif k == "map:allow" then listening = android.locationStart() == true
  elseif k == "map:fromCentre" then
    if M.waitingFix then
      local w = M.waitingFix
      requestRoutes(w.lat, w.lon, { lat = M.view.lat, lon = M.view.lon })
    end
  elseif k == "map:recenter" then M.view.follow = true
  elseif k == "map:compass" then
    config.set("mapNorthUp", not config.get("mapNorthUp"))
    if config.get("mapNorthUp") then M.heading = 0 end
    app.toast(config.get("mapNorthUp") and T("North up") or T("The way you're heading is up"))
  elseif k == "map:zoom" then
    zoomTarget = math.max(3, math.min(18, math.floor((zoomTarget or M.view.zoom) + 0.5) + id.d))
  end
  app.dirty()
end

-- Back button on the Map screen; true if it was used here
function M.back()
  if M.search then closeSearch() return true end
  if M.mode == "overview" then endNav() return true end
  return false
end

return M
