#!/usr/bin/env bash
# Exports every PNG slot expected by AppIcon.appiconset from design/icon.svg.
# Requires: rsvg-convert (brew install librsvg)
#
# Run from repo root: ./scripts/generate_icons.sh
set -euo pipefail

SRC="design/icon.svg"
DEST="Pointless/Assets.xcassets/AppIcon.appiconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install with: brew install librsvg"
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "Source icon not found at $SRC"
  exit 1
fi

mkdir -p "$DEST"

render() {
  local size=$1
  local scale=$2
  local out=$3
  local pixels=$((size * scale))
  rsvg-convert -w "$pixels" -h "$pixels" "$SRC" -o "$DEST/$out"
  echo "wrote $out (${pixels}x${pixels})"
}

render 16 1 icon_16x16.png
render 16 2 icon_16x16@2x.png
render 32 1 icon_32x32.png
render 32 2 icon_32x32@2x.png
render 128 1 icon_128x128.png
render 128 2 icon_128x128@2x.png
render 256 1 icon_256x256.png
render 256 2 icon_256x256@2x.png
render 512 1 icon_512x512.png
render 512 2 icon_512x512@2x.png

# Write an updated Contents.json pointing to the generated files.
cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",    "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",    "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png","idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png","idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png","idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo ""
echo "Icons exported to $DEST"
echo "Next: open Pointless.xcodeproj, verify AppIcon preview, and rebuild."
