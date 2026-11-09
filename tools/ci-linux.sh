#!/bin/bash
# The quick checks on Linux, as the CI runs them (.github/workflows/checks.yml):
# on Debian testing, which ships SuperCollider 3.14.1, as root in a container.
# It installs the packages megalooper's installer would ask for (as root there
# is no sudo for it to ask with), then runs the installer as a user would, and
# with it the quick checks: the unit tests, the start-up scripts and the AI
# apps' bridge.
#
#   tools/ci-linux.sh                  # VSTPlugin fetched, as by default
#   tools/ci-linux.sh --no-vstplugin   # without it, which megalooper runs with too
#
# The same run on a computer with Docker, the checkout copied in so nothing
# of it changes:
#
#   docker run --rm -v "$PWD":/src:ro debian:testing \
#       bash -c 'cp -a /src /megalooper && /megalooper/tools/ci-linux.sh'
#
# The checks' logs are left in /tmp/megalooper-checks.*; the workflow keeps
# them when one fails.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT_SC="3.14.1"
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

echo "ci: installing SuperCollider, sc3-plugins and the tools around them"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    supercollider sc3-plugins git python3 curl ca-certificates nodejs zip unzip >/dev/null

# 3.13 miscompiles a var inside nested inlined ifs; megalooper is built on
# 3.14.1. When Debian moves on, this says so rather than test another one.
have="$(sclang -v 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [ "$have" != "$WANT_SC" ]; then
    echo "ci: this image's SuperCollider is ${have:-missing}, not $WANT_SC: the job needs another image." >&2
    exit 1
fi
echo "ci: SuperCollider $have"

exec "$REPO/tools/install.sh" --yes --no-app "$@"
