import { Analytics } from "@vercel/analytics/next";
import type { Metadata } from "next";
import { Inter, M_PLUS_1_Code } from "next/font/google";
import { notFound } from "next/navigation";
import { hasLocale, NextIntlClientProvider } from "next-intl";
import { getTranslations, setRequestLocale } from "next-intl/server";
import type { ReactNode } from "react";
import { routing } from "@/i18n/routing";
import { languageAlternates, localePath, ogAlternateLocales, ogLocale } from "@/i18n/urls";
import "./globals.css";

// 道具の話をするページなので、字面は素直なゴシックにする。
// Konechi は丸ゴシックだが、あちらはキャラの輪郭に合わせたもの
const sans = Inter({
  display: "swap",
  subsets: ["latin"],
  variable: "--font-sans",
});

/* 見出しと注記の書体。図面の文字なので字幅の揃った日本語等幅を当てる。
   日本語は unicode-range で百件以上に割れるので preload は切る。
   切らないと使わない範囲まで先読みして 1ページで 1.5MB 取りに行く */
const display = M_PLUS_1_Code({
  display: "swap",
  preload: false,
  subsets: ["latin"],
  variable: "--font-display",
  weight: ["400", "700"],
});

type LayoutProps = {
  children: ReactNode;
  params: Promise<{ locale: string }>;
};

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export async function generateMetadata({
  params,
}: Omit<LayoutProps, "children">): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "meta" });

  return {
    description: t("description"),
    icons: { icon: "/icon.png" },
    alternates: {
      canonical: localePath(locale),
      languages: languageAlternates(),
    },
    metadataBase: new URL("https://gocci.kkweb.io"),
    // 画像は opengraph-image.tsx が出す。ここで指定すると、そちらが使われなくなる
    openGraph: {
      locale: ogLocale(locale),
      alternateLocale: ogAlternateLocales(locale),
      description: t("description"),
      url: localePath(locale),
      title: t("title"),
      type: "website",
    },
    title: t("title"),
    twitter: {
      card: "summary_large_image",
      description: t("description"),
      title: t("title"),
    },
  };
}

export default async function Layout({ children, params }: LayoutProps) {
  const { locale } = await params;

  if (!hasLocale(routing.locales, locale)) {
    notFound();
  }
  setRequestLocale(locale);

  return (
    <html className={`${sans.variable} ${display.variable}`} lang={locale}>
      <body className="font-[family-name:var(--font-sans)] antialiased">
        <NextIntlClientProvider>{children}</NextIntlClientProvider>
        <Analytics />
      </body>
    </html>
  );
}
