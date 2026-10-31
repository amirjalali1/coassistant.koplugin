#!/bin/sh
# Publishes wiki/ to the GitHub wiki (the recipe runs it after the release).
#   scripts/push_wiki.sh vX.Y.Z [--dry-run] [--accept-edits]
# The wiki clone is docs/wiki/ (cloned from the wiki remote if absent). The
# script refuses to run over a clone with local changes, and refuses when the
# wiki has commits it did not make (edits made on GitHub): merge those into
# wiki/ by hand first, then run again with --accept-edits. Every page is
# copied, pages that no longer exist in wiki/ are removed, Home and the footer
# are stamped with the version, the commit is "docs for vX" and is pushed,
# unless --dry-run.
set -eu
version=${1:?usage: scripts/push_wiki.sh vX.Y.Z [--dry-run] [--accept-edits]}
shift
dry=""
accept=""
for arg in "$@"; do
    case $arg in
        --dry-run) dry=1 ;;
        --accept-edits) accept=1 ;;
        *) echo "unknown option: $arg (usage: scripts/push_wiki.sh vX.Y.Z [--dry-run] [--accept-edits])" >&2; exit 2 ;;
    esac
done
root=$(cd "$(dirname "$0")/.." && pwd)
# KOA_WIKI_CLONE and KOA_WIKI_REMOTE exist for trying the script against a local bare repository
clone="${KOA_WIKI_CLONE:-$root/docs/wiki}"
remote="${KOA_WIKI_REMOTE:-https://github.com/zeeyado/koassistant.koplugin.wiki.git}"
marker="koa-wiki-sync"

if [ ! -d "$clone/.git" ]; then
    git clone "$remote" "$clone"
fi
if [ -n "$(git -C "$clone" status --porcelain)" ]; then
    echo "the wiki clone has local changes; commit, stash or discard them first: $clone" >&2
    exit 1
fi
git -C "$clone" fetch origin
branch=$(git -C "$clone" rev-parse --abbrev-ref HEAD)
git -C "$clone" reset -q --hard "origin/$branch"

# commits on the wiki since the last one this script made, that it did not make
last=$(git -C "$clone" log --format=%H --grep="$marker" -n 1 || true)
if [ -n "$last" ]; then
    foreign=$(git -C "$clone" log --format='%h %s' "$last..HEAD" | grep -v "$marker" || true)
else
    foreign=""
fi
if [ -n "$foreign" ] && [ -z "$accept" ]; then
    echo "the wiki has edits made on GitHub since the last sync; merge them into wiki/ first, then run again with --accept-edits:" >&2
    echo "$foreign" >&2
    exit 1
fi

# copy every page; remove pages that no longer exist in wiki/
for f in "$clone"/*.md; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    [ -e "$root/wiki/$name" ] || rm -f "$f"
done
cp "$root"/wiki/*.md "$clone"/
# stamp the version (no sed -i: its syntax differs between BSD and GNU sed)
for f in "$clone/Home.md" "$clone/_Footer.md"; do
    [ -e "$f" ] || continue
    sed "s#<!-- koa-version -->.*<!-- /koa-version -->#<!-- koa-version -->$version<!-- /koa-version -->#" "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
done
if [ -n "$dry" ]; then
    git -C "$clone" status --short
    git -C "$clone" diff --stat
    git -C "$clone" checkout -q -- . 2>/dev/null || true
    git -C "$clone" clean -q -fd
    echo "dry run: nothing committed or pushed"
    exit 0
fi
git -C "$clone" add -A
if git -C "$clone" diff --cached --quiet; then
    echo "the wiki already matches wiki/; nothing to push"
    exit 0
fi
sha=$(git -C "$root" rev-parse --short HEAD)
git -C "$clone" commit -q -m "docs for $version" -m "$marker: main $sha"
git -C "$clone" push origin "$branch"
echo "pushed $version to the wiki"
