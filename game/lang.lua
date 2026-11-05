-- Road Trip: translations. The English text is the key; lang/<code>.txt maps it to the
-- language's text. Missing entries fall back to English. The translations are
-- machine-made (AI), and Settings says so.

local M = { code = "en", t = {} }

-- every language that ships, with its own name for itself
M.list = {
  { code = "en", name = "English" },
  { code = "da", name = "Dansk" },
  { code = "sv", name = "Svenska" },
  { code = "nb", name = "Norsk" },
  { code = "fi", name = "Suomi" },
  { code = "is", name = "Íslenska" },
  { code = "de", name = "Deutsch" },
  { code = "nl", name = "Nederlands" },
  { code = "fr", name = "Français" },
  { code = "es", name = "Español" },
  { code = "ca", name = "Català" },
  { code = "pt", name = "Português" },
  { code = "it", name = "Italiano" },
  { code = "pl", name = "Polski" },
  { code = "cs", name = "Čeština" },
  { code = "sk", name = "Slovenčina" },
  { code = "hu", name = "Magyar" },
  { code = "ro", name = "Română" },
  { code = "hr", name = "Hrvatski" },
  { code = "sl", name = "Slovenščina" },
  { code = "sr", name = "Српски" },
  { code = "bg", name = "Български" },
  { code = "uk", name = "Українська" },
  { code = "ru", name = "Русский" },
  { code = "el", name = "Ελληνικά" },
  { code = "tr", name = "Türkçe" },
  { code = "et", name = "Eesti" },
  { code = "lv", name = "Latviešu" },
  { code = "lt", name = "Lietuvių" },
  { code = "id", name = "Bahasa Indonesia" },
  { code = "ms", name = "Bahasa Melayu" },
  { code = "vi", name = "Tiếng Việt" },
  { code = "tl", name = "Filipino" },
}

local EN_DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local EN_MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local aliases = { no = "nb", nn = "nb", iw = "he", ["in"] = "id", fil = "tl" }

function M.known(code)
  for _, l in ipairs(M.list) do if l.code == code then return l end end
  return nil
end

-- "auto" (or nil) follows the device's language when it's one we have
function M.resolve(choice, deviceLang)
  if choice and choice ~= "auto" and M.known(choice) then return choice end
  local d = (deviceLang or "en"):lower():match("^(%a+)") or "en"
  d = aliases[d] or d
  return M.known(d) and d or "en"
end

local function lines(path)
  local data = love.filesystem.read(path)
  local out = {}
  if not data then return out end
  data = data:gsub("\r", "")
  for line in (data .. (data:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  return out
end

local function split(s)
  local out = {}
  for part in (s or ""):gmatch("[^,]+") do out[#out + 1] = part end
  return out
end

-- lang/keys.txt holds the English lines; lang/<code>.txt the same lines translated, in the
-- same order, after two lines of short day and month names
function M.set(code)
  M.code = code
  M.t = {}
  if code == "en" then return end
  local keys = lines("lang/keys.txt")
  local tr = lines("lang/" .. code .. ".txt")
  if #tr < 2 then M.code = "en" return end
  local days, months = split(tr[1]), split(tr[2])
  if #days == 7 then M.t.__days = days end
  if #months == 12 then M.t.__months = months end
  for i, k in ipairs(keys) do
    local v = tr[i + 2]
    if v and v ~= "" then M.t[k] = v end
  end
end

function M.name(code)
  local l = M.known(code)
  return l and l.name or code
end

local function fill(s, vars)
  if not vars then return s end
  return (s:gsub("{(%w+)}", function(k)
    local v = vars[k]
    if v == nil then return "{" .. k .. "}" end
    return tostring(v)
  end))
end

-- T("Road Trip {v} is available", { v = "0.1.20" })
function M.T(s, vars)
  local r = M.t[s]
  if type(r) ~= "string" or r == "" then r = s end
  return fill(r, vars)
end

function M.day(t) return (M.t.__days or EN_DAYS)[tonumber(os.date("%w", t)) + 1] end
function M.month(t) return (M.t.__months or EN_MONTHS)[tonumber(os.date("%m", t))] end

return M
