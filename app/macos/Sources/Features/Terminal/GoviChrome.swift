import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Session navigation history

/// Full-area panels that take a session's place and count as their own history stops.
enum GoviPanel: String { case settings, tasks }

/// One stop in navigation history: a session, optionally showing a panel over it.
struct GoviPlace: Equatable {
    var session: UUID
    var panel: GoviPanel?
}

extension Notification.Name {
    /// Posted after navigation focuses a session; object is the GoviPlace to show.
    static let goviShowPlace = Notification.Name("app.govi.showPlace")
}

/// Browser-style back/forward across every terminal session the user has focused,
/// in any workspace, plus Settings and Tasks. Entries for closed sessions are skipped, not shown.
final class GoviNavigation: ObservableObject {
    static let shared = GoviNavigation()
    @Published private(set) var backStack: [GoviPlace] = []
    @Published private(set) var forwardStack: [GoviPlace] = []
    private(set) var current: GoviPlace?
    /// Focus changes caused by our own navigation must not be recorded as new visits.
    private var suppressUntil = Date.distantPast

    func record(_ id: UUID?, panel: GoviPanel? = nil) {
        guard let id, Date() >= suppressUntil else { return }
        let place = GoviPlace(session: id, panel: panel)
        guard place != current else { return }
        if let current { backStack.append(current) }
        if backStack.count > 64 { backStack.removeFirst(backStack.count - 64) }
        if !forwardStack.isEmpty { forwardStack.removeAll() }
        current = place
    }

    var canGoBack: Bool { backStack.contains(where: Self.exists) }
    var canGoForward: Bool { forwardStack.contains(where: Self.exists) }

    func goBack() { step(back: true) }
    func goForward() { step(back: false) }

    private func step(back: Bool) {
        while let target = back ? backStack.popLast() : forwardStack.popLast() {
            guard Self.exists(target) else { continue }
            if let current {
                if back { forwardStack.append(current) } else { backStack.append(current) }
            }
            current = target
            suppressUntil = Date().addingTimeInterval(0.4)
            Self.focus(target.session)
            // Let the workspace settle on its new session before opening or closing a panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                NotificationCenter.default.post(name: .goviShowPlace, object: target)
            }
            return
        }
    }

    static func exists(_ place: GoviPlace) -> Bool { GoviPaneCoordinator.owner(of: place.session) != nil }

    /// Bring a session's workspace forward and give it keyboard focus.
    static func focus(_ id: UUID) {
        guard let owner = GoviPaneCoordinator.owner(of: id),
            let view = owner.surfaceTree.first(where: { $0.id == id }),
            let window = owner.window
        else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        owner.focusedSurface = view
        window.makeFirstResponder(view)
    }
}

// MARK: - Backdrop (custom background)

enum GoviBackdropStyle: String, CaseIterable, Identifiable {
    case none, aurora, image
    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: "Quiet"
        case .aurora: "Aurora"
        case .image: "Image"
        }
    }
}

enum GoviBackdropStore {
    static let styleKey = "GoviBackdrop"
    static let imageKey = "GoviBackdropImage"
    static let blurKey = "GoviBackdropBlur"
    static let dimKey = "GoviBackdropDim"

    static var style: GoviBackdropStyle {
        let style = GoviBackdropStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .none
        // An image backdrop without a readable image falls back to the plain canvas.
        if style == .image, image(at: UserDefaults.standard.string(forKey: imageKey) ?? "") == nil { return .none }
        return style
    }

    /// Opacity of the terminal's default background. With a backdrop the terminal is
    /// fully clear and the window-wide tint in `GoviBackdrop` provides contrast, so the
    /// terminal reads as part of the window rather than a box on top of it.
    static var terminalOpacity: Double { style == .none ? 1 : 0 }

