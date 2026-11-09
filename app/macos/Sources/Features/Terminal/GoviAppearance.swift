import SwiftUI
import AppKit
import CoreText
import GhosttyKit

struct GoviTheme: Identifiable {
    let id: String
    let name: String
    let dark: Bool
    let background: UInt32
    let canvas: UInt32
    let sidebar: UInt32
    let foreground: UInt32
    let muted: UInt32
    let border: UInt32
    let accent: UInt32
    let palette: [UInt32]
    var sourceURL: URL? = nil

    static let presets: [GoviTheme] = [
        .init(id: "paper", name: "Paper", dark: false, background: 0xffffff, canvas: 0xf5f5f3, sidebar: 0xffffff,
              foreground: 0x292929, muted: 0x767672, border: 0xe5e5e1, accent: 0x41413e,
              palette: [0x292929,0xb8414a,0x497445,0x936c21,0x416db0,0x8f59a6,0x357d83,0xd5dae2,0x7b8797,0xca5861,0x5d8f56,0xac8433,0x5c86c9,0xa472b9,0x50969b,0xffffff]),
        .init(id: "graphite", name: "Graphite", dark: true, background: 0x1b1b1b, canvas: 0x121212, sidebar: 0x1e1e1e,
              foreground: 0xd8dce3, muted: 0x878e99, border: 0x303030, accent: 0xd8dce3,
              palette: [0x252830,0xe58989,0xa4c99a,0xe2c58c,0x9fb9e3,0xc5a4df,0x91c5ca,0xd6d9df,0x737b8b,0xf0a2a2,0xbce0af,0xf0d8a8,0xb8ceef,0xd9bdef,0xaddce0,0xf2f3f5]),
        .init(id: "midnight", name: "Midnight", dark: true, background: 0x0b0d12, canvas: 0x07090d, sidebar: 0x090b10,
              foreground: 0xcbd5e6, muted: 0x7f8ba3, border: 0x222a38, accent: 0x91b4ff,
              palette: [0x242b3b,0xef8e9b,0xa2c89e,0xe2c487,0x8caff0,0xbc9cde,0x8bc7cc,0xd0d8e7,0x63718d,0xf3acb5,0xc0d8b9,0xf0d9a9,0xadc7f6,0xd4bced,0xa6dee2,0xf1f4fa]),
        .init(id: "phosphor", name: "Phosphor", dark: true, background: 0x101a13, canvas: 0x09110c, sidebar: 0x0c150e,
              foreground: 0xbbd4b8, muted: 0x7d9b7b, border: 0x2a3c2c, accent: 0x9ed793,
              palette: [0x29382b,0xd58d77,0x9ed793,0xd3c58b,0x91b6ae,0xc7a8ba,0x8bc2a9,0xc7d8bf,0x6a8169,0xe9aa96,0xb7e9ac,0xe7dca9,0xafd0c9,0xdfc0d4,0xaadac2,0xecf4e8]),
        .init(id: "nord", name: "Nord", dark: true, background: 0x2e3440, canvas: 0x252a34, sidebar: 0x292e39,
              foreground: 0xd8dee9, muted: 0x929daf, border: 0x434c5e, accent: 0x88c0d0,
              palette: [0x3b4252,0xbf616a,0xa3be8c,0xebcb8b,0x81a1c1,0xb48ead,0x88c0d0,0xe5e9f0,0x4c566a,0xd08770,0xb6d39c,0xf0d69d,0x9bb8d5,0xc9a9c3,0x8fbcbb,0xeceff4]),
        .init(id: "tokyo", name: "Tokyo Night", dark: true, background: 0x1a1b26, canvas: 0x13141c, sidebar: 0x161720,
              foreground: 0xc0caf5, muted: 0x8a93b8, border: 0x34374d, accent: 0x7aa2f7,
              palette: [0x414868,0xf7768e,0x9ece6a,0xe0af68,0x7aa2f7,0xbb9af7,0x7dcfff,0xa9b1d6,0x565f89,0xff9eaa,0xb9dc8c,0xeac48d,0x9ab9ff,0xceb5ff,0xa3e0ff,0xc0caf5]),
        .init(id: "ember", name: "Ember", dark: true, background: 0x211c19, canvas: 0x181412, sidebar: 0x1b1715,
              foreground: 0xe5d9cb, muted: 0xa29485, border: 0x443830, accent: 0xdfae83,
              palette: [0x41352c,0xdc8b7f,0xa8bb8b,0xe0bf82,0x9aafc7,0xc6a3bc,0x91b8af,0xddcfc0,0x8d7d6e,0xeda89c,0xc1d3a4,0xf0d5a3,0xb8c9dc,0xddbed3,0xb0d3ca,0xf5eade]),
        .init(id: "snow", name: "Snow", dark: false, background: 0xfafbfc, canvas: 0xeef0f4, sidebar: 0xf2f4f7,
              foreground: 0x303846, muted: 0x6a7482, border: 0xd5dae2, accent: 0x466cc6,
              palette: [0x303846,0xb8414a,0x497445,0x936c21,0x416db0,0x8f59a6,0x357d83,0xd5dae2,0x7b8797,0xca5861,0x5d8f56,0xac8433,0x5c86c9,0xa472b9,0x50969b,0xfafbfc]),
        .init(id: "linen", name: "Linen", dark: false, background: 0xf7f3e9, canvas: 0xe9e4d9, sidebar: 0xefebe1,
              foreground: 0x494338, muted: 0x81796b, border: 0xd6cfc1, accent: 0x98724f,
              palette: [0x494338,0xb95647,0x5b7747,0x937222,0x4f7398,0x8b6595,0x437d75,0xd6cfc1,0x897f6e,0xcd705f,0x77935e,0xad8e3c,0x6c8fb2,0xa481ad,0x61998f,0xf7f3e9])
    ]
    /// Read the same bundled collection used by `+list-themes`, without launching
    /// a subprocess or reading another app's user configuration.
    static let all: [GoviTheme] = {
        let directory = Bundle.main.resourceURL!.appendingPathComponent("ghostty/themes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? []
        let bundled = files.compactMap(fromFile).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return presets + bundled
    }()
    static var current: GoviTheme {
        all.first { $0.id == UserDefaults.standard.string(forKey: "GoviTheme") } ?? presets[0]
    }

    private static func fromFile(_ url: URL) -> GoviTheme? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var colors: [String: UInt32] = [:]
        var palette = presets[0].palette
        for line in text.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].hasPrefix("#") else { continue }
            if pair[0] == "palette" {
                let entry = pair[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), palette.indices.contains(index), let value = parseColor(entry[1]) { palette[index] = value }
            } else if let value = parseColor(pair[1]) { colors[pair[0]] = value }
        }
        guard let background = colors["background"], let foreground = colors["foreground"] else { return nil }
        let dark = luminance(background) < luminance(foreground)
        let accent = palette[4]
        return .init(id: "ghostty:\(url.lastPathComponent)", name: url.lastPathComponent, dark: dark,
                     background: background, canvas: blend(background, with: dark ? 0 : 0xffffff, amount: 0.12),
                     sidebar: blend(background, with: dark ? 0 : 0xffffff, amount: 0.06),
                     foreground: foreground, muted: blend(foreground, with: background, amount: 0.42),
                     border: blend(background, with: foreground, amount: 0.14), accent: accent, palette: palette, sourceURL: url)
    }
    private static func parseColor(_ text: String) -> UInt32? {
        let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "#\" "))
        return hex.count == 6 ? UInt32(hex, radix: 16) : nil
    }
    private static func luminance(_ rgb: UInt32) -> Double {
        Double((rgb >> 16) & 255) * 0.2126 + Double((rgb >> 8) & 255) * 0.7152 + Double(rgb & 255) * 0.0722
    }
    private static func blend(_ a: UInt32, with b: UInt32, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { value, shift in
            let channel = Double((a >> shift) & 255) * (1 - amount) + Double((b >> shift) & 255) * amount
            return value | (UInt32(channel.rounded()) << shift)
        }
    }
    static func hex(_ value: UInt32) -> String { String(format: "%06x", value) }
    var configuration: String {
        var lines = ["background = \(Self.hex(background))", "foreground = \(Self.hex(foreground))",
                     "cursor-color = \(Self.hex(accent))", "selection-background = \(Self.hex(border))",
                     "selection-foreground = \(Self.hex(foreground))", "split-divider-color = \(Self.hex(canvas))",
                     "window-theme = \(dark ? "dark" : "light")"]
        lines += palette.enumerated().map { "palette = \($0.offset)=#\(Self.hex($0.element))" }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum GoviFontCatalog {
    static let bundledFamily = "JetBrains Mono"
    static let families: [String] = {
        let names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 14) else { return false }
            return font.fontDescriptor.symbolicTraits.contains(.monoSpace) && !family.hasPrefix(".") && !family.contains("Govi")
        }
        return Array(Set(names + [bundledFamily, "Menlo", "Monaco"])).sorted()
    }()
    static var selected: String {
        let saved = UserDefaults.standard.string(forKey: "GoviFont") ?? bundledFamily
        return families.contains(saved) ? saved : bundledFamily
    }
    static var size: Int {
        let saved = UserDefaults.standard.integer(forKey: "GoviFontSize")
        return saved == 0 ? 14 : min(28, max(10, saved))
    }
}

