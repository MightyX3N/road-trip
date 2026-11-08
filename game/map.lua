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
local PHOTON = "https://photon.komoot.io/api/?limit=20&q="
local OSRM = "https://routing.openstreetmap.de/routed-car/route/v1/driving/"
-- routes that avoid motorways, tolls or ferries: FOSSGIS's Valhalla (their OSRM has no avoid options)
local VALHALLA = "https://valhalla1.openstreetmap.de/route?json="
-- speed limits along the route (OpenStreetMap's maxspeed, matched by FOSSGIS's Valhalla)
local TRACE = "https://valhalla1.openstreetmap.de/trace_attributes"
-- fixed speed cameras mapped in OpenStreetMap
local OVERPASS = "https://overpass-api.de/api/interpreter"

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

local WANT = { water = true, landcover = true, park = true, transportation = true,
  transportation_name = true, place = true }

-- street and place names: which roads get labelled at which zoom, and how big places are
local ROAD_RANK = { motorway = 1, trunk = 1, primary = 2, secondary = 3, tertiary = 4, minor = 5, service = 6 }
local ROAD_MINZ = { 13, 13.5, 14, 14.5, 15.5, 17 }
local PLACE = {
  city = { size = 22, rank = 1, minz = 0 }, town = { size = 19, rank = 2, minz = 0 },
  village = { size = 16, rank = 3, minz = 12 }, suburb = { size = 15, rank = 4, minz = 13 },
  quarter = { size = 14, rank = 5, minz = 14 }, neighbourhood = { size = 14, rank = 5, minz = 15 },
  hamlet = { size = 14, rank = 5, minz = 14 },
}

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
  -- labels: the longest nearly straight run of each named road, and place points
  sh.labels = {}
  local code = require("lang").code
  local function nameOf(t) return t["name:" .. code] or t.name or t["name:latin"] end
  if layers.transportation_name then
    for _, f in ipairs(layers.transportation_name.features) do
      local nm = f.type == 2 and nameOf(f.tags)
      local rank = ROAD_RANK[f.tags.class]
      if nm and nm ~= "" and rank then
        for _, l in ipairs(geometryParts(f.geom)) do
          -- runs of segments that turn less than ~25 degrees
          local best, bx1, by1, bx2, by2 = 0
          local i = 1
          while i < #l - 2 do
            local sx, sy = l[i], l[i + 1]
            local a0 = math.atan2 and math.atan2(l[i + 3] - sy, l[i + 2] - sx) or math.atan(l[i + 3] - sy, l[i + 2] - sx)
            local j = i + 2
            while j < #l - 2 do
              local dx, dy = l[j + 2] - l[j], l[j + 3] - l[j + 1]
              local a = math.atan2 and math.atan2(dy, dx) or math.atan(dy, dx)
              local d = math.abs(((a - a0 + math.pi) % (2 * math.pi)) - math.pi)
              if d > 0.45 then break end
              j = j + 2
            end
            local ex, ey = l[j], l[j + 1]
            local len = math.sqrt((ex - sx) ^ 2 + (ey - sy) ^ 2)
            if len > best then best, bx1, by1, bx2, by2 = len, sx, sy, ex, ey end
            i = j
          end
          if best > 0 then
            sh.labels[#sh.labels + 1] = { kind = "road", name = nm, rank = rank,
              x = (bx1 + bx2) / 2, y = (by1 + by2) / 2, dx = bx2 - bx1, dy = by2 - by1, len = best }
          end
        end
      end
    end
  end
  if layers.place then
    for _, f in ipairs(layers.place.features) do
      local nm = f.type == 1 and nameOf(f.tags)
      local pc = PLACE[f.tags.class]
      if nm and nm ~= "" and pc and f.geom[2] then
        local g = f.geom -- MoveTo(1): cmd, zigzag x, zigzag y
        local x, y = g[2] % 2 == 0 and g[2] / 2 or -(g[2] + 1) / 2, g[3] % 2 == 0 and g[3] / 2 or -(g[3] + 1) / 2
        sh.labels[#sh.labels + 1] = { kind = "place", name = nm, rank = pc.rank, size = pc.size, minz = pc.minz, x = x, y = y }
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

M.shapesFrom = shapesFrom -- for tests

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

-- a downloaded offline area that has this tile (offline.lua keeps them in tiles/off/<id>/)
local function offlinePath(z, x, y)
  local areas = config.get("offlineAreas")
  if not areas then return nil end
  local rest = "/" .. z .. "/" .. x .. "/" .. y .. ".pbf"
  for _, a in ipairs(areas) do
    local p = "tiles/off/" .. a.id .. rest
    if love.filesystem.getInfo(p) then return p end
  end
end

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
    local cached = tilePath(z, x, y)
    local off = not love.filesystem.getInfo(cached) and offlinePath(z, x, y)
    if off or love.filesystem.getInfo(cached) then
      t.path = off or cached
      t.state = "queued"
      queue[#queue + 1] = t
    elseif tileURL and dlCount < 6 then
      t.state = "downloading"
      dlCount = dlCount + 1
      local url = tileURL:gsub("{z}", z):gsub("{x}", x):gsub("{y}", y)
      local path = tilePath(z, x, y)
      t.path = path
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

-- a tile only if it's on the device (cached or in an offline area); never downloads
local notLocal = {} -- tile key -> when it was last found missing (checking the disk every frame is slow)
local function localTile(z, x, y, zb)
  local k = tileKey(z, x, y)
  local t = tiles[k]
  if t and t.state == "ready" then return getTile(z, x, y, zb) end
  if t and t.state ~= "new" then return nil end
  local now = love.timer.getTime()
  if notLocal[k] and now - notLocal[k] < 10 then return nil end
  if love.filesystem.getInfo(tilePath(z, x, y)) or offlinePath(z, x, y) then
    notLocal[k] = nil
    return getTile(z, x, y, zb)
  end
  notLocal[k] = now
end

local function decodeNext()
  local t = table.remove(queue, 1)
  if not t then return end
  local data = love.filesystem.read(t.path or tilePath(t.z, t.x, t.y))
  if not data then t.state, t.retryAt = "failed", love.timer.getTime() + 20 return end
  if byte(data, 1) == 0x1f and byte(data, 2) == 0x8b then
    local ok, raw = pcall(love.data.decompress, "string", "gzip", data)
    if not ok then t.state, t.retryAt = "failed", love.timer.getTime() + 60 return end
    data = raw
  end
  local ok, layers
  if data == "" then ok, layers = true, {} -- nothing there (open sea, in an offline area)
  else ok, layers = pcall(decodeTile, data, WANT) end
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
      -- the lanes at this turn (OSRM gives them where OpenStreetMap has turn:lanes)
      local lanes
      local x1 = s.intersections and s.intersections[1]
      if x1 and type(x1.lanes) == "table" and #x1.lanes > 1 then
        lanes = {}
        for _, l in ipairs(x1.lanes) do
          lanes[#lanes + 1] = { ind = type(l.indications) == "table" and l.indications or { "straight" }, valid = l.valid == true }
        end
      end
      steps[#steps + 1] = {
        type = mv.type, modifier = mv.modifier, exit = mv.exit, name = s.name or "",
        at = cum[idx], lat = lat, lon = lon, lanes = lanes,
      }
    end
  end
  return { coords = coords, cum = cum, distance = r.distance or cum[#cum], duration = r.duration or 0, steps = steps }
end

-- Valhalla's maneuver types -> the OSRM-style type and modifier the guidance uses
local VTYPE = {
  [1] = { "depart" }, [2] = { "depart" }, [3] = { "depart" },
  [4] = { "arrive" }, [5] = { "arrive" }, [6] = { "arrive" },
  [7] = { "new name", "straight" }, [8] = { "continue", "straight" }, [22] = { "continue", "straight" },
  [9] = { "turn", "slight right" }, [10] = { "turn", "right" }, [11] = { "turn", "sharp right" },
  [12] = { "turn", "uturn" }, [13] = { "turn", "uturn" },
  [14] = { "turn", "sharp left" }, [15] = { "turn", "left" }, [16] = { "turn", "slight left" },
  [17] = { "on ramp", "straight" }, [18] = { "on ramp", "right" }, [19] = { "on ramp", "left" },
  [20] = { "off ramp", "right" }, [21] = { "off ramp", "left" },
  [23] = { "fork", "right" }, [24] = { "fork", "left" },
  [25] = { "merge", "straight" }, [37] = { "merge", "right" }, [38] = { "merge", "left" },
  [26] = { "roundabout" }, [28] = { "continue", "straight" }, [29] = { "continue", "straight" },
}

local function parseValhalla(trip)
  local coords, steps = {}, {}
  local cum = {}
  for _, leg in ipairs(trip.legs or {}) do
    local base = #coords
    local pts = decodePolyline(leg.shape or "", 6)
    for _, c in ipairs(pts) do coords[#coords + 1] = c end
    for i = math.max(2, base + 1), #coords do
      cum[1] = 0
      cum[i] = (cum[i - 1] or 0) + haversine(coords[i - 1][1], coords[i - 1][2], coords[i][1], coords[i][2])
    end
    for _, m in ipairs(leg.maneuvers or {}) do
      local vt = VTYPE[m.type]
      if vt then
        local idx = base + (m.begin_shape_index or 0) + 1
        local c = coords[idx] or coords[#coords]
        steps[#steps + 1] = {
          type = vt[1], modifier = vt[2], exit = m.roundabout_exit_count,
          name = (m.street_names and m.street_names[1]) or (m.begin_street_names and m.begin_street_names[1]) or "",
          at = cum[idx] or 0, lat = c and c[1], lon = c and c[2],
        }
      end
    end
  end
  if #coords < 2 then return nil end
  cum[1] = 0
  local sm = trip.summary or {}
  return { coords = coords, cum = cum, distance = (sm.length or 0) * 1000, duration = sm.time or 0, steps = steps }
end
M.parseValhalla = parseValhalla -- for tests

local function avoids()
  local a = config.get("mapAvoid") or {}
  return a, (a.motorway or a.toll or a.ferry) and true or false
end

-- heading: which way the car is going (degrees), so a new route starts ahead instead of
-- turning you round; nil when standing still
local function valhallaURL(fromLat, fromLon, toLat, toLon, heading)
  local a = avoids()
  local h = heading and string.format(',"heading":%d,"heading_tolerance":60', math.floor(heading + 0.5) % 360) or ""
  local body = string.format('{"locations":[{"lat":%.6f,"lon":%.6f%s},{"lat":%.6f,"lon":%.6f}],"costing":"auto",'
    .. '"costing_options":{"auto":{"use_highways":%s,"use_tolls":%s,"use_ferry":%s}},'
    .. '"directions_options":{"units":"kilometers"},"alternates":2}',
    fromLat, fromLon, h, toLat, toLon, a.motorway and "0" or "1", a.toll and "0" or "1", a.ferry and "0" or "1")
  return VALHALLA .. (body:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function routeURL(fromLat, fromLon, toLat, toLon, heading)
  local b = heading and string.format("&bearings=%d,60;", math.floor(heading + 0.5) % 360) or ""
  return string.format("%s%.6f,%.6f;%.6f,%.6f?overview=full&geometries=polyline6&steps=true&alternatives=true%s",
    OSRM, fromLon, fromLat, toLon, toLat, b)
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
local requestRoutes
function requestRoutes(lat, lon, from, noHeading)
  local f = from or M.fix
  if not f then
    M.waitingFix = { lat = lat, lon = lon }
    M.routesBusy = false
    app.dirty()
    return
  end
  M.waitingFix = nil
  M.routesBusy = true
  local _, avoiding = avoids()
  -- from your position while driving: start the way you're going (a re-route especially)
  local heading = not from and not noHeading and moving and headingTarget or nil
  local id = android.fetch(avoiding and valhallaURL(f.lat, f.lon, lat, lon, heading) or routeURL(f.lat, f.lon, lat, lon, heading))
  request(id, function(r)
    M.routesBusy = false
    local okd, dd = pcall(json.decode, r.ok and r.body or "")
    local d = okd and type(dd) == "table" and dd or nil
    local list = {}
    if avoiding then
      if d and d.trip then
        local p = parseValhalla(d.trip)
        if p then list[#list + 1] = p end
        for _, alt in ipairs(d.alternates or {}) do
          local q = alt.trip and parseValhalla(alt.trip)
          if q then list[#list + 1] = q end
        end
      end
      if #list == 0 and heading then return requestRoutes(lat, lon, from, true) end
      if #list == 0 then
        -- the avoid-router didn't answer: fall back to the usual route, and say so
        app.toast(T("Couldn't plan around those; showing the usual route"))
        local saved = config.get("mapAvoid")
        config.data.mapAvoid = nil
        requestRoutes(lat, lon, from)
        config.data.mapAvoid = saved
        return
      end
    else
      if not d or d.code ~= "Ok" or not d.routes or #d.routes == 0 then
        -- no road nearby going that way (a car park, a wrong heading): try without it
        if heading then return requestRoutes(lat, lon, from, true) end
        app.toast(d and d.message or T("Couldn't find a route"))
        return
      end
      for _, rr in ipairs(d.routes) do
        local p = parseRoute(rr)
        if p then list[#list + 1] = p end
      end
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
  -- while driving, a piece of the route going the other way counts as 40 m further away (so a
  -- road that loops back, or the other carriageway, isn't taken for where you are)
  local useHead = moving and (f.speed or -1) > 3
  local bestI, bestD, bestT, bestScore, bestDiff = n.idx, math.huge, 0, math.huge, 0
  for i = math.max(1, n.idx - 10), math.min(#c - 1, n.idx + 400) do
    local ax, ay = toLocal(c[i][1], c[i][2], lat0)
    local bx, by = toLocal(c[i + 1][1], c[i + 1][2], lat0)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
    local qx, qy = ax + t * dx - px, ay + t * dy - py
    local d = math.sqrt(qx * qx + qy * qy)
    local diff = 0
    if useHead and l2 > 1 then
      local sb = math.deg((math.atan2 or math.atan)(dx, dy))
      diff = math.abs(((sb - headingTarget + 540) % 360) - 180)
    end
    local score = d + (diff > 100 and 40 or 0)
    if score < bestScore then bestI, bestD, bestT, bestScore, bestDiff = i, d, t, score, diff end
  end
  n.idx = bestI
  n.off = bestD
  n.along = r.cum[bestI] + bestT * (r.cum[bestI + 1] - r.cum[bestI])
  local now = love.timer.getTime()

  -- off the route for a few fixes in a row: ask for a new one (FOSSGIS allows 1/s; we wait 12 s).
  -- Good GPS: 30 m off is enough (a road beside the route), or 15 m off while heading a different
  -- way than the route (turned into a side road). A vague position (wifi or the mobile network)
  -- needs to be further off, and for longer.
  local acc = f.accuracy or -1
  if acc < 0 then acc = 20 end
  local limit = acc <= 15 and 30 or math.max(50, acc + 30)
  local need = acc > 60 and 5 or 3
  local wrongWay = useHead and acc <= 25 and bestDiff > 50 and n.off > 15
  if acc <= 250 and (n.off > limit or wrongWay) then n.offCount = n.offCount + 1 else n.offCount = 0 end
  if n.offCount >= need and now - n.lastReroute > 12 and M.dest then
    n.lastReroute, n.offCount = now, 0
    requestRoutes(M.dest.lat, M.dest.lon)
  end

  local remaining = math.max(0, r.distance - n.along)
  if remaining < 25 and not n.arrivedAt then n.arrivedAt = now end
end

-- what's next, for the turn card and Home's Navigation widget
M.speed = function() return M.fix and M.fix.speed or -1 end

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
    -- for spoken directions
    g.step, g.dist, g.route = next, next.at - n.along, r
    g.afterText = after and after.type ~= "arrive" and instruction(after) or nil
    g.afterGap = after and (after.at - next.at) or nil
    g.icon = arrowIcon(next)
    if next.lanes and g.dist < 1500 then g.lanes = next.lanes end
    if after and after.type ~= "arrive" then 
      local nx = instruction(after)
      if require("lang").code == "en" then nx = nx:gsub("^%u", string.lower) end
      g.then_ = T("Then {next}", { next = nx })
    end
  end
  return g
end

----------------------------------------------------------------------------------------------
-- speed limits and speed cameras along the route being followed
----------------------------------------------------------------------------------------------

local CHUNK = 40000 -- metres of route matched for speed limits per request
local extras = { route = nil }

local function dist2(lat1, lon1, lat2, lon2)
  local k = math.cos(math.rad(lat1))
  local dy, dx = (lat2 - lat1) * 111320, (lon2 - lon1) * 111320 * k
  return dx * dx + dy * dy
end

-- the route from `from` metres, as Valhalla shape points about 25 m apart
local function shapeFrom(rt, from, to)
  local pts, lastAt, first = {}, -math.huge, nil
  for i, c in ipairs(rt.coords) do
    local at = rt.cum[i]
    if at >= from and at <= to then
      first = first or at
      if at - lastAt >= 25 then
        pts[#pts + 1] = { lat = c[1], lon = c[2] }
        lastAt = at
      end
    elseif at > to then
      pts[#pts + 1] = { lat = c[1], lon = c[2] }
      return pts, first or from, at
    end
  end
  return pts, first or from, rt.cum[#rt.cum]
end

local function requestLimits(rt, from)
  local pts, a, b = shapeFrom(rt, from, from + CHUNK)
  extras.limitsBusy = true
  extras.chunkEnd = b
  if #pts < 2 then extras.limitsBusy = false return end
  local body = json.encode({ shape = pts, costing = "auto", shape_match = "walk_or_snap", units = "kilometers",
    filters = { attributes = { "edge.speed_limit", "edge.length" }, action = "include" } })
  request(android.httpRequest("POST", TRACE, { ["Content-Type"] = "application/json" }, body), function(r)
    extras.limitsBusy = false
    if extras.route ~= rt then return end
    local ok, d = pcall(json.decode, r.ok and r.body or "")
    if not ok or type(d) ~= "table" or type(d.edges) ~= "table" then return end
    -- edge lengths along the matched road, stretched to this part of our route
    local total = 0
    for _, e in ipairs(d.edges) do total = total + (tonumber(e.length) or 0) end
    if total <= 0 then return end
    local k = (b - a) / (total * 1000)
    local at = a
    for _, e in ipairs(d.edges) do
      local len = (tonumber(e.length) or 0) * 1000 * k
      local lim = tonumber(e.speed_limit)
      if lim and lim > 0 and lim < 200 then
        extras.limits[#extras.limits + 1] = { from = at, to = at + len, kph = lim }
      else
        extras.limits[#extras.limits + 1] = { from = at, to = at + len }
      end
      at = at + len
    end
    app.dirty()
  end)
end

local function requestCameras(rt)
  local s, w, n, e = 90, 180, -90, -180
  for _, c in ipairs(rt.coords) do
    s, n = math.min(s, c[1]), math.max(n, c[1])
    w, e = math.min(w, c[2]), math.max(e, c[2])
  end
  local q = string.format('[out:json][timeout:25];node["highway"="speed_camera"](%.4f,%.4f,%.4f,%.4f);out body;',
    s - 0.01, w - 0.01, n + 0.01, e + 0.01)
  local body = "data=" .. q:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)
  request(android.httpRequest("POST", OVERPASS, { ["Content-Type"] = "application/x-www-form-urlencoded" }, body), function(r)
    if extras.route ~= rt then return end
    local ok, d = pcall(json.decode, r.ok and r.body or "")
    if not ok or type(d) ~= "table" or type(d.elements) ~= "table" then return end
    local cams = {}
    for _, el in ipairs(d.elements) do
      if el.lat and el.lon then
        -- on our route? (within 25 m of it; further is likely the other side of a motorway)
        local best, bestI = math.huge, nil
        for i = 1, #rt.coords, 2 do
          local c = rt.coords[i]
          if math.abs(c[1] - el.lat) < 0.003 then
            local d2 = dist2(el.lat, el.lon, c[1], c[2])
            if d2 < best then best, bestI = d2, i end
          end
        end
        if bestI then
          -- look closer around the nearest point
          for i = math.max(1, bestI - 2), math.min(#rt.coords, bestI + 2) do
            local c = rt.coords[i]
            local d2 = dist2(el.lat, el.lon, c[1], c[2])
            if d2 <= best then best, bestI = d2, i end
          end
        end
        if bestI and best < 25 * 25 then
          local tags = el.tags or {}
          cams[#cams + 1] = { at = rt.cum[bestI], kph = tonumber(tags.maxspeed) }
        end
      end
    end
    table.sort(cams, function(x, y) return x.at < y.at end)
    extras.cameras = cams
    app.dirty()
  end)
end

-- keeps the data in step with the route; called from M.update
local function updateExtras()
  local rt = M.nav and M.nav.route
  if rt ~= extras.route then
    extras = { route = rt, limits = {}, cameras = {}, warned = {} }
    if rt then
      requestLimits(rt, 0)
      requestCameras(rt)
    end
    return
  end
  if rt and not extras.limitsBusy and extras.chunkEnd and extras.chunkEnd < rt.distance - 1
    and (M.nav.along or 0) > extras.chunkEnd - 10000 then
    requestLimits(rt, extras.chunkEnd)
  end
end

-- what the speed sign and camera warning show: { kph?, speed (km/h)?, over?, camera = metres? }
function M.roadInfo()
  local n = M.nav
  if not n or not extras.route then return nil end
  local at = n.along or 0
  local info = {}
  for _, l in ipairs(extras.limits) do
    if at >= l.from and at < l.to then info.kph = l.kph break end
  end
  local f = M.fix
  if f and (f.speed or -1) >= 0 then info.speed = f.speed * 3.6 end
  if info.kph and info.speed then info.over = info.speed > info.kph + 3 end
  for i, c in ipairs(extras.cameras) do
    local d = c.at - at
    if d > -20 and d < 600 then
      info.camera, info.cameraIndex, info.cameraKph = math.max(0, d), i, c.kph
      break
    end
  end
  return info
end

-- once per camera, for the voice
function M.cameraWarned(i)
  if extras.warned[i] then return true end
  extras.warned[i] = true
  return false
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
  -- near you first: your position, or where the map is (the box has no GPS)
  local at = M.fix or M.view
  local url = PHOTON .. urlEncode(q) .. string.format("&lat=%.4f&lon=%.4f&zoom=9", at.lat, at.lon)
  local home = android.country()
  home = type(home) == "string" and #home == 2 and home:upper() or nil
  local asked = s.text
  request(android.fetch(url), function(r)
    if M.search ~= s then return end
    s.busy = false
    local d = r.ok and json.decode(r.body or "")
    if not d then s.err = T("Couldn't search; check the connection") return end
    local list, abroad = {}, {}
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
        local foreign = home and p.countrycode and p.countrycode:upper() ~= home
        if p.country and (foreign or not home) then subParts[#subParts + 1] = p.country end
        local item = { name = name, sub = table.concat(subParts, ", "), lat = co[2], lon = co[1] }
        if foreign then abroad[#abroad + 1] = item else list[#list + 1] = item end
      end
    end
    -- places in your own country first, then the rest; 8 at most
    for _, it in ipairs(abroad) do list[#list + 1] = it end
    for i = #list, 9, -1 do list[i] = nil end
    s.results = list
    if #list == 0 then s.err = T("Nothing found") end
    if s.text ~= asked then s.dueAt = love.timer.getTime() + 0.3 end -- typed more meanwhile
    app.dirty()
  end)
end

-- pickFor: "home" | "work" to save a place instead of routing to it
function M.openSearch(pickFor)
  M.mode = "search"
  M.search = { text = "", busy = false, pickFor = pickFor }
  ui.openKeyboard()
end

local function closeSearch()
  M.search = nil
  ui.closeKeyboard()
  M.mode = M.routes and "overview" or "browse"
end

local SAVED = { home = "mapHome", work = "mapWork" }

local function choose(place)
  local pf = M.search and M.search.pickFor
  if pf then
    config.set(SAVED[pf], { name = place.name, sub = place.sub, lat = place.lat, lon = place.lon })
    M.search = nil
    ui.closeKeyboard()
    M.mode = M.routes and "overview" or "browse"
    app.toast(pf == "home" and T("Home saved") or T("Work saved"))
    if M.onPicked then M.onPicked(pf) end
    return
  end
  M.dest = place
  M.search = nil
  ui.closeKeyboard()
  requestRoutes(place.lat, place.lon)
  M.mode = "overview"
  M.routes = nil
end

function M.wantsText() return M.search ~= nil end

function M.saved(which) return config.get(SAVED[which]) end

-- a route to Home or Work (from Home's map card); false when it isn't set
function M.goSaved(which)
  local p = M.saved(which)
  if not p then return false end
  M.open()
  choose({ name = which == "home" and T("@place:Home") or T("Work"), sub = p.name, lat = p.lat, lon = p.lon })
  return true
end

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
  -- the last known tile address, so cached and offline tiles show without a connection
  local mt = config.get("mapTiles")
  if mt then tileURL, tileVer = mt.url, mt.ver end
  local st = android.mapStatus and android.mapStatus()
  M.native = type(st) == "table" and st.attached == true
  M.engine = type(st) == "table" and st.engine or "classic"
  if M.native then
    android.mapInit({ saveDir = love.filesystem.getSaveDirectory(), accent = config.get("accent") or "#F2A23A" }) -- the pixel scale follows in M.sync
  end
end

function M.tileTemplate() return tileURL end
function M.project(lat, lon, z) return project(lat, lon, z) end
function M.unproject(x, y, z) return unproject(x, y, z) end
M.TILE = TILE
-- the route being shown or followed, if any
function M.activeRoute()
  if M.nav then return M.nav.route end
  return M.routes and M.routes[M.sel]
end

-- called when the Map screen opens: start location, get the tile address
function M.open()
  listening = android.locationStart() == true
  if not tileURL then
    request(android.fetch(TILEJSON), function(r)
      local d = r.ok and json.decode(r.body or "")
      local t = d and d.tiles and d.tiles[1]
      if t then
        local ver = t:match("/planet/([^/]+)/") or "v"
        -- a new OpenFreeMap version: last version's browsing cache is no use any more
        local old = config.get("mapTiles")
        if old and old.ver and old.ver ~= ver and old.ver ~= "off" then
          android.deleteTree(love.filesystem.getSaveDirectory() .. "/tiles/" .. old.ver)
        end
        tileURL, tileVer = t, ver
        config.set("mapTiles", { url = t, ver = ver })
        app.dirty()
      end
    end)
  end
end

function M.update(dt, onScreen)
  frame = frame + 1
  -- which part was slowest, for Diagnostics' "Slow moments"
  local clock, worst = love.timer.getTime(), 0
  M.slowPart = nil
  local function lap(name)
    local t = love.timer.getTime()
    if t - clock > worst then worst, M.slowPart = t - clock, name end
    clock = t
  end
  -- collect first: a handler may start a new request (adding to `pending` mid-loop isn't allowed)
  local done = {}
  for id in pairs(pending) do
    local r = android.fetchResult(id)
    if type(r) == "table" and r.done then done[#done + 1] = { id, r } end
  end
  lap("polling requests")
  for _, d in ipairs(done) do
    local handler = pending[d[1]]
    pending[d[1]] = nil
    if handler then handler(d[2]) end
    app.dirty()
  end
  lap("handling answers")
  if onScreen then decodeNext() end
  lap("tile decoding")

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

  lap("location")
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
  M.headingTarget = target
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
  lap("following")
  if M.search and M.search.dueAt and now > M.search.dueAt then runSearch() end
  updateExtras()
  lap("route extras")
  -- arrived: finish 20 s later, whether or not new positions come in
  if M.nav and M.nav.arrivedAt and now - M.nav.arrivedAt > 20 then
    endNav()
    app.dirty()
  end
end

-- keep drawing every frame while something moves
function M.busy()
  -- MapLibre animates the map itself; Road Trip only redraws for its own changes
  if M.native then return zoomTarget ~= nil or M.pinching == true end
  return zoomTarget ~= nil or #queue > 0 or M.nav ~= nil or (M.view.follow and M.fix ~= nil and M.mode ~= "overview")
end

----------------------------------------------------------------------------------------------
-- the MapLibre map (MapNative.java): where it shows, its camera, the route and markers
----------------------------------------------------------------------------------------------

local sent = { rect = nil, cam = nil, camAt = 0, route = nil, markers = nil, style = nil, styleAt = -100, scale = nil }

function M.beginFrame() M.drewNative = false end
function M.endFrame() if not M.drewNative then M.want = nil end end

-- is the sun up where the map is? (for the automatic day and night style)
local function sunUp(lat, lon)
  local d = os.date("!*t")
  local hour = d.hour + d.min / 60
  local g = 2 * math.pi / 365 * (d.yday - 1 + (hour - 12) / 24)
  local decl = 0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g) - 0.006758 * math.cos(2 * g)
    + 0.000907 * math.sin(2 * g) - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g)
  local eqt = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g) - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
  local ha = math.rad(((hour * 60 + eqt + 4 * lon) / 4) - 180)
  local la = math.rad(lat)
  local cz = math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl) * math.cos(ha)
  return 90 - math.deg(math.acos(math.max(-1, math.min(1, cz)))) > -3
end
M.sunUp = sunUp

function M.styleId()
  local st = config.get("mapStyle") or "auto"
  if st == "auto" then
    local f = M.fix or M.view
    return sunUp(f.lat, f.lon) and "ofm:liberty" or "ofm:dark"
  end
  return st
end

local function routeFeatures(rt, color)
  if not rt then return {} end
  local c = {}
  for _, p in ipairs(rt.coords) do c[#c + 1] = { p[2], p[1] } end
  return { { c = c, color = color } }
end

local function lonlat(rt)
  local a = {}
  for _, c in ipairs(rt.coords) do a[#a + 1] = { c[2], c[1] } end
  return a
end

-- called every loop: tells Android what changed (cheap when nothing did)
function M.sync()
  if not M.native then return end
  local w = M.want
  -- Android wants real pixels; ui.S is per LÖVE unit, and on a phone LÖVE's units are
  -- density-scaled (a 3x screen has 3 pixels per unit). Panel placement does the same.
  local S = ui.S * (lg.getDPIScale and lg.getDPIScale() or 1)
  if S ~= sent.scale then
    sent.scale = S
    android.mapInit({ scale = S })
  end
  local rect = w and string.format("%d %d %d %d", math.floor(w.x * S + 0.5), math.floor(w.y * S + 0.5),
    math.floor(w.w * S + 0.5), math.floor(w.h * S + 0.5))
  if rect ~= sent.rect then
    sent.rect = rect
    if w then
      android.mapShow(math.floor(w.x * S + 0.5), math.floor(w.y * S + 0.5), math.floor(w.w * S + 0.5), math.floor(w.h * S + 0.5))
      sent.cam = nil -- a new place: jump, don't glide
    else
      android.mapHide()
    end
  end
  local now = love.timer.getTime()
  -- style (the automatic one is checked once a minute)
  if now - sent.styleAt > 60 or config.get("mapStyle") ~= sent.styleSetting then
    sent.styleAt, sent.styleSetting = now, config.get("mapStyle")
    local id = M.styleId()
    if id ~= sent.style then
      sent.style = id
      android.mapStyle(id)
    end
  end
  if not w then return end
  -- camera: following the car glides to each new position (MapLibre animates between them)
  local v = w.view
  local follow = v.follow ~= false and M.fix ~= nil and not w.flat
  local lat, lon, bearing = v.lat, v.lon, v.rot
  if follow then lat, lon, bearing = M.fix.lat, M.fix.lon, M.headingTarget or v.rot end
  local tilt = (config.get("map3D") and not w.flat) and 55 or 0
  local cam = string.format("%.6f %.6f %.2f %.1f %d %.2f", lat, lon, v.zoom, bearing, tilt, w.ahead)
  if cam ~= sent.cam and (not follow or now - sent.camAt > 0.05) then
    local glide = 0
    if sent.cam then glide = follow and 950 or 0 end
    if follow and sent.lastZoom and math.abs(sent.lastZoom - v.zoom) > 0.01 then glide = 250 end
    sent.cam, sent.camAt, sent.lastZoom = cam, now, v.zoom
    android.mapCamera({ lat = lat, lon = lon, zoom = v.zoom, bearing = bearing, tilt = tilt, ahead = w.ahead, ms = glide })
  end
  -- the route line(s)
  local rt, alts
  if M.mode == "overview" and M.routes then
    rt = M.routes[M.sel]
    alts = {}
    for i, r in ipairs(M.routes) do if i ~= M.sel then alts[#alts + 1] = r end end
  elseif M.nav then
    rt = M.nav.route
  end
  local key = tostring(rt) .. tostring(M.mode) .. tostring(M.sel) .. tostring(ui.c.accent[1])
  if key ~= sent.route then
    sent.route = key
    local altLines = {}
    for _, r in ipairs(alts or {}) do altLines[#altLines + 1] = lonlat(r) end
    local accent = string.format("#%02X%02X%02X", math.floor(ui.c.accent[1] * 255 + 0.5),
      math.floor(ui.c.accent[2] * 255 + 0.5), math.floor(ui.c.accent[3] * 255 + 0.5))
    android.mapRoute({ route = routeFeatures(rt, accent), alt = altLines, width = M.nav and 14 or 11 })
  end
  -- you and the destination
  local f = M.fix
  local d = (M.mode == "overview" or M.mode == "nav") and M.dest or nil
  local mk = (f and string.format("%.6f %.6f %d %d", f.lat, f.lon, ((f.bearing or -1) >= 0 and (f.speed or -1) > 1) and math.floor(f.bearing) or -1,
    math.floor(f.accuracy or 0)) or "-") .. (d and string.format(" %.6f %.6f", d.lat, d.lon) or "")
  if mk ~= sent.markers then
    sent.markers = mk
    android.mapMarkers({
      pos = f and { lat = f.lat, lon = f.lon, acc = f.accuracy or 0,
        bearing = ((f.bearing or -1) >= 0 and (f.speed or -1) > 1) and f.bearing or -1 } or nil,
      dest = d and { lat = d.lat, lon = d.lon } or nil,
    })
  end
end

-- pinch: zoom to an exact level (cancels a + / − animation)
function M.requestRoutes(lat, lon, from) return requestRoutes(lat, lon, from) end -- for tests

function M.setZoom(z)
  zoomTarget = nil
  M.view.zoom = math.max(3, math.min(19.5, z))
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
  if M.native then
    -- MapLibre draws the map under Road Trip's screen; leave it a hole and say where
    ui.hole(x0, y0, w, h)
    local ahead = not (opts and opts.centered) and (M.mode == "nav" or (v.follow ~= false and moving and not config.get("mapNorthUp")))
    M.want = { x = x0, y = y0, w = w, h = h, view = v, ahead = ahead and 0.66 or 0.5,
      flat = (opts and opts.centered) or M.mode == "overview" }
    M.drewNative = true
    if M.wantFit and M.routes and not opts then
      M.wantFit = nil
      fitRoute(M.routes[M.sel], w - 540, h)
      local cx2, cy2 = project(M.view.lat, M.view.lon, M.view.zoom)
      M.view.lat, M.view.lon = unproject(cx2 - 270, cy2, M.view.zoom)
      app.dirty()
    end
    return
  end
  lg.setScissor(x0 * S, y0 * S, w * S, h * S)
  ui.rect(COL.bg, x0, y0, w, h)
  local z = v.zoom
  local zs = math.max(0, math.min(MAXZ, math.floor(z)))
  local zb = math.max(10, math.min(18, math.floor(z + 0.5)))
  local cx, cy = project(v.lat, v.lon, z)
  local tsz = TILE * 2 ^ (z - zs)
  local ax = x0 + w / 2
  -- looking ahead: the car sits lower on the screen while it's guided or driving heading-up
  local ahead = not (opts and opts.centered) and (M.mode == "nav" or (v.follow ~= false and moving and not config.get("mapNorthUp")))
  local ay = y0 + h * (ahead and 0.66 or 0.5)

  lg.push()
  lg.translate(ax, ay)
  lg.rotate(-math.rad(v.rot))
  local r = math.sqrt(w * w + h * h)
  local n = 2 ^ zs
  local tx0, tx1 = math.floor((cx - r) / tsz), math.floor((cx + r) / tsz)
  local ty0, ty1 = math.max(0, math.floor((cy - r) / tsz)), math.min(n - 1, math.floor((cy + r) / tsz))
  local list, fill, seen = {}, {}, {}
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do
      local t = getTile(zs, tx % n, ty, zb)
      if t and t.meshes then
        list[#list + 1] = { t = t, sx = tx * tsz - cx, sy = ty * tsz - cy, size = tsz }
      else
        -- not here (yet, or not offline): a coarser tile that is on the device stands in
        for d = 1, 4 do
          local pz = zs - d
          if pz < 0 then break end
          local px, py = math.floor(tx / 2 ^ d), math.floor(ty / 2 ^ d)
          local key = pz .. "/" .. px .. "/" .. py
          if seen[key] then break end
          local pt = localTile(pz, px % (2 ^ pz), py, zb)
          if pt and pt.meshes then
            seen[key] = true
            local size = tsz * 2 ^ d
            fill[#fill + 1] = { t = pt, sx = px * size - cx, sy = py * size - cy, size = size }
            break
          end
        end
      end
    end
  end
  -- the stand-ins first, so the real tiles draw over them
  for _, it in ipairs(list) do fill[#fill + 1] = it end
  -- layer by layer across all tiles, so a road on one tile never hides under the next tile's water
  for _, it in ipairs(fill) do
    local k = it.size / it.t.extent
    lg.setColor(COL.water) drawMesh(it.t.meshes.water, it.sx, it.sy, k)
    lg.setColor(COL.bg) drawMesh(it.t.meshes.holes, it.sx, it.sy, k)
    lg.setColor(COL.green) drawMesh(it.t.meshes.green, it.sx, it.sy, k)
  end
  for gi, g in ipairs(ROADS) do
    lg.setColor(g.color)
    for _, it in ipairs(fill) do drawMesh(it.t.meshes.roads[gi], it.sx, it.sy, it.size / it.t.extent) end
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

  -- names: placed after everything else, upright, without overlapping
  local labelList = list

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
  M.drawLabels(labelList, ax, ay, -math.rad(v.rot), tsz, z)
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

local placed = {}
local function overlaps(x1, y1, x2, y2)
  for _, r in ipairs(placed) do
    if x1 < r[3] and x2 > r[1] and y1 < r[4] and y2 > r[2] then return true end
  end
  return false
end

local function haloText(text, font, x, y, angle, ox, oy, col)
  local k = 1 / ui.S
  lg.setColor(COL.bg[1], COL.bg[2], COL.bg[3], 0.9)
  for _, o in ipairs({ { -1.5, 0 }, { 1.5, 0 }, { 0, -1.5 }, { 0, 1.5 } }) do
    local c, sn = math.cos(angle), math.sin(angle)
    lg.print(text, font, x + o[1] * c - o[2] * sn, y + o[1] * sn + o[2] * c, angle, k, k, ox, oy)
  end
  lg.setColor(col)
  lg.print(text, font, x, y, angle, k, k, ox, oy)
end

-- street and place names over the drawn map; `list` holds the visible tiles
function M.drawLabels(list, ax, ay, rot, tsz, z)
  placed = {}
  local cands = {}
  local cr, sr = math.cos(rot), math.sin(rot)
  for _, it in ipairs(list) do
    local k = tsz / it.t.extent
    for _, lb in ipairs(it.t.shapes.labels or {}) do
      local ok = lb.kind == "place" and z >= lb.minz or (lb.kind == "road" and z >= ROAD_MINZ[lb.rank])
      if ok then
        local wx, wy = it.sx + lb.x * k, it.sy + lb.y * k
        cands[#cands + 1] = { lb = lb, x = ax + wx * cr - wy * sr, y = ay + wx * sr + wy * cr, k = k }
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.lb.kind ~= b.lb.kind then return a.lb.kind == "place" end
    if a.lb.rank ~= b.lb.rank then return a.lb.rank < b.lb.rank end
    return (a.lb.len or 0) > (b.lb.len or 0)
  end)
  local seen = {}
  local shown = 0
  for _, c in ipairs(cands) do
    if shown >= 40 then break end
    local lb = c.lb
    if lb.kind == "place" then
      local f = ui.font("bold", lb.size)
      local w, h = f:getWidth(lb.name) / ui.S, f:getHeight() / ui.S
      local x1, y1 = c.x - w / 2 - 4, c.y - h / 2 - 2
      if not overlaps(x1, y1, x1 + w + 8, y1 + h + 4) then
        placed[#placed + 1] = { x1, y1, x1 + w + 8, y1 + h + 4 }
        haloText(lb.name, f, c.x, c.y, 0, f:getWidth(lb.name) / 2, f:getHeight() / 2, ui.c.text2)
        shown = shown + 1
      end
    else
      local size = lb.rank <= 2 and 15 or 14
      local f = ui.font("semibold", size)
      local w, h = f:getWidth(lb.name) / ui.S, f:getHeight() / ui.S
      local runLen = lb.len * c.k
      local key = lb.name
      local near = false
      for _, p in ipairs(seen[key] or {}) do
        if (p[1] - c.x) ^ 2 + (p[2] - c.y) ^ 2 < 260 * 260 then near = true break end
      end
      if runLen >= w + 24 and not near then
        local a = (math.atan2 or math.atan)(lb.dy, lb.dx) + rot
        a = (a + math.pi) % (2 * math.pi) - math.pi
        if a > math.pi / 2 then a = a - math.pi elseif a < -math.pi / 2 then a = a + math.pi end
        local ca, sa = math.abs(math.cos(a)), math.abs(math.sin(a))
        local bw, bh = w * ca + h * sa, w * sa + h * ca
        local x1, y1 = c.x - bw / 2, c.y - bh / 2
        if not overlaps(x1, y1, x1 + bw, y1 + bh) then
          placed[#placed + 1] = { x1, y1, x1 + bw, y1 + bh }
          seen[key] = seen[key] or {}
          table.insert(seen[key], { c.x, c.y })
          haloText(lb.name, f, c.x, c.y, a, f:getWidth(lb.name) / 2, f:getHeight() / 2, hex("B9B6AE"))
          shown = shown + 1
        end
      end
    end
  end
end

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
function M.cornerMasks(x, y, w, h, r, col) cornerMasks(x, y, w, h, r, col) end

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
    if g.lanes and h > 360 then M.drawLanes(g.lanes, x + 16, y + 16 + 148, cw) end
    local by = y + h - 16 - 64
    local info = M.roadInfo()
    if info and (info.kph or info.camera) then
      local used = M.drawSpeed(info, x + 16, by - 12 - 72, 36)
      M.drawCamera(info, x + 16 + used, by - 12 - 72 + 8)
    end
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

-- one lane's arrows, 0..1 box of size sz at x,y
local LANE_ANGLE = { straight = 0, ["slight right"] = 40, right = 90, ["sharp right"] = 135,
  ["slight left"] = -40, left = -90, ["sharp left"] = -135 }
local function laneArrow(ind, x, y, sz, col)
  lg.setColor(col)
  lg.setLineWidth(sz * 0.11)
  lg.setLineJoin("bevel")
  local cx, base, mid = x + sz / 2, y + sz * 0.92, y + sz * 0.5
  if ind == "uturn" then
    lg.line(cx + sz * 0.12, base, cx + sz * 0.12, y + sz * 0.3)
    lg.arc("line", "open", cx - sz * 0.06, y + sz * 0.3, sz * 0.18, math.pi, 2 * math.pi, 10)
    local tx = cx - sz * 0.24
    lg.line(tx, y + sz * 0.3, tx, y + sz * 0.55)
    lg.polygon("fill", tx - sz * 0.12, y + sz * 0.5, tx + sz * 0.12, y + sz * 0.5, tx, y + sz * 0.68)
    return
  end
  local a = math.rad(LANE_ANGLE[ind] or 0)
  local len = sz * 0.36
  local tx, ty = cx + math.sin(a) * len, mid - math.cos(a) * len
  lg.line(cx, base, cx, mid, tx, ty)
  local hx, hy = math.sin(a), -math.cos(a)
  local px, py = -hy, hx
  local h = sz * 0.16
  lg.polygon("fill", tx + hx * h, ty + hy * h, tx + px * h * 0.8, ty + py * h * 0.8, tx - px * h * 0.8, ty - py * h * 0.8)
end

-- which lanes to be in, under the turn card
local function drawLanes(lanes, x, y, maxW)
  local n = #lanes
  local cell = math.min(56, (maxW - 24) / n)
  local w = cell * n + 24
  ui.rect(ui.c.bg, x, y, w, cell + 20, 18)
  for i, l in ipairs(lanes) do
    local lx = x + 12 + (i - 1) * cell
    if i > 1 then ui.rect(hex("2A2C31"), lx, y + 14, 1, cell - 8) end
    local col = l.valid and ui.c.text or hex("4A4C52")
    for _, ind in ipairs(l.ind) do
      laneArrow(ind == "none" and "straight" or ind, lx + cell * 0.12, y + 10, cell * 0.76, col)
    end
  end
  return cell + 20
end
M.drawLanes = drawLanes

-- the speed limit sign (and how fast you're going, when over it)
local function drawSpeed(info, x, y, r)
  if not info then return 0 end
  local used = 0
  if info.kph then
    ui.circle(info.over and hex("D63B2F") or hex("FFFFFF"), x + r, y + r, r)
    ui.ring(hex("D63B2F"), x + r, y + r, r - r * 0.1, r * 0.2)
    if info.over then ui.circle(hex("D63B2F"), x + r, y + r, r * 0.72) end
    local t = tostring(math.floor(info.kph + 0.5))
    local fs = t:len() >= 3 and math.floor(r * 0.62) or math.floor(r * 0.8)
    ui.text(t, "bold", fs, info.over and hex("FFFFFF") or hex("111111"), x, y + r - ui.fontHeight("bold", fs) / 2, "center", r * 2)
    used = r * 2 + 12
  end
  if info.speed and (info.over or not info.kph) and info.speed > 3 then
    local t = string.format("%d", math.floor(info.speed + 0.5))
    local pw = math.max(ui.textWidth(t, "bold", 22), ui.textWidth("km/h", "semibold", 12)) + 28
    ui.rect(ui.c.bg, x + used, y + r - 32, pw, 64, 20)
    ui.text(t, "bold", 22, info.over and hex("F09A8A") or ui.c.text, x + used, y + r - 28, "center", pw)
    ui.text("km/h", "semibold", 12, ui.c.muted, x + used, y + r + 6, "center", pw)
    used = used + pw + 12
  end
  return used
end
M.drawSpeed = drawSpeed

-- a speed camera ahead
local function drawCamera(info, x, y)
  if not (info and info.camera) then return end
  local label = T("Speed camera") .. " · " .. fmtDist(info.camera)
  local w = ui.textWidth(label, "bold", 17) + 76
  ui.rect(hex("3A2A12"), x, y, w, 56, 20)
  ui.icon("camera", x + 16, y + 14, 28, ui.c.accent, 2)
  ui.text(label, "bold", 17, ui.c.accent, x + 56, y + (56 - ui.fontHeight("bold", 17)) / 2)
end
M.drawCamera = drawCamera

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
    local by = y0 + 248
    if not M.view.follow and M.fix then mapButton({ kind = "map:recenter" }, "locate", right, by) by = by + 76 end
    if mode == "nav" then
      local muted = config.get("voiceMuted") == true
      mapButton({ kind = "voiceMute" }, muted and "mute" or "sound", right, by)
      by = by + 76
    end
    if M.native then
      -- 2D / 3D, and (while browsing) the map's look
      ui.rect(ui.c.bg, right, by, 64, 64, 20)
      local t3 = config.get("map3D") and "2D" or "3D"
      ui.text(t3, "bold", 20, ui.c.text2, right, by + (64 - ui.fontHeight("bold", 20)) / 2, "center", 64)
      ui.hit({ kind = "map:3d" }, right, by, 64, 64)
      by = by + 76
      if mode == "browse" then mapButton({ kind = "mapStyles" }, "layers", right, by) end
    end
  end

  if mode == "nav" then
    local g = M.guidance()
    if g then
      drawTurnCard(g, x0 + 20, y0 + 20, math.min(500, w - 140))
      if g.lanes then drawLanes(g.lanes, x0 + 20, y0 + 20 + 148, math.min(500, w - 140)) end
      local by = y0 + h - 20 - 92
      local info = M.roadInfo()
      local used = drawSpeed(info, x0 + 20, by - 16 - 88, 44)
      drawCamera(info, x0 + 20 + used, by - 16 - 88 + 16)
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
      if M.nav.off > 50 or (M.nav.offCount or 0) > 0 then
        ui.text(T("Off the route"), "bold", 15, hex("F09A8A"), x0 + 26, y0 + 172 + (g.lanes and 84 or 0))
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
    local placeholder = s.pickFor == "home" and T("Search for your home address")
      or s.pickFor == "work" and T("Search for your work address") or T("Where to?")
    local shown = s.text ~= "" and s.text or placeholder
    ui.text(ui.fit(shown, "semibold", 20, fw - 80) .. ((s.text ~= "" and blink) and "|" or ""), "semibold", 20,
      s.text ~= "" and ui.c.text or ui.c.dim, px + 76, py + 22 + (64 - ui.fontHeight("semibold", 20)) / 2)
    mapButton({ kind = "map:closeSearch" }, "close", px + pw - 22 - 64, py + 22)

    local ry = py + 104
    -- rows: { place?, icon, name, sub, set? (which one to set), change? }
    local rows = {}
    if s.results then
      for _, it in ipairs(s.results) do rows[#rows + 1] = { place = it, icon = "pin", name = it.name, sub = it.sub } end
    elseif s.text == "" and not s.pickFor then
      for _, which in ipairs({ "home", "work" }) do
        local p = M.saved(which)
        local nm = which == "home" and T("@place:Home") or T("Work")
        if p then
          rows[#rows + 1] = { place = { name = nm, sub = p.name, lat = p.lat, lon = p.lon }, icon = which, name = nm,
            sub = p.name, change = which }
        else
          rows[#rows + 1] = { icon = which, name = which == "home" and T("Set Home") or T("Set Work"),
            sub = T("Search for an address to save"), set = which }
        end
      end
      local rec = config.get("mapRecents") or {}
      if #rec > 0 then rows[#rows + 1] = { heading = T("Recent") } end
      for _, it in ipairs(rec) do rows[#rows + 1] = { place = it, icon = "pin", name = it.name, sub = it.sub } end
    end
    if s.busy then ui.text(T("Searching…"), "semibold", 15, ui.c.muted, px + 24, ry) ry = ry + 30 end
    if s.err then ui.text(s.err, "semibold", 15, hex("F09A8A"), px + 24, ry) ry = ry + 30 end
    for i, r in ipairs(rows) do
      if r.heading then
        if ry + 30 > py + ph - 12 then break end
        ui.text(r.heading, "bold", 14, ui.c.muted, px + 24, ry + 4)
        ry = ry + 32
      else
        if ry + 76 > py + ph - 12 then break end
        ui.rect(i == 1 and s.results and hex("1E1A13") or ui.c.card, px + 16, ry, pw - 32, 76, 20)
        ui.circle(hex("22252A"), px + 16 + 40, ry + 38, 22)
        ui.icon(r.icon, px + 16 + 28, ry + 26, 24, ui.c.accent, 1.8)
        local right = r.change and 110 or 90
        local textW = pw - 32 - 90 - right
        ui.text(ui.fit(r.name or "", "bold", 18, textW), "bold", 18, ui.c.text2, px + 16 + 76, ry + 14)
        ui.text(ui.fit(r.sub or "", "semibold", 14, textW), "semibold", 14, ui.c.muted, px + 16 + 76, ry + 44)
        if r.set then
          ui.hit({ kind = "map:setPlace", which = r.set }, px + 16, ry, pw - 32, 76)
        else
          ui.hit({ kind = "map:pick", place = r.place }, px + 16, ry, pw - 32, 76)
        end
        if r.change then
          local cw = ui.textWidth(T("Change"), "bold", 15) + 32
          ui.pill({ kind = "map:setPlace", which = r.change }, T("Change"), px + pw - 16 - 14 - cw, ry + 18, 40, "off2")
        elseif M.fix and r.place and r.place.lat then
          local dist = fmtDist(haversine(M.fix.lat, M.fix.lon, r.place.lat, r.place.lon))
          ui.text(dist, "bold", 15, hex("B8B5AD"), px + 16, ry + 28, "right", pw - 32 - 18)
        end
        ry = ry + 84
      end
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
    local ry = py + 104
    -- avoid: motorways, tolls, ferries (changing one asks for new routes)
    do
      local a = config.get("mapAvoid") or {}
      local lx = px + 26
      ui.text(T("Avoid"), "bold", 14, ui.c.muted, lx, ry + (44 - ui.fontHeight("bold", 14)) / 2)
      lx = lx + ui.textWidth(T("Avoid"), "bold", 14) + 12
      for _, it in ipairs({ { "motorway", T("Motorways") }, { "toll", T("Tolls") }, { "ferry", T("Ferries") } }) do
        lx = lx + ui.pill({ kind = "map:avoid", what = it[1] }, it[2], lx, ry, 44, a[it[1]] and "accent" or "off2") + 8
      end
      ry = ry + 60
    end
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
    if not M.search then M.openSearch() else ui.openKeyboard() end
  elseif k == "map:closeSearch" then closeSearch()
  elseif k == "map:pick" then choose(id.place)
  elseif k == "map:setPlace" then
    M.search = { text = "", busy = false, pickFor = id.which }
    M.mode = "search"
    ui.openKeyboard()
  elseif k == "map:sel" then M.sel = id.i M.wantFit = true
  elseif k == "map:start" then startNav()
  elseif k == "map:cancel" then endNav()
  elseif k == "map:end" then endNav()
  elseif k == "map:allow" then listening = android.locationStart() == true
  elseif k == "map:avoid" then
    local a = config.get("mapAvoid") or {}
    a[id.what] = not a[id.what]
    config.set("mapAvoid", a)
    if M.dest then
      M.routes = nil
      requestRoutes(M.dest.lat, M.dest.lon)
    end
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
  elseif k == "map:3d" then
    config.set("map3D", not config.get("map3D"))
    if config.get("map3D") and M.view.zoom < 15.5 then zoomTarget = 16 end
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
