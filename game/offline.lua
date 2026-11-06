-- Road Trip: offline maps. Download an area once (around a place, or along your route) and the
-- map shows there without a connection. Tiles come from OpenFreeMap, which allows offline
-- areas of at most 3,000 tiles or 50 MB per download, 4 requests at a time; MapDownload.java
-- keeps to that. Search and new routes still need a connection.

local T = require("lang").T

local M = {}
local android, config, ui, json, app, map

local CAP = 2900          -- tiles per area, a little under OpenFreeMap's 3,000
local DETAIL_Z, WIDE_Z = 14, 12

M.place = nil             -- { lat, lon, name? } the middle of the area to download
M.status = { state = "idle" }
M.choice = "detail"       -- what the preview shows: detail | wide | route

local pending = {}
local lastPoll, previewView = 0, nil

local function request(id, handler) if type(id) == "number" then pending[id] = handler end end

local function areas() return config.get("offlineAreas") or {} end
local function saveAreas(list) config.set("offlineAreas", list) end
local function areaDir(id) return love.filesystem.getSaveDirectory() .. "/tiles/off/" .. id end

----------------------------------------------------------------------------------------------
-- which tiles

local function tileOf(lat, lon, z)
  local px, py = map.project(lat, lon, z)
  local n = 2 ^ z
  return math.floor(px / map.TILE) % n, math.max(0, math.min(n - 1, math.floor(py / map.TILE)))
end

