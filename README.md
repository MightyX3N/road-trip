# Road Trip — step 1

A working home screen: your real apps in a paged grid of round tiles, tap to open,
swipe between pages, long-press an app to open its Android info page (uninstall,
permissions). The left rail (Home, Widgets, Media) and the voice button are in place;
Widgets and Media are placeholders until step 3.

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

## Install on the Ottocast later

Copy the same `road-trip.apk` to a USB stick or download it on the box, open it in the
file manager, and allow installing from that source when asked. Then pick Road Trip as
the home app the same way. The Ottocast may still fall back to its own launcher
sometimes; that's what the guard in step 2 fixes.

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
