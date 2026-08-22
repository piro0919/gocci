import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { getTranslations } from "next-intl/server";
import { routing } from "@/i18n/routing";

// 共有されたときに出る1枚。アイコンだけを渡していたので、
// 1.91:1 の枠に正方形が置かれて余白だらけになっていた
export const size = { height: 630, width: 1200 };
export const contentType = "image/png";
export const alt = "Gocci";

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

type Props = { params: Promise<{ locale: string }> };

export default async function Image({ params }: Props) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "hero" });

  // 日本語は Inter に無いので、使う字だけに絞ったものを同梱している。
  // 文言を足すときは lp/assets/README.md に従って作り直す
  const [font, icon] = await Promise.all([
    readFile(join(process.cwd(), "assets/NotoSansJP-Bold-subset.otf")),
    readFile(join(process.cwd(), "public/icon.png")),
  ]);
  const iconSrc = `data:image/png;base64,${icon.toString("base64")}`;
  const lines = t("title").split("\n");

  return new ImageResponse(
    (
      <div
        style={{
          alignItems: "center",
          backgroundColor: "#0d2c52",
          // 本体と同じ方眼。細い目と太い目を重ねる
          backgroundImage:
            "linear-gradient(rgba(232,241,248,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(232,241,248,0.05) 1px, transparent 1px), linear-gradient(rgba(232,241,248,0.09) 1px, transparent 1px), linear-gradient(90deg, rgba(232,241,248,0.09) 1px, transparent 1px)",
          backgroundSize: "24px 24px, 24px 24px, 120px 120px, 120px 120px",
          display: "flex",
          gap: 40,
          height: "100%",
          padding: "0 64px",
          width: "100%",
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", flex: 1 }}>
          <div
            style={{
              alignSelf: "flex-start",
              border: "1px solid rgba(232,241,248,0.22)",
              color: "#9dbad2",
              display: "flex",
              fontSize: 24,
              marginBottom: 36,
              padding: "8px 22px",
            }}
          >
            macOS 14+ / Apple silicon
          </div>

          {lines.map((line) => (
            <div
              key={line}
              style={{ color: "#e8f1f8", display: "flex", fontSize: 54, lineHeight: 1.3 }}
            >
              {line}
            </div>
          ))}

          <div style={{ color: "#9dbad2", display: "flex", fontSize: 26, marginTop: 28 }}>
            {t("tagline")}
          </div>
        </div>

        <img
          alt=""
          height={300}
          src={iconSrc}
          style={{ borderRadius: 67 }}
          width={300}
        />
      </div>
    ),
    {
      ...size,
      fonts: [{ data: font, name: "Noto Sans JP", style: "normal", weight: 700 }],
    },
  );
}
