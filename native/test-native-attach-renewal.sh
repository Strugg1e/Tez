#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache -swift-version 6 -parse-as-library \
    Sources/TezNative/BackendWire.swift \
    Sources/TezNative/BackendSnapshot.swift \
    Sources/TezNative/NativeRecoveryChannel.swift \
    Sources/TezNative/BackendConnection.swift \
    Tests/NativeAttachRenewalCheck.swift -o .build/native-attach-renewal-check
if [[ "$#" != 1 ]]; then
    printf 'Usage: bash test-native-attach-renewal.sh ABSOLUTE_BUNDLED_HELPER\n' >&2
    exit 2
fi
.build/native-attach-renewal-check "$1"
