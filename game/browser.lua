-- Road Trip: a web browser (Android's Chromium WebView, placed by Panel.java). Lua draws the
-- toolbar; the page itself is an Android view in the rectangle below it. Next to the map while
-- a route is on, if you want. Covered while the car moves.

local T = require("lang").T

local M = {}
local android, config, ui, app

M.status = { url = "", title = "", progress = 100, canBack = false, canForward = false }
M.field = { text = "", typing = false }
M.split = true
M.started = false

local lastPoll = 0
local HOME = "https://duckduckgo.com/"

function M.init(deps)
  android, config, ui, app = deps.android, deps.config, deps.ui, deps.app
end

local function urlEncode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- what you typed: an address, or words to search for
function M.resolve(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return HOME end
  if text:find("^https?://") then return text end
  if not text:find("%s") then
    -- a home server (an IP address or localhost) usually has no https
    if text:find("^localhost") or text:find("^%d+%.%d+%.%d+%.%d+") then return "http://" .. text end
    if text:find("^[%w%-]+%.[%w%-%.]+[/:]?") then return "https://" .. text end
  end
  return "https://duckduckgo.com/?q=" .. urlEncode(text)
end

function M.load(text)
  local url = M.resolve(text)
  M.status.url = url
  config.set("browserLast", url)
  android.webCommand("load", url)
end

-- the panel was just shown: open the first page
function M.opened()
  if M.started then return end
  M.started = true
  local s = android.webStatus()
  if type(s) == "table" and s.url and s.url ~= "" then return end -- still open from earlier
  M.load(config.get("browserLast") or HOME)
end

function M.update(dt, visible)
  if not visible then return end
  local now = love.timer.getTime()
  if now - lastPoll < 0.5 then return end
  lastPoll = now
  local s = android.webStatus()
  if type(s) == "table" then
    if s.url ~= M.status.url or s.title ~= M.status.title or s.progress ~= M.status.progress
      or s.canBack ~= M.status.canBack or s.canForward ~= M.status.canForward then app.dirty() end
    M.status = s
    if s.url and s.url ~= "" then config.set("browserLast", s.url) end
  end
end

-- the page's rectangle (virtual units)
function M.pageRect(x, y, w, h, navigating)
  local top = y + 76
  if M.split and navigating then
    local px, pw, mx, mw = ui.split(x + 16, w - 32, 16, config.get("splitSwap"))
    return px, top, pw, h - 76 - 16, mx, mw
  end
  return x + 16, top, w - 32, h - 76 - 16
end

local function iconButton(id, icon, x, y, on)
  ui.rect(ui.c.chipHi, x, y, 56, 56, 18)
  ui.icon(icon, x + 15, y + 15, 26, on and ui.c.text2 or ui.c.dim, 2)
  if on then ui.hit(id, x, y, 56, 56) end
  return 56
end

function M.draw(x, y, w, h, drawMapCard, navigating)
  local s = M.status
  local bx, by = x + 16, y + 10
  bx = bx + iconButton({ kind = "web:back" }, "back", bx, by, s.canBack) + 8
  bx = bx + iconButton({ kind = "web:forward" }, "forward", bx, by, s.canForward) + 8
  bx = bx + iconButton({ kind = "web:reload" }, "reload", bx, by, true) + 12
  local right = x + w - 16
  if navigating then
    local label = M.split and T("Hide map") or T("Show map")
    local pw = ui.textWidth(label, "bold", 16) + 44
    right = right - pw
    ui.pill({ kind = "web:split" }, label, right, by + 4, 48, "off2")
    right = right - 12
    if M.split then
      local sw = ui.textWidth(T("Swap sides"), "bold", 16) + 44
      right = right - sw
      ui.pill({ kind = "web:swap" }, T("Swap sides"), right, by + 4, 48, "off2")
      right = right - 12
    end
  end
  -- the address field
  local fw = right - bx
  ui.rect(ui.c.chip, bx, by, fw, 56, 20)
  if M.field.typing then
    love.graphics.setColor(ui.c.accent)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", bx, by, fw, 56, 20, 20, 16)
  end
  ui.icon("globe", bx + 16, by + 15, 26, ui.c.muted, 1.8)
  local text, col
  if M.field.typing then
    local blink = math.floor(love.timer.getTime() * 2) % 2 == 0
    text = (M.field.text ~= "" and M.field.text or "") .. (blink and "|" or "")
    if M.field.text == "" and not blink then text = T("Search or type an address") end
    col = M.field.text ~= "" and ui.c.text or ui.c.dim
  else
    local u = (s.url or ""):gsub("^https?://", ""):gsub("^www%.", ""):gsub("/$", "")
    text = (s.title and s.title ~= "") and s.title or (u ~= "" and u or T("Search or type an address"))
    col = ui.c.text2
  end
  ui.text(ui.fit(text, "semibold", 17, fw - 70), "semibold", 17, col, bx + 54, by + (56 - ui.fontHeight("semibold", 17)) / 2)
  if (s.progress or 100) < 100 then
    ui.rect(ui.c.accent, bx + 14, by + 52, (fw - 28) * (s.progress / 100), 3, 1.5)
  end
  ui.hit({ kind = "web:field" }, bx, by, fw, 56)

  local px, py, pw, ph, mx, mw = M.pageRect(x, y, w, h, navigating)
  ui.rect(ui.hex("FFFFFF"), px, py, pw, ph, 0) -- under Android's page
  if mx then drawMapCard(mx, py, mw, ph) end
end

function M.wantsText() return M.field.typing end

function M.textinput(t) if M.field.typing then M.field.text = M.field.text .. t end end

function M.keypressed(key)
  if not M.field.typing then return end
  if key == "backspace" then
    local off = require("utf8").offset(M.field.text, -1)
    if off then M.field.text = M.field.text:sub(1, off - 1) end
  elseif key == "return" or key == "kpenter" then
    M.field.typing = false
    ui.closeKeyboard()
    M.load(M.field.text)
  end
end

function M.back()
  if M.field.typing then
    M.field.typing = false
    ui.closeKeyboard()
    return true
  end
  if M.status.canBack then
    android.webCommand("back")
    M.status.canBack = false
    lastPoll = 0
    return true
  end
  return false
end

function M.activate(id)
  local k = id.kind
  if k == "web:back" then android.webCommand("back")
  elseif k == "web:forward" then android.webCommand("forward")
  elseif k == "web:reload" then android.webCommand((M.status.progress or 100) < 100 and "stop" or "reload")
  elseif k == "web:split" then M.split = not M.split
  elseif k == "web:swap" then config.set("splitSwap", not config.get("splitSwap"))
  elseif k == "web:field" then
    M.field.typing = true
    M.field.text = ""
    ui.openKeyboard()
  else
    return false
  end
  lastPoll = 0
  app.dirty()
  return true
end

return M
