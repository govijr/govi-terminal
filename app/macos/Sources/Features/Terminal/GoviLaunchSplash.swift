import SwiftUI
import AppKit

/// The original signature reveals its artwork along hand-traced centerlines.
/// Personal wordmarks draw shaped font outlines before filling the letters.
struct GoviLaunchSplash: View {
    @MainActor private static var gate = GoviLaunchGate()
    /// True only for the first workbench of this app launch.
    @MainActor static func claim() -> Bool {
        gate.claim(enabled: UserDefaults.standard.bool(forKey: GoviLaunchPreferences.enabledKey))
    }

    var text = GoviLaunchPreferences.text
    let finish: () -> Void
    @Environment(\.goviPalette) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var settled = false
    @State private var leaving = false
    private static let image = NSImage(contentsOf: GoviResources.resourceURL.appendingPathComponent("Brand/GoviWordmark.png"))

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ui.canvas
                Group {
                    if GoviLaunchPreferences.normalized(text) == GoviLaunchPreferences.defaultText, let image = Self.image {
                        let size = min(340, geometry.size.width * 0.8, geometry.size.height)
                        let mark = ui.ink.mask(
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().colorInvert().luminanceToAlpha())
                        mark.mask {
                            if settled {
                                Color.black
                            } else {
                                GoviSignaturePen().trim(from: 0, to: progress)
                                    .stroke(
                                        style: StrokeStyle(
                                            lineWidth: size * 88 / GoviSignaturePen.canvas, lineCap: .round, lineJoin: .round))
                            }
                        }
                        .frame(width: size, height: size)
                    } else {
                        GoviAnimatedWordmark(text: text, progress: progress, settled: settled)
                            .frame(width: min(620, geometry.size.width * 0.8), height: min(140, geometry.size.height * 0.55))
                    }
                }
                .scaleEffect(leaving && !reduceMotion ? 1.04 : 1)
            }
        }
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            do {
                if reduceMotion {
                    settled = true
                    try await Task.sleep(nanoseconds: 600_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(.timingCurve(0.45, 0.05, 0.35, 1, duration: 1.6)) { progress = 1 }
                    try await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { settled = true }
                    try await Task.sleep(nanoseconds: 350_000_000)
                }
                withAnimation(.easeInOut(duration: 0.45)) { leaving = true }
                try await Task.sleep(nanoseconds: 450_000_000)
                finish()
            } catch {
                // A dismissed or restarted preview must not finish the next one.
            }
        }
    }
}

private struct GoviAnimatedWordmark: View {
    let text: String
    var progress: CGFloat
    var settled: Bool
    @Environment(\.goviPalette) private var ui

    var body: some View {
        let outline = GoviWordmarkOutline(text: text)
        if outline.requiresTextFallback {
            Text(GoviLaunchPreferences.normalized(text))
                .font(.custom(GoviWordmarkOutline.font.fontName, size: 140))
                .foregroundStyle(ui.ink).lineLimit(1).minimumScaleFactor(0.05)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(alignment: .leading) {
                    GeometryReader { geometry in
                        Rectangle().frame(width: geometry.size.width * (settled ? 1 : progress))
                    }
                }
        } else {
            GoviWordmarkShape(outline: outline)
                .fill(ui.ink.opacity(settled ? 1 : 0))
                .overlay {
                    GoviWordmarkShape(outline: outline).trim(from: 0, to: progress)
                        .stroke(ui.ink.opacity(settled ? 0 : 1), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
        }
    }
}

private struct GoviWordmarkShape: Shape {
    let outline: GoviWordmarkOutline
    func path(in rect: CGRect) -> Path { Path(outline.fittedPath(in: rect.insetBy(dx: 2, dy: 2))) }
}

struct GoviLaunchSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviLaunchPreferences.enabledKey) private var enabled = false
    @AppStorage(GoviLaunchPreferences.textKey) private var text = ""
    @State private var previewing = false
    @State private var previewID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Play wordmark on launch", isOn: $enabled)
                .help("Applies on the next app launch. Turn off to open directly into your workspace.")
            HStack(spacing: 8) {
                Text("Wordmark text").foregroundStyle(ui.muted)
                TextField("Govi", text: $text)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Launch wordmark text")
                    .onChange(of: text) { value in
                        if value.count > GoviLaunchPreferences.maximumLength {
                            text = String(value.prefix(GoviLaunchPreferences.maximumLength))
                        }
                    }
                Button("Reset") { text = "" }.disabled(text.isEmpty)
                Button("Preview") {
                    previewID = UUID()
                    previewing = true
                }
                .popover(isPresented: $previewing) {
                    GoviLaunchSplash(text: GoviLaunchPreferences.normalized(text)) { previewing = false }
                        .id(previewID)
                        .frame(width: 480, height: 280)
                }
            }
            Text("Saved automatically. Leave blank for the original Govi signature. Up to 40 characters.")
                .font(GoviInk.font(10)).foregroundStyle(ui.muted)
        }
    }
}

/// Centerlines of each wordmark stroke, in writing order, in the artwork's 1254-px space.
struct GoviSignaturePen: Shape {
    static let canvas: CGFloat = 1254
    private static let strokes: [[CGPoint]] = [
        // G: hook, then the long sweep round the bowl and back along the base
        [
            (505, 552), (578, 472), (530, 482), (420, 525), (300, 585), (200, 645), (152, 698), (180, 716), (270, 714), (400, 700),
            (525, 676),
        ],
        // G crossbar
        [(335, 647), (450, 627), (608, 578)],
        // descender
        [(395, 812), (470, 730), (555, 648), (612, 592)],
        // O: up to the apex, out to the point, back along the base
        [(545, 694), (630, 628), (718, 568), (815, 615), (700, 660), (570, 704), (540, 706)],
        // O: cap
        [(662, 552), (722, 545), (812, 606)],
        // V
        [(800, 528), (835, 640), (858, 762), (875, 752), (930, 640), (1000, 540), (1072, 442)],
        // I: top bar, stem, base
        [(1018, 567), (1105, 527)],
        [(1055, 552), (1015, 645), (985, 738)],
        [(930, 772), (980, 752), (1045, 745)],
    ].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.canvas
        let origin = CGPoint(x: rect.midX - Self.canvas * scale / 2, y: rect.midY - Self.canvas * scale / 2)
        var path = Path()
        for stroke in Self.strokes {
            let points = stroke.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
            path.move(to: points[0])
            // Midpoint quadratics smooth the polyline into a pen-like curve.
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                if i == 1 { path.addLine(to: mid) } else { path.addQuadCurve(to: mid, control: points[i - 1]) }
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }
}
