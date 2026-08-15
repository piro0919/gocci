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
SPARKLE_VERSION="2.9.5"

# 自動更新に Sparkle を使う。framework は大きいのでリポジトリに置かず、
# 無ければ取ってくる（Vendor/ は git の管理外）
if [ ! -d "Vendor/Sparkle.framework" ]; then
  echo "Sparkle $SPARKLE_VERSION を取得します…"
  mkdir -p Vendor
  TMP="$(mktemp -d)"
  curl -sL -o "$TMP/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar xf "$TMP/sparkle.tar.xz" -C "$TMP"
  cp -R "$TMP/Sparkle.framework" Vendor/
  cp -R "$TMP/bin" Vendor/
  rm -rf "$TMP"
fi

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

cp Vendor/rclone "$APP/Contents/MacOS/rclone"
cp -R Vendor/Sparkle.framework "$APP/Contents/Frameworks/"

swiftc \
  -parse-as-library \
  -target "$TARGET" \
  -O \
  -F Vendor \
  -framework AppKit \
  -framework ServiceManagement \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Gocci" \
  Sources/Paths.swift Sources/Localization.swift Sources/Settings.swift Sources/Mount.swift \
  Sources/RcloneConfig.swift Sources/Rc.swift Sources/Evict.swift Sources/Finisher.swift \
  Sources/Mark.swift Sources/Icon.swift Sources/Updater.swift Sources/BadgeIndex.swift \
  Sources/DSStore.swift Sources/FinderView.swift \
  Sources/RcEndpoint.swift Sources/RcClient.swift Sources/Provider.swift \
  Sources/SettingsWindow.swift Sources/main.swift

# Finder に実体の有無を出す拡張。アプリの中に PlugIns として入れる。
# 利用者がシステム設定で有効にして初めて働く
EXT="$APP/Contents/PlugIns/GocciFinderSync.appex"
mkdir -p "$EXT/Contents/MacOS"

# 拡張は main を持たない。入口は OS 側の _NSExtensionMain
swiftc \
  -parse-as-library \
  -module-name GocciFinderSync \
  -target "$TARGET" \
  -O \
  -framework AppKit \
  -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/Contents/MacOS/GocciFinderSync" \
  Sources/Paths.swift Sources/FinderSync/main.swift

cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GocciFinderSync</string>
  <key>CFBundleDisplayName</key><string>Gocci</string>
  <key>CFBundleExecutable</key><string>GocciFinderSync</string>
  <key>CFBundleIdentifier</key><string>io.kkweb.gocci.FinderSync</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
    <key>NSExtensionPrincipalClass</key><string>GocciFinderSync.GocciFinderSync</string>
    <key>NSExtensionAttributes</key><dict/>
  </dict>
</dict>
</plist>
PLIST

# Drive を「クラウドのフォルダ」として見せる拡張。
# 中身の受け渡しは rclone に頼み、マウントは張らない
FP="$APP/Contents/PlugIns/GocciFileProvider.appex"
mkdir -p "$FP/Contents/MacOS"

swiftc \
  -parse-as-library \
  -module-name GocciFileProvider \
  -target "$TARGET" \
  -O \
  -framework FileProvider \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$FP/Contents/MacOS/GocciFileProvider" \
  Sources/RcEndpoint.swift Sources/RcClient.swift Sources/FileProvider/main.swift

cat > "$FP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GocciFileProvider</string>
  <key>CFBundleDisplayName</key><string>Gocci</string>
  <key>CFBundleExecutable</key><string>GocciFileProvider</string>
  <key>CFBundleIdentifier</key><string>io.kkweb.gocci.FileProvider</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
    <key>NSExtensionPrincipalClass</key><string>GocciFileProvider.GocciFileProvider</string>
    <key>NSExtensionFileProviderSupportsEnumeration</key><true/>
  </dict>
</dict>
</plist>
PLIST

# アプリ本体のアイコン。元絵があれば .icns を組み立てる。
# 無くてもビルドは通る（Finder では白紙のままになる）
if [ -f Resources/gocci-icon.png ]; then
  # 生成した絵は角丸を自分で描いてきて、その外側が黒い。macOS 26 は透過の無い正方形を
  # 求めるので、抜くのではなく背景で埋める。元の絵には手を入れない
  mkdir -p build
  swiftc -O -target "$TARGET" -framework AppKit \
    -o build/icon Sources/Mark.swift Tools/icon/main.swift
  ./build/icon square Resources/gocci-icon.png build/gocci-icon-square.png >/dev/null

  ICONSET="build/Gocci.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size build/gocci-icon-square.png \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/gocci-icon-square.png \
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

  <!-- 自動更新（Sparkle）。確認は起動時に1回だけ行い、見つかったときだけ画面を出す。
       この2つを false にしておかないと、初回起動で「自動で確認していいか」を尋ねる画面が出る -->
  <key>SUFeedURL</key><string>https://github.com/piro0919/gocci/releases/latest/download/appcast.xml</string>
  <!-- 更新の署名を確かめる公開鍵。対になる秘密鍵はログインキーチェーンにあり、これを失うと更新を配れなくなる。
       Konechi と同じ鍵。Sparkle の鍵はアプリ単位ではなくキーチェーン単位で作られる -->
  <key>SUPublicEDKey</key><string>qYQq1iewXYNDhhkJJak1nXUXmFkZ0jAF6Gr+pjB4Bxo=</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
</dict>
</plist>
PLIST

# 同梱した実行ファイルと framework は中から署名する。先にアプリを署名すると、
# 後から中身が変わって壊れる
codesign --force --sign - "$APP/Contents/MacOS/rclone"
codesign --force --sign - --entitlements Sources/FinderSync/GocciFinderSync.entitlements "$EXT"
codesign --force --sign - --entitlements Sources/FileProvider/GocciFileProvider.entitlements "$FP"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"

echo "できました: $(pwd)/$APP"
