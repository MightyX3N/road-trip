-- Road Trip: the Map settings screen. How the map looks (OpenFreeMap's styles and Waypoint's
-- game-inspired worlds), 3D, which map engine, and offline areas.
-- know about traffic.

local T = require("lang").T

local M = {}
local android, config, ui, json, app, map

local WORLDS = require("worlds")

-- the plain styles first
local BASIC = {
  { id = "auto", name = "Auto", sub = "Colour by day, dark at night", col = { "E8E4D8", "FFFFFF", "C9D9B4" } },
  { id = "ofm:liberty", name = "Colour", sub = "OpenFreeMap Liberty", col = { "F2EFE9", "FFFFFF", "AAD3DF" } },
  { id = "ofm:bright", name = "Bright", sub = "OpenFreeMap Bright", col = { "F8F4F0", "FFFFFF", "A0C8F0" } },
  { id = "ofm:positron", name = "Light", sub = "OpenFreeMap Positron", col = { "F2F3F0", "FFFFFF", "C2C8CA" } },
  { id = "ofm:dark", name = "Dark", sub = "OpenFreeMap Dark", col = { "0E0E0E", "2B2B2B", "1B1B1D" } },
  { id = "ofm:fiord", name = "Fiord", sub = "OpenFreeMap Fiord", col = { "45516E", "6F7D9C", "38435C" } },
}

M.page = 1

local images = {}
local pending = {}

