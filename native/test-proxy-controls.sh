#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
sources=()
for source in Sources/TezNative/*.swift; do
    [[ "$source" == */TezNativeApp.swift ]] || sources+=("$source")
done
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path .build/module-cache \
    -swift-version 6 -parse-as-library "${sources[@]}" Tests/ProxyControlsCheck.swift -o .build/proxy-controls-check
.build/proxy-controls-check
if [[ "${1:-}" == --ui-bundle ]]; then
    APP="$PWD/output.noindex/Tez Proxy Controls Check.app"
    mkdir -p "$APP/Contents/MacOS"
    cp .build/proxy-controls-check "$APP/Contents/MacOS/TezProxyControlsCheck"
    cp Tests/ProxyControlsInfo.plist "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP"
    codesign --verify --strict "$APP"
fi
