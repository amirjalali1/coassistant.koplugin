#!/bin/sh
# Headless scenarios (docs/test_automation_plan.md, layer 2): KOReader's own
# frontend with no window, in a NEW run folder per run, on the mock books.
#
#   sh tests/scenarios/run.sh [base folder] [scenario ...]
#
# base folder: where the run folder is made (default: $TMPDIR/koa_scenarios).
# scenario: a file name in tests/scenarios without .lua (default: all s*.lua),
# or the path of a scenario file elsewhere (a one-off probe in a scratch folder).
# Each run: <base>/run-<time>-<pid>/ with home/ (a fresh KOReader home, this
# plugin linked into its plugins/), Books/ (the fixture, groups written into
# the home), shots/ (screenshots) and one log per scenario. Nothing is
# deleted, nothing of a real KOReader home is read, and boot.lua blocks the
# network and keeps apikeys.lua out. Exit code: the number of failed scenarios.
# KOA_BOOKS=<folder>: that folder is COPIED into Books/ too (read only at its
# source); the wiki shots use it (wiki_shots.sh, which also sets KOA_SCREEN).

TREE="$(cd "$(dirname "$0")/../.." && pwd)"
APP="/Applications/KOReader.app/Contents/koreader"
BASE="${1:-${TMPDIR:-/tmp}/koa_scenarios}"
[ $# -gt 0 ] && shift
if [ ! -x "$APP/luajit" ]; then
    echo "KOReader not found at $APP"
    exit 2
fi

RUN="$BASE/run-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUN/home/plugins" "$RUN/home/settings" "$RUN/Books" || exit 2
ln -s "$TREE" "$RUN/home/plugins/koassistant.koplugin" || exit 2

if ! (cd "$TREE" && lua tests/fixtures/mock_series/gen.lua --out "$RUN/Books" --home "$RUN/home") \
        > "$RUN/gen.log" 2>&1; then
    echo "fixture generation failed, see $RUN/gen.log"
    exit 2
fi

if [ -n "$KOA_BOOKS" ]; then
    if [ ! -d "$KOA_BOOKS" ]; then
        echo "KOA_BOOKS is not a folder: $KOA_BOOKS"
        exit 2
    fi
    cp -R "${KOA_BOOKS%/}" "$RUN/Books/" || exit 2
fi

if [ $# -eq 0 ]; then
    set -- $(cd "$TREE/tests/scenarios" && ls s*.lua | sed 's/\.lua$//')
fi

echo "run folder: $RUN"
failed=0
for s in "$@"; do
    case "$s" in
        */*|*.lua) file="$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"; s="$(basename "$s" .lua)" ;;
        *) file="$TREE/tests/scenarios/$s.lua" ;;
    esac
    echo "== $s"
    (cd "$APP" && KO_HOME="$RUN/home" KOA_RUN="$RUN" KOA_PLUGIN="$TREE" \
        ./luajit "$file") > "$RUN/$s.log" 2>&1
    code=$?
    grep -E '^  (PASS|FAIL)|^    |: [0-9]+ passed' "$RUN/$s.log"
    if [ $code -ne 0 ]; then
        failed=$((failed + 1))
        echo "   exit $code (full log: $RUN/$s.log)"
    fi
done
echo "scenarios failed: $failed"
exit $failed
