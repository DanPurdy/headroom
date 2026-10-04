#!/bin/bash
# Installs the latest Headroom release into /Applications (or ~/Applications).
#
#   curl -fsSL https://raw.githubusercontent.com/DanPurdy/headroom/main/scripts/install.sh | bash
#
# Uses the GitHub CLI when available (works for private repos), plain curl otherwise.
set -euo pipefail

bundle_id=io.github.danpurdy.headroom

# Everything runs from main, which is only called on the last line: if a `curl | bash`
# download is cut short, nothing runs at all rather than half the script.
main() {
  local repo="${HEADROOM_REPO:-DanPurdy/headroom}"
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release download --repo "$repo" --pattern 'Headroom-*.zip' --dir "$tmp"
  else
    local url
    url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*Headroom-[^"]*\.zip"' | head -1 | cut -d'"' -f4)
    [[ -n "$url" ]] || fail "No release found for $repo"
    curl -fsSL "$url" -o "$tmp/Headroom.zip"
  fi

  ditto -x -k "$tmp"/*.zip "$tmp/extract"
  local new="$tmp/extract/Headroom.app"

  # Check the download before touching the installed copy.
  [[ -d "$new" ]] || fail "The release didn't contain Headroom.app"
  [[ "$(bundle_id_of "$new")" == "$bundle_id" ]] || fail "The release isn't Headroom ($bundle_id)"
  codesign --verify --strict "$new" || fail "The release's code signature is broken"

  local dest=/Applications
  [[ -w "$dest" ]] || dest="$HOME/Applications"
  mkdir -p "$dest"

  if [[ -e "$dest/Headroom.app" ]]; then
    [[ "$(bundle_id_of "$dest/Headroom.app")" == "$bundle_id" ]] \
      || fail "$dest/Headroom.app is a different app; not replacing it"
    pkill -x HeadroomApp 2>/dev/null || true
    rm -rf "$dest/Headroom.app"
  fi
  mv "$new" "$dest/Headroom.app"
  # Browser downloads are quarantined; command-line ones aren't, but be sure.
  xattr -dr com.apple.quarantine "$dest/Headroom.app" 2>/dev/null || true

  open "$dest/Headroom.app"
  echo "Installed to $dest/Headroom.app. Click the gauge in the menu bar, then the gear, to connect your Claude Code accounts."
}

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

fail() {
  echo "headroom install: $*" >&2
  exit 1
}

main "$@"
