-- Road Trip: colours, fonts, shapes, icons, and tap targets.
-- Everything is drawn in a 720-unit-tall virtual space; ui.S is the scale to real pixels.

local lg = love.graphics

local ui = { S = 1, hits = {} }

local function hex(h)
  h = h:gsub("#", "")
  return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, 1 }
end
ui.hex = hex

ui.c = {
  bg      = hex("0E0F11"),
  rail    = hex("131518"),
  line    = hex("1F2125"),
  card    = hex("17191D"),
  tile    = hex("16181B"),
  tileOn  = hex("22252A"),
  ring    = hex("2A2C31"),
  chip    = hex("1A1C20"),
  chipHi  = hex("1E2024"),
  text    = hex("F3F1EC"),
  text2   = hex("E8E5DD"),
  muted   = hex("9A9890"),
  dim     = hex("34363B"),
  accent  = hex("F2A23A"),
  onAccent = hex("1A1306"),
  accentBg = hex("262117"),
}

-- accent colours offered in Settings, each with its dark tint for selected backgrounds
ui.accents = {
  { hex = "#F2A23A", tint = "262117" }, -- amber
  { hex = "#5BC0BE", tint = "13262A" }, -- teal
  { hex = "#E86F5A", tint = "2A1A16" }, -- coral
  { hex = "#9BC53D", tint = "1D2414" }, -- green
}

function ui.setAccent(h)
  ui.c.accent = hex(h)
  for _, a in ipairs(ui.accents) do
    if a.hex:lower() == h:lower() then ui.c.accentBg = hex(a.tint) end
  end
end

----------------------------------------------------------------------------------------------
-- fonts: built at (size × scale) so text stays sharp, drawn back at 1/scale
----------------------------------------------------------------------------------------------

local FILES = { semibold = "fonts/Manrope-SemiBold.ttf", bold = "fonts/Manrope-Bold.ttf" }
local fontCache = {}

function ui.setScale(s)
  ui.S = s
  fontCache = {}
end

function ui.font(weight, size)
  local key = weight .. size
  local f = fontCache[key]
  if not f then
    local px = math.max(1, math.floor(size * ui.S + 0.5))
    local file = FILES[weight]
    if file and love.filesystem.getInfo(file) then
      f = lg.newFont(file, px)
    else
      f = lg.newFont(px)
    end
    fontCache[key] = f
  end
  return f
end

-- width of text in virtual units
function ui.textWidth(text, weight, size)
  return ui.font(weight, size):getWidth(text) / ui.S
end

