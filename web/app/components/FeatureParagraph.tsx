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
  className: "mr-1 inline-block h-[1em] w-[1em] align-[-0.125em]",
} as const;

// Tooltip geometry in px; the card never grows wider than the window allows.
const TIP_MAX_WIDTH = 300;
const GUTTER = 16;
const OFFSET = 10;

type Tip = { token: string; left: number; top: number; width: number };

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
    const width = Math.min(TIP_MAX_WIDTH, window.innerWidth - GUTTER * 2);
    const rect = trigger.getBoundingClientRect();
    const center = rect.left + rect.width / 2;
    const left = Math.min(Math.max(GUTTER, center - width / 2), window.innerWidth - GUTTER - width);
    setTip({ token, left, top: rect.bottom + OFFSET, width });
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
              className="inline-block cursor-default rounded-sm outline-offset-2"
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
          className="fixed z-10 rounded-lg px-3.5 py-3 text-sm leading-normal font-normal shadow-lg first-letter:uppercase"
          style={{
            left: tip.left,
            top: tip.top,
            width: tip.width,
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
