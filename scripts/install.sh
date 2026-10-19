#!/usr/bin/env bash
#
# Install NoPeek for the current user (spec §9):
#   1. build + ad-hoc sign the app      (scripts/build-app.sh)
#   2. copy it to ~/Applications/NoPeek.app
#   3. write ~/Library/LaunchAgents/com.sinsombat.nopeek.plist
#   4. (re)load it with launchd so the menu-bar icon appears now and at every login
#
# Usage: scripts/install.sh
# Remove with `make uninstall` (keeps logs/config) — see scripts/uninstall.sh.
#
# Quit semantics (R8): the plist asks for `KeepAlive = { SuccessfulExit =
# false }`, not `KeepAlive = true`. A crash or a kill (signal exit) is
# restarted per ThrottleInterval; the menu's `Quit NoPeek` exits 0 and stays
# quit until the next login. To stop NoPeek for good, uninstall it.
#
# Nothing here touches a TCC-protected resource: no Screen Recording, no
# Accessibility, no Full Disk Access, no camera/mic request. The only permission
# NoPeek ever asks for is notification delivery, and that is requested by the app
# itself (later task), never by this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LABEL="com.sinsombat.nopeek"
EXECUTABLE_NAME="NoPeek"
SOURCE_APP="$ROOT_DIR/build/NoPeek.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$EXECUTABLE_NAME.app"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

"$SCRIPT_DIR/build-app.sh"

echo "==> installing to $INSTALLED_APP"
mkdir -p "$INSTALL_DIR"

# Stop the previous copy before replacing the bundle, otherwise launchd keeps
# running the old executable (KeepAlive would also fight a plain kill).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

rm -rf "$INSTALLED_APP"
cp -R "$SOURCE_APP" "$INSTALLED_APP"
codesign --verify --verbose=2 "$INSTALLED_APP"

echo "==> writing $AGENT_PLIST"
mkdir -p "$AGENT_DIR"
# launchd does not expand `~`, so `Program` is the fully expanded absolute path.
# KeepAlive is the R8 dict (not `true`): restart on crash/kill, honour a clean
# quit. See the header note.
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>Program</key>
	<string>$INSTALLED_APP/Contents/MacOS/$EXECUTABLE_NAME</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
</dict>
</plist>
PLIST

plutil -lint "$AGENT_PLIST"
# The file mode must not depend on the caller's umask: 644 is what launchd
# and every reader of ~/Library/LaunchAgents expects.
chmod 644 "$AGENT_PLIST"

echo "==> loading LaunchAgent ($DOMAIN/$LABEL)"
launchctl bootstrap "$DOMAIN" "$AGENT_PLIST"

# RunAtLoad starts the app with the bootstrap. launchd's own view is the
# success check: `state = running` means the service is up, whether or not a
# process is momentarily visible. The pgrep below stays as a secondary hint.
for _ in $(seq 1 20); do
    if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
        break
    fi
    sleep 0.25
done

if ! launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "error: launchd reports NoPeek is not running — inspect with: launchctl print $DOMAIN/$LABEL" >&2
    exit 1
fi

PID_HINT="$(pgrep -x "$EXECUTABLE_NAME" 2>/dev/null | paste -sd ' ' - || true)"
if [ -z "$PID_HINT" ]; then
    PID_HINT="no pgrep match yet (launchd still reports state = running)"
fi

echo "==> NoPeek installed and running (pid $PID_HINT)"
echo "    menu bar: shield icon · quit: Quit NoPeek (⌘Q) — stays quit until login"
echo "    status:   launchctl print $DOMAIN/$LABEL"
