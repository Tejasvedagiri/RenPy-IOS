#!/bin/bash
# Downloads the Ren'Py SDK + renios, generates the iOS Xcode project with
# Ren'Py's own packager, and patches it into RenPy Player.
#
#   scripts/setup.sh                 # first-time setup
#   scripts/setup.sh --force         # regenerate ios/RenPyPlayer from scratch
#
# Environment:
#   RENPY_VERSION  Ren'Py version to use (default 8.6.2)
#   BUNDLE_ID      App bundle identifier (default com.<user>.renpyplayer)
#   TEAM_ID        Apple Developer Team ID (default: pick it in Xcode)

set -euo pipefail

RENPY_VERSION="${RENPY_VERSION:-8.6.2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
SDK="$CACHE/renpy-$RENPY_VERSION-sdk"
STUB="$CACHE/stub"
PROJECT="$ROOT/ios/RenPyPlayer"
DL="https://www.renpy.org/dl/$RENPY_VERSION"

DEFAULT_ID="com.$(id -un | tr -cd 'A-Za-z0-9').renpyplayer"
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_ID}"
TEAM_ID="${TEAM_ID:-}"

mkdir -p "$CACHE"

if [ ! -x "$SDK/renpy.sh" ]; then
    echo "==> Downloading Ren'Py $RENPY_VERSION SDK"
    curl -fL --progress-bar -o "$CACHE/renpy-$RENPY_VERSION-sdk.tar.bz2" "$DL/renpy-$RENPY_VERSION-sdk.tar.bz2"
    tar -xjf "$CACHE/renpy-$RENPY_VERSION-sdk.tar.bz2" -C "$CACHE"
fi

if [ ! -d "$SDK/renios" ]; then
    echo "==> Downloading renios (Ren'Py iOS support)"
    curl -fL --progress-bar -o "$CACHE/renpy-$RENPY_VERSION-renios.zip" "$DL/renpy-$RENPY_VERSION-renios.zip"
    rm -rf "$CACHE/renios_x"
    unzip -q "$CACHE/renpy-$RENPY_VERSION-renios.zip" -d "$CACHE/renios_x"
    cp -R "$CACHE/renios_x/renios" "$SDK/renios"
fi

if ! cmp -s "$SDK/renios/hash.txt" "$SDK/launcher/game/renios_hash.txt"; then
    echo "renios does not match the SDK version. Delete $CACHE and try again." >&2
    exit 1
fi

# A placeholder project: Ren'Py's packager needs one to build base/ (the engine
# and Python standard library). The real games are chosen at runtime.
mkdir -p "$STUB/game"
cat > "$STUB/game/options.rpy" <<'EOF'
define config.name = "RenPy Player"
define build.name = "RenPyPlayer"
define config.version = "1.0"
EOF
cat > "$STUB/game/script.rpy" <<'EOF'
label start:
    "No game was selected. Close the app and pick a game from the library."
    return
EOF

if [ "${1:-}" = "--force" ]; then
    rm -rf "$PROJECT"
fi

if [ ! -d "$PROJECT" ]; then
    echo "==> Generating Xcode project with Ren'Py's iOS packager"
    mkdir -p "$(dirname "$PROJECT")"
    "$SDK/renpy.sh" "$SDK/launcher" ios_create "$STUB" "$PROJECT"
else
    echo "==> $PROJECT exists; re-applying patches only (use --force to regenerate)"
fi

echo "==> Applying RenPy Player overlay"
python3 "$ROOT/scripts/apply_overlay.py" "$PROJECT" --bundle-id "$BUNDLE_ID" --team "$TEAM_ID"

echo
echo "Done. Open the project with:"
echo "  open \"$PROJECT\"/*.xcodeproj"
