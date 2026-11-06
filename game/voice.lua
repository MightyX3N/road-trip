-- Road Trip: spoken directions. Speaking happens in Voice.java, with Android's own voice or a
-- natural Piper voice (downloaded once, run on the device). This file decides what to say
-- and when, and draws the voice picker.

local lg = love.graphics
local T = require("lang").T

local M = {}
local android, config, ui, json, app, map, lang

local BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-"

-- natural voices per app language: id (Piper's name), display name, download size in MB
local CATALOG = {
  en = {
    { "en_US-amy-medium", "Amy · US", 67 }, { "en_US-lessac-medium", "Lessac · US", 67 },
    { "en_US-kristin-medium", "Kristin · US", 67 }, { "en_US-ryan-medium", "Ryan · US", 67 },
    { "en_US-joe-medium", "Joe · US", 67 }, { "en_US-john-medium", "John · US", 67 },
    { "en_GB-alba-medium", "Alba · UK", 67 }, { "en_GB-cori-medium", "Cori · UK", 67 },
    { "en_GB-jenny_dioco-medium", "Jenny · UK", 67 }, { "en_GB-northern_english_male-medium", "Northern English · UK", 67 },
  },
  da = { { "da_DK-talesyntese-medium", "Talesyntese", 67 } },
  sv = { { "sv_SE-nst-medium", "NST", 67 }, { "sv_SE-lisa-medium", "Lisa", 67 }, { "sv_SE-alma-medium", "Alma", 67 } },
  nb = { { "no_NO-talesyntese-medium", "Talesyntese", 67 } },
  fi = { { "fi_FI-harri-medium", "Harri", 67 } },
  is = { { "is_IS-bui-medium", "Búi", 67 }, { "is_IS-salka-medium", "Salka", 67 } },
  de = {
    { "de_DE-thorsten-medium", "Thorsten", 67 }, { "de_DE-kerstin-low", "Kerstin", 67 },
    { "de_DE-ramona-low", "Ramona", 67 }, { "de_DE-karlsson-low", "Karlsson", 67 },
    { "de_DE-pavoque-low", "Pavoque", 67 }, { "de_DE-eva_k-x_low", "Eva", 26 },
  },
  nl = {
    { "nl_NL-pim-medium", "Pim", 67 }, { "nl_NL-ronnie-medium", "Ronnie", 67 },
    { "nl_BE-nathalie-medium", "Nathalie · België", 67 }, { "nl_BE-rdh-medium", "RDH · België", 67 },
  },
  fr = {
    { "fr_FR-siwis-medium", "Siwis", 67 }, { "fr_FR-tom-medium", "Tom", 67 },
    { "fr_FR-gilles-low", "Gilles", 67 }, { "fr_FR-upmc-medium", "UPMC", 80 },
  },
  es = {
    { "es_ES-davefx-medium", "Davefx · España", 67 }, { "es_ES-carlfm-x_low", "Carlfm · España", 26 },
    { "es_MX-claude-high", "Claude · México", 67 }, { "es_MX-ald-medium", "Ald · México", 67 },
  },
  ca = { { "ca_ES-upc_ona-medium", "Ona", 67 }, { "ca_ES-upc_pau-x_low", "Pau", 26 } },
  pt = {
    { "pt_PT-tugao-medium", "Tugão · Portugal", 67 }, { "pt_BR-faber-medium", "Faber · Brasil", 67 },
    { "pt_BR-cadu-medium", "Cadu · Brasil", 67 }, { "pt_BR-jeff-medium", "Jeff · Brasil", 67 },
    { "pt_BR-edresson-low", "Edresson · Brasil", 67 },
  },
  it = { { "it_IT-paola-medium", "Paola", 67 }, { "it_IT-riccardo-x_low", "Riccardo", 26 } },
  pl = { { "pl_PL-gosia-medium", "Gosia", 67 }, { "pl_PL-darkman-medium", "Darkman", 67 }, { "pl_PL-mc_speech-medium", "MC Speech", 67 } },
  cs = { { "cs_CZ-jirka-medium", "Jirka", 67 } },
  sk = { { "sk_SK-lili-medium", "Lili", 67 } },
  hu = { { "hu_HU-anna-medium", "Anna", 67 }, { "hu_HU-berta-medium", "Berta", 67 }, { "hu_HU-imre-medium", "Imre", 67 } },
  ro = { { "ro_RO-mihai-medium", "Mihai", 67 } },
  sr = { { "sr_RS-serbski_institut-medium", "Srpski institut", 80 } },
  sl = { { "sl_SI-artur-medium", "Artur", 67 } },
  uk = { { "uk_UA-ukrainian_tts-medium", "Ukrainian TTS", 80 }, { "uk_UA-lada-x_low", "Лада", 26 } },
  ru = {
    { "ru_RU-irina-medium", "Ирина", 67 }, { "ru_RU-denis-medium", "Денис", 67 },
    { "ru_RU-dmitri-medium", "Дмитрий", 67 }, { "ru_RU-ruslan-medium", "Руслан", 67 },
  },
  el = { { "el_GR-rapunzelina-low", "Rapunzelina", 67 } },
  tr = { { "tr_TR-dfki-medium", "DFKI", 67 }, { "tr_TR-fettah-medium", "Fettah", 67 } },
  lv = { { "lv_LV-aivars-medium", "Aivars", 67 } },
  vi = { { "vi_VN-vais1000-medium", "VAIS1000", 67 }, { "vi_VN-25hours_single-low", "25hours", 67 }, { "vi_VN-vivos-x_low", "Vivos", 26 } },
  id = { { "id_ID-news_tts-medium", "News TTS", 67 } },
}

M.status = { engine = "off", installed = {}, downloads = {}, systemVoices = {} }
local pendingUse -- a voice to switch to once its download finishes
local lastPoll = 0
local said = {} -- what's been announced for the current step: { far = true, near = true }
local saidKey, arrivedSaid = nil, false
local page = 1

function M.engine() return config.get("voiceEngine") or "system" end
function M.muted() return config.get("voiceMuted") == true end

local function catalog() return CATALOG[lang.code] or {} end

local function find(id)
  for _, v in ipairs(catalog()) do if v[1] == id then return v end end
  for _, list in pairs(CATALOG) do for _, v in ipairs(list) do if v[1] == id then return v end end end
end

local function isInstalled(id)
  for _, v in ipairs(M.status.installed or {}) do if v == id then return true end end
  return false
end

function M.send()
  android.voiceConfig({
    engine = M.engine(), voice = config.get("voicePiper") or "", systemVoice = config.get("voiceSystem") or "",
    lang = lang.code, rate = 1.0,
  })
end

function M.init(deps)
  android, config, ui, json, app, map = deps.android, deps.config, deps.ui, deps.android.json, deps.app, deps.map
  lang = require("lang")
  M.send()
end

-- the name of the voice in use, for Settings
function M.currentName()
  local e = M.engine()
  if e == "off" then return T("Off") end
  if e == "piper" then
    local v = find(config.get("voicePiper") or "")
    return v and (v[2] .. " · " .. T("Natural voice")) or T("Natural voice")
  end
  return T("Android voice")
end

----------------------------------------------------------------------------------------------
-- what to say

local function spokenDistance(d)
  if d >= 1500 then return T("{n} kilometres", { n = math.floor(d / 1000 + 0.5) }) end
  if d >= 950 then return T("1 kilometre") end
  local r = d < 200 and 10 or 50
  return T("{n} metres", { n = math.floor(d / r + 0.5) * r })
end

local function lowerFirst(s)
  if lang.code == "en" then return (s:gsub("^%u", string.lower)) end
  return s
end

local function say(text)
  if M.muted() or M.engine() == "off" or not text or text == "" then return end
  android.voiceSpeak(text)
end
M.say = say

function M.update(dt)
  local now = love.timer.getTime()
  if now - lastPoll > 1 then
    lastPoll = now
    local s = android.voiceStatus()
    if type(s) == "table" then
      M.status = s
      if pendingUse and isInstalled(pendingUse) then
        config.set("voicePiper", pendingUse)
        config.set("voiceEngine", "piper")
        pendingUse = nil
        M.send()
        app.toast(T("Voice ready"))
      end
    end
  end

  -- a speed camera ahead: said once, about 400 m before it
  local info = map.roadInfo and map.roadInfo()
  if info and info.camera and info.camera < 420 and info.camera > 30 and not map.cameraWarned(info.cameraIndex) then
    say(T("Speed camera ahead"))
  end

  local g = map.guidance()
  if not g then
    saidKey, arrivedSaid = nil, false
    return
  end
  if g.arrived then
    if not arrivedSaid then arrivedSaid = true say(T("You've arrived")) end
    return
  end
  arrivedSaid = false
  if not g.step then return end
  -- a new step (or a new route): fresh announcements, and prepare them now
  local key = tostring(g.route) .. ":" .. tostring(g.step)
  local speed = math.max(0, map.speed())
  local far = speed > 22 and 1500 or (speed > 14 and 800 or 300)
  local near = math.max(40, speed * 5)
  local nowText = g.text
  if g.afterText and g.afterGap and g.afterGap < 150 then
    nowText = T("{instruction}, then {next}", { instruction = g.text, next = lowerFirst(g.afterText) })
  end
  if key ~= saidKey then
    saidKey = key
    said = {}
    -- already close when the step starts (just after the last turn): no "in 300 metres"
    if g.dist < near * 2 then said.far = true end
    -- the last step: "You've arrived" comes on arrival, so no second announcement at it
    if g.step.type == "arrive" then said.near = true end
    if M.engine() == "piper" then
      android.voicePrepare(setmetatable({ nowText,
        T("In {dist}, {instruction}", { dist = spokenDistance(far), instruction = lowerFirst(g.text) }) }, json.array))
    end
  end
  if not said.far and g.dist <= far and g.dist > near * 2 then
    said.far = true
    -- the distance as said: rounded, so prepared audio usually matches
    local d = g.dist > far * 0.8 and far or g.dist
    say(T("In {dist}, {instruction}", { dist = spokenDistance(d), instruction = lowerFirst(g.text) }))
  elseif not said.near and g.dist <= near then
    said.near, said.far = true, true
    say(nowText)
  end
end

----------------------------------------------------------------------------------------------
-- the voice picker (Settings → Spoken directions)

local function rows()
  local out = {
    { kind = "off", name = T("Off"), sub = T("No spoken directions") },
    { kind = "system", name = T("Android voice"), sub = T("The voice built into this device"), sys = "" },
  }
  for i, v in ipairs(M.status.systemVoices or {}) do
    out[#out + 1] = { kind = "system", sys = v.name,
      name = T("Android voice {n}", { n = i }) .. ((v.country and v.country ~= "") and (" · " .. v.country) or ""),
      sub = v.network and T("Needs internet") or T("Works offline") }
  end
  for _, v in ipairs(catalog()) do
    local id = v[1]
    local dl = (M.status.downloads or {})[id]
    local sub
    if isInstalled(id) then sub = T("Natural voice · downloaded")
    elseif dl and dl.state == "downloading" then sub = T("Downloading… {n}%", { n = dl.progress or 0 })
    elseif dl and dl.state == "extracting" then sub = T("Unpacking…")
    elseif dl and dl.state == "error" then sub = T("Download failed: {error}", { error = dl.error or "" })
    else sub = T("Natural voice · {n} MB download", { n = v[3] }) end
    out[#out + 1] = { kind = "piper", id = id, name = v[2], sub = sub, installed = isInstalled(id), busy = dl and dl.state ~= "error" }
  end
  return out
end

local function selected(r)
  local e = M.engine()
  if r.kind ~= e then return false end
  if r.kind == "piper" then return r.id == config.get("voicePiper") end
  if r.kind == "system" then return (config.get("voiceSystem") or "") == r.sys end
  return true
end

function M.draw(x0, y0, w, h)
  local x = x0 + 32
  local y = y0 + 24
  ui.pill({ kind = "voice:back" }, T("Back to Settings"), x - 8, y, 48, "off2")
  ui.text(T("Spoken directions"), "bold", 22, ui.c.text, x + 236, y + 10)
  y = y + 64
  local note = #catalog() > 0 and T("Natural voices run on this device once downloaded. They come from the Piper project; each has its own licence.")
    or T("There's no natural voice for this language yet; Android's voice speaks instead.")
  ui.textWrap(note, "semibold", 15, ui.c.muted, x, y, w - 64, 2)
  y = y + 48
  local list = rows()
  local rh, gap = 70, 8
  local bottom = y0 + h - 76
  local per = math.max(1, math.floor((bottom - y + gap) / (rh + gap)))
  local pages = math.max(1, math.ceil(#list / per))
  page = math.max(1, math.min(pages, page))
  local rw = w - 64
  for i = (page - 1) * per + 1, math.min(#list, page * per) do
    local r = list[i]
    local on = selected(r)
    ui.rect(on and ui.c.accentBg or ui.c.card, x, y, rw, rh, 20)
    if on then
      lg.setColor(ui.c.accent)
      lg.setLineWidth(2)
      lg.rectangle("line", x, y, rw, rh, 20, 20, 16)
    end
    ui.circle(on and ui.c.accent or ui.hex("34363B"), x + 34, y + rh / 2, 12)
    if on then ui.circle(ui.c.onAccent, x + 34, y + rh / 2, 5) end
    local tw = rw - 70 - 260
    ui.text(ui.fit(r.name, "bold", 18, tw), "bold", 18, on and ui.c.accent or ui.c.text2, x + 62, y + 12)
    ui.text(ui.fit(r.sub, "semibold", 14, tw), "semibold", 14, ui.c.muted, x + 62, y + 40)
    ui.hit({ kind = "voice:pick", row = r }, x, y, rw - 240, rh)
    -- right side: download / test / delete
    local bx = x + rw - 16
    if r.kind == "piper" and not r.installed then
      if not r.busy then
        local lw = ui.textWidth(T("Download"), "bold", 16) + 44
        bx = bx - lw
        ui.pill({ kind = "voice:download", id = r.id }, T("Download"), bx, y + 13, 44, "accent")
      end
    elseif r.kind ~= "off" then
      local lw = ui.textWidth(T("Test"), "bold", 16) + 44
      bx = bx - lw
      ui.pill({ kind = "voice:test", row = r }, T("Test"), bx, y + 13, 44, "off2")
      if r.kind == "piper" and not on then
        local dw = ui.textWidth(T("Delete"), "bold", 16) + 44
        bx = bx - dw - 8
        ui.pill({ kind = "voice:delete", id = r.id }, T("Delete"), bx, y + 13, 44, "off2")
      end
    end
    y = y + rh + gap
  end
  if pages > 1 then
    local py = y0 + h - 64
    ui.pill(page > 1 and { kind = "voice:page", d = -1 } or nil, T("Previous"), x, py, 52, page > 1 and "off2" or "off")
    ui.text(T("{n} of {total}", { n = page, total = pages }), "semibold", 15, ui.c.muted, x, py + 16, "center", rw)
    local nw = ui.textWidth(T("Next"), "bold", 16) + 44
    ui.pill(page < pages and { kind = "voice:page", d = 1 } or nil, T("Next"), x + rw - nw, py, 52, page < pages and "off2" or "off")
  end
end

local function sample() return T("In {dist}, {instruction}", { dist = spokenDistance(300), instruction = lowerFirst(T("Turn left")) }) end

-- returns true if it handled the id
function M.activate(id)
  local k = id.kind
  if k == "voice:pick" then
    local r = id.row
    if r.kind == "piper" and not r.installed then
      pendingUse = r.id
      android.voiceDownload(r.id, BASE .. r.id .. ".tar.bz2")
      app.toast(T("Downloading the voice; it's used when it's ready"))
    else
      config.set("voiceEngine", r.kind)
      if r.kind == "piper" then config.set("voicePiper", r.id) end
      if r.kind == "system" then config.set("voiceSystem", r.sys or "") end
      M.send()
    end
  elseif k == "voice:download" then
    android.voiceDownload(id.id, BASE .. id.id .. ".tar.bz2")
  elseif k == "voice:delete" then
    android.voiceDelete(id.id)
    lastPoll = 0
  elseif k == "voice:test" then
    local r = id.row
    config.set("voiceEngine", r.kind)
    if r.kind == "piper" then config.set("voicePiper", r.id) end
    if r.kind == "system" then config.set("voiceSystem", r.sys or "") end
    M.send()
    android.voiceSpeak(sample())
  elseif k == "voice:page" then
    page = page + id.d
  else
    return false
  end
  app.dirty()
  return true
end

function M.toggleMute()
  config.set("voiceMuted", not M.muted())
  app.toast(M.muted() and T("Spoken directions off") or T("Spoken directions on"))
end

return M
