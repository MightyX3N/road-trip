#!/usr/bin/env bash
# Builds the browser version of Road Trip into $1 (default: app/). Needs Node (for love.js),
# zip and python3. The same Lua code as the APK runs in love.js; web/bridge.js stands in for
# the Android side.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-app}"
WORK="$(mktemp -d)"
rm -rf "$OUT"
(cd game && zip -9 -qr "$WORK/game.love" . -x '*.DS_Store')
npx --yes love.js@11.4.1 -c -t "Road Trip" -m 134217728 "$WORK/game.love" "$WORK/out" >/dev/null
mkdir -p "$OUT"
cp "$WORK/out/game.js" "$WORK/out/game.data" "$WORK/out/love.js" "$WORK/out/love.wasm" "$OUT/"
cp web/index.html web/bridge.js web/icon.png web/manifest.json "$OUT/"
# Waypoint's styles, fonts and textures, plus a list of which glyph ranges each font has
WP=android/app/src/main/assets/waypoint
mkdir -p "$OUT/waypoint"
cp -r "$WP/styles" "$WP/glyphs" "$WP/images" "$OUT/waypoint/"
python3 - "$OUT/waypoint" <<'PY'
import json, os, sys
d = os.path.join(sys.argv[1], "glyphs")
json.dump({f: sorted(os.listdir(os.path.join(d, f))) for f in sorted(os.listdir(d))},
          open(os.path.join(sys.argv[1], "glyphs.json"), "w"))
PY
rm -rf "$WORK"
echo "built $OUT"
