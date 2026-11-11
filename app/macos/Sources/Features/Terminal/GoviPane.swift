import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum GoviPaneNaming {
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func title(_ pane: GoviPaneView) -> String {
        if let surface = pane as? Ghostty.SurfaceView { return title(surface) }
        return pane.paneTitle
    }
    static func title(_ surface: Ghostty.SurfaceView) -> String {
        let title = surface.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = surface.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let isFolderTitle =
            title.isEmpty || title == "~" || title.hasPrefix("/") || title.hasPrefix("~/") || title.hasPrefix("…/")
            || title.hasPrefix(".../") || title == URL(fileURLWithPath: path).lastPathComponent
        if !isFolderTitle {
            let words = title.split(separator: " ")
            let executable = words.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? title
            if executable.lowercased() == "claude" { return "Claude" }
            if executable.lowercased() == "codex" { return "Codex" }
            if ["bun", "npm", "pnpm", "yarn"].contains(executable) { return words.prefix(3).joined(separator: " ") }
            return title
        }
        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent
        return path == FileManager.default.homeDirectoryForCurrentUser.path ? "\(shell) ~" : shell
    }
}

private struct GoviActivePaneKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var goviActivePane: UUID? {
        get { self[GoviActivePaneKey.self] }
        set { self[GoviActivePaneKey.self] = newValue }
    }
}

enum GoviPaneMetrics { static let headerHeight: CGFloat = 30 }

struct GoviPaneDropTarget: Equatable {
    let id: UUID
    let zone: GoviSnapZone
}

final class GoviPaneDragPreview: ObservableObject {
    static let shared = GoviPaneDragPreview()
    @Published var target: GoviPaneDropTarget?
}

