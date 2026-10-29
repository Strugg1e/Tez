#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
sources=()
for source in Sources/TezNative/*.swift; do
    [[ "$source" == */TezNativeApp.swift ]] || sources+=("$source")
done
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path .build/module-cache \
    -swift-version 6 -parse-as-library "${sources[@]}" Tests/NativeLayoutCheck.swift -o .build/profile-search-check
log=$(mktemp)
trap 'rm -f "$log"' EXIT
.build/profile-search-check --profile-search-check >"$log" 2>&1 || { cat "$log"; exit 1; }
cat "$log"
if grep -Fq 'Application performed a reentrant operation in its NSTableView delegate' "$log"; then
    echo 'FAIL: profile search triggered AppKit table reentrancy' >&2
    exit 1
fi
