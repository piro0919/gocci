#!/bin/bash
# 実機を動かす試験。実際にマウントし、rclone を落とし、復帰するところまで見る。
#
#   ./test-live.sh
#
# 普段使っているマウント先には触らない。検証用の場所を起動引数で渡す。
# macOS の設定は `-キー 値` の起動引数で一時的に上書きできるので、保存された設定は変わらない。
#
# 走らせている間、Finder に「サーバ接続が中断されました」が数回出る。
# 開いているマウントが消えるたびに macOS が出すもので、この試験では意図的に落としている。
set -uo pipefail

cd "$(dirname "$0")"

APP="$(pwd)/Gocci.app/Contents/MacOS/Gocci"
MOUNT="/Volumes/HIKSEMI/GocciTest2"
CACHE="/Volumes/HIKSEMI/.gocci-test-cache"
REMOTE="gdrive"
STATE="$HOME/Library/Containers/io.kkweb.gocci.FinderSync/Data/Library/Application Support"

failures=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; failures=$((failures + 1)); }

# 条件が満たされるまで待つ。満たされたら 0、時間切れなら 1
wait_for() {
  local seconds="$1" description="$2"
  shift 2
  local waited=0
  while [ "$waited" -lt "$seconds" ]; do
    if "$@"; then return 0; fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "      （$description を $seconds 秒待って諦めた）"
  return 1
}

mounted() { mount | grep -q " $MOUNT "; }
# 抜け殻が残っている間も「マウント在り」は真になる。張り直しを見るときは
# 新しい rclone が立ったかで判断する
new_rclone() { local old="$1" now; now="$(rclone_pid)"; [ -n "$now" ] && [ "$now" != "$old" ]; }
# 張り直しの判定。アプリは抜け殻を外してから数秒置くので、その間 rclone は居ない。
# 見るべきは「新しい rclone が立って、実際に中身が読めるか」
healthy_again() {
  local old="$1"
  new_rclone "$old" && mounted && ls "$MOUNT" >/dev/null 2>&1
}
rclone_pid() { pgrep -f "Gocci.app/Contents/MacOS/rclone .* $MOUNT" | head -1; }
rclone_running() { [ -n "$(rclone_pid)" ]; }
app_running() { pgrep -f "Gocci.app/Contents/MacOS/Gocci" >/dev/null; }

start_app() {
  nohup "$APP" -mountPoint "$MOUNT" -cacheDir "$CACHE" -remote "$REMOTE" \
    -fetchWholeFile -bool YES -cacheMaxAge "1h" -cacheMaxSize "5G" >/dev/null 2>&1 &
  sleep 2
}

stop_app() {
  pkill -f "Gocci.app/Contents/MacOS/Gocci" 2>/dev/null
  sleep 3
}

cleanup() {
  echo ""
  echo "片付け"
  stop_app
  pkill -f "Gocci.app/Contents/MacOS/rclone .* $MOUNT" 2>/dev/null
  sleep 3
  if mounted; then /sbin/umount -f "$MOUNT" >/dev/null 2>&1; fi
  rmdir "$MOUNT" 2>/dev/null
  rm -rf "$CACHE"
  echo "  終わり"
}
trap cleanup EXIT

echo "実機の試験を始めます。マウント先: $MOUNT"
echo "（普段のマウントには触りません。この間 Finder に切断の画面が数回出ます）"

# 前提の確認
if [ ! -x "$APP" ]; then
  echo "Gocci.app がありません。先に ./build.sh を実行してください" >&2
  exit 1
fi
if [ ! -d "/Volumes/HIKSEMI" ]; then
  echo "外付け HIKSEMI が繋がっていません" >&2
  exit 1
fi

# 普段のアプリは一旦止める。同じ控えの場所を取り合うため
stop_app

echo ""
echo "1. マウントできる"
start_app
if wait_for 150 "マウント" mounted && rclone_running; then
  pass "マウントされ、rclone が自分の子として動いている"
else
  fail "マウントされない"
  exit 1
fi

echo ""
echo "2. 読み書きできる"
count=$(ls "$MOUNT" 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -gt 0 ] && pass "一覧が返る（$count 件）" || fail "一覧が返らない"

probe="$MOUNT/gocci-live-test.txt"
if echo "テスト $(date +%s)" > "$probe" 2>/dev/null && [ -s "$probe" ]; then
  pass "書き込める"
  rm -f "$probe" && pass "消せる"
else
  fail "書き込めない"
fi

echo ""
echo "3. rclone が落ちたら繋ぎ直す"
before=$(rclone_pid)
kill -9 "$before" 2>/dev/null
if wait_for 180 "繋ぎ直し" healthy_again "$before"; then
  pass "新しい rclone で張り直し、中身も読める（$before → $(rclone_pid)）"
else
  fail "繋ぎ直せない"
fi

echo ""
echo "4. 応答しなくなったら落として張り直す"
before=$(rclone_pid)
kill -STOP "$before" 2>/dev/null
if wait_for 240 "張り直し" healthy_again "$before"; then
  pass "止まった rclone を落として張り直した"
else
  fail "止まったまま放置された"
  kill -9 "$before" 2>/dev/null
fi

echo ""
echo "5. 抜け殻のマウントを引き継がない"
pid=$(rclone_pid)
if [ -z "$pid" ] || ! mounted; then
  echo "      （前提を整え直す）"
  start_app
  wait_for 150 "マウント" rclone_running >/dev/null
  pid=$(rclone_pid)
