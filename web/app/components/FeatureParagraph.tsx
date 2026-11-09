"use client";

import { Fragment, useEffect, useState, type ReactNode } from "react";

export type Feature = { name: string; detail: string; token: string; icon: ReactNode };

// Shared attributes for the inline feature icons (stroke-based, 24px grid).
const iconProps = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round",
  strokeLinejoin: "round",
  "aria-hidden": true,
  className: "mr-[0.3vw] inline-block h-[1em] w-[1em] align-[-0.125em]",
} as const;

// Tooltip geometry is in vw too, so it scales with the rest of the page. Pixel values
// are derived from the window width at the moment the tooltip opens.
const TIP_WIDTH_VW = 22.5;
const GUTTER_VW = 1.25;
const OFFSET_VW = 0.9;

type Tip = { token: string; left: number; top: number };

// Each feature shows its title; hovering or focusing it opens the description
// in a card filled with the title's color. The card is clamped to the viewport.
export function FeatureParagraph({ features }: { features: Feature[] }) {
  const [tip, setTip] = useState<Tip | null>(null);

  // A card positioned to a scrolled-away title would be wrong, so close it on scroll or resize.
  useEffect(() => {
    if (!tip) return;
    const close = () => setTip(null);
    window.addEventListener("scroll", close, { passive: true });
    window.addEventListener("resize", close);
    return () => {
      window.removeEventListener("scroll", close);
      window.removeEventListener("resize", close);
    };
  }, [tip]);

  function show(token: string, trigger: HTMLElement) {
    const vw = window.innerWidth / 100;
    const width = TIP_WIDTH_VW * vw;
    const rect = trigger.getBoundingClientRect();
    const center = rect.left + rect.width / 2;
    const left = Math.min(Math.max(GUTTER_VW * vw, center - width / 2), window.innerWidth - GUTTER_VW * vw - width);
    setTip({ token, left, top: rect.bottom + OFFSET_VW * vw });
  }

  const open = tip ? features.find((feature) => feature.token === tip.token) : undefined;

  return (
    <>
      <p>
        {features.map((feature, index) => (
          <Fragment key={feature.name}>
            {index > 0 && " "}
            <span
              tabIndex={0}
              className="inline-block cursor-default rounded-sm"
              style={{ color: `var(--feat-${feature.token})` }}
              onPointerEnter={(event) => {
                if (event.pointerType === "mouse") show(feature.token, event.currentTarget);
              }}
              onPointerLeave={(event) => {
                if (event.pointerType === "mouse") setTip(null);
              }}
              onFocus={(event) => show(feature.token, event.currentTarget)}
              onBlur={() => setTip(null)}
            >
              <svg {...iconProps}>{feature.icon}</svg>
              <span className="font-semibold">{feature.name}</span>
              <span className="sr-only">: {feature.detail}.</span>
            </span>
          </Fragment>
        ))}
      </p>
      {tip && open && (
        <div
          role="tooltip"
          className="fixed z-10 rounded-lg p-[1.25vw] text-[1.25vw] leading-[1.5] font-normal shadow-lg first-letter:uppercase"
          style={{
            left: tip.left,
            top: tip.top,
            width: `${TIP_WIDTH_VW}vw`,
            backgroundColor: `var(--feat-${tip.token})`,
            color: "var(--feat-ink)",
          }}
        >
          {open.detail}.
        </div>
      )}
    </>
  );
}
