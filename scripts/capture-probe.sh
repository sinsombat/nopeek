#!/usr/bin/env bash
#
# NoPeek capture probe — record a real log stream while the user exercises the
# capture surfaces, to curate test fixtures from (spec §9 test data, plan T4).
#
# Usage:
#   scripts/capture-probe.sh [-d SECONDS] [-o OUTPUT] [-p PREDICATE_FILE]
#
#   -d SECONDS        capture duration (default 60)
#   -o OUTPUT         output file (default <repo>/probe-<timestamp>.ndjson)
#   -p PREDICATE_FILE predicate source (default scripts/log-predicate.txt)
#   -h                this help
#
# While it runs:
#   1. press ⌘⇧5 — open the screenshot toolbar, pause a beat, press Esc
#   2. press ⌃↑ (or F3) — open Mission Control, then close it; repeat 2-3x
#
# Ctrl-C stops the capture early: the `log stream` child is stopped, the
# summary still prints, and the script exits 130 (normal duration expiry
# exits 0). The cleanup also runs from an EXIT trap, so no code path can
# leave the stream orphaned.
#
# The output is a *candidate* fixture: curate a small representative subset
# into Tests/PWCoreTests/Fixtures/probe-<date>.ndjson (<200 KB) and leave the
# raw probe out of the repo (the root probe-*.ndjson pattern is gitignored).
#
# The predicate lives in scripts/log-predicate.txt so the shell and (later)
# the Swift LogStreamReader can be checked against one string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DURATION=60
OUTPUT=""
PREDICATE_FILE="$SCRIPT_DIR/log-predicate.txt"

usage() {
    sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" \
        | sed -e 's/^# \{0,1\}//' -e '/^set -euo pipefail$/d'
}

while getopts ":d:o:p:h" opt; do
    case "$opt" in
        d) DURATION="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        p) PREDICATE_FILE="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) echo "error: unknown option -$OPTARG" >&2; usage >&2; exit 2 ;;
        :)  echo "error: -$OPTARG requires a value" >&2; exit 2 ;;
    esac
done

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -eq 0 ]; then
    echo "error: -d takes a positive number of seconds, got '$DURATION'" >&2
    exit 2
fi
if [ ! -r "$PREDICATE_FILE" ]; then
    echo "error: predicate file not readable: $PREDICATE_FILE" >&2
    exit 2
fi

if [ -z "$OUTPUT" ]; then
    OUTPUT="$ROOT_DIR/probe-$(date +%Y-%m-%d-%H%M%S).ndjson"
fi
mkdir -p "$(dirname "$OUTPUT")"
if [ -e "$OUTPUT" ]; then
    echo "warning: overwriting $OUTPUT" >&2
fi

PREDICATE="$(cat "$PREDICATE_FILE")"

cat <<EOF
==> NoPeek capture probe
    predicate: $(basename "$PREDICATE_FILE")
    duration:  ${DURATION}s
    output:    $OUTPUT

    While the stream is running, please:
      1. ⌘⇧5  open the screenshot toolbar, pause, press Esc
      2. ⌃↑   open Mission Control, then close it (repeat 2-3 times)

    Ctrl-C stops early (the summary still prints).
    Starting in 5s — get ready ...
EOF

INTERRUPTED=0
trap 'INTERRUPTED=1' INT

# Countdown in 1s slices so an early Ctrl-C is seen within a second. The
# `|| true` matters: when the terminal delivers Ctrl-C to the whole process
# group, `sleep` is killed too and would otherwise trip `set -e` before the
# interrupt path below gets a chance to run.
for _ in 1 2 3 4 5; do
    [ "$INTERRUPTED" -eq 0 ] || break
    sleep 1 || true
done

STDERR_LOG="$(mktemp -t nopeek-probe)"
LOG_PID=""

stop_stream() {
    kill -INT "$LOG_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$LOG_PID" 2>/dev/null || return 0
        sleep 0.2 || true
    done
    kill -TERM "$LOG_PID" 2>/dev/null || true
    sleep 0.5 || true
    kill -KILL "$LOG_PID" 2>/dev/null || true
    return 0
}

# Belt and braces: whatever ends this script — normal end, errexit, a signal
# that still terminates it — the `log stream` child must not outlive it.
cleanup() {
    if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" 2>/dev/null; then
        stop_stream
        wait "$LOG_PID" 2>/dev/null || true
    fi
    rm -f "$STDERR_LOG"
}
trap cleanup EXIT

# Created up front so the summary can always report a count, even when the
# probe is interrupted while the countdown is still running.
: >"$OUTPUT"

if [ "$INTERRUPTED" -eq 0 ]; then
    echo "==> streaming (Ctrl-C stops early) ..."
    /usr/bin/log stream --style ndjson --predicate "$PREDICATE" >"$OUTPUT" 2>"$STDERR_LOG" &
    LOG_PID=$!

    # Wait the requested duration in 0.2s slices. A terminal Ctrl-C also kills
    # the `sleep` (same process group), so `|| true` is what lets the loop
    # re-check INTERRUPTED instead of tripping errexit and skipping the
    # stop_stream + summary below. A direct `kill -INT <script-pid>` leaves
    # the current `sleep` running to the end of its slice, then the loop
    # breaks the same way.
    for _ in $(seq 1 $((DURATION * 5))); do
        [ "$INTERRUPTED" -eq 0 ] || break
        sleep 0.2 || true
    done

    # From here on, cleanup is bounded and must not be cut short by a second
    # Ctrl-C while the child is being stopped.
    trap '' INT

    stop_stream
    wait "$LOG_PID" 2>/dev/null || true
else
    echo "==> interrupted during the countdown — no capture stream was started" >&2
fi

if [ -s "$STDERR_LOG" ]; then
    echo "--- log stream stderr ---" >&2
    cat "$STDERR_LOG" >&2
fi

LINES="$(wc -l <"$OUTPUT" | tr -d ' ')"
SIZE="$(du -h "$OUTPUT" | cut -f1)"
echo "==> wrote $LINES lines ($SIZE) to $OUTPUT"

echo "--- capture signals in this probe (line counts) ---"
for needle in updateScreenCaptureDidStart "SCDisplay init" SCContentFilter com.apple.ScreenCaptureKit WindowManager; do
    # Skip the non-JSON preamble line, which itself mentions several needles.
    count="$(tail -n +2 "$OUTPUT" | grep -c -- "$needle" || true)"
    printf '    %-32s %s\n' "$needle" "$count"
done

cat <<EOF

Next: curate a small representative subset (<200 KB) into
      Tests/PWCoreTests/Fixtures/probe-<date>.ndjson
      and keep the raw probe out of the repo.
EOF

if [ "$INTERRUPTED" -ne 0 ]; then
    echo "==> interrupted — capture ended early" >&2
    exit 130
fi