enum GoviPaneCoordinator {
    static let typeID = "dev.govi.terminal.pane"
    static let pasteboardType = NSPasteboard.PasteboardType(typeID)
    private(set) static var draggedID: UUID?
    static func beginDrag(_ surface: GoviPaneView) {
        draggedID = surface.id
        GoviPaneDragPreview.shared.target = nil
    }
    static func endDrag() {
        draggedID = nil
        GoviPaneDragPreview.shared.target = nil
    }
    static func dragProvider(for surface: GoviPaneView) -> NSItemProvider {
        beginDrag(surface)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeID, visibility: .ownProcess) { completion in
            completion(Data(surface.id.uuidString.utf8), nil)
            return nil
        }
        provider.suggestedName = GoviPaneNaming.title(surface)
        return provider
    }
    static func owner(of id: UUID) -> TerminalController? { TerminalController.all.first { $0.surfaceTree.find(id: id) != nil } }

    @discardableResult
    static func previewDrop(on target: GoviPaneView, at point: CGPoint, in size: CGSize) -> GoviSnapZone? {
        guard let draggedID, draggedID != target.id, owner(of: draggedID) != nil, owner(of: target.id) != nil,
            size.width > 0, size.height > 0, point.x.isFinite, point.y.isFinite
        else {
            leaveDrop(on: target.id)
            return nil
        }
        let zone = GoviSnapZone.at(point, size: size)
        let next = GoviPaneDropTarget(id: target.id, zone: zone)
        if GoviPaneDragPreview.shared.target != next { GoviPaneDragPreview.shared.target = next }
        return zone
    }
    static func leaveDrop(on target: UUID) {
        if GoviPaneDragPreview.shared.target?.id == target { GoviPaneDragPreview.shared.target = nil }
    }

    /// Native terminal surfaces handle pane drops explicitly, so a drop over
    /// terminal text is docking rather than a paste or a lost SwiftUI drop.
    static func updateNativeDrop(_ sender: any NSDraggingInfo, on target: GoviPaneView) -> NSDragOperation? {
        guard sender.draggingPasteboard.types?.contains(pasteboardType) == true else { return nil }
        guard nativeDragID(sender) == draggedID, draggedID != nil else {
            leaveDrop(on: target.id)
            return []
        }
        let local = target.convert(sender.draggingLocation, from: nil)
        let y = target.isFlipped ? local.y - target.bounds.minY : target.bounds.maxY - local.y
        let point = CGPoint(x: local.x - target.bounds.minX, y: y + GoviPaneMetrics.headerHeight)
        let size = CGSize(width: target.bounds.width, height: target.bounds.height + GoviPaneMetrics.headerHeight)
        return previewDrop(on: target, at: point, in: size) == nil ? [] : .move
    }
    static func performNativeDrop(_ sender: any NSDraggingInfo, on target: GoviPaneView) -> Bool? {
        guard let operation = updateNativeDrop(sender, on: target) else { return nil }
        guard operation == .move, let id = draggedID, let destination = GoviPaneDragPreview.shared.target,
            destination.id == target.id
        else { return false }
        endDrag()
        // Finish AppKit's drop dispatch before reparenting its destination view.
        DispatchQueue.main.async { move(id, to: target, zone: destination.zone) }
        return true
    }
    private static func nativeDragID(_ sender: any NSDraggingInfo) -> UUID? {
        let board = sender.draggingPasteboard
        let value =
            board.string(forType: pasteboardType)
            ?? board.data(forType: pasteboardType).flatMap { String(data: $0, encoding: .utf8) }
        return value.flatMap(UUID.init(uuidString:))
    }

    @discardableResult
    static func move(_ id: UUID, to target: GoviPaneView, zone: GoviSnapZone) -> Bool {
        guard id != target.id, let source = owner(of: id), let destination = owner(of: target.id),
            let view = source.surfaceTree.first(where: { $0.id == id })
        else { return false }
        do {
            if source === destination {
                let tree = try source.surfaceTree.docking(view: view, to: target, zone: zone)
                source.replaceSurfaceTree(tree, moveFocusTo: view, moveFocusFrom: source.focusedPane, undoAction: "Move Pane")
            } else if zone != .center {
                // Construct both results before changing ownership. Strong references
                // keep the same SurfaceView/PTY alive throughout the transfer.
                let targetTree = try destination.surfaceTree.docking(view: view, to: target, zone: zone)
                let sourceTree = source.surfaceTree.remove(.leaf(view: view))
                source.undoManager?.removeAllActions(withTarget: source)
                destination.undoManager?.removeAllActions(withTarget: destination)
                destination.surfaceTree = targetTree
                source.surfaceTree = sourceTree
                source.focusedPane = sourceTree.root?.leaves().first
            } else {
                let sourceTree = try source.surfaceTree.replace(node: .leaf(view: view), with: .leaf(view: target))
                let targetTree = try destination.surfaceTree.replace(node: .leaf(view: target), with: .leaf(view: view))
                source.undoManager?.removeAllActions(withTarget: source)
                destination.undoManager?.removeAllActions(withTarget: destination)
                source.surfaceTree = sourceTree
                destination.surfaceTree = targetTree
                source.focusedPane = target
            }
            destination.focusedPane = view
            destination.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { destination.window?.makeFirstResponder(view.paneFocusTarget) }
            NotificationCenter.default.post(name: .goviLayoutChanged, object: nil)
            return true
        } catch {
            Ghostty.logger.warning("Unable to rearrange terminal panes: \(error.localizedDescription)")
            return false
        }
    }

    static func arrange(_ views: [GoviPaneView]) {
        guard let first = views.first, let owner = owner(of: first.id), views.count > 1 else { return }
        typealias Tree = SplitTree<GoviPaneView>
        func build(_ items: ArraySlice<GoviPaneView>, horizontal: Bool) -> Tree.Node {
            if items.count == 1 { return .leaf(view: items.first!) }
            let mid = (items.count + 1) / 2
            return .split(
                .init(
                    direction: horizontal ? .horizontal : .vertical, ratio: 0.5,
                    left: build(items.prefix(mid), horizontal: !horizontal), right: build(items.dropFirst(mid), horizontal: !horizontal)))
        }
        owner.replaceSurfaceTree(
            .init(root: build(views[...], horizontal: true), zoomed: nil),
            moveFocusTo: owner.focusedPane, moveFocusFrom: owner.focusedPane, undoAction: "Arrange Panes")
        DispatchQueue.main.async { if let focused = owner.focusedPane { owner.window?.makeFirstResponder(focused.paneFocusTarget) } }
        NotificationCenter.default.post(name: .goviLayoutChanged, object: nil)
    }
}

