// Pen centerlines for the Govi signature, ported from GoviSignaturePen in
// app/macos/Sources/Features/Terminal/GoviWorkbench.swift. Coordinates are in the
// artwork's 1254 x 1254 space, in writing order.

export const PEN_CANVAS = 1254;
// Stroke width used by the Swift pen, expressed in artwork units (size * 88 / canvas).
export const PEN_WIDTH = 58;

// The signature cropped to its ink (x 144–1110, y 430–820). Shared by the splash and the nav logo
// so the splash can glide into the logo's exact spot.
export const WORDMARK_VIEWBOX = "136 422 982 406";
export const WORDMARK_ASPECT = 782 / 406;

export const PEN_STROKES: [number, number][][] = [
  // G: hook, then the long sweep round the bowl and back along the base
  [[505, 552], [578, 472], [530, 482], [420, 525], [300, 585], [200, 645], [152, 698], [180, 716], [270, 714], [400, 700], [525, 676]],
  // G crossbar
  [[335, 647], [450, 627], [608, 578]],
  // descender
  [[395, 812], [470, 730], [555, 648], [612, 592]],
  // O: up to the apex, out to the point, back along the base
  [[545, 694], [630, 628], [718, 568], [815, 615], [700, 660], [570, 704], [540, 706]],
  // O: cap
  [[662, 552], [722, 545], [812, 606]],
  // V
  [[800, 528], [835, 640], [858, 762], [875, 752], [930, 640], [1000, 540], [1072, 442]],
  // I: top bar, stem, base
  [[1018, 567], [1105, 527]],
  [[1055, 552], [1015, 645], [985, 738]],
  [[930, 772], [980, 752], [1045, 745]],
];

/** SVG path data for one stroke: midpoint quadratics smooth the polyline, as in the Swift pen. */
export function strokePath(points: [number, number][]): string {
  if (points.length < 2) return "";
  const f = (n: number) => n.toFixed(1);
  let d = `M${f(points[0][0])} ${f(points[0][1])}`;
  for (let i = 1; i < points.length; i++) {
    const [px, py] = points[i - 1];
    const [cx, cy] = points[i];
    const mx = (px + cx) / 2;
    const my = (py + cy) / 2;
    d += i === 1 ? ` L${f(mx)} ${f(my)}` : ` Q${f(px)} ${f(py)} ${f(mx)} ${f(my)}`;
  }
  const [lx, ly] = points[points.length - 1];
  return `${d} L${f(lx)} ${f(ly)}`;
}

/** Cubic-bezier easing, same curve as SwiftUI's timingCurve(x1, y1, x2, y2). */
export function cubicBezier(x1: number, y1: number, x2: number, y2: number) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
  const slopeX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x: number) => {
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sampleX(t) - x;
      const slope = slopeX(t);
      if (Math.abs(err) < 1e-6 || Math.abs(slope) < 1e-6) break;
      t -= err / slope;
    }
    return sampleY(Math.min(1, Math.max(0, t)));
  };
}
