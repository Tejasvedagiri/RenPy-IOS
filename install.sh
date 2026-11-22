#!/bin/bash
# Builds RenPy Player and (re)installs it on a connected iPhone, without Xcode's UI,
# then copies the repo's games/ folder into the app's storage on the phone
# (scripts/push_games.sh; only new or changed files are sent).
# Installing over the existing app keeps its Documents (saves and games).
#
#   ./install.sh               # build, install, push games and launch
#   ./install.sh --no-launch   # don't launch
#   ./install.sh --no-games    # app only, don't push games
#   ./install.sh --games-only  # push games only, don't build or install
#
# Environment:
#   DEVICE         Device name or UDID (default: the first connected physical device)
#   CONFIGURATION  Debug or Release (default Release)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT/ios/RenPyPlayer"
DERIVED="$ROOT/.cache/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"
DEVICE="${DEVICE:-}"
LAUNCH=1
APP_STEP=1
GAMES_STEP=1

for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        --no-games) GAMES_STEP=0 ;;
        --games-only) APP_STEP=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ ! -d "$PROJECT" ]; then
    echo "==> $PROJECT is missing; running setup.sh"
    "$ROOT/scripts/setup.sh"
fi

UDID="$("$ROOT/scripts/device_udid.sh" "$DEVICE")"
PRODUCTS="$DERIVED/Build/Products/$CONFIGURATION-iphoneos"

if [ "$APP_STEP" = 1 ]; then
    # Older builds copied games/ into the app. Start from a clean app so they're not left in it.
    for app in "$PRODUCTS"/*.app; do
        if [ -d "$app/games" ]; then
            echo "==> Removing old build that had games inside the app"
            rm -rf "$app"
        fi
    done

    echo "==> Building ($CONFIGURATION) for device $UDID"
    xcodebuild \
        -project "$PROJECT/RenPyPlayer.xcodeproj" \
        -scheme "RenPy Player" \
        -configuration "$CONFIGURATION" \
        -destination "id=$UDID" \
        -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates \
        -quiet \
        build
fi

APP="$(ls -d "$PRODUCTS/"*.app 2>/dev/null | head -n 1 || true)"
if [ -z "$APP" ]; then
    echo "No build found in $PRODUCTS. Run ./install.sh without --games-only first." >&2
    exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

if [ "$APP_STEP" = 1 ]; then
    echo "==> Installing $(basename "$APP") ($BUNDLE_ID)"
    xcrun devicectl device install app --device "$UDID" "$APP"
fi

if [ "$GAMES_STEP" = 1 ]; then
    DEVICE="$UDID" BUNDLE_ID="$BUNDLE_ID" "$ROOT/scripts/push_games.sh"
fi

if [ "$LAUNCH" = 1 ]; then
    echo "==> Launching"
    if ! xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "    Installed, but couldn't launch it (is the phone locked?). Open it from the home screen."
    fi
fi
