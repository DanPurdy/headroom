#!/bin/bash
# Builds dist/Headroom.app and dist/Headroom-<version>.zip.
#
#   VERSION=1.2.3     version stamped into Info.plist (default: 0.0.0-dev)
#   UNIVERSAL=1       build arm64 + x86_64 (needs Xcode, not just the Command Line Tools)
#   SIGN_IDENTITY=…   "Developer ID Application: …" to sign for distribution; ad-hoc otherwise
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-0.0.0-dev}"
arch_flags=()
[[ "${UNIVERSAL:-0}" == "1" ]] && arch_flags=(--arch arm64 --arch x86_64)

swift build -c release ${arch_flags[@]+"${arch_flags[@]}"}
bin=$(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)

app=dist/Headroom.app
rm -rf dist
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/HeadroomApp" "$app/Contents/MacOS/HeadroomApp"
cp "$bin/headroom" "$app/Contents/MacOS/headroom"
cp assets/AppIcon.icns assets/HeaderGlyph.png "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>io.github.danpurdy.headroom</string>
  <key>CFBundleExecutable</key><string>HeadroomApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Inner executable first, then the bundle (which signs the main executable).
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app/Contents/MacOS/headroom"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app/Contents/MacOS/headroom"
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

ditto -c -k --keepParent "$app" "dist/Headroom-${version}.zip"
echo "Built $app ($version) and dist/Headroom-${version}.zip"
