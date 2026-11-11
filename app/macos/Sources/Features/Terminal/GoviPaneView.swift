import AppKit

/// The base class for everything that can live in a Govi split: terminals
/// (`Ghostty.SurfaceView`) and native panes such as the web pane.
///
/// Members are `@objc` so the terminal's overrides can live in a Govi
/// extension instead of the upstream surface source.
class GoviPaneView: NSView, Identifiable, SplitTreeLeaf {
    typealias ID = UUID

    /// Unique ID per pane. Recovery, drag-and-drop and focus use it.
    let id: UUID

    init(id: UUID, frame: NSRect) {
        self.id = id
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A stable name for the pane type, also written as `kind` when encoded.
    @objc dynamic var paneKind: String { "pane" }
    @objc dynamic var paneTitle: String { "Pane" }
    /// The folder new terminals split from this pane should start in.
    @objc dynamic var paneDirectory: String? { nil }
    /// SF Symbol for title bars and the sidebar.
    @objc dynamic var paneIcon: String { "rectangle" }
    /// Whether closing needs confirmation (a running process, unsaved edits).
    @objc dynamic var paneNeedsConfirmClose: Bool { false }
    /// Called by the controller whenever window or pane focus changes.
    @objc dynamic func paneFocusDidChange(_ focused: Bool) {}
    /// The view that should become first responder when the pane is focused.
    @objc dynamic var paneFocusTarget: NSView { self }

    /// Tells the window's controller that this pane now has focus. Terminals
    /// report focus through SwiftUI; other panes call this when they're
    /// clicked or made first responder.
    func reportFocus() {
        guard let controller = window?.windowController as? BaseTerminalController else { return }
        controller.focusedPaneDidChange(to: self)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.reportFocus() } }
        return result
    }

    // MARK: SplitTreeLeaf

    private enum KindKey: String, CodingKey { case kind }

    func encodeLeaf(to encoder: Encoder) throws {
        guard let value = self as? Encodable else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "\(paneKind) panes can't be encoded"))
        }
        try value.encode(to: encoder)
    }

    /// Older restoration data has no `kind`; those leaves are terminals.
    class func decodeLeaf(from decoder: Decoder) throws -> Self {
        let kind = try decoder.container(keyedBy: KindKey.self).decodeIfPresent(String.self, forKey: .kind)
        let pane: GoviPaneView
        switch kind ?? Ghostty.SurfaceView.kindName {
        case Ghostty.SurfaceView.kindName: pane = try Ghostty.SurfaceView(from: decoder)
        case GoviWebPaneView.kindName: pane = try GoviWebPaneView(from: decoder)
        case GoviEditorPaneView.kindName: pane = try GoviEditorPaneView(from: decoder)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown pane kind \(kind ?? "")"))
        }
        guard let typed = pane as? Self else {
            throw DecodingError.typeMismatch(
                Self.self, .init(codingPath: decoder.codingPath, debugDescription: "Pane kind \(pane.paneKind) is not \(Self.self)"))
        }
        return typed
    }
}

// MARK: - Terminal panes

extension Ghostty.SurfaceView {
    static let kindName = "terminal"

    override var paneKind: String { Self.kindName }
    override var paneTitle: String { GoviPaneNaming.title(self) }
    override var paneDirectory: String? { pwd }
    override var paneIcon: String { "terminal" }
    override var paneNeedsConfirmClose: Bool { needsConfirmQuit }
    override func paneFocusDidChange(_ focused: Bool) { focusDidChange(focused) }
}

// MARK: - Commands for non-terminal panes

