# From Waypoint

Road Trip's game-inspired map worlds come from [Waypoint](https://github.com/the-geeky-couldron/waypoint)
(commit 124e1735ad95a7192f0d29dc21e45e1de2de9301), MIT licence (`LICENSE` here).

Copied into `android/app/src/main/assets/waypoint/`:

- `styles/*.json`: the 38 MapLibre styles (OpenFreeMap tiles, OpenMapTiles schema)
- `glyphs/`: the map fonts as MapLibre glyph files; their licences are in `font-licenses/`
- `images/`: the four patterns the styles use (paper fibre, pixel grass, stone, water)

`game/assets/worlds/*.jpg` are smaller copies of Waypoint's map previews, and `game/worlds.lua`
lists the worlds (names, what inspired them, colours) from Waypoint's `World.kt` and README.
Game names say what inspired each look; Waypoint and Road Trip aren't connected to the games
or their publishers.
