#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SWIFT_SCRATCH="${TEZ_NATIVE_SWIFT_SCRATCH:-$ROOT/.build}"
cd "$ROOT"
HELPER="${TEZ_NATIVE_HOST:-}"
WITH_CORE="${TEZ_NATIVE_BUNDLE_CORE:-0}"
WITH_SERVICE="${TEZ_NATIVE_BUNDLE_SERVICE:-$WITH_CORE}"
UI_ONLY="${TEZ_NATIVE_UI_ONLY:-0}"
STANDALONE="${TEZ_NATIVE_STANDALONE:-0}"
ACCEPTANCE_HOME="${TEZ_NATIVE_ACCEPTANCE_HOME:-}"
APP="${TEZ_NATIVE_APP_PATH:-$ROOT/output.noindex/Tez Preview.app}"
if [[ "$UI_ONLY" != 0 && "$UI_ONLY" != 1 ]]; then
    printf 'TEZ_NATIVE_UI_ONLY must be 0 or 1.\n' >&2
    exit 1
fi
if [[ "$WITH_CORE" != 0 && "$WITH_CORE" != 1 ]]; then
    printf 'TEZ_NATIVE_BUNDLE_CORE must be 0 or 1.\n' >&2
    exit 1
fi
if [[ "$WITH_SERVICE" != 0 && "$WITH_SERVICE" != 1 ]]; then
    printf 'TEZ_NATIVE_BUNDLE_SERVICE must be 0 or 1.\n' >&2
    exit 1
fi
if [[ "$STANDALONE" != 0 && "$STANDALONE" != 1 ]]; then
    printf 'TEZ_NATIVE_STANDALONE must be 0 or 1.\n' >&2
    exit 1
fi
if [[ "$APP" != /* || "$APP" != *.app ]]; then
    printf 'TEZ_NATIVE_APP_PATH must be an absolute .app path.\n' >&2
    exit 1
fi
if [[ "$STANDALONE" == 1 ]]; then
    if [[ "$UI_ONLY" != 0 || "$WITH_CORE" != 1 || "$WITH_SERVICE" != 1 || -z "$HELPER" ]]; then
        printf 'Standalone packaging requires a managed host, bundled cores and service tools.\n' >&2
        exit 1
    fi
    if [[ -e "$APP" || -L "$APP" ]]; then
        printf 'Standalone output must not already exist; refusing to overwrite it.\n' >&2
        exit 1
    fi
fi
if [[ -n "$ACCEPTANCE_HOME" ]]; then
    if [[ "$ACCEPTANCE_HOME" != /private/tmp/tez-package-acceptance-*/home || ! -d "$ACCEPTANCE_HOME" || "$WITH_SERVICE" != 1 ]]; then
        printf 'Acceptance packaging requires its prepared private HOME and service tools.\n' >&2
        exit 1
    fi
fi
if [[ -n "$HELPER" && ! -x "$HELPER" ]]; then
    printf 'TEZ_NATIVE_HOST must name a built executable.\n' >&2
    exit 1
fi
if [[ "$WITH_CORE" == 1 ]]; then
    if [[ -z "$HELPER" ]]; then
        printf 'Core packaging requires TEZ_NATIVE_HOST.\n' >&2
        exit 1
    fi
    node "$ROOT/package-core.mjs" --source-check
fi
if [[ "$WITH_SERVICE" == 1 ]]; then
    node "$ROOT/package-service.mjs" --source-check
fi
swift build --configuration release --scratch-path "$SWIFT_SCRATCH"
BIN_DIR="$(swift build --configuration release --scratch-path "$SWIFT_SCRATCH" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
EXECUTABLE=TezNativePreview
if [[ "$STANDALONE" == 1 ]]; then EXECUTABLE=Tez; fi
cp "$BIN_DIR/TezNativePreview" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ "$STANDALONE" == 1 ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Tez' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.tez.native' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tez' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tez' "$APP/Contents/Info.plist"
fi
if [[ -n "$ACCEPTANCE_HOME" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.tez.acceptance' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tez Acceptance' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tez Acceptance' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :TezAcceptanceHome string $ACCEPTANCE_HOME" "$APP/Contents/Info.plist"
fi
if [[ "$UI_ONLY" == 1 ]]; then
    /usr/libexec/PlistBuddy -c 'Add :TezInterfaceOnly bool true' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.tez.native-ui-check' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Tez UI Check' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Tez UI Check' "$APP/Contents/Info.plist"
fi
if [[ -n "$HELPER" ]]; then
    mkdir -p "$APP/Contents/Helpers"
    cp "$HELPER" "$APP/Contents/Helpers/tez-native-host"
    codesign --force --sign - "$APP/Contents/Helpers/tez-native-host"
else
    # A UI-only rebuild must not silently keep a stale helper from an older build.
    rm -f "$APP/Contents/Helpers/tez-native-host"
fi
if [[ "$WITH_CORE" == 1 ]]; then
    node "$ROOT/package-core.mjs" --copy "$APP"
else
    node "$ROOT/package-core.mjs" --remove "$APP"
fi
if [[ "$WITH_SERVICE" == 1 ]]; then
    node "$ROOT/package-service.mjs" --copy "$APP"
else
    node "$ROOT/package-service.mjs" --remove "$APP"
fi
swift "$ROOT/Resources/generate-icon.swift" "$ROOT/.build/Tez.iconset"
iconutil -c icns "$ROOT/.build/Tez.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$WITH_CORE" == 1 ]]; then
    node "$ROOT/package-core.mjs" --verify "$APP"
fi
if [[ "$WITH_SERVICE" == 1 ]]; then
    node "$ROOT/package-service.mjs" --verify "$APP"
fi
if [[ "$STANDALONE" == 1 ]]; then
    printf '\nStandalone Tez built without launching or registering it:\n%s\n' "$APP"
else
    printf '\nPreview built without launching or registering it:\n%s\n' "$APP"
fi