    private static var cache: (path: String, image: NSImage)?
    static func image(at path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cache, cache.path == path { return cache.image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache = (path, image)
        return image
    }

    /// Copy the chosen picture into Govi's support folder so it survives the original moving.
    static func importImage(from url: URL) throws -> String {
        let folder = GoviDataPaths.supportDirectory.appendingPathComponent("Backdrops", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let destination = folder.appendingPathComponent("backdrop-\(UUID().uuidString.prefix(8)).\(ext)")
        try FileManager.default.copyItem(at: url, to: destination)
        // Remove earlier copies; only one custom backdrop is kept.
        let previous = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in previous where file.lastPathComponent != destination.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
        return destination.path
    }
}

/// Window-wide background: the theme canvas, optionally covered by a blurred image or
/// the built-in aurora, then dimmed with the canvas color so text stays readable.
struct GoviBackdrop: View {
    @Environment(\.goviPalette) private var ui
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(GoviBackdropStore.styleKey) private var style = GoviBackdropStyle.none.rawValue
    @AppStorage(GoviBackdropStore.imageKey) private var imagePath = ""
    @AppStorage(GoviBackdropStore.blurKey) private var blur = 14.0
    @AppStorage(GoviBackdropStore.dimKey) private var dim = 0.45
    @AppStorage("GoviTheme") private var themeID = "paper"

    var body: some View {
        // Tint with the terminal's own background so its text colors keep their contrast.
        let tint = GoviInk.color((GoviTheme.all.first { $0.id == themeID } ?? GoviTheme.presets[0]).background)
        GeometryReader { geometry in
            ZStack {
                ui.canvas
                if !reduceTransparency {
                    switch GoviBackdropStyle(rawValue: style) ?? .none {
                    case .none: EmptyView()
                    case .aurora:
                        GoviAurora().blur(radius: blur / 3).scaleEffect(1.08)
                        tint.opacity(dim)
                    case .image:
                        if let image = GoviBackdropStore.image(at: imagePath) {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                // A non-opaque blur softens the edges; overscale hides them.
                                .blur(radius: blur).scaleEffect(1 + blur / 200)
                            tint.opacity(dim)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A diagonal band of light over a fine dot screen, drawn without any bundled asset.
struct GoviAurora: View {
    private static let dots: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor(white: 0, alpha: 0.55).setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill(using: .copy)
        image.unlockFocus()
        return image
    }()

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.035, blue: 0.05)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.18),
                    .init(color: Color(red: 0.10, green: 0.25, blue: 0.48).opacity(0.85), location: 0.34),
                    .init(color: Color(red: 0.36, green: 0.58, blue: 0.80), location: 0.43),
                    .init(color: Color(red: 0.93, green: 0.55, blue: 0.22), location: 0.50),
                    .init(color: Color(red: 0.86, green: 0.20, blue: 0.10), location: 0.56),
                    .init(color: Color(red: 0.25, green: 0.08, blue: 0.06).opacity(0.6), location: 0.64),
                    .init(color: .clear, location: 0.78),
                ], startPoint: UnitPoint(x: 0, y: 0.05), endPoint: UnitPoint(x: 1, y: 0.95))
            Rectangle().fill(ImagePaint(image: Image(nsImage: Self.dots), scale: 1))
        }
    }
}

// MARK: - Glass grouping

/// Groups related toolbar buttons into one liquid-glass capsule.
struct GoviGlassGroup: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 3).frame(height: 34).modifier(GoviGlassControl())
    }
}

// MARK: - Custom menus

/// Floating glass surface for Govi's own menus and hover cards (instead of system popovers).
struct GoviGlassPanel: ViewModifier {
    @Environment(\.goviPalette) private var ui
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// How much of the theme's paper color tints the glass; denser for large reading surfaces.
    var tint = 0.55
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
    private var rim: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [.white.opacity(0.35), .white.opacity(0.06), .white.opacity(0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
        )
        .allowsHitTesting(false)
    }
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(ui.paper, in: shape).overlay(shape.strokeBorder(ui.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(ui.paper.opacity(tint)), in: shape)
                .overlay(rim).shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        } else {
            content.background(ui.paper.opacity(tint), in: shape).background(.ultraThinMaterial, in: shape)
                .overlay(rim).shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        }
    }
}

struct GoviMenuRow<Icon: View, Trailing: View>: View {
    @Environment(\.goviPalette) private var ui
    let title: String
    var disabled = false
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let trailing: () -> Trailing
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon().font(.system(size: 12.5)).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? ui.muted : ui.ink)
        .background(hovering && !disabled ? ui.ink.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .disabled(disabled)
    }
}
extension GoviMenuRow where Trailing == Text {
    init(title: String, trailing: String, disabled: Bool = false, @ViewBuilder icon: @escaping () -> Icon, action: @escaping () -> Void) {
        self.init(
            title: title, disabled: disabled, icon: icon, trailing: { Text(trailing).font(GoviInk.font(11)).foregroundColor(.secondary) },
            action: action)
    }
}
extension GoviMenuRow where Trailing == EmptyView {
    init(title: String, disabled: Bool = false, @ViewBuilder icon: @escaping () -> Icon, action: @escaping () -> Void) {
        self.init(title: title, disabled: disabled, icon: icon, trailing: { EmptyView() }, action: action)
    }
}
struct GoviMenuHeader: View {
    @Environment(\.goviPalette) private var ui
    let title: String
    var body: some View {
        Text(title).font(GoviInk.font(11).weight(.medium)).foregroundStyle(ui.muted)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }
}
struct GoviMenuDivider: View {
    @Environment(\.goviPalette) private var ui
    var body: some View { ui.ink.opacity(0.1).frame(height: 0.5).padding(.horizontal, 8).padding(.vertical, 4) }
}

