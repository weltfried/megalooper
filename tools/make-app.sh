#!/bin/bash
# Build megalooper.app — a double-clickable Desktop icon that opens the rig
# picker (scripts/launcher.scd) and boots the looper.
#
#   ./tools/make-app.sh                 # build onto ~/Desktop
#   ./tools/make-app.sh /Applications   # build somewhere else
#
# The bundle is a thin wrapper: it execs sclang on scripts/launcher.scd with
# this repo's absolute path baked in. Nothing is copied, so edits to the scripts
# take effect on the next launch with no rebuild. MOVING THE REPO breaks the
# bundle — re-run this script after a move.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$HOME/Desktop}"
APP="$DEST/megalooper.app"

# sclang is the only hard dependency. Prefer the standard install, but accept
# one already on PATH so a Homebrew or custom build works too.
SCLANG=""
for candidate in \
    "/Applications/SuperCollider.app/Contents/MacOS/sclang" \
    "$HOME/Applications/SuperCollider.app/Contents/MacOS/sclang" \
    "$(command -v sclang 2>/dev/null || true)"
do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then SCLANG="$candidate"; break; fi
done
if [ -z "$SCLANG" ]; then
    echo "error: sclang not found." >&2
    echo "       Install SuperCollider, or put sclang on PATH, then re-run." >&2
    exit 1
fi

if [ ! -d "$DEST" ]; then
    echo "error: destination '$DEST' does not exist." >&2
    exit 1
fi

echo "repo   : $REPO"
echo "sclang : $SCLANG"
echo "target : $APP"

# ---- icon ----------------------------------------------------------------
# iconutil wants a .iconset of exact sizes. Render each one from scratch rather
# than downscaling a single master: the Möbius loop is drawn from geometry, so a
# 32 px render is sharper than a 32 px resample of 1024.
ICONSET="$(mktemp -d)/megalooper.iconset"
mkdir -p "$ICONSET"
echo "icon   : rendering…"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"
    name="${spec##*:}"
    python3 "$REPO/tools/make-icon.py" "$ICONSET/icon_$name.png" "$px" >/dev/null
done
ICNS="$(mktemp -d)/megalooper.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

# ---- bundle --------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ICNS" "$APP/Contents/Resources/megalooper.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>megalooper</string>
    <key>CFBundleDisplayName</key>       <string>megalooper</string>
    <key>CFBundleIdentifier</key>        <string>net.megalooper.launcher</string>
    <key>CFBundleExecutable</key>        <string>megalooper</string>
    <key>CFBundleIconFile</key>          <string>megalooper</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3</string>
    <key>CFBundleVersion</key>           <string>4</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- The looper records a guitar. Without a usage string macOS terminates a
         process that touches an input device rather than prompting for it. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>megalooper records audio from your interface to build loops.</string>
</dict>
</plist>
PLIST

# The launcher itself. Output goes to a log file because a Finder-launched app
# has no terminal and sclang's post window does not exist outside the IDE — the
# log is the only place a boot failure can be read afterwards.
cat > "$APP/Contents/MacOS/megalooper" <<LAUNCH
#!/bin/bash
SCLANG="$SCLANG"
SCRIPT="$REPO/scripts/launcher.scd"
LOG="\$HOME/Library/Logs/megalooper.log"

mkdir -p "\$(dirname "\$LOG")"
{
    echo ""
    echo "=== megalooper launch \$(date '+%Y-%m-%d %H:%M:%S') ==="
} >> "\$LOG"

if [ ! -f "\$SCRIPT" ]; then
    echo "launcher.scd not found at \$SCRIPT" >> "\$LOG"
    osascript -e 'display alert "megalooper" message "The megalooper repository has moved. Re-run tools/make-app.sh to rebuild this app." as critical'
    exit 1
fi

# On Apple Silicon, run sclang natively. macOS may decide on its own to start
# a bundle whose executable is a script, like this one, under Rosetta (Finder
# then shows no checkbox to undo it), and a universal sclang exec'd from a
# translated bash runs translated too: about twice the CPU, and scsynth and
# every plugin it loads with it. hw.optional.arm64 is 1 on Apple Silicon even
# inside Rosetta, where uname -m says x86_64.
if [ "\$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && file "\$SCLANG" | grep -q arm64; then
    exec /usr/bin/arch -arm64 "\$SCLANG" "\$SCRIPT" >> "\$LOG" 2>&1
fi
exec "\$SCLANG" "\$SCRIPT" >> "\$LOG" 2>&1
LAUNCH
chmod +x "$APP/Contents/MacOS/megalooper"

# Finder caches bundle icons aggressively; touching the bundle makes it re-read.
touch "$APP"

echo ""
echo "Built $APP"
echo "Double-click it to pick a rig and start. Log: ~/Library/Logs/megalooper.log"
echo ""
echo "Note: macOS may warn the first time because the bundle is unsigned."
echo "      Right-click the icon -> Open -> Open to allow it once."
