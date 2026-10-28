#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache -swift-version 6 -parse-as-library \
    Sources/TezNative/BackendWire.swift \
    Sources/TezNative/BackendSnapshot.swift \
    Sources/TezNative/NativeRecoveryChannel.swift \
    Sources/TezNative/BackendConnection.swift \
    Tests/BackendConnectionCheck.swift -o .build/backend-connection-check
.build/backend-connection-check
