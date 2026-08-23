# assets

`NotoSansJP-Bold-subset.otf` is the font drawn into the Open Graph card
(`src/app/[locale]/opengraph-image.tsx`). Inter has no Japanese, and the full
Noto Sans JP is 4.6MB, so this is cut down to the characters the card uses.

Any character missing from it silently falls back to a different face, and the
line ends up with two weights mixed into it. So when the hero copy changes,
rebuild the subset — add the new text to `--text` and keep the ASCII range:

```sh
curl -sL -o /tmp/NotoSansJP-Bold.otf \
  https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/JP/NotoSansJP-Bold.otf

pyftsubset /tmp/NotoSansJP-Bold.otf \
  --text="Gocci Google Drive は Finder に。中身は外付けに。ダウンロードした分選んだディスクに入ります macOS Apple silicon 無料オープンソース使いはじめの手順README あります" \
  --unicodes="U+0020-007E,U+00A0-00FF,U+2010-2027,U+3000-303F,U+30FB" \
  --output-file=assets/NotoSansJP-Bold-subset.otf \
  --no-hinting --desubroutinize --layout-features=''
```

Then check both cards render in one weight:

```sh
pnpm dev
open http://localhost:3000/ja/opengraph-image http://localhost:3000/en/opengraph-image
```

`MPLUS1Code-700-subset.ttf` is the face drawn into the card now — the same
display face the site uses for its headings. `NotoSansJP-Bold-subset.otf` is
the previous one and is no longer referenced.

```sh
curl -sL -o /tmp/MPLUS1Code.ttf \
  "https://github.com/google/fonts/raw/main/ofl/mplus1code/MPLUS1Code%5Bwght%5D.ttf"
fonttools varLib.instancer /tmp/MPLUS1Code.ttf wght=700 -o /tmp/MPLUS1Code-700.ttf

pyftsubset /tmp/MPLUS1Code-700.ttf \
  --text="Gocci Google ドライブを Finder に繋ぐ。Google Drive in Finder. macOS 14+ / Apple silicon" \
  --unicodes="U+0020-007E,U+00A0-00FF,U+2010-2027,U+3000-303F,U+30FB" \
  --output-file=assets/MPLUS1Code-700-subset.ttf \
  --no-hinting --desubroutinize --layout-features=''
```
