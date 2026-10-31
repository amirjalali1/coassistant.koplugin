#!/bin/sh
# Wiki gap check: the running release-notes draft's bullets against wiki/.
# Every bullet ends with "<!-- wiki: Page-A Page-B -->" (or "<!-- wiki: none -->");
# every page a tag names exists in wiki/ and has changed since the last v* tag
# (the edit the bullet promises was made). Pages changed since the tag that no
# bullet names are listed for information (truth-pass fixes are fine).
# Usage: tests/tools/wiki_gap.sh [docs/release_notes_vX.Y.Z.md]
set -eu
cd "$(dirname "$0")/../.."
draft=${1:-$(ls docs/release_notes_v*.md | sort -V | tail -n 1)}
tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*')
problems=0
named=""
# bullets are the lines starting with "- ", up to the standing "How You Can Help" section
# or an earlier release's notes appended below (a point release: "## vX Release Notes")
awk '/^## How You Can Help/{exit} /^## v[0-9][^ ]* Release Notes/{exit} /^- /{print NR":"$0}' "$draft" | while IFS= read -r line; do
    n=${line%%:*}
    text=${line#*:}
    case "$text" in
        *'<!-- wiki:'*'-->'*) ;;
        *) echo "  no wiki tag: line $n: $(printf '%s' "$text" | cut -c1-90)"; echo "PROBLEM" >> "$draft.wikigap.tmp" ;;
    esac
done
if [ -f "$draft.wikigap.tmp" ]; then problems=$(wc -l < "$draft.wikigap.tmp" | tr -d ' '); rm -f "$draft.wikigap.tmp"; fi
named=$(sed -n 's/.*<!-- wiki:\(.*\)-->.*/\1/p' "$draft" | tr ' ' '\n' | grep -v '^$' | grep -v '^none$' | sort -u)
for page in $named; do
    if [ ! -f "wiki/$page.md" ]; then
        echo "  named page does not exist: $page"; problems=$((problems + 1))
    elif git diff --quiet "$tag" -- "wiki/$page.md" 2>/dev/null && git ls-tree -r --name-only "$tag" -- "wiki/$page.md" | grep -q .; then
        echo "  named but unchanged since $tag: $page"; problems=$((problems + 1))
    fi
done
changed=$(git diff --name-only "$tag" -- wiki/ 2>/dev/null | sed -n 's#^wiki/\(.*\)\.md$#\1#p')
for page in $changed; do
    case " $(printf '%s ' $named) " in
        *" $page "*) ;;
        *) case "$page" in _Sidebar|_Footer|Home|Settings-Reference) ;; *) echo "  changed since $tag, named by no bullet (information): $page" ;; esac ;;
    esac
done
echo "$draft: $problems wiki gap(s) since $tag"
[ "$problems" -eq 0 ]