local function list()
  local out = {}
  for _, b in ipairs(BASIC) do
    out[#out + 1] = { id = b.id, name = b.id == "ofm:fiord" and b.name or T(b.name), sub = b.id == "auto" and T(b.sub) or b.sub, col = b.col }
  end
  for _, w in ipairs(WORLDS) do
    out[#out + 1] = { id = "wp:" .. w[1], file = w[1], name = w[2], sub = T("Inspired by {game}", { game = w[3] }),
      col = { w[5], w[6], w[7] }, route = w[4] }
  end
  return out
end

local function preview(file)
  if not file then return nil end
  local e = images[file]
  if e == nil then
    local path = "assets/worlds/" .. file .. ".jpg"
    if love.filesystem.getInfo(path) then
      local ok, img = pcall(love.graphics.newImage, path)
      e = ok and img or false
    else
      e = false
    end
    images[file] = e
  end
  return e or nil
end

function M.init(deps)
  android, config, ui, json, app, map = deps.android, deps.config, deps.ui, deps.android.json, deps.app, deps.map
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
end

function M.wantsText() return false end
function M.back() return false end

----------------------------------------------------------------------------------------------
-- drawing

local function swatch(col, x, y, w, h)
  ui.rect(ui.hex(col[1]), x, y, w, h, 12)
  love.graphics.setColor(ui.hex(col[2]))
  love.graphics.setLineWidth(6)
  love.graphics.line(x + 8, y + h * 0.7, x + w * 0.45, y + h * 0.35, x + w - 8, y + h * 0.55)
  ui.rect(ui.hex(col[3]), x + w * 0.62, y + 8, w * 0.3, h * 0.3, 6)
end

local function row(title, sub, x, y, w, button, toggle)
  local right = x + w - 20
  if button then
    local bw = ui.textWidth(button[1], "bold", 16) + 44
    right = right - bw
    ui.pill(button[2], button[1], right, y + 14, 48, button[3] or "off2")
  elseif toggle then
    right = right - 60
    ui.rect(toggle[1] and ui.c.accent or ui.hex("34363B"), right, y + 21, 60, 34, 17)
    ui.circle(ui.c.text, toggle[1] and (right + 60 - 17) or (right + 17), y + 38, 13)
    ui.hit(toggle[2], right - 10, y + 6, 80, 64)
  end
  local tw = right - x - 40
  ui.text(ui.fit(title, "bold", 18, tw), "bold", 18, ui.c.text, x + 20, y + 12)
  if sub then ui.text(ui.fit(sub, "semibold", 14, tw), "semibold", 14, ui.c.muted, x + 20, y + 42) end
end

function M.draw(x, y, w, h)
  ui.pill({ kind = "ms:back" }, T("Back to Settings"), x + 24, y + 16, 48, "off2")
  ui.text(T("Map"), "bold", 22, ui.c.text, x + 24 + ui.textWidth(T("Back to Settings"), "bold", 16) + 64, y + 26)
  local top = y + 84
  local lw = math.min(440, (w - 68) * 0.42)
  local lx, rx = x + 24, x + 24 + lw + 20
  local rw = x + w - 24 - rx
  local bottom = y + h - 20

  -- left: engine, offline areas, 3D
  ui.rect(ui.c.card, lx, top, lw, bottom - top, 20)
  local ry = top + 8
  local native = map.native
  row(T("Map engine"), native and T("MapLibre: styles, 3D, smooth") or T("Road Trip's own: simpler"),
    lx, ry, lw, { T("Change"), { kind = "ms:engine" } })
  ry = ry + 76
  ui.rect(ui.c.line, lx + 20, ry, lw - 40, 1)
  local areas = #(config.get("offlineAreas") or {})
  row(T("Offline maps"), areas > 0 and T("{n} areas on this device", { n = areas }) or T("Download your area once; the map works without data"),
    lx, ry, lw, { T("Open"), { kind = "offOpen" } })
  ry = ry + 76
  ui.rect(ui.c.line, lx + 20, ry, lw - 40, 1)
  row(T("3D view"), native and T("Tilts the map while you drive") or T("Needs the MapLibre engine"), lx, ry, lw, nil,
    native and { config.get("map3D") == true, { kind = "ms:3d" } } or nil)
  ry = ry + 76
  ui.rect(ui.c.line, lx + 20, ry, lw - 40, 1)

  -- right: how the map looks
  ui.rect(ui.c.card, rx, top, rw, bottom - top, 20)
  ui.text(T("How the map looks"), "bold", 14, ui.c.muted, rx + 22, top + 20)
  if not native then
    ui.textWrap(T("Styles need the MapLibre engine. Change it on the left."), "semibold", 15, ui.c.muted, rx + 22, top + 52, rw - 44, 3)
    return
  end
  local items = list()
  local cols = rw > 760 and 3 or 2
  local gap = 14
  local cw = (rw - 44 - gap * (cols - 1)) / cols
  local ch = 150
  local gy = top + 50
  local rows = math.max(1, math.floor((bottom - 70 - gy + gap) / (ch + gap)))
  local per = rows * cols
  local pages = math.ceil(#items / per)
  M.page = math.max(1, math.min(pages, M.page))
  local cur = config.get("mapStyle") or "auto"
  local first = (M.page - 1) * per + 1
  for i = first, math.min(#items, first + per - 1) do
    local it = items[i]
    local k = i - first
    local cx = rx + 22 + (k % cols) * (cw + gap)
    local cy = gy + math.floor(k / cols) * (ch + gap)
    local on = it.id == cur
    ui.rect(on and ui.c.accentBg or ui.c.chipHi, cx, cy, cw, ch, 18)
    local img = preview(it.file)
    local iw, ih = cw - 20, ch - 66
    if img then
      local sc = math.max(iw / img:getWidth(), ih / img:getHeight())
      local S = ui.S
      love.graphics.setScissor((cx + 10) * S, (cy + 10) * S, iw * S, ih * S)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(img, cx + 10 + (iw - img:getWidth() * sc) / 2, cy + 10 + (ih - img:getHeight() * sc) / 2, 0, sc, sc)
      love.graphics.setScissor()
    else
      swatch(it.col, cx + 10, cy + 10, iw, ih)
    end
    if on then
      love.graphics.setColor(ui.c.accent)
      love.graphics.setLineWidth(3)
      love.graphics.rectangle("line", cx, cy, cw, ch, 18, 18, 16)
    end
    ui.text(ui.fit(it.name, "bold", 16, cw - 24), "bold", 16, on and ui.c.accent or ui.c.text, cx + 12, cy + ch - 52)
    ui.text(ui.fit(it.sub, "semibold", 12, cw - 24), "semibold", 12, ui.c.muted, cx + 12, cy + ch - 28)
    ui.hit({ kind = "ms:pick", id = it.id }, cx, cy, cw, ch)
  end
  if pages > 1 then
    local py = bottom - 64
    ui.pill(M.page > 1 and { kind = "ms:page", d = -1 } or nil, T("Previous"), rx + 22, py, 48, M.page > 1 and "off2" or "off")
    ui.text(T("{n} of {total}", { n = M.page, total = pages }), "semibold", 15, ui.c.muted, rx, py + 14, "center", rw)
    local nw = ui.textWidth(T("Next"), "bold", 16) + 44
    ui.pill(M.page < pages and { kind = "ms:page", d = 1 } or nil, T("Next"), rx + rw - 22 - nw, py, 48, M.page < pages and "off2" or "off")
  end
  ui.text(ui.fit(T("Game-inspired worlds by Waypoint (MIT licence) · map data © OpenStreetMap"), "semibold", 11, rw - 44),
    "semibold", 11, ui.c.dim, rx + 22, bottom - 12 - ui.fontHeight("semibold", 11))
end

function M.activate(id)
  local k = id.kind
  if k == "ms:pick" then
    config.set("mapStyle", id.id)
  elseif k == "ms:page" then
    M.page = M.page + id.d
  elseif k == "ms:3d" then
    config.set("map3D", not config.get("map3D"))
  elseif k == "ms:engine" then
    local to = map.native and "classic" or "maplibre"
    app.toast(T("Starting Road Trip again with the other map…"))
    android.mapSetEngine(to)
  else
    return false
  end
  app.dirty()
  return true
end

return M