enum GoviResources {
    static var resourceURL: URL { Bundle.main.resourceURL!.appendingPathComponent("Govi") }
    static let registerFonts: Void = {
        for face in ["Regular", "Bold", "Italic", "BoldItalic"] {
            CTFontManagerRegisterFontsForURL(resourceURL.appendingPathComponent("Fonts/JetBrainsMono-\(face).ttf") as CFURL, .process, nil)
        }
        for face in ["Regular", "Medium", "SemiBold", "Bold"] {
            CTFontManagerRegisterFontsForURL(resourceURL.appendingPathComponent("Fonts/Geist-\(face).ttf") as CFURL, .process, nil)
        }
    }()

    static func loadConfiguration(into config: ghostty_config_t) {
        _ = registerFonts
        func load(_ url: URL) {
            if !url.path.withCString({ govi_config_load_file(config, $0) }) {
                Ghostty.logger.error("Govi could not read configuration: \(url.path)")
            }
        }
        load(resourceURL.appendingPathComponent("default.conf"))
        let theme = GoviTheme.current
        if let url = theme.sourceURL {
            // Load original colors, including cursor/selection colors, without
            // reducing the upstream theme to its preview palette.
            load(url)
        } else {
            apply(theme.configuration, into: config)
        }
        let preferences = UserDefaults.standard
        let family = GoviFontCatalog.selected.replacingOccurrences(of: "\"", with: "")
        let padding = preferences.object(forKey: "GoviPadding") == nil ? 8 : min(32, max(0, preferences.integer(forKey: "GoviPadding")))
        let lineHeight = preferences.object(forKey: "GoviLineHeight") == nil ? 8 : min(40, max(0, preferences.integer(forKey: "GoviLineHeight")))
        let cursor = preferences.string(forKey: "GoviCursor") ?? "bar"
        let cursorStyle = ["bar", "block", "underline"].contains(cursor) ? cursor : "bar"
        let ligatures = preferences.bool(forKey: "GoviLigatures")
        apply("""
        window-theme = \(theme.dark ? "dark" : "light")
        split-divider-color = \(GoviTheme.hex(theme.canvas))
        font-family = ""
        font-family = "\(family)"
        font-family-bold = ""
        font-family-italic = ""
        font-family-bold-italic = ""
        font-size = \(GoviFontCatalog.size)
        font-thicken = \(preferences.bool(forKey: "GoviFontThicken"))
        font-feature = \(ligatures ? "+liga" : "-liga")
        font-feature = \(ligatures ? "+calt" : "-calt")
        adjust-cell-height = \(lineHeight)%
        window-padding-x = \(padding)
        window-padding-y = \(padding)
        cursor-style = \(cursorStyle)
        cursor-style-blink = \(preferences.bool(forKey: "GoviCursorBlink"))
        background-opacity = \(String(format: "%.2f", GoviBackdropStore.terminalOpacity))
        shell-integration-features = no-cursor,sudo,title

        """, into: config)
        apply(GoviShortcutPreferences.configuration(values: GoviShortcutPreferences.load()), into: config)
    }

