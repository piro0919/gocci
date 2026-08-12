#!/bin/bash
# Gocci をビルドして Gocci.app を作る。Xcode 本体は不要（Command Line Tools のみで動く）。
set -euo pipefail

cd "$(dirname "$0")"

APP="Gocci.app"
TARGET="arm64-apple-macos14.0"
# リリース時は release.sh から渡される。手元のビルドでは 0.0.0 のままでよい
VERSION="${GOCCI_VERSION:-0.0.0}"

# NFS マウントは rclone 側が Experimental と明記している機能なので、検証した版で固定する。
# 上げるときは手元でマウント・読み書き・アンマウントを確かめてから
RCLONE_VERSION="1.75.0"

# rclone は同梱する。初回起動時に取りに行く方式は採らない（SPEC.md「rclone は同梱する」）。
# バイナリ自体はリポジトリに置かず、無ければここで取ってくる
if [ ! -x "Vendor/rclone" ]; then
  echo "rclone $RCLONE_VERSION を取得します…"
  mkdir -p Vendor
  TMP="$(mktemp -d)"
  curl -sL -o "$TMP/rclone.zip" \
    "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-osx-arm64.zip"
  unzip -q "$TMP/rclone.zip" -d "$TMP"
  cp "$TMP/rclone-v${RCLONE_VERSION}-osx-arm64/rclone" Vendor/rclone
  chmod +x Vendor/rclone
  rm -rf "$TMP"
fi

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS"

cp Vendor/rclone "$APP/Contents/MacOS/rclone"

swiftc \
  -parse-as-library \
  -target "$TARGET" \
  -O \
  -framework AppKit \
  -framework ServiceManagement \
  -o "$APP/Contents/MacOS/Gocci" \
  Sources/Localization.swift Sources/Settings.swift Sources/Mount.swift \
  Sources/Mark.swift Sources/Icon.swift Sources/SettingsWindow.swift Sources/main.swift

# アプリ本体のアイコン。元絵があれば .icns を組み立てる。
# 無くてもビルドは通る（Finder では白紙のままになる）
if [ -f Resources/gocci-icon.png ]; then
  ICONSET="build/Gocci.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/gocci-icon.png \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/gocci-icon.png \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  mkdir -p "$APP/Contents/Resources"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Gocci.icns"
fi

if [ -d Resources ]; then
  mkdir -p "$APP/Contents/Resources"
  cp -R Resources/. "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Gocci</string>
  <key>CFBundleDisplayName</key><string>Gocci</string>
  <key>CFBundleExecutable</key><string>Gocci</string>
  <key>CFBundleIconFile</key><string>Gocci</string>
  <key>CFBundleIdentifier</key><string>io.kkweb.gocci</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Dock とアプリ切替に出さず、メニューバーだけに常駐させる -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 同梱した実行ファイルは中から署名する。先にアプリを署名すると、後から中身が変わって壊れる
codesign --force --sign - "$APP/Contents/MacOS/rclone"
codesign --force --sign - "$APP"

echo "できました: $(pwd)/$APP"
