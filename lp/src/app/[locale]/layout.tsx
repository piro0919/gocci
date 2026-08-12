import type { Metadata } from "next";
import { Inter } from "next/font/google";
import { NextIntlClientProvider, hasLocale } from "next-intl";
import { getTranslations, setRequestLocale } from "next-intl/server";
import { notFound } from "next/navigation";
import type { ReactNode } from "react";
import { routing } from "@/i18n/routing";
import "./globals.css";

// 道具の話をするページなので、字面は素直なゴシックにする。
// Konechi は丸ゴシックだが、あちらはキャラの輪郭に合わせたもの
const sans = Inter({
  display: "swap",
  subsets: ["latin"],
  variable: "--font-sans",
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
    metadataBase: new URL("https://gocci.kkweb.io"),
    openGraph: {
      description: t("description"),
      images: ["/icon.png"],
      title: t("title"),
      type: "website",
    },
    title: t("title"),
    twitter: {
      card: "summary",
      description: t("description"),
      images: ["/icon.png"],
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
    <html className={sans.variable} lang={locale}>
      <body className="font-[family-name:var(--font-sans)] antialiased">
        <NextIntlClientProvider>{children}</NextIntlClientProvider>
      </body>
    </html>
  );
}
