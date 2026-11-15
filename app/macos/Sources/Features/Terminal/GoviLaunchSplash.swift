import SwiftUI
import AppKit

/// The original Govi artwork keeps its traced pen animation. Personal wordmarks
/// reveal the exact filled shapes from the bundled Givi Signature font.
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
                    if GoviLaunchPreferences.normalized(text) != GoviLaunchPreferences.defaultText,
                        let font = GoviLaunchArtwork.font, let outline = GoviSignatureOutline(text: text, font: font)
                    {
                        GoviSignatureWordmark(outline: outline, progress: progress, settled: settled)
                            .frame(width: min(620, geometry.size.width * 0.8), height: min(140, geometry.size.height * 0.55))
                    } else if let image = Self.image {
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
                // Dismissed and restarted animations must not finish a later replay.
            }
        }
    }
}

private enum GoviLaunchArtwork {
    static let font = GoviSignatureFont(url: GoviResources.resourceURL.appendingPathComponent("Fonts/\(GoviSignatureFont.fileName)"))
}

private struct GoviSignatureWordmark: View {
    let outline: GoviSignatureOutline
    var progress: CGFloat
    var settled: Bool
    @Environment(\.goviPalette) private var ui

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 1, dy: 1)
            let shape = Path(outline.fittedPath(in: rect))
            shape.fill(ui.ink)
                .mask {
                    if settled {
                        Color.black
                    } else {
                        shape.trim(from: 0, to: progress)
                            .stroke(style: StrokeStyle(lineWidth: outline.revealWidth(in: rect), lineCap: .round, lineJoin: .round))
                    }
                }
        }
    }
}

struct GoviLaunchSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviLaunchPreferences.enabledKey) private var enabled = false
    @AppStorage(GoviLaunchPreferences.textKey) private var savedText = ""
    @State private var text = ""
    @State private var previewing = false
    @State private var previewID = UUID()

    private var problem: String? {
        guard let font = GoviLaunchArtwork.font else {
            return "The signature font is unavailable. The original Govi signature will be used."
        }
        let missing = font.unsupportedCharacters(in: GoviLaunchPreferences.normalized(text))
        guard !missing.isEmpty else { return nil }
        return "Your font doesn't include: \(missing.prefix(6).joined(separator: " ")). Your last valid wordmark is kept."
    }

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
                        } else if problem == nil {
                            savedText = value
                        }
                    }
                Button("Reset") {
                    text = ""
                    savedText = ""
                }.disabled(text.isEmpty && savedText.isEmpty)
                Button("Preview") {
                    previewID = UUID()
                    previewing = true
                }
                .disabled(problem != nil)
                .popover(isPresented: $previewing) {
                    GoviLaunchSplash(text: GoviLaunchPreferences.normalized(text)) { previewing = false }
                        .id(previewID).frame(width: 480, height: 280)
                }
            }
            if let problem {
                Text(problem).font(GoviInk.font(10)).foregroundStyle(.red)
            } else {
                Text("Givi Signature · Saved automatically · Up to 40 characters. Leave blank for the original Govi signature.")
                    .font(GoviInk.font(10)).foregroundStyle(ui.muted)
            }
        }
        .onAppear { text = savedText }
        .onChange(of: savedText) { value in if text != value { text = value } }
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