extension BaseTerminalController {
    /// Split, close, zoom and focus commands for panes Ghostty doesn't own.
    /// Terminals keep using Ghostty's actions so their keybindings and config
    /// inheritance are unchanged. Returns false for commands that don't apply.
    @discardableResult
    func performPaneCommand(_ action: GoviShortcutAction, on pane: GoviPaneView) -> Bool {
        if let surface = pane as? Ghostty.SurfaceView, let binding = action.terminalAction {
            return surface.surfaceModel?.perform(action: binding) ?? false
        }
        guard let node = surfaceTree.root?.node(view: pane) else { return false }
        switch action {
        case .splitRight: return newSplit(at: pane, direction: .right) != nil
        case .splitDown: return newSplit(at: pane, direction: .down) != nil
        case .closeTerminal:
            closeSurface(node, withConfirmation: true)
            return true
        case .zoom:
            toggleZoom(node, focus: pane)
            return true
        case .left, .right, .up, .down:
            let direction: SplitTree<GoviPaneView>.Spatial.Direction =
                switch action {
                case .left: .left
                case .right: .right
                case .up: .up
                default: .down
                }
            guard let next = surfaceTree.focusTarget(for: .spatial(direction), from: node) else { return false }
            if surfaceTree.zoomed != nil { surfaceTree = .init(root: surfaceTree.root, zoomed: nil) }
            DispatchQueue.main.async { Ghostty.moveFocus(to: next, from: pane) }
            return true
        case .palette:
            toggleCommandPalette(nil)
            return true
        case .newWorkspace, .newWindow:
            // New terminals start in the pane's folder, else the window's terminal.
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.paneDirectory ?? surfaceTree.surfaces.first?.pwd
            if action == .newWindow {
                _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
            } else {
                _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
            }
            return true
        default:
            return false
        }
    }

    /// Zoom a pane to fill the window, or restore the split layout.
    func toggleZoom(_ node: SplitTree<GoviPaneView>.Node, focus pane: GoviPaneView) {
        if surfaceTree.zoomed == node {
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            guard surfaceTree.isSplit else { return }
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: node)
        }
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
    }

    /// Open a browser pane beside the focused pane, or as the only pane.
    @discardableResult
    func openWebPane(
        _ address: String? = nil, beside: GoviPaneView? = nil, direction: SplitTree<GoviPaneView>.NewDirection = .right
    ) -> GoviWebPaneView? {
        let pane = GoviWebPaneView()
        if let address { pane.load(address) }
        return insertPane(pane, beside: beside, direction: direction, undoAction: "Open Browser") ? pane : nil
    }

    /// Adds `pane` beside `anchor` (or the focused pane) and focuses it.
    func insertPane(
        _ pane: GoviPaneView, beside anchor: GoviPaneView?, direction: SplitTree<GoviPaneView>.NewDirection = .right,
        undoAction: String
    ) -> Bool {
        let anchor = anchor.flatMap { surfaceTree.contains($0) ? $0 : nil } ?? focusedPane ?? surfaceTree.root?.leftmostLeaf()
        let tree: SplitTree<GoviPaneView>
        do {
            tree = try anchor.map { try surfaceTree.insert(view: pane, at: $0, direction: direction) } ?? .init(view: pane)
        } catch {
            Ghostty.logger.warning("failed to open \(pane.paneKind) pane: \(error)")
            return false
        }
        replaceSurfaceTree(tree, moveFocusTo: pane, moveFocusFrom: focusedPane, undoAction: undoAction)
        return true
    }
}

// MARK: - Typed views of a pane tree

extension SplitTree where ViewType == GoviPaneView {
    /// The terminal panes in this tree, in layout order.
    var surfaces: [Ghostty.SurfaceView] { compactMap { $0 as? Ghostty.SurfaceView } }
}

extension SplitTree.Node where ViewType == GoviPaneView {
    var surfaces: [Ghostty.SurfaceView] { leaves().compactMap { $0 as? Ghostty.SurfaceView } }
}

extension GoviLinkRouter {
    /// Opens a clicked link inside Govi when that's the better home for it.
    /// Returns false to let the caller open it with macOS.
    static func open(_ url: URL, from surface: Ghostty.SurfaceView) -> Bool {
        guard isLocalWeb(url), let controller = surface.window?.windowController as? BaseTerminalController else { return false }
        return controller.showWebPane(browsable(url), beside: surface) != nil
    }
}

extension BaseTerminalController {
    /// Shows `url` in this window: reuses a browser pane already on the same
    /// origin, otherwise opens one beside `anchor`.
    @discardableResult
    func showWebPane(_ url: URL, beside anchor: GoviPaneView? = nil) -> GoviWebPaneView? {
        if let existing = surfaceTree.compactMap({ $0 as? GoviWebPaneView })
            .first(where: { $0.url.map(GoviLinkRouter.origin) == GoviLinkRouter.origin(url) }) {
            existing.load(url.absoluteString)
            if surfaceTree.zoomed != nil { surfaceTree = .init(root: surfaceTree.root, zoomed: nil) }
            DispatchQueue.main.async { Ghostty.moveFocus(to: existing) }
            return existing
        }
        return openWebPane(url.absoluteString, beside: anchor)
    }
}
