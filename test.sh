#!/bin/bash
# 計算の間違いを捕まえる試験。実機には触らない。
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

swiftc -O -target arm64-apple-macos14.0 -o build/tests Sources/Paths.swift Sources/DSStore.swift Tools/tests/main.swift
./build/tests
