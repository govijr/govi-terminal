"use client";

import { useEffect, useRef, useState } from "react";
import { PEN_CANVAS, PEN_STROKES, PEN_WIDTH, WORDMARK_ASPECT, WORDMARK_VIEWBOX, cubicBezier, strokePath } from "./pen";

// Timing follows GoviLaunchSplash in the Mac app: a 150ms pause, a 1.6s pen draw on a timing curve,
// a short settle, a hold, then the wordmark glides left to its resting place as the hero, shrinking 15% as it lands.
const CSS_CURVE = "cubic-bezier(0.45, 0.05, 0.35, 1)";
const ease = cubicBezier(0.45, 0.05, 0.35, 1);
const DRAW_DELAY = 150;
const DRAW_DURATION = 1600;
const SETTLE_AT = 1750;
const MOVE_AT = 2100;
const MOVE_DURATION = 900;
const REDUCED_DONE_AT = 600;
const MAX_WIDTH = 520;
// The hero is drawn this much smaller than the splash, so the mark shrinks as it settles.
const SETTLED_SCALE = 0.85;

export function LaunchSplash() {
  const [visible, setVisible] = useState(true);
  const [settled, setSettled] = useState(false);
  const overlay = useRef<HTMLDivElement>(null);
  const mark = useRef<HTMLDivElement>(null);
  const penPaths = useRef<(SVGPathElement | null)[]>([]);

  useEffect(() => {
    const overlayEl = overlay.current;
    const markEl = mark.current;
    if (!overlayEl || !markEl) return;

    // Start centred on screen, 15% larger than the hero wordmark (but never wider than the screen).
    const hero = document.querySelector(".hero-mark")?.getBoundingClientRect();
    const width = hero?.width
      ? Math.min(hero.width / SETTLED_SCALE, window.innerWidth - 32)
      : Math.min(MAX_WIDTH, window.innerWidth * 0.78);
    const height = width / WORDMARK_ASPECT;
    Object.assign(markEl.style, {
      width: `${width}px`,
      left: `${(window.innerWidth - width) / 2}px`,
      top: `${(window.innerHeight - height) / 2}px`,
    });

    const paths = penPaths.current.filter((p): p is SVGPathElement => p !== null);
    const lengths = paths.map((p) => p.getTotalLength());
    const total = lengths.reduce((a, b) => a + b, 0);

    // Reveal the first `progress` share of the pen's total length, stroke by stroke.
    const setProgress = (progress: number) => {
      let consumed = 0;
      paths.forEach((el, i) => {
        const length = lengths[i];
        const visibleLength = Math.min(length, Math.max(0, progress * total - consumed));
        el.style.opacity = "";
        el.style.strokeDasharray = `${length} ${length}`;
        el.style.strokeDashoffset = String(length - visibleLength);
        consumed += length;
      });
    };

    // Mark the intro as finished: the page reveals its content and the nav logo appears.
    function finish() {
      document.documentElement.dataset.intro = "done";
      setVisible(false);
    }

    // Glide the wordmark left into the hero's exact spot while the background clears.
    function moveToHero() {
      const target = document.querySelector(".hero-mark")?.getBoundingClientRect();
      if (!target) return finish();
      markEl!.style.transition = ["left", "top", "width"].map((p) => `${p} ${MOVE_DURATION}ms ${CSS_CURVE}`).join(", ");
      Object.assign(markEl!.style, {
        left: `${target.left}px`,
        top: `${target.top}px`,
        width: `${target.width}px`,
      });
      overlayEl!.classList.add("is-moving");
      timers.push(window.setTimeout(finish, MOVE_DURATION));
    }

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const timers: number[] = [];
    let frame = 0;
    setProgress(0);

    if (reduce) {
      setProgress(1);
      setSettled(true);
      timers.push(window.setTimeout(finish, REDUCED_DONE_AT));
    } else {
      const start = performance.now();
      const tick = (now: number) => {
        const t = (now - start - DRAW_DELAY) / DRAW_DURATION;
        setProgress(ease(Math.min(1, Math.max(0, t))));
        if (t < 1) frame = requestAnimationFrame(tick);
      };
      frame = requestAnimationFrame(tick);
      timers.push(window.setTimeout(() => setSettled(true), SETTLE_AT));
      timers.push(window.setTimeout(moveToHero, MOVE_AT));
    }

    return () => {
      cancelAnimationFrame(frame);
      timers.forEach(window.clearTimeout);
    };
  }, []);

  if (!visible) return null;

  return (
    <div
      ref={overlay}
      aria-hidden="true"
      className="pointer-events-none fixed inset-0 z-50 hidden bg-canvas transition-[background-color] duration-900 ease-glide js:block motion-reduce:transition-none [&.is-moving]:bg-transparent"
    >
      <div ref={mark} className="absolute">
        <svg viewBox={WORDMARK_VIEWBOX} width="100%" height="100%" className="block overflow-visible">
          <defs>
            <filter id="splash-invert" colorInterpolationFilters="sRGB">
              <feColorMatrix type="matrix" values="-1.05 0 0 0 1.04  0 -1.05 0 0 1.04  0 0 -1.05 0 1.04  0 0 0 1 0" />
            </filter>
            {/* The artwork's dark strokes, as a luminance mask. */}
            <mask id="splash-ink" maskUnits="userSpaceOnUse" x="0" y="0" width={PEN_CANVAS} height={PEN_CANVAS}>
              <image href="/brand/GoviWordmark.png" width={PEN_CANVAS} height={PEN_CANVAS} filter="url(#splash-invert)" />
            </mask>
            {/* The pen: a thick round-capped stroke along each centerline. */}
            <mask id="splash-pen" maskUnits="userSpaceOnUse" x="0" y="0" width={PEN_CANVAS} height={PEN_CANVAS}>
              <g fill="none" stroke="#fff" strokeWidth={PEN_WIDTH} strokeLinecap="round" strokeLinejoin="round">
                {PEN_STROKES.map((stroke, i) => (
                  <path
                    key={i}
                    ref={(el) => {
                      penPaths.current[i] = el;
                    }}
                    d={strokePath(stroke)}
                    style={{ opacity: 0 }}
                  />
                ))}
              </g>
            </mask>
          </defs>
          <g mask="url(#splash-pen)">
            <rect width={PEN_CANVAS} height={PEN_CANVAS} mask="url(#splash-ink)" className="fill-ink" />
          </g>
          <rect
            width={PEN_CANVAS}
            height={PEN_CANVAS}
            mask="url(#splash-ink)"
            className="fill-ink transition-opacity duration-200 ease-out motion-reduce:transition-none"
            style={{ opacity: settled ? 1 : 0 }}
          />
        </svg>
      </div>
    </div>
  );
}