// MARK: - Background settings

struct GoviBackdropSettingsView: View {
    @Environment(\.goviPalette) private var ui
    var ghostty: Ghostty.App
    @AppStorage(GoviBackdropStore.styleKey) private var style = GoviBackdropStyle.none.rawValue
    @AppStorage(GoviBackdropStore.imageKey) private var imagePath = ""
    @AppStorage(GoviBackdropStore.blurKey) private var blur = 14.0
    @AppStorage(GoviBackdropStore.dimKey) private var dim = 0.45
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Window background").font(GoviInk.font(13).weight(.medium))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quiet reading preset").font(GoviInk.font(13).weight(.medium))
                    Text("Solid Graphite colors with your current font and spacing.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
                }
                Spacer()
                Button("Use Quiet Preset") {
                    UserDefaults.standard.set("graphite", forKey: "GoviTheme")
                    style = GoviBackdropStyle.none.rawValue
                    ghostty.reloadConfig()
                }
            }.padding(12).background(ui.canvas, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 14) {
                ForEach(GoviBackdropStyle.allCases) { option in
                    Button {
                        select(option)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            preview(option)
                                .frame(height: 92).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(style == option.rawValue ? ui.accent : ui.line, lineWidth: style == option.rawValue ? 2 : 1)
                                )
                            HStack {
                                Text(option.name)
                                Spacer()
                                if style == option.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(ui.accent) }
                            }.font(GoviInk.font(11))
                        }
                    }.buttonStyle(.plain).accessibilityLabel("\(option.name) background")
                }
            }
            HStack(spacing: 10) {
                Button(imagePath.isEmpty ? "Choose image…" : "Change image…", action: chooseImage)
                if !imagePath.isEmpty {
                    Text(URL(fileURLWithPath: imagePath).lastPathComponent).font(GoviInk.font(11)).foregroundStyle(ui.muted).lineLimit(1)
                    Button("Remove") {
                        try? FileManager.default.removeItem(atPath: imagePath)
                        imagePath = ""
                        if style == GoviBackdropStyle.image.rawValue { select(.none) }
                    }
                }
            }
            if let failure { Text(failure).font(GoviInk.font(11)).foregroundStyle(.red) }
            Divider()
            slider("Blur", value: $blur, range: 0...40, label: "\(Int(blur)) pt")
            slider("Tint", value: $dim, range: 0...0.95, label: "\(Int(dim * 100))%")
            Text(
                "The background fills the whole window, terminal included. Tint washes it with the terminal theme's background color; raise it if text is hard to read. Cells with their own colors stay solid."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func preview(_ option: GoviBackdropStyle) -> some View {
        switch option {
        case .none: ui.canvas.overlay(Text("Theme").font(GoviInk.font(11)).foregroundStyle(ui.muted))
        case .aurora: GoviAurora()
        case .image:
            if let image = GoviBackdropStore.image(at: imagePath) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ui.canvas.overlay(Image(systemName: "photo.badge.plus").font(.system(size: 20)).foregroundStyle(ui.muted))
            }
        }
    }

    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String, commit: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: { editing in if !editing { commit() } })
            Text(label).foregroundStyle(ui.muted).monospacedDigit().frame(width: 48, alignment: .trailing)
        }.disabled(style == GoviBackdropStyle.none.rawValue)
    }

    private func select(_ option: GoviBackdropStyle) {
        if option == .image && GoviBackdropStore.image(at: imagePath) == nil {
            chooseImage()
            return
        }
        style = option.rawValue
        ghostty.reloadConfig()
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image."
        panel.prompt = "Use image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let previous = imagePath
            let path = try GoviBackdropStore.importImage(from: url)
            guard GoviBackdropStore.image(at: path) != nil else {
                failure = "That file could not be read as an image."
                return
            }
            if !previous.isEmpty, previous != path { try? FileManager.default.removeItem(atPath: previous) }
            failure = nil
            imagePath = path
            style = GoviBackdropStyle.image.rawValue
            ghostty.reloadConfig()
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let goviSearchSessions = Notification.Name("goviSearchSessions")
}
