import { getTranslations, setRequestLocale } from "next-intl/server";
import Image from "next/image";
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
}: {
  children: ReactNode;
  id?: string;
  lead?: string;
  title: string;
}) {
  return (
    <section className="px-6 py-20" id={id}>
      <div className="mx-auto max-w-5xl">
        <h2 className="font-bold text-3xl tracking-tight sm:text-4xl">
          {title}
        </h2>
        {lead ? (
          <p className="mt-4 max-w-2xl text-lg text-ink/70 leading-relaxed">
            {lead}
          </p>
        ) : null}
        <div className="mt-10">{children}</div>
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
      {/* 見出し。アイコンと同じグラデーションを敷いて、名前と絵を結び付ける */}
      <header className="brand px-6 pt-8 pb-24 text-white">
        <div className="mx-auto flex max-w-5xl items-center justify-between">
          <span className="font-bold text-lg tracking-tight">Gocci</span>
          <LanguageSwitch />
        </div>

        <div className="mx-auto mt-16 flex max-w-5xl flex-col items-center gap-12 lg:flex-row lg:items-center">
          <div className="flex-1 text-center lg:text-left">
            <span className="inline-block rounded-full border border-white/40 px-3 py-1 text-sm">
              {t("hero.badge")}
            </span>
            <h1 className="mt-6 font-bold text-4xl leading-tight tracking-tight sm:text-5xl">
              {t("hero.title")}
            </h1>
            <p className="mt-5 text-lg text-white/85 leading-relaxed">
              {t("hero.tagline")}
            </p>

            <div className="mt-9 flex flex-wrap items-center justify-center gap-4 lg:justify-start">
              <a
                className="rounded-full bg-white px-8 py-3.5 font-bold text-navy-deep transition hover:bg-white/90"
                href={DOWNLOAD}
              >
                {t("hero.download")}
              </a>
              <a
                className="rounded-full border border-white/50 px-8 py-3.5 font-bold transition hover:bg-white/10"
                href={REPO}
              >
                {t("hero.source")}
              </a>
            </div>
            <p className="mt-4 text-sm text-white/60">{t("hero.note")}</p>
          </div>

          <Image
            alt="Gocci"
            className="w-40 rounded-[22%] shadow-2xl sm:w-56"
            height={512}
            priority={true}
            src="/icon.png"
            width={512}
          />
        </div>
      </header>

      {/* なぜ作ったか。既にある道具で駄目だった理由を並べる */}
      <div className="grid-bg">
        <Section lead={t("problem.lead")} title={t("problem.title")}>
          <div className="grid gap-5 sm:grid-cols-3">
            {problems.map((item) => (
              <div
                className="rounded-2xl border border-line bg-white p-6"
                key={item.title}
              >
                <h3 className="font-bold text-lg">{item.title}</h3>
                <p className="mt-3 text-ink/70 leading-relaxed">{item.body}</p>
              </div>
            ))}
          </div>
        </Section>
      </div>

      <Section title={t("features.title")}>
        <div className="grid gap-5 sm:grid-cols-2">
          {features.map((item) => (
            <div
              className="rounded-2xl border border-line bg-white p-7"
              key={item.title}
            >
              <h3 className="font-bold text-xl">{item.title}</h3>
              <p className="mt-3 text-ink/70 leading-relaxed">{item.body}</p>
            </div>
          ))}
        </div>
      </Section>

      {/* 仕組み。隠さずに書く。NFS で動くことは利点でもあり、制約でもある */}
      <div className="brand text-white">
        <Section title={t("how.title")}>
          <p className="max-w-3xl text-lg text-white/85 leading-relaxed">
            {t("how.body")}
          </p>
          <ul className="mt-8 space-y-3">
            {points.map((point) => (
              <li className="flex gap-3 text-white/85" key={point}>
                <span aria-hidden="true">—</span>
                <span>{point}</span>
              </li>
            ))}
          </ul>
        </Section>
      </div>

      <Section title={t("install.title")}>
        <ol className="grid gap-5 sm:grid-cols-3">
          {steps.map((step, index) => (
            <li
              className="rounded-2xl border border-line bg-white p-6"
              key={step.title}
            >
              <span className="font-bold text-teal-deep text-sm">
                {String(index + 1).padStart(2, "0")}
              </span>
              <h3 className="mt-2 font-bold text-lg">{step.title}</h3>
              <p className="mt-3 text-ink/70 leading-relaxed">{step.body}</p>
            </li>
          ))}
        </ol>

        <div className="mt-10">
          <a
            className="inline-block rounded-full bg-navy px-8 py-3.5 font-bold text-white transition hover:bg-navy-deep"
            href={DOWNLOAD}
          >
            {t("hero.download")}
          </a>
        </div>
      </Section>

      <footer className="border-line border-t px-6 py-10">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 text-ink/60 text-sm">
          <span>{t("footer.built")}</span>
          <a className="font-bold hover:text-ink" href={REPO}>
            {t("footer.source")}
          </a>
        </div>
      </footer>
    </>
  );
}
