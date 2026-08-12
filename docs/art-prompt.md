# 絵の生成に使う指示

そのまま貼り付けて使う。作るのは**アプリのアイコン1枚だけ**。

メニューバーの印は絵にしない。18pt では絵が潰れること、接続中・未接続・待ち・不具合の
4状態を同じ形で描き分ける必要があることから、`Sources/Mark.swift` で図形として描いている。
生成した絵と形が揃うよう、下の指示にも同じ形（雲が円盤に載っている）を書いてある。

今 `Resources/gocci-icon.png` にあるのは、その図形をそのまま大きくした仮の絵。
生成したものが手に入ったら差し替える。

## アプリのアイコン（`Resources/gocci-icon.png`）

```text
Draw an app icon for a small macOS menu bar utility called "Gocci". The app
mounts Google Drive as a disk on the Mac, so cloud storage can be used like an
external drive.

Shape: a rounded square, the standard macOS app icon shape, filled edge to edge.

Background: a smooth diagonal gradient from a bright teal in the upper left to
a deep navy blue in the lower right. Nothing else in the background — no
scenery, no stars, no sparkles, no texture.

Subject: a simple white cloud resting on a white disk, centered.

- The cloud is a soft rounded cloud made of three merged bumps, the tallest in
  the middle. It is one solid shape, no separated puffs.
- The disk below it is a flat wide ellipse, as if a drive platter seen from
  slightly above. It is clearly wider than the cloud, so it reads as a plate
  the cloud is sitting on.
- There is a small visible gap between the bottom of the cloud and the top of
  the disk. They must not merge into one silhouette, or it reads as a hat.
- Both are pure white with only very soft shading, in the same style as a
  modern flat app icon. No outlines.

Composition: the cloud and disk together occupy about 60% of the icon width and
sit slightly above the center.

Do not include: text, letters, logos, the Google Drive triangle logo, arrows,
shadows cast on the background, or any other object.
```

> Galopen が青紫のグラデーションなので、こちらは青緑から藍に振ってある。
> Konechi のようなキャラは置かない。生き物にはしないと決めてある。

## 置き場所

`Resources/gocci-icon.png` に置く。`build.sh` がここから `.icns` を組み立てる。
正方形で 1024×1024 以上、背景は塗りつぶし（透過にしない）。

## 確認の仕方

```bash
./icon.sh   # メニューバーの印を実寸で並べた見本を作って開く
```

`docs/icon-preview.png` に 18pt・36pt・72pt の並びが出る。18pt で形が残っているかだけ見る。
