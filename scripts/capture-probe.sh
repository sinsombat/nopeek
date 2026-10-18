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
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'
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

    Starting in 5s — get ready ...
EOF
sleep 5

STDERR_LOG="$(mktemp -t nopeek-probe)"
cleanup() { rm -f "$STDERR_LOG"; }
trap cleanup EXIT

echo "==> streaming (Ctrl-C stops early) ..."
/usr/bin/log stream --style ndjson --predicate "$PREDICATE" >"$OUTPUT" 2>"$STDERR_LOG" &
LOG_PID=$!

stop_stream() {
    kill -INT "$LOG_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$LOG_PID" 2>/dev/null || return 0
        sleep 0.2
    done
    kill -TERM "$LOG_PID" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$LOG_PID" 2>/dev/null || true
    return 0
}

INTERRUPTED=0
trap 'INTERRUPTED=1' INT
# Wait the requested duration in 0.2s slices so Ctrl-C is honoured promptly.
ticks=$((DURATION * 5))
for _ in $(seq 1 "$ticks"); do
    [ "$INTERRUPTED" -eq 0 ] || break
    sleep 0.2
done
trap - INT

stop_stream
wait "$LOG_PID" 2>/dev/null || true

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