struct GoviTerminalPane: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    var isSplit: Bool

    var body: some View {
        GoviPaneFrame(pane: surface, isSplit: isSplit, label: "Terminal pane") { showButtons in
            GoviPaneBar(surface: surface, isSplit: isSplit, showButtons: showButtons)
        } content: {
            Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: isSplit)
        }
    }
}

/// The layout every pane shares: a title bar, the content, the active-pane
/// line, the docking preview and the drop target for pane drags.
struct GoviPaneFrame<Header: View, Content: View>: View {
    @Environment(\.goviPalette) private var ui

    let pane: GoviPaneView
    var isSplit: Bool
    var label: String
    @ViewBuilder var header: (_ showButtons: Bool) -> Header
    @ViewBuilder var content: () -> Content
    @ObservedObject private var dragPreview = GoviPaneDragPreview.shared
    @Environment(\.goviActivePane) private var activeID
    @State private var hovering = false
    // Re-render when the backdrop or terminal opacity changes in Settings.
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"
    private var active: Bool { activeID == pane.id }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header(active || hovering)
                    .onHover { hovering = $0 }
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The terminal surface already paints its own translucent background;
            // a second layer here would stack up and hide the backdrop.
            .background(
                GoviBackdropStore.terminalOpacity < 1 ? Color.clear : GoviInk.color(GoviTheme.current.background), ignoresSafeAreaEdges: []
            )
            .overlay(alignment: .top) { if isSplit && active { ui.line.frame(height: 1).allowsHitTesting(false) } }
            .overlay(alignment: .topLeading) {
                if let target = dragPreview.target, target.id == pane.id {
                    let rect = target.zone.rect(in: geometry.size).insetBy(dx: 3, dy: 3)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ui.accent.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ui.accent.opacity(0.85), lineWidth: 1.5))
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onDrop(of: [GoviPaneCoordinator.typeID], delegate: GoviPaneDropDelegate(surface: pane, size: geometry.size))
            .background(GoviPaneFrameProbe(id: pane.id))
        }
        .accessibilityElement(children: .contain).accessibilityLabel("\(label): \(GoviPaneNaming.title(pane))")
    }
}

/// SwiftUI handles the title/gaps; the native surface handles terminal content.
/// Both routes publish the same pane-local preview and use the same move logic.
private struct GoviPaneDropDelegate: DropDelegate {
    let surface: GoviPaneView
    let size: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [GoviPaneCoordinator.typeID]) && GoviPaneCoordinator.draggedID != nil
            && GoviPaneCoordinator.draggedID != surface.id
    }
    func dropEntered(info: DropInfo) { GoviPaneCoordinator.previewDrop(on: surface, at: info.location, in: size) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let zone = GoviPaneCoordinator.previewDrop(on: surface, at: info.location, in: size)
        return DropProposal(operation: zone == nil ? .cancel : .move)
    }
    func dropExited(info: DropInfo) { GoviPaneCoordinator.leaveDrop(on: surface.id) }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = GoviPaneCoordinator.draggedID,
            let zone = GoviPaneCoordinator.previewDrop(on: surface, at: info.location, in: size),
            let provider = info.itemProviders(for: [GoviPaneCoordinator.typeID]).first
        else {
            GoviPaneCoordinator.leaveDrop(on: surface.id)
            return false
        }
        GoviPaneCoordinator.endDrag()
        provider.loadDataRepresentation(forTypeIdentifier: GoviPaneCoordinator.typeID) { data, _ in
            DispatchQueue.main.async {
                guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text),
                    id == source
                else { return }
                GoviPaneCoordinator.move(id, to: surface, zone: zone)
            }
        }
        return true
    }
}

