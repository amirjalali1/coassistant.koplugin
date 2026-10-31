#!/bin/sh
# Wiki screenshots: the w_*.lua scenarios on a Kobo Clara's screen (1072x1448,
# 300 dpi, grayscale), the emoji font registered when the desktop has it, the
# shots books copied in from the folder KOA_BOOKS names (none without it). Each
# scenario runs through run.sh in a run of its own (a fresh home, so one
# scenario's settings never reach the next; nothing of a real KOReader home
# read, no network). Then: which names of docs/assets/wiki_shotlist.txt were
# produced and which were not, and the produced PNGs copied into
# docs/assets/screenshots-src/wiki/ for review.
#
#   KOA_BOOKS=/path/to/shots/books sh tests/scenarios/wiki_shots.sh <scratch base> [w_scenario ...]
#
# Exit code: the number of scenarios that failed.

TREE="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${1:?usage: wiki_shots.sh <scratch base> [w_scenario ...]}"
shift
if [ $# -eq 0 ]; then
    set -- $(cd "$TREE/tests/scenarios" && ls w_*.lua | sed 's/\.lua$//')
fi
BOOKS="${KOA_BOOKS:-}"
if [ -n "$BOOKS" ] && [ ! -d "$BOOKS" ]; then
    echo "KOA_BOOKS is not a folder: $BOOKS"
    exit 2
fi
[ -z "$BOOKS" ] && echo "KOA_BOOKS unset: no shots books, the pages that need them are partial"
mkdir -p "$BASE" || exit 2

LOG="$BASE/wiki_shots_last.log"
: > "$LOG"
runs=""
failed=0
for s in "$@"; do
    out=$(KOA_SCREEN="${KOA_SCREEN:-1072x1448}" EMULATE_READER_DPI="${EMULATE_READER_DPI:-300}" KOA_EMOJI=1 \
        KOA_BOOKS="$BOOKS" sh "$TREE/tests/scenarios/run.sh" "$BASE" "$s" 2>&1)
    code=$?
    printf '%s\n' "$out" | tee -a "$LOG"
    [ $code -ne 0 ] && failed=$((failed + 1))
    run=$(printf "%s\n" "$out" | LC_ALL=C sed -n "s/^run folder: //p" | tail -1)
    [ -n "$run" ] && runs="$runs $run"
done

MANIFEST="$TREE/docs/assets/wiki_shotlist.txt"
OUT="$TREE/docs/assets/screenshots-src/wiki"
mkdir -p "$OUT"
made=0
total=0
missing=""
if [ -f "$MANIFEST" ]; then
    for name in $(grep -v '^[[:space:]]*#' "$MANIFEST" | sed -n 's/^[[:space:]]*\([^|[:space:]][^|]*[^|[:space:]]\)[[:space:]]*|.*/\1/p'); do
        total=$((total + 1))
        found=""
        for run in $runs; do
            [ -f "$run/wiki/$name" ] && found="$run/wiki/$name"
        done
        if [ -n "$found" ]; then
            made=$((made + 1))
            cp "$found" "$OUT/$name"
        else
            missing="$missing $name"
        fi
    done
fi
for run in $runs; do
    for f in "$run"/wiki/*.png; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        if [ -f "$MANIFEST" ] && ! grep -q "^[[:space:]]*$name[[:space:]]*|" "$MANIFEST"; then
            echo "not in the manifest (left in $run/wiki): $name"
        fi
    done
done
echo "scenarios failed: $failed"
echo "manifest shots produced: $made of $total (copied to docs/assets/screenshots-src/wiki/)"
[ -n "$missing" ] && echo "not produced:$missing"
exit $failed