fi
# アプリを片付けの余地なく落とす。SIGTERM だと自分でアンマウントしてしまい、
# 抜け殻を作れない（そう直したので）
pkill -9 -f "Gocci.app/Contents/MacOS/Gocci" 2>/dev/null
sleep 5
kill -9 "$pid" 2>/dev/null
sleep 3
if mounted && ! rclone_running; then
  pass "抜け殻を作れた（マウント表に残り、rclone は不在）"
  start_app
  if wait_for 180 "張り直し" bash -c '[ -n "$(pgrep -f "Gocci.app/Contents/MacOS/rclone .* '"$MOUNT"'")" ] && ls "'"$MOUNT"'" >/dev/null 2>&1'; then
    pass "外して張り直し、中身が読める"
  else
    fail "張り直せない"
  fi
else
  fail "抜け殻ができなかった（この試験は成立せず）"
  start_app
  wait_for 180 "マウント" rclone_running >/dev/null
fi

echo ""
echo "6. 手元から削除できる"
# 根にファイルが無いことがあるので、フォルダを1つ覗いて探す
target=$(cd "$MOUNT" 2>/dev/null && find . -maxdepth 1 -type f -size +1k 2>/dev/null | head -1 | sed 's|^\./||')
if [ -z "$target" ]; then
  folder=$(ls "$MOUNT" | head -1)
  file=$(ls "$MOUNT/$folder" 2>/dev/null | head -1)
  [ -n "$file" ] && [ -f "$MOUNT/$folder/$file" ] && target="$folder/$file"
fi
if [ -n "$target" ] && [ -f "$MOUNT/$target" ]; then
  dd if="$MOUNT/$target" of=/dev/null bs=1m count=1 >/dev/null 2>&1
  sleep 8
  if [ -e "$CACHE/vfs/$REMOTE"*"/$target" ] || ls "$CACHE/vfs/$REMOTE"*/"$target" >/dev/null 2>&1; then
    pass "読んだファイルがキャッシュに載った"
    python3 -c "import json,sys; json.dump(['$MOUNT/$target'], open('$STATE/evict.json','w'))"
    sleep 8
    if ls "$CACHE/vfs/$REMOTE"*/"$target" >/dev/null 2>&1; then
      fail "キャッシュから消えていない"
    else
      pass "キャッシュから消えた"
      [ -f "$MOUNT/$target" ] && pass "Drive 側のファイルは無事" || fail "Drive 側が消えた"
    fi
  else
    fail "キャッシュに載らなかった"
  fi
else
  echo "      （根に読めるファイルが無いので飛ばす）"
fi

echo ""
echo "6.5 設定が rclone に渡っている"
args=$(pgrep -lf "Gocci.app/Contents/MacOS/rclone .* $MOUNT" | head -1)
echo "$args" | grep -q -- "--vfs-cache-mode full" && pass "書き込みできる設定で動いている" || fail "--vfs-cache-mode が無い"
echo "$args" | grep -q -- "--cache-dir $CACHE" && pass "キャッシュ先が渡っている" || fail "キャッシュ先が違う"
echo "$args" | grep -q -- "--vfs-cache-max-age 1h" && pass "寿命が渡っている" || fail "寿命が渡っていない"
echo "$args" | grep -q -- "--vfs-read-ahead" && fail "先読みが渡っている（渡してはいけない）" || pass "先読みは渡していない"

echo ""
echo "6.6 眺めただけでは大きいファイルを落とさない"
before=$(du -sk "$CACHE" 2>/dev/null | cut -f1)
big=$(cd "$MOUNT" && find . -maxdepth 2 -type f -size +200M 2>/dev/null | head -1 | sed 's|^\./||')
if [ -n "$big" ]; then
  # 一覧と、先頭を少し読むところまで（Finder のサムネイル相当）
  ls -la "$MOUNT/$(dirname "$big")" >/dev/null 2>&1
  dd if="$MOUNT/$big" of=/dev/null bs=1m count=4 >/dev/null 2>&1
  sleep 25
  after=$(du -sk "$CACHE" 2>/dev/null | cut -f1)
  grown=$(( (after - before) / 1024 ))
  [ "$grown" -lt 200 ] && pass "覗いただけでは丸ごと落ちない（+${grown}MB）" \
    || fail "覗いただけで ${grown}MB 落ちた"

  echo ""
  echo "6.7 使ったファイルは最後まで取りにいく"
  dd if="$MOUNT/$big" of=/dev/null bs=1m count=40 >/dev/null 2>&1
  if wait_for 240 "取得の完了" bash -c '
     python3 - "$0" "$1" <<PYEOF
import json,os,sys
p=os.path.expanduser("~/Library/Containers/io.kkweb.gocci.FinderSync/Data/Library/Application Support/state.json")
try: d=json.load(open(p))["progress"]
except Exception: sys.exit(1)
sys.exit(0 if d.get(sys.argv[1], 0) >= 100 else 1)
PYEOF' "" "$big"; then
    pass "40MB 読んで止めたら、最後まで落ちた"
  else
    fail "続きを取りにいっていない"
  fi
else
  echo "      （200MB 以上のファイルが無いので飛ばす）"
fi

echo ""
echo "7. 終了したらアンマウントされる"
osascript -e 'tell application id "io.kkweb.gocci" to quit' >/dev/null 2>&1 || stop_app
if wait_for 60 "後片付け" bash -c '! mount | grep -q " '"$MOUNT"' " && [ -z "$(pgrep -f "Gocci.app/Contents/MacOS/rclone .* '"$MOUNT"'")" ]'; then
  pass "外れた"
  pass "rclone も残らない"
else
  mounted && fail "マウントが残っている" || pass "外れた"
  rclone_running && fail "rclone が残っている" || pass "rclone も残らない"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "全部通りました"
else
  echo "$failures 件落ちました"
fi
exit "$failures"
