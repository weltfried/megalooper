#!/bin/bash
# The Claude Desktop extension: megalooper.mcpb, a zip with the manifest and
# the icon at its root and the Node bridge with its tool list in server/
# (docs/ai.md). Claude Desktop runs the bridge with its own Node, so the
# extension needs nothing installed.
#
#   ./tools/make-mcpb.sh                 # megalooper.mcpb in this folder
#   ./tools/make-mcpb.sh /some/x.mcpb    # or there
#
# Needs only zip. The Setup view's "Install in Claude Desktop" runs this and
# opens what it made; a release attaches it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/megalooper.mcpb}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

if ! command -v zip >/dev/null 2>&1; then
    echo "error: zip is needed to make the extension, and is not here." >&2
    exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/megalooper-mcpb.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/server" "$(dirname "$OUT")"
cp "$REPO/tools/mcpb/manifest.json" "$REPO/tools/mcpb/icon.png" "$STAGE/"
cp "$REPO/tools/mcpb/server/index.js" "$REPO/tools/mcp-tools.json" "$STAGE/server/"
rm -f "$OUT"
(cd "$STAGE" && zip -q -X -r "$OUT" manifest.json icon.png server)
echo "$OUT"
