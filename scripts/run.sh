#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

# Everyday launch: optimize the app and its Swift dependencies, without a watcher.
swift build -c release
app_bundle=".build/ReadBudMac.app"
mkdir -p "$app_bundle/Contents/MacOS"
cp Support/Info.plist "$app_bundle/Contents/Info.plist"
cp .build/release/ReadBudMac "$app_bundle/Contents/MacOS/ReadBudMac"
for resource_bundle in .build/release/*.bundle; do
    ditto "$resource_bundle" "$app_bundle/${resource_bundle:t}"
done
/usr/bin/codesign --force --deep --sign - "$app_bundle"
open "$app_bundle"
