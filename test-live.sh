#!/bin/bash
# 実機を動かす試験。実際に Drive へ繋ぎ、読み書きし、落ちてこないことまで見る。
#
#   ./test-live.sh
#
# Drive の根に `gocci-live-test` を作って使い、終わりに消す。ほかの場所には書かない。
# 普段の繋ぎはそのまま使う（File Provider のドメインは1つしか持てないため）。
#
# ここで見ているのは、コードを読んでも分からなかったことばかり。
# 「フォルダを開いても落ちてこない」は、実際に開いて数えるまで確かめようがない。
set -uo pipefail

cd "$(dirname "$0")"

APP="/Applications/Gocci.app"
RCLONE="$APP/Contents/MacOS/rclone"
DRIVE="$HOME/Library/CloudStorage/Gocci-Gocci"
REMOTE="gdrive"
WORK="gocci-live-test"

failures=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; failures=$((failures + 1)); }

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else
    fail "$1"
    echo "      期待: $3"
    echo "      実際: $2"
  fi
}

# 条件が満たされるまで待つ。Drive との往復があるので、その場では終わらない
wait_for() {
  local seconds="$1" description="$2"
  shift 2
  local waited=0
  while [ "$waited" -lt "$seconds" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "      （$description を $seconds 秒待ちました）"
  return 1
}

cleanup() {
  echo ""
  echo "片付け"
  rm -rf "$DRIVE/$WORK" 2>/dev/null
  sleep 5
  "$RCLONE" purge "$REMOTE:$WORK" >/dev/null 2>&1
  echo "  終わり"
}
trap cleanup EXIT

echo "実機の試験を始めます。Drive の $WORK を使います"

if [ ! -x "$RCLONE" ]; then
  echo "/Applications/Gocci.app がありません。先に差し替えてください" >&2
  exit 1
fi

# 前の試験の残りがあると数が合わない
"$RCLONE" purge "$REMOTE:$WORK" >/dev/null 2>&1

echo ""
echo "繋がっているか"

if [ ! -d "$DRIVE" ]; then
  echo "  繋がっていないので起動します"
  open -a "$APP"
  wait_for 90 "繋がるの" test -d "$DRIVE"
fi
check "Finder から見える" "$([ -d "$DRIVE" ] && echo yes || echo no)" "yes"

count=$(ls "$DRIVE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -gt 0 ]; then pass "一覧が取れる（$count 件）"; else fail "一覧が取れる"; fi

echo ""
echo "書き込み"

mkdir "$DRIVE/$WORK" 2>/dev/null
if wait_for 60 "フォルダが Drive に届くの" \
  sh -c "'$RCLONE' lsd '$REMOTE:' --no-traverse 2>/dev/null | grep -q '$WORK'"; then
  pass "作ったフォルダが Drive に届く"
else
  fail "作ったフォルダが Drive に届く"
fi

echo "gocci live test" > "$DRIVE/$WORK/hello.txt" 2>/dev/null
if wait_for 90 "ファイルが Drive に届くの" \
  sh -c "'$RCLONE' ls '$REMOTE:$WORK' --no-traverse 2>/dev/null | grep -q 'hello.txt'"; then
  pass "書いたファイルが Drive に届く"
  # 名前を渡し損ねると、macOS の一時ファイルの番号がそのまま Drive の名前になる
  check "名前が保たれる" \
    "$("$RCLONE" cat "$REMOTE:$WORK/hello.txt" 2>/dev/null)" "gocci live test"
else
  fail "書いたファイルが Drive に届く"
fi

echo ""
echo "開いても落ちてこない"

# Gocci を通さずに Drive へ画像を置き、そのフォルダを開いて、実体が増えないことを見る。
# ここが Gocci の眼目。旧方式では、開いた瞬間に中身が丸ごと落ちてきた
SAMPLE="$(mktemp -d)/sample.png"
sips -s format png --resampleWidth 800 \
  /System/Library/CoreServices/DefaultDesktop.heic --out "$SAMPLE" >/dev/null 2>&1
if [ -f "$SAMPLE" ]; then
  "$RCLONE" copy "$SAMPLE" "$REMOTE:$WORK/" >/dev/null 2>&1
  wait_for 60 "画像が見えるの" test -e "$DRIVE/$WORK/sample.png"

  before=$(find "$DRIVE/$WORK" -type f -size +1k 2>/dev/null | wc -l | tr -d ' ')
  open "$DRIVE/$WORK" >/dev/null 2>&1
  sleep 25
  after=$(find "$DRIVE/$WORK" -type f -size +1k 2>/dev/null | wc -l | tr -d ' ')
  check "フォルダを開いても実体が増えない" "$after" "$before"
else
  echo "  （見本の画像を作れなかったので飛ばします）"
fi

echo ""
echo "読み出し"

if [ -e "$DRIVE/$WORK/sample.png" ]; then
  original=$("$RCLONE" md5sum "$REMOTE:$WORK/sample.png" 2>/dev/null | awk '{print $1}')
  through=$(md5 -q "$DRIVE/$WORK/sample.png" 2>/dev/null)
  check "中身が一致する" "$through" "$original"
fi

echo ""
echo "削除"

# 消えるまでは書き込みより待つ。macOS は消す仕事を溜めてからまとめて渡してくる
rm "$DRIVE/$WORK/hello.txt" 2>/dev/null
if wait_for 150 "Drive から消えるの" \
  sh -c "! '$RCLONE' ls '$REMOTE:$WORK' --no-traverse 2>/dev/null | grep -q 'hello.txt'"; then
  pass "消すと Drive からも消える"
else
  fail "消すと Drive からも消える"
fi

echo ""
if [ "$failures" = "0" ]; then
  echo "全部通りました"
else
  echo "$failures 件落ちました"
  exit 1
fi
