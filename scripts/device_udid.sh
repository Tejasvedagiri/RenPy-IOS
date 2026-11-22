#!/bin/bash
# Prints the hardware UDID of the connected iPhone (used by both xcodebuild and devicectl).
#
#   scripts/device_udid.sh [name-or-udid]   # default: the first paired physical device

set -euo pipefail

DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --quiet --json-output "$DEVICES_JSON" >/dev/null
UDID="$(python3 - "$DEVICES_JSON" "${1:-}" <<'EOF'
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
    echo "No connected iPhone found${1:+ matching '$1'}. Plug it in, unlock it and trust this Mac." >&2
    exit 1
fi
echo "$UDID"