-- every tile from zoom 0 to maxz in a square `half` km either side of the middle
local function squareTiles(lat, lon, half, maxz, countOnly)
  local dlat = half / 111.32
  local dlon = half / (111.32 * math.max(0.05, math.cos(math.rad(lat))))
  local list, count = {}, 0
  for z = 0, maxz do
    local x0, y0 = tileOf(math.min(85, lat + dlat), lon - dlon, z)
    local x1, y1 = tileOf(math.max(-85, lat - dlat), lon + dlon, z)
    local n = 2 ^ z
    local nx = (x1 - x0) % n + 1
    if not countOnly then
      for i = 0, nx - 1 do
        for y = y0, y1 do list[#list + 1] = z .. "/" .. ((x0 + i) % n) .. "/" .. y end
      end
    end
    count = count + nx * (y1 - y0 + 1)
  end
  return list, count
end

-- the biggest square that stays under the cap
local function fitSquare(lat, lon, maxz)
  local lo, hi = 1, 600
  for _ = 1, 24 do
    local mid = (lo + hi) / 2
    local _, n = squareTiles(lat, lon, mid, maxz, true)
    if n <= CAP then lo = mid else hi = mid end
  end
  local _, n = squareTiles(lat, lon, lo, maxz, true)
  return lo, n
end

-- tiles along the route (a band about a tile either side), as far as the cap allows
local function routeTiles(route)
  local seen, list = {}, {}
  local coords, cum = route.coords, route.cum
  local covered = 0
  local nextAt = 0
  for i = 1, #coords do
    if (cum[i] or 0) >= nextAt or i == #coords then
      nextAt = (cum[i] or 0) + 400
      local add = {}
      for z = 0, DETAIL_Z do
        local tx, ty = tileOf(coords[i][1], coords[i][2], z)
        local n = 2 ^ z
        for dx = -1, 1 do
          for dy = -1, 1 do
            local y = ty + dy
            if y >= 0 and y < n then
              local k = z .. "/" .. ((tx + dx) % n) .. "/" .. y
              if not seen[k] then add[#add + 1] = k end
            end
          end
        end
      end
      if #list + #add > CAP then break end
      for _, k in ipairs(add) do seen[k] = true list[#list + 1] = k end
      covered = cum[i] or 0
    end
  end
  return list, covered
end

----------------------------------------------------------------------------------------------

function M.init(deps)
  android, config, ui, json, app, map = deps.android, deps.config, deps.ui, deps.android.json, deps.app, deps.map
end

-- the middle of the area: the map's middle (where you left it, or where you are)
function M.open()
  local v = map.view
  local lat, lon = v.lat, v.lon
  if v.follow ~= false and map.fix then lat, lon = map.fix.lat, map.fix.lon end
  if not M.place or math.abs(M.place.lat - lat) > 1e-4 or math.abs(M.place.lon - lon) > 1e-4 then
    M.place = { lat = lat, lon = lon }
    M.sizes = nil
    local place = M.place
    request(android.fetch(string.format("https://photon.komoot.io/reverse?lat=%.5f&lon=%.5f&limit=1", lat, lon)), function(r)
      local ok, d = pcall(json.decode, r.ok and r.body or "")
      local p = ok and type(d) == "table" and d.features and d.features[1] and d.features[1].properties
      if p and place == M.place then
        place.name = p.city or p.town or p.village or p.name or p.county or p.state
        app.dirty()
      end
    end)
  end
  if not M.sizes then
    local dh, dn = fitSquare(M.place.lat, M.place.lon, DETAIL_Z)
    local wh, wn = fitSquare(M.place.lat, M.place.lon, WIDE_Z)
    M.sizes = { detail = { half = dh, n = dn }, wide = { half = wh, n = wn } }
  end
  if M.choice == "route" and not map.activeRoute() then M.choice = "detail" end
  local s = android.storage()
  M.free = type(s) == "table" and s.free or nil
end

local function placeName()
  local p = M.place
  return (p and p.name) or (p and string.format("%.3f, %.3f", p.lat, p.lon)) or ""
end

function M.start(kind)
  if M.status.state == "running" then return end
  local template = map.tileTemplate()
  if not template then app.toast(T("Can't reach the map server; check the connection")) return end
  local list, area
  local id = tostring(os.time())
  if kind == "route" then
    local rt = map.activeRoute()
    if not rt then return end
    local covered
    list, covered = routeTiles(rt)
    area = { id = id, kind = "route", name = T("Route to {place}", { place = (map.dest and map.dest.name) or "?" }),
      km = math.floor(covered / 1000 + 0.5), full = covered >= (rt.cum[#rt.cum] or 0) - 1,
      lat = rt.coords[1][1], lon = rt.coords[1][2] }
  else
    local sz = M.sizes[kind]
    list = squareTiles(M.place.lat, M.place.lon, sz.half, kind == "wide" and WIDE_Z or DETAIL_Z)
    area = { id = id, kind = kind, name = placeName(), km = math.floor(sz.half * 2 + 0.5),
      lat = M.place.lat, lon = M.place.lon }
  end
  area.tiles, area.at, area.complete = #list, os.time(), false
  love.filesystem.createDirectory("tiles/off/" .. id)
  love.filesystem.write("tiles/off/" .. id .. "/tiles.json", json.encode(list))
  if android.mapDownload(id, template, list, areaDir(id)) then
    local all = areas()
    table.insert(all, 1, area)
    saveAreas(all)
    M.status = { state = "running", id = id, done = 0, total = #list, bytes = 0 }
    lastPoll = 0
  else
    app.toast(T("Couldn't start the download"))
  end
end

-- download what's missing (or everything again, for an area that's old)
local function resume(a, fresh)
  if M.status.state == "running" then app.toast(T("Another area is downloading")) return end
  local template = map.tileTemplate()
  if not template then app.toast(T("Can't reach the map server; check the connection")) return end
  local data = love.filesystem.read("tiles/off/" .. a.id .. "/tiles.json")
  local ok, list = pcall(json.decode, data or "")
  if not ok or type(list) ~= "table" then app.toast(T("Couldn't start the download")) return end
  if fresh then
    -- start over in a new folder, so the old tiles keep working until the new ones are in
    local old = a.id
    a.id = tostring(os.time())
    love.filesystem.createDirectory("tiles/off/" .. a.id)
    love.filesystem.write("tiles/off/" .. a.id .. "/tiles.json", data)
    a.replaces = old
  end
  a.complete = false
  if android.mapDownload(a.id, template, list, areaDir(a.id)) then
    local all = areas()
    for i, b in ipairs(all) do if b.id == a.id or b.id == a.replaces then all[i] = a end end
    saveAreas(all)
    M.status = { state = "running", id = a.id, done = 0, total = #list, bytes = 0 }
    lastPoll = 0
  end
end

local function finished(st)
  local all = areas()
  for _, a in ipairs(all) do
    if a.id == st.id then
      local s = android.storage(areaDir(a.id))
      a.bytes = type(s) == "table" and s.size or st.bytes
      a.done, a.failed = st.done, st.failed
      a.complete = st.state == "done" and (st.failed or 0) == 0
      a.limited = st.state == "limit"
      a.at = os.time()
      if a.replaces and a.complete then
        android.deleteTree(areaDir(a.replaces))
        a.replaces = nil
      end
    end
  end
  saveAreas(all)
  if st.state == "done" then
    app.toast((st.failed or 0) == 0 and T("Offline map ready") or T("Offline map downloaded, {n} tiles missing", { n = st.failed }))
  elseif st.state == "limit" then
    app.toast(T("Stopped at 50 MB; that's as much as one area may be"))
  end
  local s = android.storage()
  M.free = type(s) == "table" and s.free or M.free
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
  end
  local now = love.timer.getTime()
  if M.status.state == "running" and now - lastPoll > 0.5 then
    lastPoll = now
    local st = android.mapDownloadStatus()
    if type(st) == "table" then
      local was = M.status
      M.status = st
      if st.state ~= "running" and was.state == "running" then finished(st) end
      app.dirty()
    end
  end
end

-- on start: a download that was running when Road Trip closed shows as not finished
function M.check()
  local st = android.mapDownloadStatus()
  if type(st) == "table" and st.state == "running" then M.status = st end
end

----------------------------------------------------------------------------------------------
-- drawing

local function mb(b) return string.format("%.0f MB", math.max(1, (b or 0) / 1048576)) end

local function option(kind, title, sub, x, y, w, enabled)
  local on = M.choice == kind
  ui.rect(on and ui.c.accentBg or ui.c.chipHi, x, y, w, 76, 20)
  if on then
    love.graphics.setColor(ui.c.accent)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, 76, 20, 20, 16)
  end
  local busy = M.status.state == "running"
  local label = T("Download")
  local bw = ui.textWidth(label, "bold", 16) + 44
  ui.hit({ kind = "off:choose", which = kind }, x, y, w, 76)
  if enabled then
    ui.pill(not busy and { kind = "off:start", which = kind } or nil, label, x + w - 16 - bw, y + 14, 48, busy and "off" or "accent")
  end
  local tw = w - 32 - (enabled and bw + 12 or 0)
  ui.text(ui.fit(title, "bold", 17, tw), "bold", 17, enabled and ui.c.text or ui.c.muted, x + 18, y + 14)
  ui.text(ui.fit(sub, "semibold", 14, tw), "semibold", 14, ui.c.muted, x + 18, y + 42)
end

local function preview(x, y, w, h)
  local p = M.place
  if not p then return end
  local rt = map.activeRoute()
  local half, view
  if M.choice == "route" and rt then
    -- fit the route
    local minLat, maxLat, minLon, maxLon = 90, -90, 180, -180
    for _, c in ipairs(rt.coords) do
      minLat, maxLat = math.min(minLat, c[1]), math.max(maxLat, c[1])
      minLon, maxLon = math.min(minLon, c[2]), math.max(maxLon, c[2])
    end
    local clat, clon = (minLat + maxLat) / 2, (minLon + maxLon) / 2
    local km = math.max((maxLat - minLat) * 111.32, (maxLon - minLon) * 111.32 * math.cos(math.rad(clat)), 2)
    half = km / 2
    view = { lat = clat, lon = clon }
  else
    local sz = M.sizes and M.sizes[M.choice]
    half = sz and sz.half or 10
    view = { lat = p.lat, lon = p.lon }
  end
  -- zoom so the area takes most of the preview
  local kmPerPxAtZ0 = 40075 * math.cos(math.rad(view.lat)) / map.TILE
  local z = math.log((math.min(w, h) * 0.8) * kmPerPxAtZ0 / (half * 2)) / math.log(2)
  view.zoom, view.rot, view.follow = math.max(1, math.min(16, z)), 0, false
  previewView = view
  map.drawMap(x, y, w, h, { view = view, centered = true })
  if M.choice ~= "route" then
    local side = half * 2 / kmPerPxAtZ0 * 2 ^ view.zoom
    love.graphics.setColor(ui.c.accent)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", x + (w - side) / 2, y + (h - side) / 2, side, side, 6, 6)
  end
  ui.text(ui.fit(M.choice == "route" and T("Along your route") or placeName(), "bold", 15, w - 40), "bold", 15, ui.c.text,
    x + 16, y + 14)
end

function M.draw(x, y, w, h)
  ui.pill({ kind = "off:back" }, T("Back"), x + 24, y + 16, 48, "off2")
  ui.text(T("Offline maps"), "bold", 22, ui.c.text, x + 24 + ui.textWidth(T("Back"), "bold", 16) + 64, y + 26)
  local top = y + 84
  local colW = (w - 48 - 20) / 2
  local lx, rx = x + 24, x + 24 + colW + 20
  local bottom = y + h - 20

  -- left: what to download
  local ph = math.min(240, bottom - top - 3 * 86 - 70)
  preview(lx, top, colW, ph)
  map.cornerMasks(lx, top, colW, ph, 20, ui.c.bg)
  local by = top + ph + 6
  ui.pill({ kind = "off:pick" }, T("Choose on the map"), lx + colW - 16 - ui.textWidth(T("Choose on the map"), "bold", 16) - 44, top + ph - 60, 48, "off2")
  local sz = M.sizes or {}
  local d, wd = sz.detail or {}, sz.wide or {}
  option("detail", T("Every street, about {km} km across", { km = math.floor((d.half or 0) * 2 + 0.5) }),
    T("{n} map tiles, at most 50 MB", { n = d.n or 0 }), lx, by + 8, colW, true)
  option("wide", T("Main roads, about {km} km across", { km = math.floor((wd.half or 0) * 2 + 0.5) }),
    T("A bigger area with less detail · {n} tiles", { n = wd.n or 0 }), lx, by + 94, colW, true)
  local rt = map.activeRoute()
  option("route", T("Along your route"),
    rt and T("Every street, a band along the route ({km} km)", { km = math.floor((rt.distance or 0) / 1000 + 0.5) })
      or T("Plan a route on the map first"), lx, by + 180, colW, rt ~= nil)
  local note = T("OpenFreeMap allows up to 3,000 tiles or 50 MB per download, so a big region takes a few areas. Search and new routes still need a connection.")
  if M.free and M.free > 0 then note = T("{n} free on this device.", { n = string.format("%.1f GB", M.free / 1073741824) }) .. " " .. note end
  ui.textWrap(note, "semibold", 13, ui.c.muted, lx + 4, by + 266, colW - 8, 3)

  -- right: the areas you have, and the one downloading
  ui.rect(ui.c.card, rx, top, colW, bottom - top, 20)
  ui.text(T("Downloaded areas"), "bold", 14, ui.c.muted, rx + 22, top + 20)
  local ry = top + 52
  local st = M.status
  local list = areas()
  if #list == 0 then
    ui.textWrap(T("Nothing yet. Pick a size on the left and tap Download."), "semibold", 15, ui.c.muted, rx + 22, ry + 4, colW - 44, 3)
  end
  for _, a in ipairs(list) do
    if ry + 96 > bottom then break end
    if ry > top + 52 then ui.rect(ui.c.line, rx + 22, ry - 6, colW - 44, 1) end
    local running = st.state == "running" and st.id == a.id
    local sub
    if running then
      sub = T("Downloading… {done} of {total}", { done = st.done or 0, total = st.total or a.tiles }) .. " · " .. mb(st.bytes)
    elseif a.complete then
      sub = (a.kind == "route" and T("{km} km of route", { km = a.km }) or T("{km} km across", { km = a.km })) .. " · " .. mb(a.bytes)
        .. " · " .. os.date("%d.%m.%Y", a.at)
    elseif a.limited then
      sub = T("Stopped at 50 MB") .. " · " .. mb(a.bytes)
    else
      sub = T("Not finished") .. ((a.done and a.tiles) and (" · " .. a.done .. "/" .. a.tiles) or "")
    end
    local bx = rx + colW - 22
    local function btn(label, id, style)
      local bw = ui.textWidth(label, "bold", 15) + 36
      bx = bx - bw
      ui.pill(id, label, bx, ry + 20, 44, style or "off2")
      bx = bx - 8
    end
    if running then
      btn(T("Cancel"), { kind = "off:cancel" })
    else
      btn(T("Delete"), { kind = "off:delete", id = a.id })
      if a.complete then btn(T("Update"), { kind = "off:update", id = a.id })
      elseif not a.limited then btn(T("Finish"), { kind = "off:resume", id = a.id }, "accent") end
    end
    btn(T("Show"), { kind = "off:show", id = a.id })
    local tw = bx - (rx + 22) - 8
    ui.text(ui.fit(a.name or "?", "bold", 17, tw), "bold", 17, ui.c.text, rx + 22, ry + 12)
    ui.text(ui.fit(sub, "semibold", 13, tw), "semibold", 13, ui.c.muted, rx + 22, ry + 40)
    if running and (st.total or 0) > 0 then
      ui.rect(ui.hex("2C2E33"), rx + 22, ry + 66, colW - 44, 4, 2)
      ui.rect(ui.c.accent, rx + 22, ry + 66, (colW - 44) * math.min(1, (st.done or 0) / st.total), 4, 2)
    end
    ry = ry + 86
  end
end

local function find(id)
  for i, a in ipairs(areas()) do if a.id == id then return a, i end end
end

function M.activate(id)
  local k = id.kind
  if k == "off:choose" then M.choice = id.which
  elseif k == "off:start" then M.choice = id.which M.start(id.which)
  elseif k == "off:cancel" then android.mapDownloadCancel()
  elseif k == "off:resume" then local a = find(id.id) if a then resume(a, false) end
  elseif k == "off:update" then local a = find(id.id) if a then resume(a, true) end
  elseif k == "off:delete" then
    local _, i = find(id.id)
    if i then
      local all = areas()
      table.remove(all, i)
      saveAreas(all)
      android.deleteTree(areaDir(id.id))
      app.toast(T("Offline area deleted"))
    end
  elseif k == "off:show" then
    local a = find(id.id)
    if a then return "show", a end
  else
    return false
  end
  app.dirty()
  return true
end

return M
