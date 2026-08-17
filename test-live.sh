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
REMOTE="gdrive"
WORK="gocci-live-test"

# 見える場所は置き場所によって変わる。外付けに置くと、内蔵の
# `~/Library/CloudStorage` には何も現れない。決め打ちにすると外付けの構成で
# 試験そのものが走らない（2026-08-17）
find_drive() {
  local candidate
  for candidate in /Volumes/*/.CloudStorage/Data/Gocci-* \
    "$HOME/Library/CloudStorage/Gocci-"*; do
    [ -d "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}
DRIVE="$(find_drive 2>/dev/null)"
DRIVE="${DRIVE:-$HOME/Library/CloudStorage/Gocci-Gocci}"

# 落ちてきた分が何ブロック占めているか。0 なら手元には無い
blocks() { /usr/bin/stat -f "%b" "$1" 2>/dev/null || echo 0; }

# Finder に板が残っていると、以降の操作が `-15260 ビジー状態です` で通らなくなる
dismiss_dialogs() {
  osascript >/dev/null 2>&1 <<'AS'
tell application "System Events" to tell process "Finder"
  repeat with w in windows
    try
      if subrole of w is "AXDialog" then click button 1 of w
    end try
  end repeat
end tell
AS
}

# Finder の右クリックの品を押す。読むだけでは `fetchPartialContents` の側しか
# 通らず、丸ごと落とす道は試されない（2026-08-17 に取りこぼした）。
#
# 一度送っただけでは開かないことがある。焦点は行ではなく一覧全体に当たっていて、
# そこへの `AXShowMenu` は開いたり開かなかったりする。開くまで繰り返す。
# ここを一発勝負にしていたせいで、動いている機能を「落ちた」と報告した（同日）
finder_action() {
  local path="$1" item="$2"
  dismiss_dialogs
  osascript >/dev/null 2>&1 <<AS
tell application "Finder"
  activate
  reveal POSIX file "$path" as alias
end tell
delay 3
tell application "System Events" to tell process "Finder"
  set el to value of attribute "AXFocusedUIElement"
  repeat 5 times
    perform action "AXShowMenu" of el
    delay 2
    try
      click menu item "$item" of menu 1 of el
      return
    end try
    delay 2
  end repeat
end tell
AS
}

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

# 上げ終わっていない子を抱えたままフォルダごと消さない。
# `rm -rf` で消すと、宙に浮いた子がドライブの一番上に付け直される
# （2026-08-17 実測。hello.txt と sample.png が根に現れた）。
# 中を先に空にして、上げ終わるのを待ってから、フォルダを外す
cleanup() {
  echo ""
  echo "片付け"

  if [ -d "$DRIVE/$WORK" ]; then
    rm -f "$DRIVE/$WORK"/* 2>/dev/null
    wait_for 60 "中身が上がりきるの" \
      sh -c "[ -z \"\$('$RCLONE' ls '$REMOTE:$WORK' --no-traverse 2>/dev/null)\" ]"
    rmdir "$DRIVE/$WORK" 2>/dev/null
    sleep 5
  fi

  "$RCLONE" purge "$REMOTE:$WORK" >/dev/null 2>&1

  # 根に落ちてしまったものが無いか、毎回見る。あれば黙って直さず言う
  local strays
  strays=$(ls "$DRIVE" 2>/dev/null | grep -E "^(hello\.txt|sample\.png)$" || true)
  if [ -n "$strays" ]; then
    echo "  ドライブの一番上に残りました。消してください:"
    echo "$strays" | sed 's/^/    /'
  fi
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
# 作ったものと動いているものが食い違ったまま2時間以上検証したことがある。
# その間の結論は全部無効だった（2026-08-17）
FP="Contents/PlugIns/GocciFileProvider.appex/Contents/MacOS/GocciFileProvider"
if [ -f "Gocci.app/$FP" ]; then
  check "作ったものが入っている" \
    "$(shasum -a 256 "Gocci.app/$FP" 2>/dev/null | awk '{print $1}')" \
    "$(shasum -a 256 "$APP/$FP" 2>/dev/null | awk '{print $1}')"
fi
running=$(pgrep -lf GocciFileProvider | awk '{print $2}' | head -1)
if [ -n "$running" ]; then
  check "入っているものが動いている" \
    "$(shasum -a 256 "$running" 2>/dev/null | awk '{print $1}')" \
    "$(shasum -a 256 "$APP/$FP" 2>/dev/null | awk '{print $1}')"
fi

check "Finder から見える" "$([ -d "$DRIVE" ] && echo yes || echo no)" "yes"
echo "  見える場所: $DRIVE"

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
echo "削除"

# 上げ終わる前に消しにいかない。macOS はアップロード中のものを消そうとすると、
# その仕事を保留したまま先へ進まない（2026-08-16 実測。150秒待っても届かなかった）
wait_for 90 "上げ終わるの" \
  sh -c "'$RCLONE' ls '$REMOTE:$WORK' --no-traverse 2>/dev/null | grep -q 'hello.txt'"
sleep 10

rm "$DRIVE/$WORK/hello.txt" 2>/dev/null
if wait_for 150 "Drive から消えるの" \
  sh -c "! '$RCLONE' ls '$REMOTE:$WORK' --no-traverse 2>/dev/null | grep -q 'hello.txt'"; then
  pass "消すと Drive からも消える"
else
  fail "消すと Drive からも消える"
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
echo "丸ごと落とす"

# ここは読むだけでは通らない。読むと `fetchPartialContents` が呼ばれ、
# `fetchContents` は一度も試されないまま「直った」ことになる（2026-08-17 実測）
if [ -e "$DRIVE/$WORK/sample.png" ]; then
  check "落とす前は手元に無い" "$(blocks "$DRIVE/$WORK/sample.png")" "0"

  finder_action "$DRIVE/$WORK/sample.png" "今すぐダウンロード"
  if wait_for 90 "落ちてくるの" \
    sh -c "[ \"\$(/usr/bin/stat -f '%b' '$DRIVE/$WORK/sample.png' 2>/dev/null)\" != 0 ]"; then
    pass "「今すぐダウンロード」で落ちてくる"

    original=$("$RCLONE" md5sum "$REMOTE:$WORK/sample.png" 2>/dev/null | awk '{print $1}')
    check "落ちてきた中身が一致する" "$(md5 -q "$DRIVE/$WORK/sample.png" 2>/dev/null)" "$original"

    # 眼目はここ。落ちた分が置き場所のディスクに入っていること
    where=$(df "$DRIVE/$WORK/sample.png" 2>/dev/null | awk 'NR==2 {print $NF}')
    root=$(df / 2>/dev/null | awk 'NR==2 {print $NF}')
    if [ "$where" = "$root" ]; then
      echo "  ・置き場所は起動ディスク（$where）"
    else
      pass "落ちた分は $where に入る"
    fi
  else
    fail "「今すぐダウンロード」で落ちてくる"
  fi

  echo ""
  echo "手元から消す"

  finder_action "$DRIVE/$WORK/sample.png" "ダウンロードを削除"
  if wait_for 60 "手元から消えるの" \
    sh -c "[ \"\$(/usr/bin/stat -f '%b' '$DRIVE/$WORK/sample.png' 2>/dev/null)\" = 0 ]"; then
    pass "「ダウンロードを削除」で手元から消える"
  else
    fail "「ダウンロードを削除」で手元から消える"
  fi
  check "消しても見えたままになる" \
    "$([ -e "$DRIVE/$WORK/sample.png" ] && echo yes || echo no)" "yes"
fi

echo ""
echo "読み出し"

if [ -e "$DRIVE/$WORK/sample.png" ]; then
  original=$("$RCLONE" md5sum "$REMOTE:$WORK/sample.png" 2>/dev/null | awk '{print $1}')
  through=$(md5 -q "$DRIVE/$WORK/sample.png" 2>/dev/null)
  check "中身が一致する" "$through" "$original"
fi

# 板を出したまま終わると、次に走らせたときに何も押せない
dismiss_dialogs


echo ""
if [ "$failures" = "0" ]; then
  echo "全部通りました"
else
  echo "$failures 件落ちました"
  exit 1
fi
