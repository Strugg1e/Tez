#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -swift-version 6 -module-cache-path .build/module-cache -parse-as-library Sources/TezNative/BackendWire.swift Tests/BackendWireCheck.swift -o .build/backend-wire-check
.build/backend-wire-check "$@"
