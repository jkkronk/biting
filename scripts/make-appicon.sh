#!/usr/bin/env bash
#
# make-appicon.sh — regenerate the macOS AppIcon set from a single 1024×1024 master.
#
# Reproducibly resizes art/AppIcon-1024.png into 7 unique PNGs mapped to the 10 Mac App
# Store icon slots (16–512 pt, @1x/@2x — sizes are shared across slots) and writes a
# matching Contents.json. Run after
# editing the master, then `xcodegen generate` is NOT needed (assets are globbed),
# but a rebuild is required to recompile Assets.car.
#
# Usage:  bash scripts/make-appicon.sh
#
# Required pixel sizes (slot → pixels):
#   16@1x=16  16@2x=32  32@1x=32  32@2x=64  128@1x=128 128@2x=256
#   256@1x=256 256@2x=512 512@1x=512 512@2x=1024
set -euo pipefail

# Resolve repo root so the script works from any cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/art/AppIcon-1024.png"
OUT="$ROOT/Shoo/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$SRC" ]]; then
  echo "error: master icon not found at $SRC" >&2
  exit 1
fi

mkdir -p "$OUT"

# Render each unique pixel size once; slots below reuse these files.
gen() { sips -z "$1" "$1" "$SRC" --out "$OUT/icon_${1}.png" >/dev/null; }
for s in 16 32 64 128 256 512 1024; do gen "$s"; done

# Emit Contents.json mapping each slot to its filename.
cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Wrote 7 PNGs + Contents.json into $OUT"