    private static func apply(_ settings: String, into config: ghostty_config_t) {
        if !settings.withCString({ govi_config_load_settings(config, $0) }) {
            Ghostty.logger.error("Govi could not apply Settings")
        }
    }
}

// BEGIN CHROME MATH
/// UI-only colors. Never serialized into the terminal's Ghostty configuration.
struct GoviChromePalette {
    let dark: Bool
    let canvas, surface, foreground, secondary, separator, hover, selection: UInt32
    static func blend(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let left = Double((a >> shift) & 255)
            let right = Double((b >> shift) & 255)
            let channel = UInt32((left * (1 - amount) + right * amount).rounded())
            return result | (channel << shift)
        }
    }
    static func luminance(_ rgb: UInt32) -> Double {
        let channels = [16, 8, 0].map { shift -> Double in
            let c = Double((rgb >> shift) & 255) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func readable(_ seed: UInt32, on backgrounds: [UInt32], minimum: Double) -> UInt32 {
        func score(_ c: UInt32) -> Double { backgrounds.map { contrast(c, $0) }.min() ?? 1 }
        if score(seed) >= minimum { return seed }
        let target: UInt32 = score(0) > score(0xffffff) ? 0 : 0xffffff
        for step in 1...100 {
            let candidate = blend(seed, target, Double(step) / 100)
            if score(candidate) >= minimum { return candidate }
        }
        return target
    }
    init(background: UInt32, text: UInt32, mode: String, increased: Bool) {
        // Retain the theme hue even when the chrome's luminance is overridden.
        var base = mode == "light" ? Self.blend(background, 0xffffff, 0.93) :
            mode == "dark" ? Self.blend(background, 0, 0.88) : background
        dark = Self.luminance(base) < 0.179
        // Mid-luminance themes may not admit readable text on every tonal state.
        // Move chrome only toward its chosen pole until the whole group is safe.
        let pole: UInt32 = dark ? 0 : 0xffffff
        let textPole: UInt32 = dark ? 0xffffff : 0
        for _ in 0..<100 {
            let panel = Self.blend(base, dark ? 0xffffff : 0, dark ? 0.065 : 0.035)
            let selected = Self.blend(panel, textPole, 0.065)
            if Self.contrast(textPole, selected) >= (increased ? 7 : 4.5) { break }
            base = Self.blend(base, pole, 0.025)
        }
        canvas = Self.blend(base, dark ? 0 : 0xffffff, 0.035)
        surface = Self.blend(base, dark ? 0xffffff : 0, dark ? 0.065 : 0.035)
        let target: UInt32 = dark ? 0xffffff : 0
        hover = Self.blend(surface, target, 0.035)
        selection = Self.blend(surface, target, 0.065)
        let backgrounds = [canvas, surface, hover, selection]
        foreground = Self.readable(text, on: backgrounds, minimum: increased ? 7 : 4.5)
        secondary = Self.readable(Self.blend(text, surface, 0.40), on: backgrounds, minimum: increased ? 7 : 4.5)
        separator = increased ? Self.readable(text, on: [canvas, surface], minimum: 3) : Self.blend(surface, foreground, 0.18)
    }
}
// END CHROME MATH

struct GoviUIPalette {
    let values: GoviChromePalette
    /// The theme's accent and ANSI hues, nudged until readable on the chrome surface.
    var accentSeed: UInt32 = 0x416db0
    var toneSeeds: [UInt32] = []
    private func readable(_ seed: UInt32) -> Color {
        GoviInk.color(GoviChromePalette.readable(seed, on: [values.surface, values.canvas], minimum: 3))
    }
    /// Sidebar icons and selection use this instead of grey so the chrome follows the theme.
    var accent: Color { readable(accentSeed) }
    /// A stable theme hue for `key`, so each project keeps its colour.
    func tone(for key: String) -> Color {
        guard !toneSeeds.isEmpty else { return accent }
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return readable(toneSeeds[Int(hash % UInt32(toneSeeds.count))])
    }
    var paper: Color { GoviInk.color(values.surface) }
    var canvas: Color { GoviInk.color(values.canvas) }
    var sidebar: Color { paper }
    var ink: Color { GoviInk.color(values.foreground) }
    var muted: Color { GoviInk.color(values.secondary) }
    var line: Color { GoviInk.color(values.separator) }
    var green: Color { ink }
    var wash: Color { GoviInk.color(values.selection) }
    var hover: Color { GoviInk.color(values.hover) }
}
private struct GoviUIPaletteKey: EnvironmentKey {
    static let defaultValue = GoviUIPalette(values: .init(background: 0xffffff, text: 0x292929, mode: "follow", increased: false))
}
extension EnvironmentValues {
    var goviPalette: GoviUIPalette {
        get { self[GoviUIPaletteKey.self] }
        set { self[GoviUIPaletteKey.self] = newValue }
    }
}
struct GoviChromeAppearance: ViewModifier {
    @AppStorage("GoviTheme") private var themeID = "paper"
    @AppStorage("GoviChromeAppearance") private var mode = "follow"
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let theme = GoviTheme.all.first { $0.id == themeID } ?? GoviTheme.presets[0]
        // Monochrome themes (Paper, Graphite) use their foreground as accent; take blue instead.
        let accent = GoviChromePalette.contrast(theme.accent, theme.foreground) < 1.5 ? theme.palette[4] : theme.accent
        let palette = GoviUIPalette(values: .init(background: theme.background, text: theme.foreground, mode: mode, increased: contrast == .increased),
                                    accentSeed: accent, toneSeeds: [2, 3, 4, 5, 6, 1].compactMap { theme.palette.indices.contains($0) ? theme.palette[$0] : nil })
        content.environment(\.goviPalette, palette)
            .preferredColorScheme(palette.values.dark ? .dark : .light)
    }
}

