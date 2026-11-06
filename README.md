# Road Trip

An Android car launcher written in Lua on LÖVE.

Right now: **Home** opens first, with a live map (and the next turn while you're guided),
now playing or the radio, weather, your next calendar event, and your favorite apps along
the bottom. **Apps** has
every app in a paged grid; tap to open, swipe between pages, long-press for a menu to add
or remove a favorite or open the app's info page. On first launch you pick 3 to 5
favorite apps; change them any time with the pencil button on Home or by long-pressing a
favorite. **Media** and the Now playing widget on Home show and control whatever's playing
in any app, and the Navigation widget shows your next turn from Google Maps, Waze and
other nav apps (both need notification access, which Road Trip asks for). Home also shows the weather for your city (pick it in Settings) and your next calendar
event. On first launch a short setup walks through permissions, favorite apps, Home and Work, and
local radio stations (run it again from Settings). **Map** shows where you are, with street
and place names, turned the way you're driving; searches places (with one-tap Home and Work), offers route choices (avoiding motorways, tolls or ferries if you like) and guides you turn
by turn, finding a new route if you leave it; the next turn also shows on Home. It needs
location access (Road Trip asks). Without a position yet, a route waits for the first fix
or can start from the middle of the map. Directions are spoken, with Android's voice or a natural voice (Piper, through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)) downloaded once in Settings → Spoken
directions and run on the device; the mute button on the map silences them. **Apps** and the
radio lists can be searched. **Radio** plays internet radio from
[Radio Browser](https://www.radio-browser.info): the most listened stations in your country
(change it with Change country), popular ones worldwide, or search by name. Star stations to
keep them as favorites; next and previous (on screen, in the notification or on the steering
wheel) step through them. The last station plays again when the car starts (switch that off
on the Radio screen). While the car moves, video apps are covered by the next turn and what's playing (the
sound keeps going; the video comes back once you've stopped for a few seconds). It needs
Keep in front to see which app is open, and GPS speed; Settings chooses what happens
without speed (hide video by default). While Road Trip guides you and another app is
open, a next-turn banner sits at the top of the screen. **Media** shows what's playing and
has a **Jellyfin** tab: sign in to your own Jellyfin server (with a password or Quick Connect),
browse music, audiobooks, films and series, and play music in the background with the
steering-wheel buttons. Video plays inside Road Trip, next to the map while a route is on
(Swap sides puts the map on the other side) or full screen; while the car moves the picture is
covered and the sound keeps going. Road Trip asks the server how to play each video and plays
the file as it is when the device can, otherwise the server's H.264 conversion.
**Browser** is a web browser (Android's own Chromium WebView) with the same rule: covered while
you drive, and next to the map if you like.

The map is drawn by [MapLibre](https://maplibre.org) under Road Trip's screen (Road Trip's own
buttons and turn card are drawn over it). Settings → Map picks how it looks: OpenFreeMap's
Colour (Liberty), Bright, Light, Dark and Fiord styles, Auto (colour by day, dark after
sunset), or one of the 38 game-inspired worlds from [Waypoint](https://github.com/the-geeky-couldron/waypoint)
(MIT licence; its styles, map fonts and patterns are bundled, see `third_party/waypoint`).
The 3D button tilts the map with 3D buildings where the style has them, and two fingers
pinch to zoom. If the MapLibre map doesn't show on a device, Settings → Map → Map engine
switches back to Road Trip's own simpler map.

While Road Trip guides you, it shows which lanes to be in before a turn (where OpenStreetMap
has the lanes mapped), the speed limit of the road you're on (OpenStreetMap's limits, matched to
the route by FOSSGIS's Valhalla server; red when you're going faster), and warns about fixed
speed cameras on the route (the ones mapped in OpenStreetMap, found with the Overpass API), by
voice too. All keyless; where OpenStreetMap has no data, nothing shows.

Settings → Map → Offline maps downloads an area so the map works without data: every street
around a place (about 60 km across), the main roads of a bigger region (about 250 km), or a
band along the route you've planned. Each download keeps to OpenFreeMap's limit for offline
use (3,000 tiles or 50 MB, 4 requests at a time), so a big region takes a few areas. Search and
new routes still need a connection. Settings → Diagnostics lists slow moments and freezes (with where Android was stuck), to
send in when something hangs. **Settings** has everything else: Keep in front, permissions, favorites, accent colour,
language and updates. Road Trip comes in 33 languages and follows the device's language
unless you pick one; the translations are made by AI, so some words may be off. The voice button opens the device's
assistant.

## Get the APK (no Android tools needed)

GitHub builds it for you, free, on its own servers.

1. Sign in at github.com (make a free account if you don't have one).
2. Top right **+** → **New repository**. Name it `road-trip`, leave everything else as is,
   click **Create repository**.
3. On the new repository page click **uploading an existing file**.
4. Unzip `road-trip-step1.zip` on your PC, open the `road-trip` folder, select
   **everything inside it** (`.github`, `android`, `game`, `README.md`) and drag it onto
   the upload page. Folders keep their structure. Click **Commit changes**.
   - `.github` is a hidden folder on some systems. On Windows: View → Show → Hidden items.
     On macOS: Cmd+Shift+. in Finder. Without it, nothing gets built.
5. Open the **Actions** tab. A run called "Build APK" starts by itself. It takes about
   20–40 minutes the first time.
6. When it shows a green tick, open the run and download **road-trip-apk** at the bottom.
   Unzip it: inside is `road-trip.apk`.

Every time you upload changed files, it builds a new APK. New APKs install over old
ones, since they're all signed with the same key (`android/debug.keystore`).

If the run fails with a red cross, open it, click the failed step, and send me the
last 30 or so lines.

## In a browser (and on iPhone)

The same Lua code runs in a browser at **[mightyx3n.github.io/road-trip/app](https://mightyx3n.github.io/road-trip/app/)**, through [love.js](https://github.com/Davidobot/love.js) (LÖVE 11.4 compiled to WebAssembly). `web/bridge.js` answers the calls that go to `LauncherBridge.java` on Android: web requests, GPS, radio and Jellyfin audio, the browser's voice, a MapLibre GL JS map under the canvas, video, the keyboard and the microphone. The **Build web app** workflow rebuilds `app/` on every push that touches `game/` or `web/` (`tools/build_web.sh` does the same locally).

Android-only, so hidden in the browser: being the home app, Keep in front, other apps' music and turns, offline maps, natural voices, updates. Web pages open in a new tab, because most sites refuse to be shown inside another page. On iPhone: Safari → Share → Add to Home Screen for full screen.

## Keep Road Trip in front (the guard)

Some car boxes, the Ottocast included, switch back to their own launcher by themselves.
Road Trip's guard notices and comes straight back. It's an Android accessibility
service that only sees which app is in front, never what's on screen, and it ignores
any app you open yourself.

Turn it on once: tap **Turn on** in the banner on Home (or long-press the clock →
*Turn on Keep in front*), then in Accessibility find **Road Trip: keep in front** and
switch it on.

On Android 13 and newer, if you installed the APK from a file manager or browser,
Android greys that switch out as a "Restricted setting". Road Trip's **Turn on** button
walks you through it, or by hand:
1. In Accessibility, tap **Road Trip: keep in front** once and dismiss the
   "Restricted setting" message. (This is what unlocks the next step.)
2. Settings → Apps → Road Trip → ⋮ (top right) → **Allow restricted settings**.
3. Back in Accessibility, switch it on.
(APKs installed by dragging onto Genymotion or with adb aren't affected.)

**Keeping it on through updates.** Some Android builds switch off a sideloaded app's
accessibility service when the app updates. Road Trip then shows a banner to turn it
back on. To make it switch itself back on, run this once from a computer with adb:

```sh
adb shell pm grant app.roadtrip android.permission.WRITE_SECURE_SETTINGS
```

Settings → *Keep in front after updates* shows whether it's allowed.

Long-press the clock any time for:
- **Open the box's launcher for 2 minutes**, to use the stock launcher on purpose
- **Keep in front on / off**
- **Default home app**

## Updates

Road Trip checks this repo's releases on Wi-Fi every few hours and shows a banner on
Home when there's a newer version. Tap **Update**: it downloads in the background, then
Android asks you to confirm the install. Your favorites and settings stay. The first
time, Android asks you to allow Road Trip to install apps ("Allow from this source").
Long-press the clock → **Check for updates** to check right away, on any connection.

## Install on the Ottocast later

Copy the same `road-trip.apk` to a USB stick or download it on the box, open it in the
file manager, and allow installing from that source when asked. Then pick Road Trip as
the home app the same way. Then turn on the guard, as above.

## What to check

1. All your apps appear, with their icons, sorted by name.
2. Tapping an app opens it; Home brings you back to Road Trip.
3. Swiping left and right changes pages; the dots follow.
4. Installing or removing an app shows up when you return to Road Trip.
5. Long-press opens the app's info page.
6. The voice button opens the assistant, if the device has one.

If anything fails, the error shows in red at the top right.

## What's in here

```
.github/workflows/build.yml  the GitHub build
android/                     goes over a love-android checkout
  gradle.properties          name "Road Trip", id app.roadtrip, sensorLandscape
  app/src/main/AndroidManifest.xml   home-app intent filter, <queries>, new icon
  app/src/main/java/app/roadtrip/LauncherBridge.java   app list, launch, icons, home check
  app/src/main/res/...       adaptive icon (background, foreground, themed monochrome)
  debug.keystore             signing key so updates install over each other
game/                        the LÖVE project, goes in app/src/embed/assets
  main.lua  ui.lua  android.lua  config.lua  conf.lua
  fonts/                     Manrope SemiBold + Bold (SIL Open Font License, OFL.txt)
```

## Try it on your PC without an APK

Install LÖVE from love2d.org and run `love game` (or drag the `game` folder onto
love.exe). Android calls are stubbed with fake apps, so the grid, paging and rail all
work. Resize the window to check other screen shapes.

## How the bridge works

`android.lua` reaches `LauncherBridge.call(context, method, argsJson)` through LuaJIT's
FFI: it gets the JNI environment and activity from SDL (SDL3 in LÖVE 12, SDL2 in 11.5),
loads the bridge class through the activity's class loader (plain `FindClass` can't see
app classes from SDL's thread), and calls one static method. Arguments and results are
JSON; Java escapes all non-ASCII so JNI's modified UTF-8 never gets in the way.

## Map data

Map data © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors. Tiles
from [OpenFreeMap](https://openfreemap.org), place search by [Photon](https://photon.komoot.io),
routes by the [FOSSGIS OSRM server](https://routing.openstreetmap.de) (and FOSSGIS's Valhalla server for routes that avoid motorways, tolls or ferries). Radio stations come from
[Radio Browser](https://www.radio-browser.info), a free community directory; Road Trip
reports each play to it, as it asks. Speed limits come from the same Valhalla server and speed cameras from the
[Overpass API](https://overpass-api.de), once per route. None of them need an account or key.
Map styles: OpenFreeMap's, and [Waypoint](https://github.com/the-geeky-couldron/waypoint)'s worlds
(MIT licence; the game names say what inspired each look, Waypoint isn't linked to the games). Road Trip asks the routing server for at most one route at a time, and
waits at least 15 seconds between new routes while you drive.

## Translations

The English text is the key: `game/lang/keys.txt` has one English line per string, and
`game/lang/<code>.txt` has the same lines translated, in the same order, after a line of
short day names and a line of short month names. Missing lines show in English.
`python3 tools/check_lang.py` checks that every string in the code is in `keys.txt` and
that each language has every line with the same `{placeholders}`; `--write` appends new
strings to `keys.txt`.