-- shorten text with an ellipsis until it fits maxW
function ui.fit(text, weight, size, maxW)
  if ui.textWidth(text, weight, size) <= maxW then return text end
  local utf8 = require("utf8")
  local n = utf8.len(text) or #text
  while n > 1 do
    n = n - 1
    local cut = text:sub(1, (utf8.offset(text, n + 1) or (#text + 1)) - 1) .. "…"
    if ui.textWidth(cut, weight, size) <= maxW then return cut end
  end
  return "…"
end

-- align: "left" | "center" | "right"; x,w define the box for center/right
function ui.text(text, weight, size, color, x, y, align, w)
  local f = ui.font(weight, size)
  lg.setColor(color)
  if align and align ~= "left" then
    lg.printf(text, f, x, y, (w or 0) * ui.S, align, 0, 1 / ui.S)
  else
    lg.print(text, f, x, y, 0, 1 / ui.S)
  end
end

function ui.fontHeight(weight, size) return ui.font(weight, size):getHeight() / ui.S end

-- wrapped text, at most maxLines lines (the last one gets an ellipsis if it doesn't fit)
function ui.textWrap(text, weight, size, color, x, y, w, maxLines)
  local f = ui.font(weight, size)
  local _, lines = f:getWrap(text, w * ui.S)
  if maxLines and #lines > maxLines then
    local rest = table.concat(lines, " ", maxLines)
    lines = { unpack(lines, 1, maxLines - 1) }
    lines[#lines + 1] = ui.fit(rest, weight, size, w)
  end
  lg.setColor(color)
  local lh = f:getHeight() / ui.S
  for i, line in ipairs(lines) do lg.print(line, f, x, y + (i - 1) * lh, 0, 1 / ui.S) end
  return #lines * lh
end

----------------------------------------------------------------------------------------------
-- shapes
----------------------------------------------------------------------------------------------

function ui.rect(color, x, y, w, h, r)
  lg.setColor(color)
  lg.rectangle("fill", x, y, w, h, r or 0, r or 0, 16)
end

function ui.circle(color, x, y, r)
  lg.setColor(color)
  lg.circle("fill", x, y, r, 64)
end

function ui.ring(color, x, y, r, width)
  lg.setColor(color)
  lg.setLineWidth(width or 2)
  lg.circle("line", x, y, r, 64)
end

----------------------------------------------------------------------------------------------
-- icons: hand-drawn outlines in a 24-unit box, matching the design canvas
----------------------------------------------------------------------------------------------

local icons = {}

function icons.home()
  lg.line(4, 11, 12, 4, 20, 11, 20, 20, 15, 20, 15, 14, 9, 14, 9, 20, 4, 20, 4, 11)
end

function icons.widgets()
  lg.rectangle("line", 4, 4, 7, 7)
  lg.rectangle("line", 13, 4, 7, 7)
  lg.rectangle("line", 4, 13, 7, 7)
  lg.rectangle("line", 13, 13, 7, 7)
end

function icons.media()
  lg.line(9, 18, 9, 5, 20, 3, 20, 16)
  lg.circle("line", 6, 18, 3, 24)
  lg.circle("line", 17, 16, 3, 24)
end

function icons.mic()
  lg.rectangle("line", 9, 3, 6, 11, 3, 3, 12)
  lg.arc("line", "open", 12, 11, 6, 0, math.pi, 24)
  lg.line(12, 17, 12, 20)
end

function icons.close()
  lg.line(6, 6, 18, 18)
  lg.line(18, 6, 6, 18)
end

function icons.pin()
  lg.arc("line", "open", 12, 10, 7, math.pi - 0.6, 2 * math.pi + 0.6, 24)
  lg.line(6.2, 13.95, 12, 21, 17.8, 13.95)
  lg.circle("line", 12, 10, 2.5, 16)
end

function icons.radio()
  lg.rectangle("line", 4, 9, 16, 11)
  lg.line(7, 9, 17, 4)
  lg.circle("line", 8.5, 14.5, 2, 16)
  lg.line(13, 13, 17, 13)
  lg.line(13, 16, 17, 16)
end

function icons.sun()
  lg.circle("line", 12, 12, 4, 20)
  for i = 0, 7 do
    local a = i * math.pi / 4
    lg.line(12 + math.cos(a) * 6.5, 12 + math.sin(a) * 6.5, 12 + math.cos(a) * 9, 12 + math.sin(a) * 9)
  end
end

function icons.calendar()
  lg.rectangle("line", 4, 6, 16, 14)
  lg.line(4, 10, 20, 10)
  lg.line(8, 3, 8, 7)
  lg.line(16, 3, 16, 7)
end

function icons.edit()
  lg.line(4, 20, 8, 20, 19, 9, 15, 5, 4, 16, 4, 20)
end

function icons.check()
  lg.line(5, 12, 10, 17, 19, 7)
end

-- weather
local function cloudShape(dy)
  dy = dy or 0
  lg.arc("line", "open", 8.5, 14 + dy, 3.5, math.pi * 0.5, math.pi * 1.5, 16)
  lg.arc("line", "open", 13.5, 11.5 + dy, 5, math.pi * 1.1, math.pi * 1.95, 20)
  lg.arc("line", "open", 17, 14.5 + dy, 3, math.pi * 1.5, math.pi * 2.5, 16)
  lg.line(8.5, 17.5 + dy, 17, 17.5 + dy)
end
function icons.cloud() cloudShape(0) end
function icons.rain()
  cloudShape(-3)
  lg.line(9, 17, 8, 20); lg.line(13, 17, 12, 20); lg.line(17, 17, 16, 20)
end
function icons.snow()
  cloudShape(-3)
  for _, x in ipairs({ 9, 13, 17 }) do lg.circle("fill", x - 0.5, 19, 1, 8) end
end
function icons.storm()
  cloudShape(-3)
  lg.line(13, 15.5, 11, 19, 14, 19, 12, 22.5)
end
function icons.fog()
  lg.line(5, 9, 19, 9); lg.line(4, 13, 20, 13); lg.line(6, 17, 18, 17)
end
function icons.moon()
  lg.arc("line", "open", 12, 12, 7, math.pi * 0.35, math.pi * 1.65, 24)
  lg.arc("line", "open", 15.5, 9.5, 5.2, math.pi * 0.62, math.pi * 1.38, 20)
end

function icons.gear()
  lg.circle("line", 12, 12, 6.5, 24)
  lg.circle("line", 12, 12, 2.5, 16)
  for i = 0, 7 do
    local a = i * math.pi / 4
    lg.line(12 + math.cos(a) * 6.5, 12 + math.sin(a) * 6.5, 12 + math.cos(a) * 9.5, 12 + math.sin(a) * 9.5)
  end
end

function icons.turn() -- turn right
  lg.line(8, 20, 8, 10, 17, 10)
  lg.line(14, 6, 18, 10, 14, 14)
end

local function mirrored(f)
  return function()
    lg.push()
    lg.translate(24, 0)
    lg.scale(-1, 1)
    f()
    lg.pop()
  end
end

icons.turnLeft = mirrored(icons.turn)

function icons.straight()
  lg.line(12, 20, 12, 5)
  lg.line(7, 10, 12, 5, 17, 10)
end

function icons.slightRight()
  lg.line(9, 20, 9, 13, 16, 6)
  lg.line(11, 6, 16, 6, 16, 11)
end
icons.slightLeft = mirrored(icons.slightRight)

function icons.uturn()
  lg.line(8, 20, 8, 10)
  lg.arc("line", "open", 12, 10, 4, math.pi, 2 * math.pi, 12)
  lg.line(16, 10, 16, 16)
  lg.line(13, 13, 16, 16, 19, 13)
end

function icons.roundabout()
  lg.circle("line", 12, 10, 4, 20)
  lg.line(12, 14, 12, 21)
  lg.line(15, 7, 19, 3)
  lg.line(15, 3, 19, 3, 19, 7)
end

function icons.search()
  lg.circle("line", 11, 11, 6.5, 24)
  lg.line(16, 16, 20, 20)
end

function icons.minus() lg.line(5, 12, 19, 12) end

function icons.locate()
  lg.circle("line", 12, 12, 6.5, 24)
  lg.circle("fill", 12, 12, 2.5, 16)
  lg.line(12, 2, 12, 5.5) lg.line(12, 18.5, 12, 22) lg.line(2, 12, 5.5, 12) lg.line(18.5, 12, 22, 12)
end

function icons.navArrow() lg.polygon("fill", 12, 3, 19, 21, 12, 17, 5, 21) end

function icons.map()
  lg.line(9, 4, 3, 6, 3, 20, 9, 18, 15, 20, 21, 18, 21, 4, 15, 6, 9, 4)
  lg.line(9, 4, 9, 18)
  lg.line(15, 6, 15, 20)
end

-- transport controls are solid shapes
function icons.play() lg.polygon("fill", 7, 4.5, 20, 12, 7, 19.5) end
function icons.pause()
  lg.rectangle("fill", 6, 5, 4, 14, 1, 1)
  lg.rectangle("fill", 14, 5, 4, 14, 1, 1)
end
function icons.prev()
  lg.polygon("fill", 19, 5, 19, 19, 9, 12)
  lg.rectangle("fill", 5, 5, 2.6, 14, 1, 1)
end
function icons.next()
  lg.polygon("fill", 5, 5, 5, 19, 15, 12)
  lg.rectangle("fill", 16.4, 5, 2.6, 14, 1, 1)
end

local STAR = {}
for i = 0, 9 do
  local a = -math.pi / 2 + i * math.pi / 5
  local r = i % 2 == 0 and 9.5 or 4.2
  STAR[#STAR + 1] = 12 + math.cos(a) * r
  STAR[#STAR + 1] = 12.8 + math.sin(a) * r
end
function icons.star()
  local closed = { unpack(STAR) }
  closed[#closed + 1], closed[#closed + 2] = STAR[1], STAR[2]
  lg.line(closed)
end
function icons.starFill()
  -- concave: draw as a fan of triangles from the centre
  for i = 1, #STAR, 2 do
    local j = i + 2 > #STAR and 1 or i + 2
    lg.polygon("fill", 12, 12.8, STAR[i], STAR[i + 1], STAR[j], STAR[j + 1])
  end
end
function icons.stop() lg.rectangle("fill", 6, 6, 12, 12, 1.5, 1.5) end

function icons.work() -- a briefcase
  lg.rectangle("line", 4, 8, 16, 11, 2, 2)
  lg.line(9, 8, 9, 5, 15, 5, 15, 8)
  lg.line(4, 13, 20, 13)
end

function icons.sound()
  lg.polygon("fill", 4, 9, 8, 9, 13, 5, 13, 19, 8, 15, 4, 15)
  lg.arc("line", "open", 13, 12, 4, -0.9, 0.9, 10)
  lg.arc("line", "open", 13, 12, 7.5, -0.9, 0.9, 14)
end
function icons.mute()
  lg.polygon("fill", 4, 9, 8, 9, 13, 5, 13, 19, 8, 15, 4, 15)
  lg.line(16, 9, 22, 15)
  lg.line(22, 9, 16, 15)
end

function icons.globe()
  lg.circle("line", 12, 12, 8.5, 32)
  lg.ellipse("line", 12, 12, 3.6, 8.5, 24)
  lg.line(3.5, 12, 20.5, 12)
end

function icons.back()
  lg.line(19, 12, 5, 12)
  lg.line(11, 6, 5, 12, 11, 18)
end

function icons.forward()
  lg.line(5, 12, 19, 12)
  lg.line(13, 6, 19, 12, 13, 18)
end

function icons.reload()
  lg.arc("line", "open", 12, 12, 7, -math.pi * 0.35, math.pi * 1.4, 24)
  lg.polygon("fill", 15.5, 2.5, 19.5, 7.5, 13.5, 8.5)
end

function icons.plus()
  lg.line(12, 5, 12, 19)
  lg.line(5, 12, 19, 12)
end

-- draw icon `name` with its top-left at x,y and edge length `size`
function ui.icon(name, x, y, size, color, width)
  local s = size / 24
  lg.push()
  lg.translate(x, y)
  lg.scale(s)
  lg.setColor(color)
  lg.setLineWidth((width or 1.8))
  lg.setLineJoin("bevel")
  icons[name]()
  lg.pop()
end

-- pill button; style: "primary" (light), "accent", "off" (dimmed), "off2" (quiet), nil (text only).
-- Returns its width.
function ui.pill(id, label, x, y, h, style)
  local size = h >= 60 and 18 or 16
  local w = ui.textWidth(label, "bold", size) + (h >= 60 and 72 or 44)
  local c = ui.c
  local bg = style == "primary" and c.text or style == "accent" and c.accent
    or (style == "off" or style == "off2") and c.chipHi or nil
  local fg = style == "primary" and c.bg or style == "accent" and c.onAccent or style == "off" and c.dim
    or style == "off2" and c.text2 or c.muted
  if bg then ui.rect(bg, x, y, w, h, h / 2) end
  ui.text(label, "bold", size, fg, x, y + (h - ui.fontHeight("bold", size)) / 2, "center", w)
  if id then ui.hit(id, x, y, w, h) end
  return w
end

----------------------------------------------------------------------------------------------
-- tap targets: register while drawing, look up on release
----------------------------------------------------------------------------------------------

function ui.beginFrame() ui.hits = {} end

-- `id` is any value identifying the target; later registrations win (drawn on top)
function ui.hit(id, x, y, w, h)
  ui.hits[#ui.hits + 1] = { id = id, x = x, y = y, w = w, h = h }
end

function ui.hitAt(px, py)
  for i = #ui.hits, 1, -1 do
    local h = ui.hits[i]
    if px >= h.x and px <= h.x + h.w and py >= h.y and py <= h.y + h.h then return h.id end
  end
end

return ui
