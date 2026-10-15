#!/bin/bash
# Install megalooper on this machine: macOS, or Linux (Arch and Omarchy with
# pacman, Debian and Ubuntu with apt; elsewhere it says what it needs).
#
#   ./tools/install.sh                 # install, then run the quick checks
#   ./tools/install.sh --yes           # don't ask before installing packages
#   ./tools/install.sh --no-checks     # skip the checks
#   ./tools/install.sh --no-app        # no Desktop icon (macOS), no launcher entry (Linux)
#   ./tools/install.sh --no-vstplugin  # don't fetch VSTPlugin
#
# What it does, in this order:
#   1. finds SuperCollider. On Linux it offers to install it with pacman or
#      apt, together with sc3-plugins and a JACK for PipeWire;
#   2. checks that sc3-plugins is there (megalooper's classes need it);
#   3. fetches BBCut, at the commit megalooper is tested against, into
#      SuperCollider's Extensions, unless you have it already;
#   4. fetches VSTPlugin 0.6.2, which hosts VST plugins in the effect chains,
#      into Extensions, unless you have it already. megalooper runs without
#      it, so a download that fails is a warning and the install goes on;
#   5. links this checkout's classes/ into Extensions as "megalooper";
#   6. runs the quick checks (the unit tests and the static check);
#   7. builds the Desktop icon (macOS) or adds megalooper to the application
#      launcher (Linux).
#
# It deletes nothing of yours. The one thing it replaces is the "megalooper"
# link in Extensions, when that link points at another checkout: run it again
# after moving this folder.
#
# For its own tests: MEGALOOPER_OS stands in for `uname -s`, MEGALOOPER_ARCH
# for `uname -m`, MEGALOOPER_BBCUT_URL for where BBCut is cloned from, and
# MEGALOOPER_VSTPLUGIN_URL for where VSTPlugin's zip is fetched from.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="${MEGALOOPER_OS:-$(uname -s)}"
ARCH="${MEGALOOPER_ARCH:-$(uname -m)}"
BBCUT_URL="${MEGALOOPER_BBCUT_URL:-https://github.com/nhthn/BBCut.git}"
BBCUT_COMMIT="edd86e1cbc4f269828df1acac51afdb3e54bfdb8"
MIN_VERSION="3.14.1"
# VSTPlugin's release zips, as its release page links them, each with the
# SHA-256 it had when megalooper was tested with it.
VST_VERSION="0.6.2"
VST_UPLOADS="https://git.iem.at/-/project/485/uploads"

YES=0; CHECKS=1; APP=1; VST=1
for arg in "$@"; do
    case "$arg" in
        --yes) YES=1 ;;
        --no-checks) CHECKS=0 ;;
        --no-app) APP=0 ;;
        --no-vstplugin) VST=0 ;;
        -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option '$arg' (try --help)." >&2; exit 2 ;;
    esac
done

say()  { echo "megalooper: $*"; }
fail() { echo "megalooper: error: $*" >&2; exit 1; }

case "$OS" in
    Darwin)
        SUPPORT="$HOME/Library/Application Support/SuperCollider"
        SYSTEM_EXT=("/Library/Application Support/SuperCollider/Extensions")
        ;;
    Linux)
        SUPPORT="${XDG_DATA_HOME:-$HOME/.local/share}/SuperCollider"
        SYSTEM_EXT=("/usr/share/SuperCollider/Extensions" "/usr/local/share/SuperCollider/Extensions")
        ;;
    *) fail "megalooper runs on macOS and Linux; this is '$OS'." ;;
esac
EXT="$SUPPORT/Extensions"
QUARKS="$SUPPORT/downloaded-quarks"

find_sclang() {
    local candidate
    for candidate in \
        "/Applications/SuperCollider.app/Contents/MacOS/sclang" \
        "$HOME/Applications/SuperCollider.app/Contents/MacOS/sclang" \
        "$(command -v sclang 2>/dev/null || true)"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
    done
    return 1
}

