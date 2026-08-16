import Image from "next/image";
import { getTranslations, setRequestLocale } from "next-intl/server";
import { LanguageSwitch } from "./language-switch";

const REPO = "https://github.com/piro0919/gocci";
const DOWNLOAD = `${REPO}/releases/latest`;

type PageProps = {
  params: Promise<{ locale: string }>;
};

export default async function Page({ params }: PageProps) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations();

  return (
    <div className="flex min-h-dvh flex-col">
      {/* 一画面に収める。やることが一つしかないので、説明を足すほど嘘くさくなる */}
      <header className="aurora relative flex flex-1 flex-col overflow-hidden px-6 pt-8 pb-20">
        <div className="mx-auto flex w-full max-w-5xl items-center justify-between">
          <span className="font-bold text-lg tracking-tight">Gocci</span>
          <LanguageSwitch />
        </div>

        <div className="mx-auto flex w-full max-w-5xl flex-1 flex-col items-center justify-center gap-14 py-16 lg:flex-row lg:py-24">
          <div className="text-center lg:flex-1 lg:text-left">
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

      <footer className="border-line border-t px-6 py-8">
        <div className="mx-auto flex max-w-5xl justify-end text-muted text-sm">
          <a className="cursor-pointer font-bold hover:text-text" href={REPO}>
            {t("footer.source")}
          </a>
        </div>
      </footer>
    </div>
  );
}
