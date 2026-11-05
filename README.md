# Road Trip

An Android car launcher written in Lua on LÖVE.

Right now: **Home** opens first, with your favorite apps along the bottom, the next turn,
now playing, weather and your next calendar event (radio arrives in a later update). **Apps** has
every app in a paged grid; tap to open, swipe between pages, long-press for a menu to add
or remove a favorite or open the app's info page. On first launch you pick 3 to 5
favorite apps; change them any time with the pencil button on Home or by long-pressing a
favorite. **Media** and the Now playing widget on Home show and control whatever's playing
in any app, and the Navigation widget shows your next turn from Google Maps, Waze and
other nav apps (both need notification access, which Road Trip asks for). Home also shows the weather for your city (pick it in Settings) and your next calendar
event. **Map** shows where you are, searches places, offers route choices and guides you turn
by turn, finding a new route if you leave it; the next turn also shows on Home. It needs
location access (Road Trip asks) and a GPS in the device. **Settings** has everything else: Keep in front, permissions, favorites, accent colour and updates. The voice button opens the device's
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

## Run it in Genymotion

1. Use a virtual device with **Android 11 or newer**. The APK contains x86_64 code for
   emulators and ARM code for the Ottocast; older Genymotion images are 32-bit x86 and
   won't install it.
2. Drag `road-trip.apk` onto the Genymotion window. It installs and appears in the app
   drawer as Road Trip.
3. Make it the home app: press the Home button and choose Road Trip → Always, or go to
   Settings → Apps → Default apps → Home app → Road Trip.
4. Set the virtual device to landscape (the rotate button in Genymotion's side bar).

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
routes by the [FOSSGIS OSRM server](https://routing.openstreetmap.de). None of them need an
account or key. Road Trip asks the routing server for at most one route at a time, and
waits at least 15 seconds between new routes while you drive.