# Is a class file of that name in the user's or the system's Extensions, or
# among the quarks?
have_class() {
    local dir
    for dir in "$EXT" "$QUARKS" "${SYSTEM_EXT[@]}"; do
        if [ -d "$dir" ] && [ -n "$(find -L "$dir" -name "$1" -print -quit 2>/dev/null)" ]; then return 0; fi
    done
    return 1
}

# ---- 1. SuperCollider, and on Linux the packages beside it ----------------
# pacman (Arch, Omarchy) or apt (Debian, Ubuntu): the same things under each
# one's names.
PM=""
if [ "$OS" = "Linux" ]; then
    if command -v pacman >/dev/null 2>&1; then PM="pacman"
    elif command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then PM="apt"
    fi
fi

have_pkg() {
    if [ "$PM" = "pacman" ]; then pacman -Qq "$1" >/dev/null 2>&1
    else dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
    fi
}

if [ -n "$PM" ]; then
    missing=()
    if [ "$PM" = "pacman" ]; then
        wanted="supercollider sc3-plugins git python"
        install_cmd="sudo pacman -S --needed"
    else
        # curl fetches VSTPlugin, and Ubuntu's desktop comes without it.
        wanted="supercollider sc3-plugins git python3 curl"
        install_cmd="sudo apt-get install"
    fi
    for pkg in $wanted; do
        have_pkg "$pkg" || missing+=("$pkg")
    done
    # scsynth speaks JACK.
    if [ "$PM" = "pacman" ]; then
        # PipeWire's own (Omarchy has PipeWire) unless a JACK is installed
        # already.
        if ! have_pkg pipewire-jack && ! have_pkg jack2; then missing+=("pipewire-jack"); fi
    else
        # Debian's SuperCollider brings JACK 2 with it, which does not reach
        # PipeWire. Where PipeWire carries the sound, pipewire-jack does:
        # tools/megalooper starts through its pw-jack.
        if have_pkg pipewire && ! have_pkg pipewire-jack; then missing+=("pipewire-jack"); fi
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        say "these packages are missing: ${missing[*]}"
        if [ "$YES" -eq 0 ]; then
            printf "megalooper: install them now with '%s %s'? [y/N] " "$install_cmd" "${missing[*]}"
            read -r answer
            case "$answer" in y|Y|yes|Yes) ;; *) fail "not installed. Install them and run this again." ;; esac
        fi
        $install_cmd "${missing[@]}" || fail "$PM did not install them."
    fi
fi

SCLANG="$(find_sclang)" || {
    if [ "$OS" = "Darwin" ]; then
        fail "SuperCollider is not installed. Get $MIN_VERSION or later from https://supercollider.github.io/ (or: brew install --cask supercollider), then run this again."
    else
        fail "SuperCollider is not installed. Install the packages supercollider and sc3-plugins (and a JACK: pipewire-jack or jack2), then run this again."
    fi
}
say "SuperCollider: $SCLANG"

version="$("$SCLANG" -v 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -n "$version" ]; then
    oldest="$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
    if [ "$oldest" != "$MIN_VERSION" ]; then
        say "warning: this is SuperCollider $version. megalooper is built and tested on $MIN_VERSION; older ones may work, and Megalooper SA was never tried on them. docs/linux.md says which distributions ship which."
    fi
else
    say "warning: could not read SuperCollider's version (megalooper wants $MIN_VERSION or later)."
fi

# ---- 2. sc3-plugins --------------------------------------------------------
if have_class "Tartini.sc"; then
    say "sc3-plugins: found"
else
    if [ "$OS" = "Darwin" ]; then
        fail "sc3-plugins is not installed, and megalooper's classes do not compile without it. Download the macOS zip of the release built for your SuperCollider from https://github.com/supercollider/sc3-plugins/releases, unzip it into \"$EXT\", then run this again."
    else
        fail "sc3-plugins is not installed, and megalooper's classes do not compile without it. Install your distribution's sc3-plugins package, then run this again."
    fi
