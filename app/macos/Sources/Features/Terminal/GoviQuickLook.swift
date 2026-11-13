import AppKit
import GhosttyKit
import Quartz
import SwiftUI
import WebKit

/// Quick Look for links in a terminal.
///
/// - Hold Shift-Command over a path or web address for a small peek beside the pointer.
/// - Command-click a link Govi has no pane for (an image, a PDF, a web page) to
///   preview it over the window.
/// - Press the Quick Look shortcut (Command-Y) to page through every link the
///   focused terminal has printed, with the arrow keys.
///
/// Command-W or Escape closes a preview. The preview lives in a child panel
/// that never takes the keyboard, so the terminal window stays key and these
/// shortcuts are handled before it sees them.
enum GoviQuickLookPreferences {
    static let clickKey = "GoviQuickLookPreviewsClickedLinks"
    static let hoverKey = "GoviQuickLookPeeksOnHover"
    static var previewsClickedLinks: Bool { UserDefaults.standard.object(forKey: clickKey) as? Bool ?? true }
    static var peeksOnHover: Bool { UserDefaults.standard.object(forKey: hoverKey) as? Bool ?? true }
}

struct GoviPreviewItem: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var isWeb: Bool { !url.isFileURL }
    var title: String { isWeb ? (url.host ?? url.absoluteString) : url.lastPathComponent }
    var icon: String { isWeb ? "globe" : "doc" }

    /// The app macOS would open this with, for the "Open with" button.
    var openerName: String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Width over height for images, so the preview hugs the picture.
    var aspect: CGFloat? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double,
            width > 0, height > 0
        else { return nil }
        let turned = (properties[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        return CGFloat(turned ? height / width : width / height)
    }
}

final class GoviQuickLook: ObservableObject {
    static let shared = GoviQuickLook()
    enum Mode { case peek, full }

    @Published private(set) var items: [GoviPreviewItem] = []
    @Published private(set) var index = 0
    @Published private(set) var mode: Mode = .peek

    static let headerHeight: CGFloat = 32
    private var panel: GoviQuickLookPanel?
    private var dim: GoviQuickLookDim?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    private var anchor = NSPoint.zero

    var current: GoviPreviewItem? { items.indices.contains(index) ? items[index] : nil }
    var isShowing: Bool { panel != nil }

