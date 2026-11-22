#!/bin/bash
# Copies the repo's games/ folder into RenPy Player's storage on the iPhone
# (Documents/games), so games don't have to be built into the app.
# Only new or changed files are sent; unchanged ones are skipped.
#
#   scripts/push_games.sh                  # push every game in games/
#   scripts/push_games.sh "Game A" GameB   # push only these game folders
#
# The app must already be installed (./install.sh does both). Keep the phone unlocked
# while copying.
# Games removed from games/ stay on the phone: swipe left in the app to delete them.
#
# Environment:
#   DEVICE     Device name or UDID (default: the first connected physical device)
#   BUNDLE_ID  App bundle identifier (default: read from the last build)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/games"
# A hard-linked copy of games/ without what the app doesn't need (scripts/stage_games.py).
STAGE="$ROOT/.cache/games-stage"
CONFIGURATION="${CONFIGURATION:-Release}"

UDID="$("$ROOT/scripts/device_udid.sh" "${DEVICE:-}")"

if [ -z "${BUNDLE_ID:-}" ]; then
    APP="$(ls -d "$ROOT/.cache/DerivedData/Build/Products/$CONFIGURATION-iphoneos/"*.app 2>/dev/null | head -n 1 || true)"
    if [ -z "$APP" ]; then
        echo "Set BUNDLE_ID, or run ./install.sh first." >&2
        exit 1
    fi
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
fi

if [ $# -gt 0 ]; then
    GAMES=("$@")
else
    GAMES=()
    for dir in "$SRC"/*/; do
        [ -d "$dir" ] && GAMES+=("$(basename "$dir")")
    done
fi
if [ ${#GAMES[@]} -eq 0 ]; then
    echo "==> No games in $SRC"
    exit 0
fi

mkdir -p "$STAGE"
if [ $# -eq 0 ]; then
    # Drop staged copies of games that were removed from games/, so they don't keep using disk space.
    for dir in "$STAGE"/*/; do
        [ -d "$dir" ] && [ ! -d "$SRC/$(basename "$dir")" ] && rm -rf "$dir"
    done
fi
for name in "${GAMES[@]}"; do
    if [ ! -d "$SRC/$name" ]; then
        echo "No such game folder: $SRC/$name" >&2
        exit 1
    fi

    # Skip desktop executables and the game's own copy of Ren'Py (the app ships its own).
    python3 "$ROOT/scripts/stage_games.py" "$SRC/$name" "$STAGE/$name"

    echo "==> Copying $name ($(du -sh "$STAGE/$name" | cut -f1)) to the phone"
    # Copies sometimes fail part way (e.g. the phone locked). Files already sent are
    # skipped on the next try, so just retry.
    for attempt in 1 2 3; do
        if xcrun devicectl device copy to --quiet \
            --device "$UDID" \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source "$STAGE/$name" --destination "Documents/games/$name"; then
            break
        fi
        if [ "$attempt" = 3 ]; then
            echo "Couldn't copy $name. Keep the phone unlocked and run scripts/push_games.sh again." >&2
            exit 1
        fi
        echo "    Copy failed; retrying ($attempt/2)"
        sleep 5
    done
done