/// A native mouse drag starts immediately from the title, with no long press or
/// SwiftUI tap recognizer competing with it. The pane's controls stay separate.
struct GoviPaneDragHandle: NSViewRepresentable {
    let surface: GoviPaneView
    let isSplit: Bool

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.registerForDraggedTypes([GoviPaneCoordinator.pasteboardType])
        return view
    }
    func updateNSView(_ view: Handle, context: Context) {
        view.surface = surface
        view.isSplit = isSplit
        view.floatingDrag = context.environment.goviFloatingDrag
        view.toolTip =
            view.floatingDrag == nil
            ? "Drag to dock this pane beside another. Drop in the center to swap."
            : "Drag to move. Double-click, or press the detach button again, to dock it beside the nearest pane."
    }

    final class Handle: NSView, NSDraggingSource {
        weak var surface: GoviPaneView?
        var isSplit = false
        /// Set when this title bar belongs to a floating panel: dragging moves the panel.
        var floatingDrag: GoviFloatingDrag?
        private var floatingStart: CGPoint?
        private var mouseDownPoint: CGPoint?
        private var dragging = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            if let surface { surface.window?.makeFirstResponder(surface.paneFocusTarget) }
            if let floatingDrag {
                if event.clickCount == 2 {
                    floatingStart = nil
                    floatingDrag.doubleClicked()
                } else {
                    floatingStart = event.locationInWindow
                    floatingDrag.began()
                }
                return
            }
            if event.clickCount == 2, isSplit, let surface {
                (surface.window?.windowController as? BaseTerminalController)?.performPaneCommand(.zoom, on: surface)
                mouseDownPoint = nil
            } else {
                mouseDownPoint = convert(event.locationInWindow, from: nil)
            }
        }
        override func mouseUp(with event: NSEvent) {
            mouseDownPoint = nil
            if let floatingDrag, floatingStart != nil {
                floatingStart = nil
                NSCursor.arrow.set()
                floatingDrag.ended()
            }
        }
        override func mouseDragged(with event: NSEvent) {
            if let floatingDrag {
                guard let start = floatingStart else { return }
                let point = event.locationInWindow
                NSCursor.closedHand.set()
                // Window coordinates grow upward; panel offsets grow downward.
                floatingDrag.moved(CGSize(width: point.x - start.x, height: start.y - point.y))
                return
            }
            guard !dragging, let start = mouseDownPoint, let surface else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragging = true
            GoviPaneCoordinator.beginDrag(surface)
            let writer = NSPasteboardItem()
            writer.setString(surface.id.uuidString, forType: GoviPaneCoordinator.pasteboardType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = dragImage(title: GoviPaneNaming.title(surface))
            item.setDraggingFrame(
                NSRect(x: point.x - 12, y: point.y - 14, width: image.size.width, height: image.size.height), contents: image)
            NSCursor.closedHand.set()
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            mouseDownPoint = nil
            GoviPaneCoordinator.endDrag()
            NSCursor.arrow.set()
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let surface else { return [] }
            return GoviPaneCoordinator.updateNativeDrop(sender, on: surface) ?? []
        }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            if let surface { GoviPaneCoordinator.leaveDrop(on: surface.id) }
        }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let surface else { return false }
            return GoviPaneCoordinator.performNativeDrop(sender, on: surface) ?? false
        }
        private func dragImage(title: String) -> NSImage {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
            let text = NSAttributedString(string: title, attributes: attributes)
            let image = NSImage(size: NSSize(width: min(260, text.size().width + 24), height: 28))
            image.lockFocus()
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: 7, yRadius: 7).fill()
            text.draw(in: NSRect(x: 12, y: 6, width: image.size.width - 24, height: 16))
            image.unlockFocus()
            return image
        }
    }
}

