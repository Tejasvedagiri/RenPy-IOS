#!/bin/bash
# Builds RenPy Player and (re)installs it on a connected iPhone, without Xcode's UI.
# Installing over the existing app keeps its Documents (saves and imported games).
#
#   ./install.sh               # build, install and launch
#   ./install.sh --no-launch   # build and install only
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

for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ ! -d "$PROJECT" ]; then
    echo "==> $PROJECT is missing; running setup.sh"
    "$ROOT/scripts/setup.sh"
fi

# Resolve the device to its hardware UDID (used by both xcodebuild and devicectl).
DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --quiet --json-output "$DEVICES_JSON" >/dev/null
UDID="$(python3 - "$DEVICES_JSON" "$DEVICE" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
want = sys.argv[2]
for d in devices:
    hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    if hw.get("reality") != "physical" or hw.get("platform") != "iOS":
        continue
    ids = {hw.get("udid"), d.get("identifier"), props.get("name")}
    if want and want not in ids:
        continue
    if not want and d.get("connectionProperties", {}).get("pairingState") != "paired":
        continue
    print(hw["udid"])
    break
EOF
)"
if [ -z "$UDID" ]; then
    echo "No connected iPhone found${DEVICE:+ matching '$DEVICE'}. Plug it in, unlock it and trust this Mac." >&2
    exit 1
fi

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

APP="$(ls -d "$DERIVED/Build/Products/$CONFIGURATION-iphoneos/"*.app | head -n 1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

echo "==> Installing $(basename "$APP") ($BUNDLE_ID)"
xcrun devicectl device install app --device "$UDID" "$APP"

if [ "$LAUNCH" = 1 ]; then
    echo "==> Launching"
    if ! xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "    Installed, but couldn't launch it (is the phone locked?). Open it from the home screen."
    fi
fi
