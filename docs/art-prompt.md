# 絵の生成に使う指示

そのまま貼り付けて使う。作るのは3枚。**アプリのアイコン1枚**と、**メニューバーの印2枚**。

描くのは**渦巻きの殻を背負ったヤドカリ**。別の場所にあった容れ物を自分のものとして背負う形が、
外のストレージを自分のディスクとして持つ話と重なる。

メニューバーの印は、以前は `Sources/Mark.swift` で図形として描いていた。今は塗りと中抜きの
2枚を読み込んで単色として扱う。接続中・未接続・待ち・不具合の4状態のうち、待ちは塗りを
薄くしたもの、不具合は中抜きにバッジを重ねたもので、どちらも `Mark.swift` が作る。

18pt でヤドカリとは読めない。丸に鋏が2本付いた印、という程度に落ちる。これは大きさの
制約で、どの絵で作っても同じになる。

## アプリのアイコン（`Resources/gocci-icon.png`）

```text
Draw an app icon for a small macOS menu bar utility called "Gocci". The app
mounts Google Drive as a disk on the Mac, so cloud storage can be used like an
external drive.

Shape: a full square. Do NOT round the corners and do NOT leave any
transparency — macOS rounds the corners itself. The background must reach all
four corners.

Background: a smooth diagonal gradient from a bright teal in the upper left to
a deep navy blue in the lower right. Nothing else in the background — no
scenery, no stars, no sparkles, no texture.

Subject: a small hermit crab carrying its spiral shell, seen from the side,
facing left, centered. It is a calm, friendly, simplified character — not
realistic, not detailed, not scary.

- The shell is the main shape: a smooth spiral seen from the side, a clean
  logarithmic curve with about two and a half turns, drawn as one solid white
  shape with a single darker line marking the spiral groove. It is large — the
  shell alone is roughly two thirds of the whole subject.
- The crab itself is small and simple: a rounded body peeking out of the shell
  opening at the lower left, two short stubby claws, and two eyes. It has
  exactly two claws and nothing else — no extra legs, no thin pale limbs.
- The eyes matter most. They sit directly on the body, NOT on stalks, and each
  eye is a solid dark navy dot on the white body, like a friendly cartoon
  character. Blank white eyes without pupils are wrong and look frightening.
- The body is white with only very soft shading, in the style of a modern flat
  app icon. The two dark marks in the whole subject are the eyes; the spiral
  groove is a single light grey line.
- The silhouette must stay readable when shrunk very small: keep the shell's
  spiral wide and open, and keep the claws thick and stubby, never thin lines.

Composition: the crab occupies about 65% of the icon width and is centered,
sitting very slightly above the middle. It floats on the plain background.

Do not include: eyes on stalks, blank pupil-less eyes, more than two limbs,
thin finger-like limbs, text, letters, logos, the Google Drive triangle logo,
arrows, sand, water, bubbles, a beach, ground, a horizon line, a cast shadow,
a cloud, a disk or ellipse, or any other object.
```

> Galopen が青紫のグラデーションなので、こちらは青緑から藍に振ってある。
> 生き物やキャラを避ける決まりは無い。Konechi にキャラが居るのと同じ線で置いてよい。

**目で失敗する。** 1回目（2026-08-15）は、全部を白と指定したせいで瞳の無い白い球が
柄の先に付き、手足も5本の細長い白で出て、はっきり怖い絵になった。目は濃い色の点を
体に直接置く、手足は2本まで、と明示してある。ここだけは毎回確認する。

そのほか外しやすいのは、細部を描き込みすぎることと、砂浜や波を勝手に添えること。
どちらも 18pt で潰れるか、風景として読まれる。駄目なら
"flat vector icon, minimal detail, plain background, no scenery" を足して出し直す。
文字やロゴを足してくることも多い。

## メニューバーの印（`Resources/mark-solid.png` と `Resources/mark-outline.png`）

2枚要る。塗りと中抜き。待ちは塗りを薄くしたもの、不具合は中抜きにバッジを重ねたもので、
どちらもこちら側で作る。