/// Title and split controls at the top of every terminal pane.
struct GoviPaneBar: View {
    @Environment(\.goviPalette) private var ui
    @Environment(\.goviFloatingDrag) private var floatingDrag
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    var isSplit: Bool
    var showButtons: Bool
    // Re-render when the backdrop or terminal opacity changes in Settings.
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"
    /// The latest local dev-server address on screen, offered as a chip.
    @State private var localURL: URL?
    @AppStorage(GoviBrowserPreferences.detectKey) private var detectLocal = true
    private let scan = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let title = GoviPaneNaming.title(surface)
        let path = surface.pwd.map(GoviPaneNaming.shortPath)
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                GoviSymbol(symbol: "arrow.up.and.down.and.arrow.left.and.right").scaleEffect(0.75).frame(width: 14, height: 14)
                    .foregroundStyle(ui.muted)
                Text(title).foregroundStyle(ui.ink).lineLimit(1)
                if let path, path != "~" || !title.hasSuffix("~") {
                    Text(path).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: GoviPaneMetrics.headerHeight)
                .overlay { GoviPaneDragHandle(surface: surface, isSplit: isSplit) }
                .help("Drag to dock beside another pane; drop in its center to swap")
            if let localURL {
                let label = (localURL.host ?? "localhost") + (localURL.port.map { ":\($0)" } ?? "")
                Button {
                    (surface.window?.windowController as? BaseTerminalController)?.showWebPane(localURL, beside: surface)
                } label: {
                    Label(label, systemImage: "globe").labelStyle(.titleAndIcon).font(GoviInk.font(11)).lineLimit(1)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(ui.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(ui.ink)
                }.buttonStyle(.plain).fixedSize()
                    .help("Open \(localURL.absoluteString) in a browser pane")
                    .accessibilityLabel("Open \(label) in a browser pane")
            }
            HStack(spacing: 2) {
                if floatingDrag == nil {
                    button("rectangle.split.2x1", "Split right (\(shortcuts.chord(.splitRight).display))") { perform("new_split:right") }
                    button("rectangle.split.1x2", "Split below (\(shortcuts.chord(.splitDown).display))") { perform("new_split:down") }
                    button("plus.square.on.square", "New workspace here (\(shortcuts.chord(.newWorkspace).display))") { perform("new_tab") }
                }
                GoviFloatingButtons(pane: surface, isSplit: isSplit)
                if isSplit && floatingDrag == nil {
                    button("arrow.up.left.and.arrow.down.right", "Maximize / restore terminal (\(shortcuts.chord(.zoom).display))") {
                        perform("toggle_split_zoom")
                    }
                }
                button("xmark", "Close terminal (\(shortcuts.chord(.closeTerminal).display))") { perform("close_surface") }
            }.opacity(showButtons ? 1 : 0).allowsHitTesting(showButtons)
        }
        .font(GoviInk.font(12))
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: GoviPaneMetrics.headerHeight)
        .background(GoviInk.color(GoviTheme.current.background).opacity(GoviBackdropStore.terminalOpacity), ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: showButtons)
        .onReceive(scan) { _ in
            // Only windows on screen; the surface caches its visible text for 500 ms.
            guard detectLocal, surface.window?.occlusionState.contains(.visible) == true, !surface.processExited else {
                if localURL != nil { localURL = nil }
                return
            }
            let found = GoviLinkRouter.latestLocalURL(in: surface.cachedVisibleContents.get())
            if found != localURL { localURL = found }
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 24).modifier(GoviHoverHighlight())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func perform(_ action: String) {
        surface.window?.makeFirstResponder(surface)
        _ = surface.surfaceModel?.perform(action: action)
    }
}

// MARK: - Browser pane

/// A browser in a split: the shared pane frame around a `GoviWebPaneView`.
struct GoviWebPane: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviWebPaneView
    var isSplit: Bool
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"

    var body: some View {
        // Over a backdrop a page can't be see-through like the terminal, so it sits in the
        // window as a rounded sheet, and an empty pane shows the backdrop rather than a blank box.
        let floating = GoviBackdropStore.terminalOpacity < 1
        GoviPaneFrame(pane: pane, isSplit: isSplit, label: "Browser pane") { showButtons in
            GoviWebPaneBar(pane: pane, isSplit: isSplit, showButtons: showButtons)
        } content: {
            GoviPaneHost(view: pane)
                .opacity(pane.url == nil ? 0 : 1)
                .padding([.horizontal, .bottom], floating ? 6 : 0)
                .overlay {
                    if pane.url == nil {
                        VStack(spacing: 10) {
                            GoviGlyph(kind: .globe).scaleEffect(2.2).frame(width: 40, height: 40).foregroundStyle(ui.color(for: .globe))
                            Text("Type an address above, such as localhost:3000").font(GoviInk.font(12)).foregroundStyle(ui.muted)
                        }.allowsHitTesting(false)
                    }
                }
                .onAppear { pane.setRounded(floating) }
                .onChange(of: backdropStyle) { _ in pane.setRounded(GoviBackdropStore.terminalOpacity < 1) }
                .overlay(alignment: .bottom) {
                    if let problem = pane.problem {
                        Text(problem).font(GoviInk.font(11.5)).foregroundStyle(ui.ink).lineLimit(2)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .padding(10)
                            .accessibilityLabel("Browser problem: \(problem)")
                    }
                }
        }
    }
}

