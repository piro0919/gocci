#!/bin/bash
# アイコンを作り直して開く。Resources/gocci-icon.png と docs/icon-preview.png ができる。
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build docs Resources

swiftc -O -target arm64-apple-macos14.0 -framework AppKit \
  -o build/icon Sources/Mark.swift Tools/icon/main.swift

./build/icon Resources docs
open docs/icon-preview.png Resources/gocci-icon.png
