#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
sources=()
for source in Sources/TezNative/*.swift; do
    [[ "$source" == */TezNativeApp.swift ]] || sources+=("$source")
done
swiftc -swift-version 6 -parse-as-library "${sources[@]}" Tests/MaterialHierarchyCheck.swift -o .build/material-hierarchy-check
.build/material-hierarchy-check