/// Puts an existing pane view (and its live state) into SwiftUI without
/// recreating it when the split layout changes.
struct GoviPaneHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Title, address field and pane controls for a browser pane.
private struct GoviWebPaneBar: View {
    @Environment(\.goviPalette) private var ui
    @Environment(\.goviFloatingDrag) private var floatingDrag
    @ObservedObject var pane: GoviWebPaneView
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    var isSplit: Bool
    var showButtons: Bool
    @State private var address = ""
    @FocusState private var editing: Bool
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: pane.isLoading ? "hourglass" : "globe").font(.system(size: 11)).foregroundStyle(ui.muted)
                    .frame(width: 14, height: 14)
                Text(pane.paneTitle).foregroundStyle(ui.ink).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
            }
            .frame(height: GoviPaneMetrics.headerHeight)
            .overlay { GoviPaneDragHandle(surface: pane, isSplit: isSplit) }
            .help("Drag to dock beside another pane; drop in its center to swap")
            button("chevron.left", "Back") { pane.goBack() }.disabled(!pane.canGoBack)
            button("chevron.right", "Forward") { pane.goForward() }.disabled(!pane.canGoForward)
            button(pane.isLoading ? "xmark" : "arrow.clockwise", pane.isLoading ? "Stop loading" : "Reload") { pane.reload() }
            Button { pane.togglePicker() } label: {
                Image(systemName: "cursorarrow.rays").font(.system(size: 12, weight: .regular))
                    .foregroundStyle(pane.isPicking ? ui.accent : ui.ink)
                    .frame(width: 24, height: 24).modifier(GoviHoverHighlight())
            }.buttonStyle(.plain).disabled(pane.url == nil)
                .help(pane.isPicking ? "Cancel picking (Esc)" : "Pick an element and send it to the last terminal you used")
                .accessibilityLabel(pane.isPicking ? "Cancel element picker" : "Pick an element")
            TextField("Address, such as localhost:3000", text: $address)
                .textFieldStyle(.plain).font(GoviInk.font(11.5)).foregroundStyle(ui.ink)
                .padding(.horizontal, 8).frame(height: 22)
                .background(ui.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .focused($editing)
                .onSubmit { if pane.load(address) { pane.window?.makeFirstResponder(pane.paneFocusTarget) } }
                .accessibilityLabel("Address")
            HStack(spacing: 2) {
                if floatingDrag == nil {
                    button("rectangle.split.2x1", "Split right (\(shortcuts.chord(.splitRight).display))") { command(.splitRight) }
                    button("rectangle.split.1x2", "Split below (\(shortcuts.chord(.splitDown).display))") { command(.splitDown) }
                }
                GoviFloatingButtons(pane: pane, isSplit: isSplit)
                if isSplit && floatingDrag == nil {
                    button("arrow.up.left.and.arrow.down.right", "Maximize / restore pane (\(shortcuts.chord(.zoom).display))") {
                        command(.zoom)
                    }
                }
                button("xmark", "Close pane (\(shortcuts.chord(.closeTerminal).display))") { command(.closeTerminal) }
            }.opacity(showButtons ? 1 : 0).allowsHitTesting(showButtons)
        }
        .font(GoviInk.font(12))
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: GoviPaneMetrics.headerHeight)
        .background(GoviInk.color(GoviTheme.current.background).opacity(GoviBackdropStore.terminalOpacity), ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: showButtons)
        .onAppear {
            address = pane.url?.absoluteString ?? ""
            // A new, empty browser starts with the address field ready for typing.
            if pane.url == nil { DispatchQueue.main.async { editing = true } }
        }
        .onChange(of: pane.url) { url in if !editing { address = url?.absoluteString ?? "" } }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 24).modifier(GoviHoverHighlight())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func command(_ action: GoviShortcutAction) {
        (pane.window?.windowController as? BaseTerminalController)?.performPaneCommand(action, on: pane)
    }
}
