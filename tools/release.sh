#!/bin/bash
# Release megalooper: the new version written everywhere it is read, every
# check run, and only when they all pass the release commit, its tag and the
# Claude Desktop extension. Nothing leaves this Mac unless --publish is given.
#
#   ./tools/release.sh 1.14 --dry-run     # say what it would do, change nothing
#   ./tools/release.sh 1.14               # prepare the release here
#   ./tools/release.sh 1.14 --notes notes.md --publish
#                                         # and push it and make the GitHub release
#
# Preparing:
#   1. refuses unless this checkout is on main with nothing uncommitted, the
#      version is after VERSION's, and there is no tag for it yet;
#   2. writes the version and the next build number into VERSION, and the
#      version into the extension's manifest (tools/mcpb/manifest.json), the
#      bridges' tool list (tools/mcp-tools.json) and the install lines, which
#      clone the release's tag (README.md, docs/linux.md, the website);
#   3. runs every check (tools/run-checks.sh, about ten minutes). If one
#      fails the release is refused, and those files go back as they were. A
#      check skipped for material this Mac lacks (the kits' samples) does not
#      count;
#   4. commits them as "megalooper 1.14" and tags the commit v1.14;
#   5. builds the extension, megalooper.mcpb, into --out (this folder).
#
# Publishing (--publish, after those, asking first unless --yes): pushes main
# and the tag to origin and makes the GitHub release, titled "megalooper
# 1.14", with the notes file and the extension attached, as the latest (gh).
#
# Run it yourself, in a terminal: the checks open no audio device, but some
# of them load your plugins, which only your own login can read.
#
# For its own tests: MEGALOOPER_RELEASE_CHECKS is the command run instead of
# tools/run-checks.sh, and MEGALOOPER_RELEASE_BRANCH the branch released from.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${MEGALOOPER_RELEASE_BRANCH:-main}"
CHECKS_CMD="${MEGALOOPER_RELEASE_CHECKS:-$REPO/tools/run-checks.sh}"
# Where each is written. The install lines: every line that clones megalooper.
VERSION_FILES="VERSION tools/mcpb/manifest.json tools/mcp-tools.json"
CLONE_FILES="README.md docs/linux.md site/src/pages/index.astro"

NEW=""; NOTES=""; OUT="$PWD"; PUBLISH=0; YES=0; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="${2:-}"; shift ;;
        --out) OUT="${2:-}"; shift ;;
        --publish) PUBLISH=1 ;;
        --yes) YES=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "release: unknown option '$1' (try --help)." >&2; exit 2 ;;
        *) if [ -z "$NEW" ]; then NEW="$1"; else echo "release: one version, not '$1' too." >&2; exit 2; fi ;;
    esac
    shift
done

say()  { echo "release: $*"; }
fail() { echo "release: refused: $*" >&2; exit 1; }

cd "$REPO" || exit 1
[ -n "$NEW" ] || fail "which version? ./tools/release.sh 1.14 (--help says more)."
echo "$NEW" | grep -Eq '^[0-9]+\.[0-9]+$' || fail "a version is major.minor, like 1.14, not '$NEW'."
if [ "$PUBLISH" -eq 1 ]; then
    [ -n "$NOTES" ] && [ -f "$NOTES" ] || fail "--publish needs --notes with the release notes' file."
    command -v gh >/dev/null 2>&1 || fail "--publish needs GitHub's gh, which is not here."
fi
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[ -d "$OUT" ] || fail "--out $OUT is no folder."

# ---- 1. where it is released from ------------------------------------------
OLD="$(awk '$1 == "version" { print $2 }' VERSION 2>/dev/null)"
OLD_BUILD="$(awk '$1 == "build" { print $2 }' VERSION 2>/dev/null)"
[ -n "$OLD" ] && [ -n "$OLD_BUILD" ] || fail "VERSION does not say the version and the build."
BUILD=$((OLD_BUILD + 1))
on="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$on" = "$BRANCH" ] || fail "this checkout is on '${on:-no branch}', not $BRANCH."
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "there are uncommitted changes: commit them, or set them aside, first."
newest="$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -t. -k1,1n -k2,2n | tail -1)"
[ "$NEW" != "$OLD" ] && [ "$newest" = "$NEW" ] || fail "$NEW is not after $OLD, VERSION's."
git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null && fail "there is a tag v$NEW already."
say "megalooper $OLD (build $OLD_BUILD) -> $NEW (build $BUILD), from $BRANCH at $(git rev-parse --short HEAD)."

