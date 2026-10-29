#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache -swift-version 6 -parse-as-library \
    Sources/TezNative/BackendWire.swift \
    Sources/TezNative/BackendSnapshot.swift \
    Sources/TezNative/NativeCoreLifecycle.swift \
    Sources/TezNative/NativeRecoveryChannel.swift \
    Sources/TezNative/BackendConnection.swift \
    Sources/TezNative/TezStyle.swift \
    Sources/TezNative/NativeProfileEditor.swift \
    Tests/ProfileEditorCheck.swift -o .build/profile-editor-check
.build/profile-editor-check
