-- Road Trip: saved settings (config.json in the save directory).

local json = require("android").json

local FILE = "config.json"

local defaults = {
  accent = "#F2A23A",
  homeHintDismissed = false, -- "set as home app" banner
}

local M = { data = {} }

function M.load()
  local data = {}
  if love.filesystem.getInfo(FILE) then
    local text = love.filesystem.read(FILE)
    data = (text and json.decode(text)) or {}
  end
  for k, v in pairs(defaults) do
    if data[k] == nil then data[k] = v end
  end
  M.data = data
end

function M.save()
  local ok, err = love.filesystem.write(FILE, json.encode(M.data))
  if not ok then print("config save failed: " .. tostring(err)) end
end

function M.get(k) return M.data[k] end

function M.set(k, v)
  M.data[k] = v
  M.save()
end

return M