    /// Watches the pointer and modifier keys inside Govi's own windows.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] event in
            self?.hoverEvent(event)
            return event
        }
    }

    // MARK: Peek on hover

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    private func hoverEvent(_ event: NSEvent) {
        pending?.cancel()
        pending = nil
        guard Self.modifiers(event.modifierFlags) == [.command, .shift], GoviQuickLookPreferences.peeksOnHover,
            let window = event.window, window.windowController is BaseTerminalController
        else { return }
        // Wait for the pointer to rest, and for the terminal to learn where it is.
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.peekUnderPointer(in: window)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func peekUnderPointer(in window: NSWindow) {
        guard Self.modifiers(NSEvent.modifierFlags) == [.command, .shift], window.isKeyWindow, window.attachedSheet == nil,
            !(isShowing && mode == .full)
        else { return }
        var view = window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream)
        while let candidate = view, !(candidate is Ghostty.SurfaceView) { view = candidate.superview }
        guard let surface = view as? Ghostty.SurfaceView, let token = surface.goviTokenUnderPointer(),
            let url = GoviLinkRouter.previewTarget(token, relativeTo: surface.pwd)
        else { return }
        if isShowing, parent === window, current?.url == url { return }
        show([.init(url: url)], at: 0, mode: .peek, in: window, anchor: NSEvent.mouseLocation)
    }

    // MARK: Showing

    /// Previews a link that was Command-clicked. Returns false to leave it to macOS.
    func previewClicked(_ raw: String, from surface: Ghostty.SurfaceView) -> Bool {
        guard GoviQuickLookPreferences.previewsClickedLinks, let window = surface.window,
            window.windowController is BaseTerminalController, let url = GoviLinkRouter.previewTarget(raw, relativeTo: surface.pwd)
        else { return false }
        // Folders are better opened in Finder.
        if url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return false }
        show([.init(url: url)], at: 0, mode: .full, in: window)
        return true
    }

    /// The Quick Look shortcut: closes an open preview, otherwise pages through
    /// the links printed in the focused terminal, starting at the newest (or at
    /// the one being peeked).
    func toggle(in controller: BaseTerminalController) {
        let peeked = mode == .peek ? current?.url : nil
        if isShowing, mode == .full {
            close()
            return
        }
        guard let window = controller.window, let surface = controller.focusedSurface else {
            NSSound.beep()
            return
        }
        var urls = GoviLinkRouter.previewTargets(in: surface.cachedScreenContents.get(), relativeTo: surface.pwd)
        if let peeked, !urls.contains(peeked) { urls.append(peeked) }
        guard !urls.isEmpty else {
            close()
            NSSound.beep()
            return
        }
        let start = peeked.flatMap { urls.firstIndex(of: $0) } ?? urls.count - 1
        show(urls.map { GoviPreviewItem(url: $0) }, at: start, mode: .full, in: window)
    }

    private func show(_ items: [GoviPreviewItem], at index: Int, mode: Mode, in window: NSWindow, anchor: NSPoint = .zero) {
        if parent !== window { close() }
        self.items = items
        self.index = index
        self.mode = mode
        self.anchor = anchor
        if panel == nil {
            let panel = GoviQuickLookPanel()
            panel.contentView = NSHostingView(rootView: GoviQuickLookView(model: self).modifier(GoviChromeAppearance()))
            panel.alphaValue = 0
            self.panel = panel
            parent = window
            window.addChildWindow(panel, ordered: .above)
            let center = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.close() })
            }
            observers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.layout(animated: false)
                })
            layout(animated: false)
            panel.animator().alphaValue = 1
        } else {
            layout(animated: true)
        }
    }

    func close() {
        pending?.cancel()
        pending = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        dim?.removeFromSuperview()
        dim = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        parent = nil
        // Emptying the list tears down the web page or Quick Look view.
        items = []
        index = 0
    }

    func step(_ delta: Int) {
        guard items.count > 1 else { return }
        index = (index + delta + items.count) % items.count
        layout(animated: true)
    }

    /// Grow a peek into the full preview.
    func expand() {
        guard isShowing, mode == .peek else { return }
        mode = .full
        layout(animated: true)
    }

    func openExternally() {
        guard let url = current?.url else { return }
        close()
        NSWorkspace.shared.open(url)
    }

    // MARK: Layout

    private func layout(animated: Bool) {
        guard let panel, let parent, let item = current else { return }
        let frame: CGRect
        switch mode {
        case .full:
            showDim(in: parent)
            let bounds = parent.frame
            let limit = CGSize(
                width: max(bounds.width - 2 * max(28, bounds.width * 0.08), 320),
                height: max(bounds.height - 2 * max(28, bounds.height * 0.08), 240))
            var size = limit
            if let aspect = item.aspect {
                let width = min(limit.width, (limit.height - Self.headerHeight) * aspect)
                size = CGSize(width: max(width, 320), height: max(width / aspect + Self.headerHeight, 200))
            }
            size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
            frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        case .peek:
            dim?.removeFromSuperview()
            dim = nil
            let width: CGFloat = item.isWeb ? 380 : 300
            let content = item.aspect.map { min(max(width / $0, 110), 300) } ?? (item.isWeb ? 250 : 190)
            let size = CGSize(width: width, height: content + Self.headerHeight)
            // Below and to the right of the pointer, kept on its screen.
            var origin = CGPoint(x: anchor.x + 14, y: anchor.y - 18 - size.height)
            if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
                if origin.y < visible.minY { origin.y = anchor.y + 18 }
                origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
                origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - size.height - 6)
            }
            frame = CGRect(origin: origin, size: size)
        }
        if animated, panel.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    private func showDim(in window: NSWindow) {
        guard dim == nil, let content = window.contentView else { return }
        let view = GoviQuickLookDim(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        view.onClick = { [weak self] in self?.close() }
        content.addSubview(view, positioned: .above, relativeTo: nil)
        view.alphaValue = 0
        view.animator().alphaValue = 1
        dim = view
    }

    // MARK: Keys

    /// Keys for an open preview, handled before the terminal sees them.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isShowing, let parent, NSApp.keyWindow === parent else { return false }
        let flags = Self.modifiers(event.modifierFlags)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if (flags == .command && key == "w") || (flags.isEmpty && event.keyCode == 53) {
            close()
            return true
        }
        if flags == .command, event.keyCode == 36 {
            openExternally()
            return true
        }
        guard mode == .full else { return false }
        if flags.isEmpty {
            switch event.keyCode {
            case 123: step(-1)
            case 124: step(1)
            case 49: close()
            default: break
            }
        }
        // The preview covers the terminal; don't let stray typing reach it.
        return !flags.contains(.command) && !flags.contains(.control)
    }
}

