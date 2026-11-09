import { PEN_CANVAS, WORDMARK_VIEWBOX } from "./pen";

// The settled signature, cropped to its ink. Static: no pen, so it renders the same on server and client.
export function Wordmark({ id, className }: { id: string; className?: string }) {
  return (
    <svg viewBox={WORDMARK_VIEWBOX} className={className} role="img" aria-label="govi" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <filter id={`${id}-invert`} colorInterpolationFilters="sRGB">
          <feColorMatrix type="matrix" values="-1.05 0 0 0 1.04  0 -1.05 0 0 1.04  0 0 -1.05 0 1.04  0 0 0 1 0" />
        </filter>
        <mask id={`${id}-ink`} maskUnits="userSpaceOnUse" x="0" y="0" width={PEN_CANVAS} height={PEN_CANVAS}>
          <image href="/brand/GoviWordmark.png" width={PEN_CANVAS} height={PEN_CANVAS} filter={`url(#${id}-invert)`} />
        </mask>
      </defs>
      <rect width={PEN_CANVAS} height={PEN_CANVAS} mask={`url(#${id}-ink)`} className="fill-ink" />
    </svg>
  );
}
