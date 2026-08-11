# 仕様

壁打ちで決まったことを置く場所。決まっていないものは「保留」に残す。

## なぜ作るのか

CloudMounter で Google Drive を外付けにマウントしていたところ、ドライブの一番上に
自分が作った覚えのないファイルが並び、案件が増えるたびに増え続けていた。

正体は、リンク共有で開いたことのある他人のファイル。ブラウザのマイドライブにも
共有アイテムにも出ないのに、CloudMounter だけがルートに並べていた。CloudMounter 側に
表示を絞る設定は無く（アプリの文言リソースを全部確認した）、Drive 側にも消せる実体が無い。

同じことが何度も起きているので、道具を替える。

## 決まったこと

### 名前

**Gocci（ゴッチ）。**

- 既存の macOS アプリでは見つからなかった。出てきたのはミュージシャン数名、
  大学のキャンパスアプリ goCI（綴りが違う）、活動の止まった Gocci Software の X アカウント、
  アルバニア系の姓
- **Gucci と1文字違いであることは承知のうえで採る。** 商標は指定区分が違えば衝突しにくく、
  ファッションブランドとメニューバーアプリが実際に問題になることはまず無い。
  実害は検索が混ざる程度
- 見送った候補と理由
  - Kumochi — 「雲を持つ」で機能とまっすぐ繋がるが、macOS に Kumo という別アプリ（プロキシ）がある
  - Tsunachi — Twitch に同名の配信者、App Store に語感の近い Tsunagi がある（Konechi のときと同じ理由）
  - Kumobako — 4音でやや長い

名前が機能を説明しないぶん、**アイコンが意味を引き受ける**。

### 対応範囲

**Google Drive 専用。** 他のリモートには広げない。

汎用の rclone GUI は RcloneView、Rclone UI、Rclone Manager、RcloneBrowser と既に4本あり、
公式にも Web GUI がある。後発で対応数を競っても不利。

一方「Google Drive を macFUSE 無しで、好きな場所に、共有アイテム抜きでマウントする」は
空白だった。公式アプリはマウント先を選べず、Mountain Duck も macOS では内蔵ディスク固定、
CloudMounter は共有アイテムが散らかる。

後から他のリモートを足すのは技術的には簡単なので、広げる余地は残る。

### マウント方式

**rclone の NFS 方式（`rclone nfsmount`）。macFUSE は使わない。**

| 方式 | 導入の手間 | マウント先 | 状態 |
| --- | --- | --- | --- |
| NFS（rclone 内蔵） | なし | 自由 | rclone 側が Experimental |
| macFUSE | カーネル拡張＋再起動＋許可 | 自由 | 枯れている |
| File Provider（OS標準） | なし | `~/Library/CloudStorage` 固定の可能性 | 安定 |

導入の手間がゼロで、かつマウント先を自由に選べるのはこの方式だけ。
外付けに置けることが今回の出発点なので、ここは譲れない。

背負うリスク:

- rclone が [serve nfs](https://rclone.org/commands/rclone_serve_nfs/) を **Experimental** と明記している
- NFS サーバーに認証が無い（既定で localhost の乱数ポートに閉じるので実害は小さい）
- 書き込みには `--vfs-cache-mode full` が必須。指定しないと読み取り専用になる

前例として macsh が同じ方式で動いている（Google Drive 非対応なだけ）。

macFUSE を採らなかったのは、ここで脱落する人が多すぎるため。
CloudMounter も Mountain Duck も File Provider に移っているのは、たぶん同じ判断。

### 実装で裏を取った内容（2026-08-12）

rclone v1.75.0 / macOS 26.5.2 / 外付け APFS（USB）で、実際に確かめた。

```bash
rclone nfsmount gdrive: /Volumes/HIKSEMI/GocciTest \
  --vfs-cache-mode full \
  --cache-dir /Volumes/HIKSEMI/.gocci-cache \
  --drive-export-formats webloc \
  --daemon
```

| 確かめたこと | 結果 |
| --- | --- |
| macFUSE 無しでマウント | 可。`localhost:/ on … (nfs, nodev, nosuid, mounted by piro)` |
| 外付けに置ける | 可 |
| 共有アイテムが出ない | 出ない。17フォルダ＋1ファイルで、ブラウザのマイドライブと完全一致 |
| 読み書き | 可。新規作成・追記・削除とも Drive に反映（58バイト、2行とも到達） |
| Google ドキュメント類 | `.webloc` で出る。開くとブラウザで Drive が開く |
| 速度 | フォルダ一覧が 0.6 秒 |

`--drive-shared-with-me` の既定は `false`。**何もしなくても共有アイテムは出ない。**

### client_id は利用者が用意する

rclone が共用している Google の client_id は **2026年中に停止する**（rclone 自身が起動時に警告を出す）。
各自で Google Cloud Console から作る必要がある。

配布するアプリが自前の client_id を同梱する道は採らない。本番公開のアプリが制限付きスコープを
使う場合、ブランド審査に2〜3営業日、データアクセス審査に数週間、第三者によるセキュリティ評価
（CASA）が要ることがある。審査を受けず「テスト」状態のまま出すと、利用者数の上限・警告画面・
リフレッシュトークンの寿命制限が付き、配布物として成り立たない。

**Gocci が持つのは、client_id と client_secret の入力欄と、取得手順の案内まで。**
Cloud Console を開くリンクを添える。凝った案内は作らない。基本は自分が使う前提。

### 最初のバージョンに入れるもの

- Google アカウントを1つ繋ぐ
- マウント先を選ぶ（外付けを選べる）
- メニューバーからマウント / アンマウント
- 共有アイテムを表示しない
- ログイン時に自動マウント。外付けが繋がるまで待つ

### 入れないもの

- 複数アカウント
- 共有ドライブ、共有アイテムの表示切り替え
- キャッシュ容量の管理画面
- Google Drive 以外のサービス
- 同期モード（常にストリーミングのみ）

狙いは、CloudMounter を今日そのまま置き換えられる最小の形。

### メニューを開いたときに出すもの

```text
┌──────────────────────────────────┐
│ ● Google Drive          接続中   │
│   /Volumes/HIKSEMI/GoogleDrive   │
├──────────────────────────────────┤
│   Finder で開く                   │
│   接続を切る                      │
├──────────────────────────────────┤
│   設定…                           │
│   終了                            │
└──────────────────────────────────┘
```

手動の切り替えが要る理由は2つ。**外付けを抜くとき**（繋がったまま抜くとエラーになる）と、
**調子が悪いとき**（切って繋ぎ直せば直る）。普段はログイン時に自動で繋がるので、
このメニューを触るのは外付けを抜き差しするときくらい。

### rclone は同梱する

**アプリに同梱する。初回起動時に取りに行く方式は採らない。**

- **バージョンを握れる。** Experimental と明記された NFS 機能に乗るので、rclone 側の更新で
  挙動が変わると直撃する。こちらが検証したバージョンで固定する
- **初回起動の失敗要因を減らせる。** アドホック署名の警告をシステム設定で乗り越えてもらった
  直後に「rclone のダウンロードに失敗しました」が出るのは体験として最悪

代償は容量。rclone は MIT ライセンスで同梱に支障は無いが、macOS arm64 の配布物が 31MB あり、
Sparkle は差分更新をしないので、更新のたびにその全部を落とし直すことになる。
Konechi の DMG が 9.6MB なのに対し、Gocci は 40MB 前後になる見込み。

### 対応環境

Konechi に倣う。

- **arm64 のみ。** Intel は切る
- **macOS 14 以上**
- `LSUIElement` で Dock に出さず、メニューバーだけに常駐

### 技術スタック

**Swift / SwiftUI。** Xcode は使わず、Command Line Tools の `swiftc` と `build.sh`。

作るものはメニューバー常駐のユーティリティで画面はほとんど無い。ログイン項目への登録、通知、
rclone プロセスの起動と監視、署名、自動更新と、全部 macOS 側の作法に乗る話なのでネイティブが素直。
Tauri だと WebView を1枚抱えることになり、この規模には重い。

### 配布

Konechi と同じ形。

- **アドホック署名**（`codesign --sign -`）。Developer ID も公証も無し
- Apple Developer Program（年 99 USD）には登録しない
- 初回は「開発元未確認」の警告が出る。システム設定から許可してもらう。README に明記する
- 初回は DMG、更新は ZIP
- `release.sh` から `gh release create` で GitHub Releases へ
- LP は `lp/` に同居させて Next.js + next-intl。`gocci.kkweb.io`

Mac App Store には出さない。サンドボックスが必須で、外部プロセス（rclone）の起動と
任意の場所へのマウントが通らない。手元の CloudMounter を調べたところ、直配布版で
App Sandbox の entitlement を持っていなかった。同じ構成を採る。

### 自動更新

Sparkle。鍵はログインキーチェーン。`generate_appcast` で appcast.xml を作る。
Konechi の `release.sh` をそのまま持ってくる。

## 保留

### アイコン

**Galopen 方向。生き物にはしない。**
角丸スクエアにグラデーション背景と白いモチーフ、メニューバーは単色のシルエット。
Konechi のような表情で状態を表すキャラは採らない。

モチーフの候補として **雲 + ディスク**（雲の下半分が円盤）を挙げてある。
塊同士の組み合わせなので 18px でも潰れず、「クラウドをドライブとして扱う」がそのまま形になる。
状態は塗り・中抜き・薄い塗りで出し分け、エラーのときだけ小さいバッジを足す。

配色は Galopen が青紫のグラデーションなので、被らないように振る。

**ただし、見た目は後で決める。**

### 決めていないこと

- 外付けが未接続のときの挙動の細部（待つ間隔、諦めるまでの時間、通知を出すか）
- キャッシュの寿命と上限をどう扱うか
- rclone プロセスが落ちたときの検知と再起動
- 設定画面の項目

## 手元の状態（2026-08-12 時点）

**骨組みが動くところまで来た。** `./build.sh` で `Gocci.app` ができ、メニューバーから
マウントとアンマウントができる。

| 確かめたこと | 結果 |
| --- | --- |
| `build.sh` で Gocci.app ができる | 可。rclone v1.75.0 を同梱して 66MB |
| アプリからマウント | 可。`/Volumes/HIKSEMI/GocciApp` に `localhost:/ … (nfs)` |
| 中身 | 18項目。検証用マウントと同じ |
| 読み書き | 可。作成・読み出し・削除とも通った |
| 終了時のアンマウント | 可。rclone も残らない |
| 起動時の自動マウント | 可。繋がるまで 15 秒ほど（Drive の認証が入るため） |
| 外付けが無いときの待ち | 可。無いディスクを指すと rclone を起動せず待つ |

書いたもの:

| ファイル | 中身 |
| --- | --- |
| `build.sh` | rclone を取ってきて同梱し、`swiftc` で組んでアドホック署名まで |
| `Sources/Mount.swift` | rclone の起動・停止。マウントの有無は statfs で見る |
| `Sources/main.swift` | メニューバーの常駐とメニュー |
| `Sources/SettingsWindow.swift` | マウント先・キャッシュ先・リモート名・言語・ログイン時の起動 |
| `Sources/Settings.swift` | UserDefaults。キャッシュ先の既定はマウント先と同じディスクの直下 |
| `Sources/Localization.swift` | 日本語と英語。Konechi と同じ表形式 |
| `Sources/Icon.swift` | SF Symbols での仮のアイコン |

決めたこと:

- **`--daemon` は付けない。** 付けると rclone がすぐ抜けて、落ちたことを知る手立てが無くなる。
  前面で走らせて子プロセスとして持つ
- **マウントの成否は rclone の出力ではなく statfs で見る。** 知りたいのは実際にマウント表に
  載ったかどうかで、rclone が何を書いたかではない
- **アンマウントは SIGTERM から。** rclone は自分で外して終わる。umount を先に叩くと、
  書き戻しの途中で足元を外すことになる。外れなければ umount、それでも駄目なら
  `diskutil unmount force` の順で降りる
- **キャッシュ先の既定はマウント先と同じディスクの直下。** 内蔵の空きが乏しいから外付けに
  マウントしているので、既定でも内蔵には置かない
- **外付けを待つのは 30 分まで。** 見回りは5秒ごとで、加えて macOS の
  「ディスクが繋がった」通知でも起こす。挿した瞬間に繋がるように。
  待っている間もメニューから手で繋げる。通知は出さない
- **Sparkle はまだ入れていない。** 署名鍵を作らないと `SUPublicEDKey` が埋められない。
  `release.sh` と一緒に、配布を始める段で入れる

環境:

- **rclone は導入済み。** `brew install rclone` で v1.75.0。同梱するバイナリは `build.sh` が
  同じ v1.75.0 を `downloads.rclone.org` から取ってきて `Vendor/rclone` に置く（git の管理外）
- **`gdrive` リモートは設定済み。** `~/.config/rclone/rclone.conf`。
  ただし **rclone 共用の client_id のまま**なので、起動のたびに 2026年中に停止する旨の警告が出る。
  自前の client_id への差し替えはまだ
- **検証用のマウントが生きている。** `/Volumes/HIKSEMI/GocciTest`（手で張ったほう）。
  外すときは `umount /Volumes/HIKSEMI/GocciTest`。キャッシュは `/Volumes/HIKSEMI/.gocci-cache`
- **アプリの動作確認に使った設定が残っている。** マウント先は `/Volumes/HIKSEMI/GocciApp`。
  本番の置き換えでは CloudMounter と同じ場所に振り直す
- 置き換え対象の CloudMounter は `/Volumes/HIKSEMI/.CloudStorage/CloudMounter-KouheiKawamura` に
  マウントされたまま。並行して動かして見比べてから外す

### 参照する既存リポジトリ

同じ人が作った macOS メニューバーアプリ。作法はここに倣う。

| リポジトリ | 何を参照するか |
| --- | --- |
| `/Users/piro/Repository/konechi` | Swift の骨組み、`build.sh`、`release.sh`、Sparkle、SPEC.md の書式。一番近い |
| `/Users/piro/Repository/galopen` | アプリアイコンとトレイアイコンの作り、README の見せ方、LP |
| `/Users/piro/Repository/mac-classic-player` | アンマウント周りの扱い |

### 次にやること

1. **rclone が落ちたときの扱い。** 今は「エラー」と出して止まるだけ。再起動するかを決める
2. **アイコン。** 雲＋ディスクの案を形にする。今は SF Symbols の仮
3. **Sparkle と `release.sh`。** 署名鍵を作るところから。Konechi の `release.sh` を持ってくる
4. **README と LP。**

## 調べた結果、採らなかったもの

- **Google 公式のドライブアプリ** — マウント先を選べず、内蔵ディスク固定。内蔵の空きが 42GB しか無い
- **Mountain Duck** — macOS で使えるのは Integrated モードだけで、ドキュメントに
  「Custom mount location is not honoured in Integrated connect mode but always in
  `~/Library/CloudStorage`」と明記がある。マウント先もキャッシュ先も内蔵固定
- **CloudMounter を使い続ける** — 表示を絞る設定が無い。アプリの文言リソースを全部確認した結果、
  あるのはマウント種別、ネットワークドライブ化、他アカウントへの表示、キャッシュフォルダ・寿命・
  更新間隔、デスクトップ表示、サイドバー名、ドラッグ&ドロップ時のコピー、暗号化だけだった