extension Ghostty.SurfaceView {
    /// The whitespace-delimited text under the pointer, read from the row the
    /// terminal reports for its word under the pointer.
    func goviTokenUnderPointer() -> String? {
        guard let surface else { return nil }
        var word = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &word) else { return nil }
        let start = Int(word.offset_start)
        let visible = word.tl_px_x >= 0
        let wordText = word.text.map { String(cString: $0) } ?? ""
        ghostty_surface_free_text(surface, &word)
        let columns = Int(ghostty_surface_size(surface).columns)
        let trimmed = wordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible, columns > 0, !trimmed.isEmpty else { return nil }
        let row = UInt32(start / columns)
        var line = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: row),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: row),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &line) else { return nil }
        defer { ghostty_surface_free_text(surface, &line) }
        guard let text = line.text else { return nil }
        return GoviLinkRouter.token(in: String(cString: text), atColumn: start % columns, containing: trimmed)
    }
}

// MARK: - Windows

/// Borderless and never key: the terminal window keeps the keyboard.
private final class GoviQuickLookPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Darkens the window behind a full preview; a click on it closes the preview.
private final class GoviQuickLookDim: NSView {
    var onClick: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private struct GoviQuickLookView: View {
    @ObservedObject var model: GoviQuickLook
    @Environment(\.goviPalette) private var ui

    var body: some View {
        if let item = model.current {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            VStack(spacing: 0) {
                header(item)
                Rectangle().fill(ui.line).frame(height: 0.5)
                Group {
                    if item.isWeb { GoviQuickLookWeb(url: item.url) } else { GoviQuickLookFile(url: item.url) }
                }
                .id(item.url)
            }
            .background(ui.paper)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ui.ink.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick Look: \(item.title)")
        }
    }

    private func header(_ item: GoviPreviewItem) -> some View {
        HStack(spacing: 4) {
            button("xmark", "Close (⌘W)") { model.close() }
            if model.mode == .peek {
                button("arrow.up.left.and.arrow.down.right", "Enlarge") { model.expand() }
            } else if model.items.count > 1 {
                button("chevron.left", "Previous link (←)") { model.step(-1) }
                button("chevron.right", "Next link (→)") { model.step(1) }
                Text("\(model.index + 1) of \(model.items.count)").font(GoviInk.font(11)).foregroundStyle(ui.muted).monospacedDigit()
                    .padding(.trailing, 4)
            }
            Image(systemName: item.icon).font(.system(size: 11)).foregroundStyle(ui.muted)
            Text(item.title).font(GoviInk.font(12).weight(.medium)).foregroundStyle(ui.ink).lineLimit(1).truncationMode(.middle)
                .help(item.isWeb ? item.url.absoluteString : item.url.path)
            Spacer(minLength: 6)
            Button {
                model.openExternally()
            } label: {
                Text(item.openerName.map { "Open with \($0)" } ?? "Open")
                    .font(GoviInk.font(11)).foregroundStyle(ui.ink).lineLimit(1)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(ui.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open outside Govi (⌘↩)").layoutPriority(1)
        }
        .padding(.horizontal, 6)
        .frame(height: GoviQuickLook.headerHeight)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22).modifier(GoviHoverHighlight())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

/// The system Quick Look preview: images, GIFs, PDFs, movies, documents.
private struct GoviQuickLookFile: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {}
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// A web page, using the same site-data setting as browser panes.
private struct GoviQuickLookWeb: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = GoviBrowserPreferences.dataStore()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.stopLoading() }
}

// MARK: - Settings

struct GoviQuickLookSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviQuickLookPreferences.clickKey) private var click = true
    @AppStorage(GoviQuickLookPreferences.hoverKey) private var hover = true

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("Peek at a link when I hold ⇧⌘ over it", isOn: $hover)
            Toggle("Preview images, documents and web links I Command-click", isOn: $click)
            Text(
                "\(GoviShortcuts.shared.chord(.quickLook).display) pages through every link in the focused terminal; ← and → move between them. ⌘W or Escape closes a preview, and ⌘↩ opens it outside Govi."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
        }
    }
}
