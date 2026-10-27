#!/bin/bash
# Run megalooper's offline checks, one sclang at a time, and say which passed.
#
#   ./tools/run-checks.sh          # all twenty-six, about six minutes
#   ./tools/run-checks.sh quick    # the unit tests, the static check and the AI bridge's
#
# Nothing here opens an audio device or touches MIDI, and megalooper may be
# running beside it: each sclang gets a UDP port far from megalooper's, and
# the renders run on an offline server (scsynth -N). The pane checks build
# their windows without showing them, so they need a logged-in Mac, not a
# bare ssh session.
#
# The checks run against the classes SuperCollider compiles, so the classes/
# folder of THIS checkout must be the one linked into Extensions (README.md,
# "Install"). With a second checkout, point MEGALOOPER_SCLANG_CONF at an sclang
# configuration file (sclang -l) that includes its classes instead. Each check
# gets seven minutes; one that is killed by the clock counts as failed. The
# exit code is the number of checks that failed.
#
# Five of them play material the repository cannot ship: the kits' samples
# and the reverb's impulse responses (exported from Ableton Live's library,
# docs/drums.md) and one recorded take. Where it is missing they are skipped,
# saying what they need, and do not count as failed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCLANG=""
for candidate in \
    "/Applications/SuperCollider.app/Contents/MacOS/sclang" \
    "$HOME/Applications/SuperCollider.app/Contents/MacOS/sclang" \
    "$(command -v sclang 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then SCLANG="$candidate"; break; fi
done
if [ -z "$SCLANG" ]; then
    echo "error: sclang not found. Install SuperCollider, or put sclang on PATH." >&2
    exit 99
fi

QUICK="scripts/tests/run-tests.scd scripts/check.scd tools/test-megalooper-mcp.py"
PANES="scripts/check-gui-ai.scd scripts/check-gui-audio.scd scripts/check-gui-effects.scd scripts/check-gui-maptags.scd scripts/check-gui-drums.scd scripts/check-gui-synth.scd scripts/check-gui-midimap.scd"
RENDERS="scripts/sa/nrt-chains.scd scripts/sa/nrt-drums.scd scripts/sa/nrt-session.scd scripts/sa/nrt-drum-voices.scd scripts/sa/nrt-drums-fx.scd scripts/sa/nrt-plugin-scan.scd scripts/sa/nrt-pitchloop.scd scripts/sa/nrt-drumchain.scd scripts/sa/nrt-shifter.scd scripts/sa/nrt-noteseq.scd scripts/sa/nrt-wave.scd scripts/sa/nrt-instrument.scd scripts/sa/nrt-engine-rate.scd scripts/sa/nrt-utility.scd scripts/sa/nrt-texture.scd scripts/sa/nrt-space.scd"

case "${1:-all}" in
    quick) CHECKS="$QUICK" ;;
    all)   CHECKS="$QUICK $PANES $RENDERS" ;;
    *)     echo "usage: $0 [quick]" >&2; exit 98 ;;
esac

KITS="$REPO/presets/sa/drums/kits"
TAKE="$REPO/sessions/260929_100616-tap.wav"
have_kits() {
    ls "$KITS/carbon-layer/"*.wav "$KITS/one-hit/"*.wav "$KITS/_ir/"*.wav >/dev/null 2>&1
}
have_take() { [ -f "$TAKE" ]; }
# What a check lacks here, in words, or nothing.
lacks() {
    case "$1" in
        test-megalooper-mcp) command -v python3 >/dev/null 2>&1 || echo "python3" ;;
        check-gui-maptags|check-gui-drums) have_kits || echo "the kits' samples" ;;
        nrt-chains) have_take || echo "the recorded take" ;;
        nrt-drums|nrt-session)
            if ! have_kits && ! have_take; then echo "the kits' samples and the recorded take"
            elif ! have_kits; then echo "the kits' samples"
            elif ! have_take; then echo "the recorded take"; fi ;;
    esac
}

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/megalooper-checks.XXXXXX")"
failed=0
skipped=0
for check in $CHECKS; do
    name="$(basename "$check")"; name="${name%.*}"
    why="$(lacks "$name")"
    if [ -n "$why" ]; then
        skipped=$((skipped + 1))
        echo "skipped $name  (needs $why)"
        continue
    fi
    port=$((58100 + RANDOM % 800))
    start=$(date +%s)
    case "$check" in
        # The AI bridge's own check, which starts its sclang itself.
        *.py) perl -e 'alarm shift; exec @ARGV' 420 python3 "$REPO/$check" > "$LOGS/$name.log" 2>&1 ;;
        *) perl -e 'alarm shift; exec @ARGV' 420 "$SCLANG" -u "$port" ${MEGALOOPER_SCLANG_CONF:+-l "$MEGALOOPER_SCLANG_CONF"} \
            "$REPO/$check" > "$LOGS/$name.log" 2>&1 ;;
    esac
    code=$?
    secs=$(( $(date +%s) - start ))
    if [ "$code" -eq 0 ]; then
        echo "ok      $name  (${secs} s)"
    else
        failed=$((failed + 1))
        if [ "$code" -eq 142 ]; then why="no answer in 7 minutes"; else why="exit $code"; fi
        echo "FAILED  $name  (${secs} s, $why): $LOGS/$name.log"
    fi
done

if [ "$failed" -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then echo "ALL CHECKS PASSED ($skipped skipped: they need material only the author has)"
    else echo "ALL CHECKS PASSED"; fi
    rm -f "$LOGS"/*.log
    rmdir "$LOGS"
else
    echo "$failed FAILED. Logs are in $LOGS"
fi
exit "$failed"
