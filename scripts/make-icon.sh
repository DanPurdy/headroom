#!/bin/bash
# Regenerates assets/AppIcon.icns, assets/HeaderGlyph.png and assets/MenuBarIcon*.png from
# assets/icon.svg. Run after editing the SVG and commit them all, so builds (and CI) never need
# an SVG renderer.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "needs rsvg-convert: brew install librsvg" >&2; exit 1; }

iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" assets/icon.svg -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) assets/icon.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o assets/AppIcon.icns

# The dropdown header shows just the head: drop the tile background and crop to the head.
glyph="$(mktemp -d)/glyph.svg"
sed -e '/fill="url(#bg)"/d' -e 's/viewBox="0 0 1024 1024" width="1024" height="1024"/viewBox="205 222 613 712"/' \
  assets/icon.svg > "$glyph"
rsvg-convert -h 72 "$glyph" -o assets/HeaderGlyph.png

# The menu bar icon is a template image (macOS tints it from its alpha): the head in black,
# lighter above the fill line, at 1x and 2x.
menubar="$(mktemp -d)/menubar.svg"
sed -e 's/<use href="#head" fill="#ECE7E0" mask="url(#aboveWave)"\/>/<use href="#head" fill="black" fill-opacity="0.45" mask="url(#aboveWave)"\/>/' \
    -e 's/<use href="#wave" fill="url(#fill)"\/>/<use href="#wave" fill="black"\/>/' "$glyph" > "$menubar"
rsvg-convert -h 18 "$menubar" -o assets/MenuBarIcon.png
rsvg-convert -h 36 "$menubar" -o assets/MenuBarIcon@2x.png
echo "Wrote assets/AppIcon.icns, assets/HeaderGlyph.png and assets/MenuBarIcon*.png"
