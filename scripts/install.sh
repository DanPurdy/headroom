#!/bin/bash
# Installs the latest Headroom release into /Applications (or ~/Applications).
#
#   curl -fsSL https://raw.githubusercontent.com/DanPurdy/headroom/main/scripts/install.sh | bash
#
# Uses the GitHub CLI when available (works for private repos), plain curl otherwise.
set -euo pipefail

repo="${HEADROOM_REPO:-DanPurdy/headroom}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release download --repo "$repo" --pattern 'Headroom-*.zip' --dir "$tmp"
else
  url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*Headroom-[^"]*\.zip"' | head -1 | cut -d'"' -f4)
  [[ -n "$url" ]] || { echo "No release found for $repo" >&2; exit 1; }
  curl -fsSL "$url" -o "$tmp/Headroom.zip"
fi

ditto -x -k "$tmp"/*.zip "$tmp/extract"

dest=/Applications
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"

pkill -x HeadroomApp 2>/dev/null || true
rm -rf "$dest/Headroom.app"
mv "$tmp/extract/Headroom.app" "$dest/Headroom.app"
# Unsigned builds downloaded by a browser get quarantined; command-line downloads don't, but be sure.
xattr -dr com.apple.quarantine "$dest/Headroom.app" 2>/dev/null || true

open "$dest/Headroom.app"
echo "Installed to $dest/Headroom.app. Open its menu and use 'Claude Code setup' to connect your accounts."
