#!/usr/bin/env bash
#
# Uninstall NoPeek for the current user (spec §9).
#
#   scripts/uninstall.sh            stop it, remove the app + LaunchAgent,
#                                   and KEEP the logs, config and state
#   scripts/uninstall.sh --purge    ...and delete the logs, config and state
#
# What runs, in order:
#   1. `launchctl bootout gui/<uid>/com.sinsombat.nopeek` — a service that is
#      not loaded is fine ("nothing to stop"), the file is what goes next
#   2. remove ~/Library/LaunchAgents/com.sinsombat.nopeek.plist
#   3. remove ~/Applications/NoPeek.app
#   4. --purge only: remove ~/Library/Logs/NoPeek, ~/.config/nopeek and
#      ~/Library/Application Support/NoPeek
#
# Nothing outside those paths is touched. Logs and config are kept by default
# because they are the user's own evidence: a later `make install` picks the
# history back up. `make uninstall` calls this script without --purge.
#
# Quit semantics (R8): this is a *full* removal. To only stop NoPeek, use the
# menu's Quit NoPeek — with `KeepAlive = { SuccessfulExit = false }` a clean
# quit (exit 0) stays quit until the next login, while a crash/kill respawns.

set -euo pipefail

LABEL="com.sinsombat.nopeek"
EXECUTABLE_NAME="NoPeek"
INSTALLED_APP="$HOME/Applications/NoPeek.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/NoPeek"
CONFIG_DIR="$HOME/.config/nopeek"
STATE_DIR="$HOME/Library/Application Support/NoPeek"
DOMAIN="gui/$(id -u)"

PURGE=0
if [ $# -gt 1 ] || { [ $# -eq 1 ] && [ "$1" != "--purge" ]; }; then
    echo "usage: $(basename "$0") [--purge]" >&2
    exit 2
fi
[ "${1:-}" = "--purge" ] && PURGE=1

# --- 1. stop the service ------------------------------------------------------

echo "==> stopping $DOMAIN/$LABEL"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    if launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null; then
        echo "    booted out"
    else
        echo "    warning: launchctl bootout failed — the service may still be loaded" >&2
    fi
else
    echo "    not loaded — nothing to stop"
fi

# bootout terminates the app; give it a moment, then handle an instance that
# was started outside launchd (it would otherwise keep a deleted bundle alive
# and stay invisible to the next install).
for _ in $(seq 1 20); do
    pgrep -x "$EXECUTABLE_NAME" >/dev/null || break
    sleep 0.25
done
if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
    echo "    $EXECUTABLE_NAME is still running (not launchd-managed) — terminating it"
    pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
    for _ in $(seq 1 8); do
        pgrep -x "$EXECUTABLE_NAME" >/dev/null || break
        sleep 0.25
    done
fi
if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
    echo "    $EXECUTABLE_NAME ignored SIGTERM — SIGKILL"
    pkill -9 -x "$EXECUTABLE_NAME" 2>/dev/null || true
    for _ in $(seq 1 8); do
        pgrep -x "$EXECUTABLE_NAME" >/dev/null || break
        sleep 0.25
    done
fi

# Final gate before anything is deleted: a surviving process means launchd (a
# stale KeepAlive job) or the kernel is respawning/holding it, and removing the
# bundle now would leave a running copy behind for the next install to trip on.
if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
    echo "error: $EXECUTABLE_NAME is still running after SIGKILL — nothing was removed." >&2
    echo "       a KeepAlive job may be respawning it; check: launchctl print $DOMAIN/$LABEL" >&2
    exit 1
fi

# --- 2./3. remove what the installer wrote ------------------------------------

echo "==> removing LaunchAgent"
if [ -e "$AGENT_PLIST" ]; then
    rm -f "$AGENT_PLIST"
    echo "    removed: $AGENT_PLIST"
else
    echo "    not present: $AGENT_PLIST"
fi

echo "==> removing app"
if [ -e "$INSTALLED_APP" ]; then
    rm -rf "$INSTALLED_APP"
    echo "    removed: $INSTALLED_APP"
else
    echo "    not present: $INSTALLED_APP"
fi

# --- 4. logs / config / state: kept, or purged --------------------------------

if [ "$PURGE" -eq 1 ]; then
    echo "==> --purge: removing logs, config and state"
    for dir in "$LOG_DIR" "$CONFIG_DIR" "$STATE_DIR"; do
        if [ -e "$dir" ]; then
            rm -rf "$dir"
            echo "    removed: $dir"
        else
            echo "    not present: $dir"
        fi
    done
else
    echo "==> keeping logs, config and state (pass --purge to remove them too)"
    for dir in "$LOG_DIR" "$CONFIG_DIR" "$STATE_DIR"; do
        if [ -e "$dir" ]; then
            echo "    kept:    $dir"
        else
            echo "    not present: $dir"
        fi
    done
fi

echo "==> NoPeek uninstalled — reinstall any time with: make install"
