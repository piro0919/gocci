import { getTranslations, setRequestLocale } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { FlowDiagram } from "./flow-diagram";
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
    <div className="grid-paper flex min-h-dvh flex-col">
      {/* 一画面に収める。やることが一つしかないので、説明を足すほど嘘くさくなる */}
      <header className="px-6 pt-6">
        <div className="mx-auto flex w-full max-w-5xl items-center justify-between">
          <span className="font-mono text-sm tracking-[0.3em]">GOCCI</span>
          <LanguageSwitch />
        </div>
      </header>

      <main className="mx-auto flex w-full max-w-5xl flex-1 flex-col justify-center gap-14 px-6 py-14 lg:flex-row lg:items-center lg:gap-16 lg:py-20">
        <div className="min-w-0 lg:flex-1">
          <span className="font-mono text-muted text-xs tracking-wider">
            {t("hero.badge")}
          </span>
          <h1 className="mt-6 whitespace-pre-line font-display font-bold text-4xl leading-[1.15] tracking-tight sm:text-5xl">
            {t("hero.title")}
          </h1>
          <p className="mt-6 max-w-md text-lg text-muted leading-relaxed">
            {t("hero.tagline")}
          </p>

          <div className="mt-10 flex flex-col gap-3 sm:flex-row">
            <a
              className="lift bg-teal px-8 py-3.5 text-center font-bold text-blueprint hover:bg-text"
              href={DOWNLOAD}
            >
              {t("hero.download")}
            </a>
            <a
              className="lift border border-line px-8 py-3.5 text-center font-bold hover:border-teal"
              href={REPO}
            >
              {t("hero.source")}
            </a>
          </div>
          <p className="mt-5 text-muted text-sm">{t("hero.note")}</p>
        </div>

        <div className="min-w-0 lg:flex-1">
          <FlowDiagram
            caption={t("diagram.caption")}
            disk={t("diagram.disk")}
            drive={t("diagram.drive")}
            finder={t("diagram.finder")}
            flowBottom={t("diagram.flowBottom")}
            flowTop={t("diagram.flowTop")}
          />
        </div>
      </main>

      <footer className="border-line border-t px-6 py-8">
        <div className="mx-auto flex max-w-5xl justify-end text-muted text-sm">
          <a className="cursor-pointer font-bold hover:text-text" href={REPO}>
            {t("footer.source")}
          </a>
          <span className="px-3">·</span>
          <Link
            className="cursor-pointer font-bold hover:text-text"
            href="/privacy"
          >
            {t("footer.privacy")}
          </Link>
        </div>
      </footer>
    </div>
  );
}
