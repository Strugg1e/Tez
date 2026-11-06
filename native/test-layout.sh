#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache output.noindex
sources=()
for source in Sources/TezNative/*.swift; do
    [[ "$source" == */TezNativeApp.swift ]] || sources+=("$source")
done
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path .build/module-cache \
    -swift-version 6 -parse-as-library "${sources[@]}" Tests/NativeLayoutCheck.swift -o .build/native-layout-check
.build/native-layout-check
if [[ "${1:-}" == --ui-bundle ]]; then
    APP="$PWD/output.noindex/Tez Layout Check.app"
    mkdir -p "$APP/Contents/MacOS"
    cp .build/native-layout-check "$APP/Contents/MacOS/TezLayoutCheck"
    cp Tests/LayoutInfo.plist "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP"
    codesign --verify --strict "$APP"
fi
