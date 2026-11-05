function love.conf(t)
  local onAndroid = love._os == "Android"

  t.identity = "roadtrip"
  -- runs on LÖVE 12 and 11.5; matching the running version skips the "made for" warning
  local major, minor = love.getVersion()
  t.version = major .. "." .. minor
  t.console = false

  t.window.title = "Road Trip"
  t.window.width = 1280
  t.window.height = 720
  t.window.fullscreen = onAndroid
  t.window.resizable = not onAndroid -- resize on desktop to test other screen shapes
  t.window.highdpi = true
  t.window.msaa = 4
  t.window.vsync = 1

  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
end