if [ "$DRY" -eq 1 ]; then
    say "would write $NEW into $VERSION_FILES, and v$NEW into the install lines of $CLONE_FILES;"
    say "would run $CHECKS_CMD, and on a failure put those files back and stop;"
    say "would commit \"megalooper $NEW\", tag it v$NEW, and build $OUT/megalooper.mcpb."
    [ "$PUBLISH" -eq 1 ] && say "would then push $BRANCH and v$NEW to origin and make the GitHub release with $NOTES."
    exit 0
fi

# ---- 2. the version, everywhere -----------------------------------------------
restore() { git checkout -- $VERSION_FILES $CLONE_FILES; }
perl -pi -e "s/^version .*/version $NEW/; s/^build .*/build $BUILD/" VERSION
# The first "version" in the manifest is its own (the format's is
# manifest_version); the tool list's is serverVersion.
perl -pi -e "\$d ||= s/^(\\s*\"version\":\\s*\")[^\"]*\"/\${1}$NEW.0\"/" tools/mcpb/manifest.json
perl -pi -e "s/^(\\s*\"serverVersion\":\\s*\")[^\"]*\"/\${1}$NEW.0\"/" tools/mcp-tools.json
perl -pi -e "s/--branch v[0-9]+\\.[0-9]+/--branch v$NEW/ if /git clone/" $CLONE_FILES
changed="$(git diff --name-only -- $VERSION_FILES $CLONE_FILES | wc -l | tr -d ' ')"
expected=$(( $(echo $VERSION_FILES $CLONE_FILES | wc -w) ))
if [ "$changed" -ne "$expected" ]; then
    restore
    fail "only $changed of the $expected files took the version; each is put back. Is one's line no longer where this looks?"
fi
say "wrote $NEW into $VERSION_FILES $CLONE_FILES."

# ---- 3. every check --------------------------------------------------------------
say "running the checks ($CHECKS_CMD). They take a while."
if ! "$CHECKS_CMD"; then
    restore
    fail "a check failed (its log is named above). The version files are as they were; nothing was committed."
fi

# ---- 4. the commit and the tag -----------------------------------------------------
git commit -q -m "megalooper $NEW" -- $VERSION_FILES $CLONE_FILES || { restore; fail "git did not commit."; }
git tag "v$NEW" || fail "git did not tag the commit (it stands: tag it v$NEW by hand)."
say "committed $(git rev-parse --short HEAD) \"megalooper $NEW\", tagged v$NEW."

# ---- 5. the extension ----------------------------------------------------------------
MCPB="$OUT/megalooper.mcpb"
"$REPO/tools/make-mcpb.sh" "$MCPB" >/dev/null || fail "the extension was not built (tools/make-mcpb.sh); the commit and tag stand."
say "built $MCPB."

if [ "$PUBLISH" -eq 0 ]; then
    say "ready, here only. To publish it:"
    say "  git push origin $BRANCH v$NEW"
    say "  gh release create v$NEW --title \"megalooper $NEW\" --notes-file <notes> --latest \"$MCPB\""
    exit 0
fi

# ---- publishing ----------------------------------------------------------------------
if [ "$YES" -eq 0 ]; then
    printf "release: push %s and v%s to origin and make the GitHub release now? [y/N] " "$BRANCH" "$NEW"
    read -r answer
    case "$answer" in y|Y|yes|Yes) ;; *) say "not published. The commit, the tag and $MCPB stand."; exit 0 ;; esac
fi
git push origin "$BRANCH" "v$NEW" || fail "the push failed; nothing was released on GitHub."
gh release create "v$NEW" --title "megalooper $NEW" --notes-file "$NOTES" --latest "$MCPB" \
    || fail "the GitHub release was not made (the push went through): gh release create v$NEW by hand."
say "released megalooper $NEW."
