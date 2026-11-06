#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
sources=()
for source in Sources/TezNative/*.swift; do
    [[ "$source" == */TezNativeApp.swift ]] || sources+=("$source")
done
for source in "${sources[@]}" Tests/NativeLayoutCheck.swift; do
    if [[ ! -x .build/window-drag-layout-fixture || "$source" -nt .build/window-drag-layout-fixture ]]; then
        swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path .build/module-cache \
            -swift-version 6 -parse-as-library "${sources[@]}" Tests/NativeLayoutCheck.swift -o .build/window-drag-layout-fixture
        break
    fi
done
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path .build/module-cache \
    -swift-version 6 -parse-as-library "${sources[@]}" Tests/WindowDraggingCheck.swift -o .build/window-dragging-check
APP="$PWD/output.noindex/Tez Window Drag Regression.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/window-dragging-check "$APP/Contents/MacOS/TezWindowDragCheck"
cp .build/window-drag-layout-fixture "$APP/Contents/MacOS/TezLayoutFixture"
cp Tests/LayoutInfo.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable TezWindowDragCheck' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.tez.window-drag-regression' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Tez Window Drag Regression' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [[ "${1:-}" == --build-only ]]; then exit 0; fi
"$APP/Contents/MacOS/TezWindowDragCheck"
