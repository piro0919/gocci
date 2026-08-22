import type { ReactNode } from "react";

type Props = {
  caption: string;
  disk: string;
  drive: string;
  finder: string;
  flowBottom: string;
  flowTop: string;
};

const LABEL =
  "ui-monospace, SFMono-Regular, Menlo, monospace";

/**
 * ファイルがどこに置かれるかの図。スクリーンショットが無いアプリなので、
 * 画面を撮るかわりに経路そのものを図面として描く
 */
export function FlowDiagram({
  caption,
  disk,
  drive,
  finder,
  flowBottom,
  flowTop,
}: Props): ReactNode {
  return (
    <figure className="w-full">
      <svg
        aria-hidden="true"
        className="h-auto w-full"
        fill="none"
        viewBox="0 0 560 440"
        xmlns="http://www.w3.org/2000/svg"
      >
        <g stroke="#e8f1f8" strokeOpacity="0.85" strokeWidth="1.6">
          {/* 雲。Google ドライブ側 */}
          <path d="M36 92c-13 0-24-11-24-24s11-24 24-24c2 0 5 0 7 1 7-16 23-27 41-27 24 0 44 19 45 43 16 2 29 16 29 33 0 18-15 33-33 33H36Z" />

          {/* Finder の窓 */}
          <rect height="150" width="330" x="12" y="188" />
          <line x1="12" x2="342" y1="216" y2="216" />
          <line x1="104" x2="104" y1="216" y2="338" />
          <circle cx="28" cy="202" r="4.5" />
          <circle cx="44" cy="202" r="4.5" />
          <circle cx="60" cy="202" r="4.5" />
          {[240, 264, 288].map((y) => (
            <line key={y} x1="28" x2="88" y1={y} y2={y} />
          ))}
          {[240, 264, 288, 312].map((y) => (
            <line key={y} x1="122" x2="326" y1={y} y2={y} />
          ))}

          {/* 選んだディスク */}
          <rect height="76" rx="4" width="220" x="328" y="352" />
          <line x1="328" x2="548" y1="398" y2="398" />
          <circle cx="352" cy="414" r="5.5" />
        </g>

        {/* 経路。上は一覧が見えるだけ、下は実体が落ちる */}
        <g stroke="#29c7c0" strokeWidth="1.6">
          <path d="M150 122v66" strokeDasharray="6 6" />
          <path d="M220 338v52h108" />
          <path d="M320 382l8 8-8 8" />
        </g>

        <g fill="#9dbad2" fontFamily={LABEL} fontSize="12" letterSpacing="1">
          <text x="12" y="148">
            {drive}
          </text>
          <text x="12" y="180">
            {finder}
          </text>
          <text x="328" y="344">
            {disk}
          </text>
        </g>
        <g fill="#29c7c0" fontFamily={LABEL} fontSize="12" letterSpacing="1">
          <text x="162" y="160">
            {flowTop}
          </text>
          <text x="232" y="378">
            {flowBottom}
          </text>
        </g>
      </svg>
      <figcaption className="mt-5 font-mono text-muted text-xs">
        {caption}
      </figcaption>
    </figure>
  );
}