// Shared chrome colors, also used by the command palette.
enum GoviInk {
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255,
              blue: Double(hex & 255) / 255, opacity: 1)
    }
    static func font(_ size: CGFloat = 13) -> Font { .system(size: size) }
}

struct GoviOutline: Shape {
    func path(in rect: CGRect) -> Path { Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 9) }
}

/// Consistent 18-point outline glyphs for the workspace, with no menu arrows.
struct GoviSymbol: View {
    let symbol: String
    var body: some View {
        if symbol == "terminal" {
            Path { p in
                p.move(to: .init(x: 2, y: 4)); p.addLine(to: .init(x: 7, y: 9)); p.addLine(to: .init(x: 2, y: 14))
                p.move(to: .init(x: 9, y: 14)); p.addLine(to: .init(x: 16, y: 14))
            }.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 18, height: 18)
        } else {
            Image(systemName: symbol).font(.system(size: 13.5, weight: .regular)).frame(width: 18, height: 18)
        }
    }
}

/// Own AppKit's native traffic-light widgets independently of the hidden titlebar.
/// Reparenting the window's original buttons is unstable when AppKit rebuilds it.
struct GoviTrafficLights: NSViewRepresentable {
    final class Host: NSView {
        private var buttons: [NSButton] = []
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let controls: [(NSWindow.ButtonType, Selector, String)] = [
                (.closeButton, #selector(closeWindow), "Close window"),
                (.miniaturizeButton, #selector(minimizeWindow), "Minimize window"),
                (.zoomButton, #selector(fullscreenWindow), "Full screen")
            ]
            for (index, control) in controls.enumerated() {
                guard let button = NSWindow.standardWindowButton(control.0, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.target = self
                button.action = control.1
                button.setAccessibilityLabel(control.2)
                button.frame = NSRect(x: index * 21, y: 6, width: 13, height: 13)
                addSubview(button)
                buttons.append(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        @objc private func closeWindow() { window?.performClose(nil) }
        @objc private func minimizeWindow() { window?.performMiniaturize(nil) }
        @objc private func fullscreenWindow() {
            if NSEvent.modifierFlags.contains(.option) { window?.performZoom(nil) }
            else { window?.toggleFullScreen(nil) }
        }
    }
    func makeNSView(context: Context) -> Host { Host(frame: .zero) }
    func updateNSView(_ view: Host, context: Context) {}
}

struct GoviWindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct GoviGlassChromeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var goviGlassChrome: Bool {
        get { self[GoviGlassChromeKey.self] }
        set { self[GoviGlassChromeKey.self] = newValue }
    }
}

/// Chrome icon buttons share one size and one hover treatment everywhere:
/// 28×28, no resting background, a soft rounded fill on hover or when on.
enum GoviChromeMetrics {
    static let button: CGFloat = 28
    static let corner: CGFloat = 7
}

struct GoviHoverHighlight: ViewModifier {
    @Environment(\.goviPalette) private var ui
    var on = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(hovering || on ? ui.ink : ui.muted)
            .background(ui.ink.opacity(on ? 0.10 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: GoviChromeMetrics.corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: GoviChromeMetrics.corner, style: .continuous))
            .onHover { hovering = $0 }
    }
}

struct GoviIconButton: View {
    let symbol: String
    let help: String
    var on = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            GoviSymbol(symbol: symbol)
                .frame(width: GoviChromeMetrics.button, height: GoviChromeMetrics.button)
                .modifier(GoviHoverHighlight(on: on))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct GoviSettingsView: View {
    @Environment(\.goviPalette) private var ui

    var ghostty: Ghostty.App
    var close: (() -> Void)? = nil
    var initialSection = "Appearance"
    /// Inline mode renders inside the terminal window: no own surfaces or
    /// dividers, so the window backdrop runs straight through it.
    var inline = false
    @AppStorage("GoviTheme") private var themeID = "paper"
    @AppStorage("GoviChromeAppearance") private var chromeAppearance = "follow"
    @AppStorage("GoviFont") private var font = "JetBrains Mono"
    @AppStorage("GoviFontSize") private var fontSize = 14
    @AppStorage("GoviPadding") private var padding = 8
    @AppStorage("GoviLineHeight") private var lineHeight = 8
    @AppStorage("GoviCursor") private var cursor = "bar"
    @AppStorage("GoviCursorBlink") private var cursorBlink = false
    @AppStorage("GoviLigatures") private var ligatures = false
    @AppStorage("GoviFontThicken") private var fontThicken = false
    @State private var section = "Appearance"
    @State private var themeSearch = ""
    @State private var themeFilter = "All"
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    private var filteredThemes: [GoviTheme] {
        GoviTheme.all.filter {
            (themeSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(themeSearch)) &&
            (themeFilter == "All" || (themeFilter == "Dark" ? $0.dark : !$0.dark))
        }
    }

    var body: some View {
        if inline {
            layout
                .font(GoviInk.font(12)).foregroundStyle(ui.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { section = initialSection }
                .onExitCommand { close?() }
        } else {
            layout
                .font(GoviInk.font(12)).foregroundStyle(ui.ink).background(ui.paper)
                .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
                .modifier(GoviChromeAppearance())
                .onAppear { section = initialSection }
                .onExitCommand { close?() }
        }
    }

    private var layout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings").font(GoviInk.font(17).weight(.medium)).padding(.bottom, inline ? 16 : 23)
                settingsTab("Appearance", icon: "paintpalette")
                settingsTab("Background", icon: "photo")
                settingsTab("Terminal", icon: "terminal")
                settingsTab("Suggestions", icon: "text.cursor")
                settingsTab("Agents", icon: "bell.badge")
                settingsTab("Connections", icon: "link")
                settingsTab("Shortcuts", icon: "command")
                Spacer()
                Text("Govi").font(GoviInk.font(11).weight(.medium)).foregroundStyle(ui.muted)
                Text("Powered by Ghostty").font(GoviInk.font(10)).foregroundStyle(ui.muted)
            }
            .padding(inline ? 18 : 22).frame(width: 185)
            .background(inline ? Color.clear : ui.sidebar)
            if !inline { Rectangle().fill(ui.line).frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section).font(GoviInk.font(18).weight(.medium))
                    Spacer()
                    if inline, let close {
                        GoviIconButton(symbol: "xmark", help: "Close Settings (Esc)", action: close)
                            .keyboardShortcut(.cancelAction)
                    }
                }.padding(.bottom, 23)
                if section == "Appearance" { appearance }
                else if section == "Background" { GoviBackdropSettingsView(ghostty: ghostty) }
                else if section == "Terminal" { terminal }
                else if section == "Suggestions" { GoviInlineSettingsView() }
                else if section == "Agents" { GoviActivitySettingsView() }
                else if section == "Connections" { GoviIntegrationSettingsView() }
                else { GoviShortcutsSettingsView(ghostty: ghostty) }
                Spacer(minLength: 0)
            }
            .padding(inline ? EdgeInsets(top: 18, leading: 22, bottom: 10, trailing: 6) : EdgeInsets(top: 27, leading: 27, bottom: 27, trailing: 27))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker("Interface appearance", selection: $chromeAppearance) {
                Text("Follow Terminal Theme").tag("follow")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Text("Changes the interface only. Terminal colors stay exactly as defined by the selected theme.")
                .font(GoviInk.font(11)).foregroundStyle(ui.muted)
            fontControls
            Toggle("Show launch animation", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "GoviLaunchAnimation") }, set: { UserDefaults.standard.set($0, forKey: "GoviLaunchAnimation") }))
                .help("Off by default so the terminal appears immediately. Applies on the next launch.")
            Divider().padding(.vertical, 4)
            HStack {
                Text("Color themes").font(GoviInk.font(13).weight(.medium))
                Spacer()
                Text("\(filteredThemes.count) themes").font(GoviInk.font(11)).foregroundStyle(ui.muted)
            }
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ui.muted)
                    TextField("Search themes…", text: $themeSearch).textFieldStyle(.plain)
                }.padding(9).background(ui.canvas, in: RoundedRectangle(cornerRadius: 7))
                ForEach(["All", "Dark", "Light"], id: \.self) { filter in
                    Button { themeFilter = filter } label: {
                        Text(filter).padding(.horizontal, 10).padding(.vertical, 8)
                            .background(themeFilter == filter ? ui.wash : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).foregroundStyle(themeFilter == filter ? ui.ink : ui.muted)
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 17) {
                    ForEach(filteredThemes) { theme in themeCard(theme) }
                }.padding(2)
                if filteredThemes.isEmpty {
                    Text("No themes match your search.").foregroundStyle(ui.muted).padding(.vertical, 30)
                }
            }
        }
    }

    private func themeCard(_ theme: GoviTheme) -> some View {
        Button {
            themeID = theme.id; ghostty.reloadConfig()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Aa").font(.custom(GoviFontCatalog.selected, size: 24))
                        Spacer()
                        Text("~/").padding(4).background(GoviInk.color(theme.border), in: RoundedRectangle(cornerRadius: 4))
                        RoundedRectangle(cornerRadius: 2).fill(GoviInk.color(theme.accent)).frame(width: 6, height: 20)
                    }.foregroundStyle(GoviInk.color(theme.foreground))
                    HStack(spacing: 3) {
                        ForEach(1..<9) { i in Circle().fill(GoviInk.color(theme.palette[i])).frame(width: 11, height: 11) }
                    }
                }
                .padding(12).frame(maxWidth: .infinity).background(GoviInk.color(theme.background))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.id == themeID ? ui.green : ui.line, lineWidth: theme.id == themeID ? 2 : 1))
                HStack {
                    Text(theme.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 2)
                    if theme.id == themeID { Image(systemName: "checkmark.circle.fill").foregroundStyle(ui.green) }
                }
                    .font(GoviInk.font(11))
            }
        }.buttonStyle(.plain).help(theme.name).accessibilityLabel("\(theme.name) theme")
    }

    private var fontControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monospace font").font(GoviInk.font(13).weight(.medium))
            HStack(spacing: 16) {
                Picker("Family", selection: $font) {
                    ForEach(GoviFontCatalog.families, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().menuIndicator(.hidden).frame(maxWidth: .infinity)
                    .onChange(of: font) { _ in ghostty.reloadConfig() }
                numberControl(value: $fontSize, range: 10...28, suffix: "pt")
            }
            Text("Aa Bb Cc  0O 1lI  { } [ ]  => !=")
                .font(.custom(GoviFontCatalog.selected, size: CGFloat(fontSize)))
                .lineLimit(1).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(ui.canvas, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Text and spacing").font(GoviInk.font(13).weight(.medium))
            HStack { Text("Terminal padding"); Spacer(); numberControl(value: $padding, range: 0...32, suffix: "px") }
            HStack { Text("Extra line height"); Spacer(); numberControl(value: $lineHeight, range: 0...40, suffix: "%") }
            Toggle("Font ligatures", isOn: $ligatures).onChange(of: ligatures) { _ in ghostty.reloadConfig() }
            Toggle("Thicker text", isOn: $fontThicken).onChange(of: fontThicken) { _ in ghostty.reloadConfig() }
            Divider().padding(.vertical, 3)
            Text("Cursor").font(GoviInk.font(13).weight(.medium))
            HStack {
                ForEach(["bar", "block", "underline"], id: \.self) { style in
                    Button { cursor = style; ghostty.reloadConfig() } label: {
                        Text(style.capitalized).frame(maxWidth: .infinity).padding(10)
                            .background(cursor == style ? ui.wash : ui.canvas, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(cursor == style ? ui.green : .clear))
                    }.buttonStyle(.plain)
                }
            }
            Toggle("Blink cursor", isOn: $cursorBlink).onChange(of: cursorBlink) { _ in ghostty.reloadConfig() }
        }
    }

    private func numberControl(value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        HStack(spacing: 8) {
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1); ghostty.reloadConfig() } label: { Image(systemName: "minus").frame(width: 22, height: 25) }
                .disabled(value.wrappedValue <= range.lowerBound)
            Text("\(value.wrappedValue) \(suffix)").frame(minWidth: 42)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1); ghostty.reloadConfig() } label: { Image(systemName: "plus").frame(width: 22, height: 25) }
                .disabled(value.wrappedValue >= range.upperBound)
        }.buttonStyle(.plain).padding(.horizontal, 5).background(ui.canvas, in: RoundedRectangle(cornerRadius: 6))
    }

    private func settingsTab(_ title: String, icon: String) -> some View {
        Button { section = title } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .foregroundStyle(section == title ? ui.ink : ui.muted)
                .background(section == title ? ui.wash : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}


/// A dedicated AppKit hit region keeps this control clickable in the hidden
/// titlebar, including the first click when the terminal window is inactive.
struct GoviSidebarToggle: NSViewRepresentable {
    var isOpen: Bool
    var action: () -> Void
    final class Button: NSButton {
        var handler: () -> Void = {}
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc func toggleSidebar() { handler() }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sidebar")
        button.target = button; button.action = #selector(Button.toggleSidebar)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.handler = action
        button.toolTip = isOpen ? "Hide sidebar" : "Show sidebar"
        button.setAccessibilityLabel(button.toolTip)
        button.contentTintColor = .labelColor
    }
}

/// Regular glass separates text-heavy navigation from every terminal palette.
/// Foreground comes from the contrast-checked chrome palette, never ANSI colors.
struct GoviSidebarGlass: ViewModifier {
    @Environment(\.goviPalette) private var ui

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(GoviBackdropStore.styleKey) private var backdrop = "none"
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }
    /// A bright rim, strongest at the top-left, like light catching a glass edge.
    private var rim: some View {
        shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.04), .white.opacity(0.22)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            .allowsHitTesting(false)
    }
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(ui.sidebar, in: shape)
                .clipShape(shape).contentShape(shape)
        } else if backdrop != "none", #available(macOS 26.0, *) {
            // Over a backdrop, clear glass lets the picture through; a faint tint keeps text legible.
            content
                .background(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.01)], startPoint: .top, endPoint: .bottom), in: shape)
                .glassEffect(.clear.tint(ui.sidebar.opacity(0.14)), in: shape)
                .overlay(rim)
                .clipShape(shape).contentShape(shape)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        } else if backdrop != "none" {
            content.background {
                GoviSidebarMaterial().opacity(0.55).overlay(Color.white.opacity(0.04)).clipShape(shape).allowsHitTesting(false)
            }.overlay(rim).clipShape(shape).contentShape(shape)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        } else if #available(macOS 26.0, *) {
            content
                .background(ui.sidebar.opacity(0.28), in: shape)
                .glassEffect(.regular.tint(ui.sidebar.opacity(0.45)), in: shape)
                .clipShape(shape).contentShape(shape)
        } else {
            content.background {
                GoviSidebarMaterial().overlay(ui.sidebar.opacity(0.35)).clipShape(shape).allowsHitTesting(false)
            }.clipShape(shape).contentShape(shape)
        }
    }
}
private struct GoviSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar; view.blendingMode = .withinWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


/// A single optical surface per control, with accessible opaque fallbacks.
struct GoviGlassControl: ViewModifier {
    @Environment(\.goviPalette) private var ui
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var enabled = true
    var highlighted = false
    @ViewBuilder func body(content: Content) -> some View {
        if !enabled { content }
        else if reduceTransparency || contrast == .increased {
            content.background(highlighted ? ui.wash : ui.sidebar, in: Capsule())
                .overlay(Capsule().strokeBorder(ui.line, lineWidth: contrast == .increased ? 1 : 0.5).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content
                .background(ui.wash.opacity(highlighted ? 0.32 : 0.12), in: Capsule())
                .glassEffect(.regular.tint(ui.sidebar.opacity(highlighted ? 0.25 : 0.12)), in: Capsule())
        } else {
            content.background(.thinMaterial, in: Capsule())
                .overlay(Capsule().fill(ui.wash.opacity(highlighted ? 0.20 : 0.08)).allowsHitTesting(false))
        }
    }
}
