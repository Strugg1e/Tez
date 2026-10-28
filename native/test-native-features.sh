#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path .build/module-cache -swift-version 6 -parse-as-library \
    Sources/TezNative/BackendWire.swift \
    Sources/TezNative/BackendSnapshot.swift \
    Sources/TezNative/NativeRecoveryChannel.swift \
    Sources/TezNative/BackendConnection.swift \
    Sources/TezNative/TezStyle.swift \
    Sources/TezNative/NativeActivity.swift \
    Sources/TezNative/NativeActivityView.swift \
    Sources/TezNative/NativeFeatureViews.swift \
    Sources/TezNative/NativeLatency.swift \
    Sources/TezNative/NativeSubscriptions.swift \
    Tests/NativeFeaturesCheck.swift -o .build/native-features-check
.build/native-features-check
if [[ "${1:-}" == --ui-bundle || "${1:-}" == --isolated-ui-bundle ]]; then
    APP="$PWD/output.noindex/Tez Feature Check.app"
    mkdir -p "$APP/Contents/MacOS"
    cp .build/native-features-check "$APP/Contents/MacOS/TezFeatureCheck"
    cp Tests/FeaturesInfo.plist "$APP/Contents/Info.plist"
    if [[ "${1:-}" == --isolated-ui-bundle ]]; then
        [[ "${2:-}" == /* && -x "$2" ]] || { printf 'Expected absolute packaged helper path.\n' >&2; exit 2; }
        /usr/libexec/PlistBuddy -c "Add :TezIsolatedHelper string $2" "$APP/Contents/Info.plist"
    fi
    codesign --force --sign - "$APP"
    codesign --verify --strict "$APP"
fi
