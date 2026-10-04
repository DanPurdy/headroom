<img src="assets/icon.svg" width="128" alt="Headroom icon: a head in profile, filling up with orange">

# Headroom

A macOS menu bar app showing how much of your Claude plan's limits you've used, across
several Claude Code accounts at once. It needs Claude Code installed and logged in on the Mac.

- **5-hour and weekly limits** per account, with reset countdowns. The menu bar shows one
  column per account: its label beside two stacked bars with percentages, 5-hour on top
  and weekly below.
- **Active Claude Code sessions** per account: project, model, context used.
- **Today's API-equivalent cost** per account, as estimated by Claude Code. It is not what
  your subscription bills.

## How it works, and why it's safe

By default Headroom never sees your Claude login and never calls any API.

Claude Code already passes your plan usage (`rate_limits`) to its
[status line command](https://code.claude.com/docs/en/statusline) after each reply. Headroom
wraps that command: it saves the numbers to small JSON files in
`~/Library/Application Support/Headroom`, then runs your original status line with the same
input, so what you see in the terminal doesn't change. The status line runs locally and
uses no tokens.

Those figures are as of that session's last reply, which for an idle session can be days
old, so Headroom dates each reading by the last reply in the session's transcript and never
lets an older reading replace a newer one.

The menu bar app watches those files with kqueue, so it does nothing until one changes.
The other things that wake it are a Claude Code process exiting, which drops that session
from the list, and precomputed moments: a limit window resetting, a reading going stale,
midnight, or a Live check falling due. The only timer that ticks is the countdown display,
once a minute, while the menu panel is open.

**Trade-off:** without Live, numbers update only when Claude Code replies on that account.
Usage from claude.ai, the desktop app or other devices counts towards the same limits but
shows up only after the next Claude Code reply. Readings older than 30 minutes are dimmed
with an orange "as of" age.

### Live usage (optional, per account)

Turn on **Live usage** for an account in Settings to also check its usage hourly and when
you press ⟳ on its card. This catches use from anywhere: claude.ai, the desktop app,
mobile and other machines. It reads the login Claude Code saved in your Keychain (macOS asks
first) and calls `https://api.anthropic.com/api/oauth/usage`, the undocumented endpoint
behind Claude Code's `/usage`. Headroom only reads that login: it never refreshes or
replaces it, so it can't log Claude Code out. If the saved login has expired, Live says so
until Claude Code next runs on that account. Because releases aren't signed with a
Developer ID yet, macOS will likely ask for Keychain access again after each update.

Each Claude Code config dir (`~/.claude`, or whatever `CLAUDE_CONFIG_DIR` points at) is
treated as one account.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/DanPurdy/headroom/main/scripts/install.sh | bash
```

Or download `Headroom-x.y.z.zip` from Releases and move `Headroom.app` to Applications.
Until releases are signed with a Developer ID, macOS blocks a browser download the first
time you open it. Either approve it under System Settings → Privacy & Security → Open
Anyway, or run `xattr -dr com.apple.quarantine /Applications/Headroom.app`.

Then open the menu, go to **Settings** (the gear), give each Claude Code folder a label and
press **Install**. Headroom lists `~/.claude` and any `~/.claude-*` folder; if yours lives
elsewhere, use **Add folder…**. That edits the `statusLine` in that dir's `settings.json`; your previous
status line keeps working, and a backup is kept in `~/Library/Application Support/Headroom/installs`.
**Remove** puts the original back.

Everything is also available from the command line:

```sh
/Applications/Headroom.app/Contents/MacOS/headroom install --config-dir ~/.claude-work --label Work
/Applications/Headroom.app/Contents/MacOS/headroom status
/Applications/Headroom.app/Contents/MacOS/headroom uninstall --config-dir ~/.claude-work
```

If you move the app, reopen it once: it repoints your status lines at the new location.
If you delete it, run `uninstall` first, or Claude Code's status line will fail until
you remove the `statusLine` entry from `settings.json`.

## Develop

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```sh
scripts/test.sh          # tests (works with Command Line Tools only)
swift run HeadroomApp    # run the menu bar app from source
scripts/build-app.sh     # dist/Headroom.app + zip (UNIVERSAL=1 for arm64+x86_64; needs Xcode)
scripts/make-icon.sh     # regenerate assets/AppIcon.icns after editing assets/icon.svg
```

`Sources/HeadroomCore` has everything testable: parsing, snapshots, the settings installer.
`Sources/headroom` is the CLI that Claude Code runs. `Sources/HeadroomApp` is the SwiftUI
menu bar app. Both executables ship inside `Headroom.app/Contents/MacOS`.

### Releasing

Push a `v*` tag. `.github/workflows/release.yml` tests, builds a universal app and attaches
the zip to a GitHub release. Add the signing secrets it lists to get a Developer ID-signed,
notarised build that opens without any Gatekeeper prompt.

## Later: Codex

Codex CLI writes the same kind of data to its session logs. In
`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, `event_msg` lines with
`payload.type == "token_count"` carry:

```json
"rate_limits": {
  "primary":   {"used_percent": 1.0, "window_minutes": 300,   "resets_at": 1770213616},
  "secondary": {"used_percent": 3.0, "window_minutes": 10080, "resets_at": 1770765266}
}
```

`rate_limits` can be `null`. Watching that directory with FSEvents and reading the newest
file's last non-null `rate_limits` would give a Codex card with no tokens or auth involved.
