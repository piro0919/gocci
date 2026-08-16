import Image from "next/image";
import { getTranslations, setRequestLocale } from "next-intl/server";
import type { ReactNode } from "react";
import { LanguageSwitch } from "./language-switch";

const REPO = "https://github.com/piro0919/gocci";
const DOWNLOAD = `${REPO}/releases/latest`;

type PageProps = {
  params: Promise<{ locale: string }>;
};

type Item = { body: string; title: string };

function Section({
  children,
  id,
  title,
  lead,
  tone = "plain",
}: {
  children: ReactNode;
  id?: string;
  lead?: string;
  title: string;
  tone?: "panel" | "plain";
}) {
  return (
    <section className={`${tone === "panel" ? "panel" : ""} px-6 py-24`} id={id}>
      <div className="mx-auto max-w-5xl">
        <h2 className="font-bold text-3xl tracking-tight sm:text-4xl">{title}</h2>
        {lead ? (
          <p className="mt-4 max-w-2xl text-lg text-muted leading-relaxed">{lead}</p>
        ) : null}
        <div className="mt-12">{children}</div>
      </div>
    </section>
  );
}

export default async function Page({ params }: PageProps) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations();
  const problems = t.raw("problem.items") as Item[];
  const features = t.raw("features.items") as Item[];
  const points = t.raw("how.points") as string[];
  const steps = t.raw("install.steps") as Item[];

  return (
    <>
      {/* 見出し。帯で塗らず、奥に光を置く。アイコンは絵として大きく扱う */}
      <header className="aurora relative overflow-hidden px-6 pt-8 pb-28">
        <div className="mx-auto flex max-w-5xl items-center justify-between">
          <span className="font-bold text-lg tracking-tight">Gocci</span>
          <LanguageSwitch />
        </div>

        <div className="mx-auto mt-20 flex max-w-5xl flex-col items-center gap-14 lg:flex-row">
          <div className="flex-1 text-center lg:text-left">
            <span className="inline-block rounded-full border border-line bg-surface/60 px-3 py-1 text-muted text-sm">
              {t("hero.badge")}
            </span>
            <h1 className="mt-7 whitespace-pre-line font-bold text-4xl leading-[1.15] tracking-tight sm:text-6xl">
              {t("hero.title")}
            </h1>
            <p className="mt-6 max-w-xl text-lg text-muted leading-relaxed">
              {t("hero.tagline")}
            </p>

            <div className="mt-10 flex flex-wrap items-center justify-center gap-4 lg:justify-start">
              <a
                className="lift cursor-pointer rounded-full bg-teal px-8 py-3.5 font-bold text-ink hover:bg-teal/90"
                href={DOWNLOAD}
              >
                {t("hero.download")}
              </a>
              <a
                className="lift cursor-pointer rounded-full border border-line px-8 py-3.5 font-bold hover:bg-surface"
                href={REPO}
              >
                {t("hero.source")}
              </a>
            </div>
            <p className="mt-5 text-muted text-sm">{t("hero.note")}</p>
          </div>

          <Image
            alt="Gocci"
            className="w-44 rounded-[22%] shadow-[0_30px_80px_-20px_rgba(41,199,192,0.45)] sm:w-60"
            height={512}
            priority={true}
            src="/icon.png"
            width={512}
          />
        </div>
      </header>

      {/* なぜ作ったか。既にある道具で駄目だった理由を並べる */}
      <Section lead={t("problem.lead")} title={t("problem.title")} tone="panel">
        <div className="grid gap-5 sm:grid-cols-3">
          {problems.map((item) => (
            <div className="card card-glow lift rounded-2xl p-6" key={item.title}>
              <h3 className="font-bold text-lg">{item.title}</h3>
              <p className="mt-3 text-muted leading-relaxed">{item.body}</p>
            </div>
          ))}
        </div>
      </Section>

      {/* できること。数が多いので3列に落とし、1枚あたりを小さくする */}
      <Section title={t("features.title")}>
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((item) => (
            <div className="card card-glow lift rounded-2xl p-6" key={item.title}>
              <h3 className="font-bold text-lg leading-snug">{item.title}</h3>
              <p className="mt-3 text-muted text-sm leading-relaxed">{item.body}</p>
            </div>
          ))}
        </div>
      </Section>

      {/* 実際の画面。メニューと設定の2枚だけ */}
      <Section lead={t("screens.lead")} title={t("screens.title")} tone="panel">
        <div className="grid items-start gap-10 sm:grid-cols-5">
          {/* 設定は情報が多いので広く取る。メニューは実寸のまま置いて滲ませない */}
          <figure className="sm:col-span-3">
            <Image
              alt={t("screens.settings")}
              className="w-full rounded-xl border border-line shadow-2xl"
              height={870}
              src="/shot-settings.png"
              width={1252}
            />
            <figcaption className="mt-4 text-muted text-sm">{t("screens.settings")}</figcaption>
          </figure>
          <figure className="sm:col-span-2">
            <Image
              alt={t("screens.menu")}
              className="w-full max-w-64.5 rounded-xl border border-line shadow-2xl"
              height={152}
              src="/shot-menu.png"
              width={258}
            />
            <figcaption className="mt-4 text-muted text-sm">{t("screens.menu")}</figcaption>
          </figure>
        </div>
      </Section>

      {/* 仕組み。隠さずに書く */}
      <Section title={t("how.title")}>
        <p className="max-w-3xl text-lg text-muted leading-relaxed">{t("how.body")}</p>
        <ul className="mt-10 space-y-4">
          {points.map((point) => (
            <li className="flex gap-4 text-muted" key={point}>
              <span aria-hidden="true" className="text-teal">
                —
              </span>
              <span>{point}</span>
            </li>
          ))}
        </ul>
      </Section>

      <Section title={t("install.title")} tone="panel">
        <ol className="grid gap-5 sm:grid-cols-3">
          {steps.map((step, index) => (
            <li className="card card-glow rounded-2xl p-6" key={step.title}>
              <span className="font-bold text-sm text-teal">
                {String(index + 1).padStart(2, "0")}
              </span>
              <h3 className="mt-2 font-bold text-lg">{step.title}</h3>
              <p className="mt-3 text-muted leading-relaxed">{step.body}</p>
            </li>
          ))}
        </ol>

        <div className="mt-12">
          <a
            className="lift inline-block cursor-pointer rounded-full bg-teal px-8 py-3.5 font-bold text-ink hover:bg-teal/90"
            href={DOWNLOAD}
          >
            {t("hero.download")}
          </a>
        </div>
      </Section>

      <footer className="border-line border-t px-6 py-12">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 text-muted text-sm">
          <span>{t("footer.built")}</span>
          <a className="cursor-pointer font-bold hover:text-text" href={REPO}>
            {t("footer.source")}
          </a>
        </div>
      </footer>
    </>
  );
}
