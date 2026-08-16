#!/bin/bash
# 組み上がったものを確かめる試験。実機には触らない。繋ぎもしないし、Drive も設定も変えない。
#
#   ./test.sh
#
# 見ているのは、手元で実際に踏んだ落とし穴ばかり。どれも「ビルドは通るのに動かない」種類で、
# コードを読んでも分からず、動かして初めて気づいたもの。
set -euo pipefail

cd "$(dirname "$0")"

APP="Gocci.app"
FP="$APP/Contents/PlugIns/GocciFileProvider.appex"
failures=0

check() {
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1"
    echo "      期待: $3"
    echo "      実際: $2"
    failures=$((failures + 1))
  fi
}

if [ ! -d "$APP" ]; then
  echo "Gocci.app がありません。先に ./build.sh を実行してください" >&2
  exit 1
fi

echo ""
echo "拡張の組み立て"

# 拡張が入っていないと、Drive はどこにも現れない
check "拡張が入っている" "$([ -d "$FP" ] && echo yes || echo no)" "yes"

# `com.apple.fileprovider-nonui` でないと、File Provider として登録されない
point=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" \
  "$FP/Contents/Info.plist" 2>/dev/null || echo "")
check "File Provider として名乗っている" "$point" "com.apple.fileprovider-nonui"

# 入口の名前を間違えると、起こされても何も起きない
class=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPrincipalClass" \
  "$FP/Contents/Info.plist" 2>/dev/null || echo "")
check "入口の名前が合っている" "$class" "GocciFileProvider.GocciFileProvider"

echo ""
echo "拡張の署名"

# サンドボックスが無いと、一覧に載らず有効にできない（Finder 拡張で踏んだ）
entitlements=$(codesign -d --entitlements - --xml "$FP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || echo "")
check "サンドボックスが付いている" \
  "$(echo "$entitlements" | grep -c "com.apple.security.app-sandbox")" "1"

# rclone の口へ HTTP で訊く。これが無いと、一覧も中身も取れない
check "外へ繋ぐ許しがある" \
  "$(echo "$entitlements" | grep -c "com.apple.security.network.client")" "1"

check "署名が通っている" "$(codesign -v "$FP" 2>&1 | wc -l | tr -d ' ')" "0"

echo ""
echo "同梱したもの"

check "rclone が入っている" "$([ -x "$APP/Contents/MacOS/rclone" ] && echo yes || echo no)" "yes"
# `rcd` に `--rc` を渡すと弾かれる。引数の組み立てを間違えると起動直後に落ちる
check "rcd が --rc を拒む" \
  "$("$APP/Contents/MacOS/rclone" rcd --rc --rc-addr 127.0.0.1:0 2>&1 | grep -c "Don't supply --rc")" "1"

echo ""
if [ "$failures" = "0" ]; then
  echo "全部通りました"
else
  echo "$failures 件落ちました"
  exit 1
fi
