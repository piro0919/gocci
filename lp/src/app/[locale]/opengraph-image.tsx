import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { routing } from "@/i18n/routing";

// 共有されたときに出る1枚。実際に出るのは kk-web の一覧で176px、
// X のカードで500px 前後なので、その大きさで残るものだけを置く
export const size = { height: 630, width: 1200 };
export const contentType = "image/png";
export const alt = "Gocci";

export function generateStaticParams(): { locale: string }[] {
  return routing.locales.map((locale) => ({ locale }));
}

const FIELD = "#0d2c52";
const PAPER = "#e8f1f8";
const TEAL = "#29c7c0";
const MUTED = "#9dbad2";

type Props = { params: Promise<{ locale: string }> };

export default async function Image({ params }: Props) {
  const { locale } = await params;
  const isJa = locale === "ja";

  /* 見出しの書体はサイトと同じ M PLUS 1 Code。使う文字だけに絞ったものを
     同梱している。文言を変えたら assets/README.md の手順で作り直す */
  const [font, icon] = await Promise.all([
    readFile(join(process.cwd(), "assets/MPLUS1Code-700-subset.ttf")),
    readFile(join(process.cwd(), "public/icon.png")),
  ]);
  const iconSrc = `data:image/png;base64,${icon.toString("base64")}`;

  return new ImageResponse(
    (
      <div
        style={{
          alignItems: "center",
          backgroundColor: FIELD,
          // 本体と同じ方眼
          backgroundImage:
            "linear-gradient(rgba(232,241,248,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(232,241,248,0.05) 1px, transparent 1px), linear-gradient(rgba(232,241,248,0.09) 1px, transparent 1px), linear-gradient(90deg, rgba(232,241,248,0.09) 1px, transparent 1px)",
          backgroundSize: "24px 24px, 24px 24px, 120px 120px, 120px 120px",
          color: PAPER,
          display: "flex",
          gap: 60,
          height: "100%",
          padding: "0 84px",
          width: "100%",
        }}
      >
        <img alt="" height={300} src={iconSrc} width={300} />
        <div style={{ display: "flex", flexDirection: "column" }}>
          <div style={{ color: MUTED, display: "flex", fontSize: 24 }}>
            macOS 14+ / Apple silicon
          </div>
          <div
            style={{
              display: "flex",
              fontSize: 132,
              letterSpacing: -4,
              marginTop: 14,
            }}
          >
            Gocci
          </div>
          <div style={{ color: TEAL, display: "flex", fontSize: 36, marginTop: 16 }}>
            {isJa
              ? "Google ドライブを Finder に繋ぐ。"
              : "Google Drive in Finder."}
          </div>
        </div>
      </div>
    ),
    {
      ...size,
      fonts: [{ data: font, name: "M PLUS 1 Code", style: "normal", weight: 700 }],
    },
  );
}
