#!/bin/bash
# メニューバーの印の見本を作り直して開く。docs/icon-preview.png ができる。
# 絵がまだ無ければ、仮のアプリアイコンも作る。
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build docs Resources

swiftc -O -target arm64-apple-macos14.0 -framework AppKit \
  -o build/icon Sources/Mark.swift Tools/icon/main.swift

./build/icon preview docs

if [ ! -f Resources/gocci-icon.png ]; then
  ./build/icon placeholder Resources/gocci-icon.png
fi

open docs/icon-preview.png
