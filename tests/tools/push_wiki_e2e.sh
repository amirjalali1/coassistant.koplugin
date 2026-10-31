#!/bin/sh
# Runs scripts/push_wiki.sh end to end against a scratch bare repository, never
# the real wiki: a dry run, a push, the idempotent re-run, the refusal of edits
# made on the wiki (then --accept-edits over them, which also removes a page the
# wiki gained), the refusal of local changes in the clone, an unknown option.
# The scratch remote is seeded from the maintainer's wiki clone (docs/wiki,
# when present), so the first push replays what the real one would do;
# otherwise from a single Home page.
#   sh tests/tools/push_wiki_e2e.sh [scratch-dir]   (absent or empty; kept afterwards)
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
S=${1:-$(mktemp -d "${TMPDIR:-/tmp}/koa_wiki_e2e.XXXXXX")}
if [ -e "$S" ] && [ -n "$(ls -A "$S")" ]; then
    echo "scratch dir must be absent or empty: $S" >&2
    exit 2
fi
mkdir -p "$S"
case $S in /*) ;; *) S=$(pwd)/$S ;; esac
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
push="$root/scripts/push_wiki.sh"
before=$(git -C "$root/docs/wiki" status --porcelain 2>/dev/null || echo "(no clone)")

if [ -d "$root/docs/wiki/.git" ]; then
    git clone -q --bare "$root/docs/wiki" "$S/remote.git"
else
    git -c init.defaultBranch=master init -q --bare "$S/remote.git"
    git clone -q "$S/remote.git" "$S/seed" 2>/dev/null
    printf '# Home\n\nseed\n' > "$S/seed/Home.md"
    git -C "$S/seed" add -A
    git -C "$S/seed" -c user.name=seed -c user.email=seed@example.com commit -qm "Created Home (markdown)"
    git -C "$S/seed" push -q origin master
fi
export KOA_WIKI_CLONE="$S/clone" KOA_WIKI_REMOTE="$S/remote.git"

echo "1. dry run on a fresh clone"
"$push" v0.0.0-e2e --dry-run > "$S/out" 2>&1 || fail "dry run exited $?"
[ -z "$(git -C "$S/clone" status --porcelain)" ] || fail "the clone is not clean after the dry run"
grep -q "dry run: nothing committed or pushed" "$S/out" || fail "dry run did not say so"

echo "2. push"
"$push" v0.0.0-e2e > "$S/out" 2>&1 || fail "push exited $?"
git -C "$S/remote.git" log --format='%s|%b' -n 1 | grep -q '^docs for v0.0.0-e2e|koa-wiki-sync: main ' || fail "the sync commit's subject or trailer"
for f in Home.md _Footer.md; do
    git -C "$S/remote.git" show "HEAD:$f" | grep -q '<!-- koa-version -->v0.0.0-e2e<!-- /koa-version -->' || fail "$f not stamped"
done
git -C "$S/remote.git" ls-tree --name-only HEAD | sort > "$S/remote.lst"
ls "$root/wiki" | sort > "$S/local.lst"
cmp -s "$S/remote.lst" "$S/local.lst" || { fail "the wiki's file set differs from wiki/"; diff "$S/remote.lst" "$S/local.lst"; }

echo "3. re-run: nothing to push"
"$push" v0.0.0-e2e > "$S/out" 2>&1 || fail "re-run exited $?"
grep -q "already matches" "$S/out" || fail "re-run did not say the wiki already matches"

echo "4. an edit and a page made on the wiki: refusal"
git clone -q "$S/remote.git" "$S/other"
echo "a line added on GitHub" >> "$S/other/Home.md"
printf '# Scratch Page\n\nmade on GitHub\n' > "$S/other/Scratch-Page.md"
git -C "$S/other" add -A
git -C "$S/other" -c user.name=web -c user.email=web@example.com commit -qm "Updated Home (markdown)"
git -C "$S/other" push -q origin master
if "$push" v0.0.1-e2e > "$S/out" 2>&1; then fail "did not refuse the wiki's own edit"; fi
grep -q "Updated Home (markdown)" "$S/out" || fail "the refusal does not name the foreign commit"

echo "5. --accept-edits: wiki/ wins, the page made on the wiki goes"
"$push" v0.0.1-e2e --accept-edits > "$S/out" 2>&1 || fail "--accept-edits exited $?"
git -C "$S/remote.git" show HEAD:Home.md | grep -q "a line added on GitHub" && fail "the wiki's edit survived the push"
git -C "$S/remote.git" ls-tree --name-only HEAD | grep -q Scratch-Page && fail "Scratch-Page.md survived the push"

echo "6. the run after an accepted edit needs no flag"
"$push" v0.0.1-e2e > "$S/out" 2>&1 || fail "run after accept exited $?"
grep -q "already matches" "$S/out" || fail "run after accept did not say the wiki already matches"

echo "7. local changes in the clone: refusal"
echo x >> "$S/clone/Home.md"
if "$push" v0.0.2-e2e > "$S/out" 2>&1; then fail "did not refuse local changes"; fi
git -C "$S/clone" checkout -q -- Home.md

echo "8. an unknown option: refusal"
if "$push" v0.0.2-e2e --bogus > "$S/out" 2>&1; then fail "accepted an unknown option"; fi

echo "9. the real clone is untouched"
after=$(git -C "$root/docs/wiki" status --porcelain 2>/dev/null || echo "(no clone)")
[ "$before" = "$after" ] || fail "docs/wiki changed"

if [ "$fails" -eq 0 ]; then
    echo "push_wiki e2e: all checks passed ($S)"
else
    echo "push_wiki e2e: $fails failure(s) ($S)" >&2
    exit 1
fi
