#!/bin/zsh

set -u

cd "${0:A:h}/.."

if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

app_pid=""
app_bundle=".build/ReadBudMac.app"

cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null
        wait "$app_pid" 2>/dev/null
    fi
}

source_fingerprint() {
    find Sources -type f -print0 \
        | xargs -0 stat -f '%m %N' \
        | shasum
    stat -f '%m %N' Package.swift Package.resolved 2>/dev/null | shasum
}

build_and_run() {
    cleanup
    app_pid=""

    print '\nBuilding ReadBudMac...'
    if swift build; then
        rm -rf "$app_bundle"
        mkdir -p "$app_bundle/Contents/MacOS"
        cp Support/Info.plist "$app_bundle/Contents/Info.plist"
        cp .build/debug/ReadBudMac "$app_bundle/Contents/MacOS/ReadBudMac"
        for resource_bundle in .build/debug/*.bundle; do
            cp -R "$resource_bundle" "$app_bundle/${resource_bundle:t}"
        done
        /usr/bin/codesign --force --deep --sign - "$app_bundle" >/dev/null
        open -n "$app_bundle"
        sleep 0.4
        app_pid="$(pgrep -n -f "$app_bundle/Contents/MacOS/ReadBudMac" || true)"
        print "ReadBudMac is running (PID $app_pid). Watching for changes..."
    else
        print 'Build failed. Watching for the next change...'
    fi
}

trap cleanup EXIT
trap 'exit 0' INT TERM

mkdir -p .build
watcher=".build/readbud-source-watcher"
if [[ ! -x "$watcher" || scripts/watch-sources.swift -nt "$watcher" ]]; then
    swiftc scripts/watch-sources.swift -o "$watcher" || exit 1
fi

fingerprint="$(source_fingerprint)"
build_and_run

while true; do
    next_fingerprint="$(source_fingerprint)"
    if [[ "$next_fingerprint" == "$fingerprint" ]]; then
        "$watcher" || exit 1
        sleep 0.3
    fi
    fingerprint="$(source_fingerprint)"
    build_and_run
done