**白黒で作ってもらう。** メニューバーの印は単色として扱わせる（`isTemplate = true`）ので、
色は使わない。黒の濃さだけが形になる。

### 1枚目・塗り

```text
Draw a single flat black silhouette of a hermit crab carrying a spiral shell,
seen from the side, facing left, centered on a pure white square background.

This is a macOS menu bar icon. It will be displayed at 18 pixels tall, so it
must be extremely simple and bold — closer to a road sign than to a drawing.

- Pure black shape on pure white. No grey, no gradient, no shading, no texture.
- The shell is a large plain round shape filling most of the icon. It has no
  spiral groove and no bumps along its edge — a clean, simple round shell.
- Exactly TWO claws stick out at the lower left, and NOTHING else. No walking
  legs. No feelers. No antennae. Six thin legs is wrong. Two thick claws only.
- Each claw is a short, fat, rounded blob, as thick as it is long. The gap
  between the two claws is wide and obvious.
- Nothing anywhere in the shape may be thinner than 1/8 of the icon width.
  Measure the thinnest part: if it is thinner than that, make it fatter.
- One single connected shape, with a smooth simple outer edge.
- Leave a small even white margin around the shape.

Do not include: walking legs, antennae, eyes, a spiral groove, bumps on the
shell edge, text, letters, colour, grey fills, a shadow, or any second object.
```

### 2枚目・中抜き

同じ形の輪郭だけ。1枚目を出したあと、続けてこう頼む。

```text
Now draw the exact same hermit crab shape as an outline only: the same
silhouette, hollow inside, drawn as a uniform thick black stroke tracing the
outer edge, white inside, on the same pure white square background.

The stroke is uniform and very thick — roughly 1/8 of the icon width — with
rounded joins. Only the outer edge is drawn: no inner lines, no spiral groove,
no divisions between the shell, the body and the claws.

Keep the two claws fat and far apart, so the white gap between them stays open
and does not close up.

Do not include: walking legs, antennae, eyes, text, letters, colour, grey
fills, or any second object.
```

正方形で 512×512 以上。地は白でよい。透過は要らない。

**脚を足してくる。** 1回目（2026-08-15）は「細い部分なし・鋏2本」と書いたのに細い脚が
5本付いてきた。18pt で潰れるだけでなく、中抜きも作れなくなる。上の指示にある「1/8 より
細い部分を作らない」「脚は描かない」を消さないこと。

### 取り込み方

生成した2枚は、そのままでは使えない。

- 地の白はぴったり 255 ではない。24 未満を 0 に落としてから伸ばさないと、薄い灰色の
  四角が印として残る
- 2枚は**同じ枠**で切る。別々に切ると、状態が変わるたびに印がわずかに動く
- 黒に透明度だけを持たせた PNG にして `Resources/mark-solid.png` と
  `Resources/mark-outline.png` に置く。色は `Mark.draw` が塗る

## 置き場所

`Resources/gocci-icon.png` に置く。`build.sh` がここから `.icns` を組み立てる。
正方形で 1024×1024 以上、背景は塗りつぶし（透過にしない）。

**角は自分で丸めない。透過も入れない。** macOS 26 は透過を含まない正方形を受け取ると
自分で角丸に切り抜く。少しでも透過があると「角丸を描けていない絵」とみなし、薄い板を
敷いてその上に載せる（Konechi で実測済み）。

生成した絵が角丸を描いて外側を黒く塗ってきた場合も、そのまま置いてよい。`build.sh` が
背景で埋めて透過の無い正方形に直してから `.icns` にする。元の絵には手を入れない。
次に作り直すときは、上の指示に「背景は四隅まで塗る。角を丸めない」を足しておくと手数が減る。

## 確認の仕方

```bash
./icon.sh   # メニューバーの印を実寸で並べた見本を作って開く
```

`docs/icon-preview.png` に 18pt・36pt・72pt の並びが出る。18pt で形が残っているかだけ見る。
