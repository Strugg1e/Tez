#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache -swift-version 6 -parse-as-library \
    Sources/TezNative/BackendWire.swift \
    Sources/TezNative/BackendSnapshot.swift \
    Sources/TezNative/NativeRecoveryChannel.swift \
    Sources/TezNative/BackendConnection.swift \
    Tests/NativeIsolatedConnectionCheck.swift -o .build/native-isolated-connection-check
if [[ "${1:-}" == "--compile-only" && "$#" == 1 ]]; then
    exit 0
fi
if [[ "$#" != 2 ]]; then
    printf 'Usage: bash test-native-isolated-connection.sh BUNDLED_HELPER NEW_ISOLATED_ROOT\n' >&2
    exit 2
fi
.build/native-isolated-connection-check "$@"