fi

# ---- 3. BBCut ----------------------------------------------------------------
mkdir -p "$EXT" || fail "could not make $EXT."
if have_class "BBCut2.sc"; then
    say "BBCut: found"
else
    command -v git >/dev/null 2>&1 || fail "git is not installed: it fetches BBCut."
    say "BBCut: fetching it into $EXT/BBCut"
    git clone --quiet "$BBCUT_URL" "$EXT/BBCut" || fail "could not fetch BBCut from $BBCUT_URL."
    git -C "$EXT/BBCut" checkout --quiet "$BBCUT_COMMIT" \
        || say "warning: BBCut is there, but not at the commit megalooper is tested against ($BBCUT_COMMIT)."
fi

# ---- 4. VSTPlugin ---------------------------------------------------------------
# megalooper plays its built-in effects without it, so nothing here stops the
# install: what went wrong is said, and the install goes on.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

unpack_zip() {
    mkdir -p "$2" || return 1
    if command -v unzip >/dev/null 2>&1; then unzip -q "$1" -d "$2"
    elif command -v python3 >/dev/null 2>&1; then python3 -m zipfile -e "$1" "$2"
    else return 1
    fi
}

fetch_vstplugin() {
    local file sum url tmp got dest="$EXT/VSTPlugin"
    case "$OS/$ARCH" in
        Darwin/*)
            file="d7d04b43c6e025d00ddb7cd73217aadf/vstplugin_v${VST_VERSION}_macOS.zip"
            sum="82f0bc18ed17a61467231d3320e351e885d39b5187dbd776f9dc83eda9ff40af" ;;
        Linux/x86_64|Linux/amd64)
            file="7dcb287f5cc882fd3aa6f157cdc7bb5d/vstplugin_v${VST_VERSION}_Linux.zip"
            sum="f7139df5ac74be5bd71fe32b992a8706470897ca026bec3b06c920ea170f227f" ;;
        Linux/aarch64|Linux/arm64)
            file="c3466098d71e135c229dccf3703ee263/vstplugin_v${VST_VERSION}_Linux_ARM64.zip"
            sum="787f29c6b1c941d168069a1db92321f5811da9f69e3871cad0b1bffdf4a04145" ;;
        *)
            say "VSTPlugin: megalooper knows no build of $VST_VERSION for this processor ($ARCH)."
            return 1 ;;
    esac
    url="${MEGALOOPER_VSTPLUGIN_URL:-$VST_UPLOADS/$file}"
    command -v curl >/dev/null 2>&1 || { say "VSTPlugin: curl is not installed: it fetches VSTPlugin."; return 1; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/megalooper-vstplugin.XXXXXX")" || { say "VSTPlugin: could not make a folder to download into."; return 1; }
    say "VSTPlugin: fetching $VST_VERSION into $dest"
    if ! curl -fsSL --retry 2 -o "$tmp/vstplugin.zip" "$url"; then
        say "VSTPlugin: could not fetch $url."
        rm -rf "$tmp"; return 1
    fi
    got="$(sha256_of "$tmp/vstplugin.zip")"
    if [ "$got" != "$sum" ]; then
        if [ -z "$got" ]; then
            say "VSTPlugin: neither sha256sum nor shasum is here to check the download with, so it was not installed."
        else
            say "VSTPlugin: the download is not the file megalooper was tested with (SHA-256 $got), so it was not installed."
        fi
        rm -rf "$tmp"; return 1
    fi
    if ! unpack_zip "$tmp/vstplugin.zip" "$tmp/out" || [ ! -f "$tmp/out/sc/VSTPlugin/classes/VSTPlugin.sc" ]; then
        say "VSTPlugin: could not unpack the download (it needs unzip or python3)."
        rm -rf "$tmp"; return 1
    fi
    # megalooper plays through scsynth, which on macOS loads the supernova
    # build beside its own too; the two copies' classes risk a crash.
    if [ "$OS" = "Darwin" ]; then rm -f "$tmp/out/sc/VSTPlugin/plugins/VSTPlugin_supernova.scx"; fi
    # `host` probes every plugin in a scan. python3 unpacks without the bit.
    chmod +x "$tmp/out/sc/VSTPlugin/plugins/"host* 2>/dev/null
    if ! mv "$tmp/out/sc/VSTPlugin" "$dest"; then
        say "VSTPlugin: could not move it into $EXT."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    say "VSTPlugin: installed"
}

if [ "$VST" -eq 1 ]; then
    if have_class "VSTPlugin.sc"; then
        say "VSTPlugin: found"
    elif [ -e "$EXT/VSTPlugin" ]; then
        say "warning: $EXT/VSTPlugin is there but holds no VSTPlugin.sc. Move it away and run this again to fetch VSTPlugin."
    else
        fetch_vstplugin || say "warning: VSTPlugin was not installed. megalooper runs without it, with its built-in effects and no plugins; docs/standalone.md, \"Installing VSTPlugin by hand\", says how."
    fi
fi

# ---- 5. megalooper's classes --------------------------------------------------
LINK="$EXT/megalooper"
if [ -L "$LINK" ]; then
    was="$(readlink "$LINK")"
    if [ "$was" = "$REPO/classes" ]; then
        say "classes: already linked"
    else
        ln -sfn "$REPO/classes" "$LINK" || fail "could not relink $LINK."
        say "classes: the link pointed at $was; it now points at this checkout"
    fi
elif [ -e "$LINK" ]; then
    fail "$LINK is there and is no link. Move it away (it would be compiled beside this checkout's classes), then run this again."
else
    ln -s "$REPO/classes" "$LINK" || fail "could not link $LINK."
    say "classes: linked into $EXT"
fi

# ---- 6. the quick checks -------------------------------------------------------
checks_failed=0
if [ "$CHECKS" -eq 1 ]; then
    say "running the quick checks (about half a minute)…"
    # sclang wants a display even for these; without one, Qt's off-screen one.
    if [ "$OS" = "Linux" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        export QT_QPA_PLATFORM=offscreen
    fi
    "$REPO/tools/run-checks.sh" quick || checks_failed=1
fi

# ---- 7. a way to start it -------------------------------------------------------
if [ "$APP" -eq 1 ]; then
    if [ "$OS" = "Darwin" ]; then
        "$REPO/tools/make-app.sh" || say "warning: the Desktop icon was not built; ./tools/megalooper starts megalooper too."
    else
        data="${XDG_DATA_HOME:-$HOME/.local/share}"
        mkdir -p "$data/applications" "$data/icons"
        icon="$data/icons/megalooper.png"
        python3 "$REPO/tools/make-icon.py" "$icon" 256 >/dev/null 2>&1 || icon="audio-x-generic"
        {
            echo "[Desktop Entry]"
            echo "Type=Application"
            echo "Name=megalooper"
            echo "Comment=A live looper that finds the meter"
            echo "Exec=\"$REPO/tools/megalooper\""
            echo "Icon=$icon"
            echo "Terminal=false"
            echo "Categories=AudioVideo;Audio;Music;"
        } > "$data/applications/megalooper.desktop"
        say "launcher: megalooper is in your application launcher ($data/applications/megalooper.desktop)"
    fi
fi

echo
if [ "$checks_failed" -eq 1 ]; then
    say "installed, but the quick checks FAILED: see the log named above before you play."
    exit 1
fi
say "installed."
if [ "$APP" -eq 0 ]; then
    how="with ./tools/megalooper"
elif [ "$OS" = "Darwin" ]; then
    how="from the Desktop icon, or with ./tools/megalooper"
else
    how="from your application launcher, or with ./tools/megalooper"
fi
if [ "$OS" = "Darwin" ]; then
    say "start it $how. README.md, \"First run\", goes on from here."
else
    say "start it $how. docs/linux.md goes on from here."
fi
