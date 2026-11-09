import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum GoviPaneNaming {
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func title(_ surface: Ghostty.SurfaceView) -> String {
        let title = surface.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = surface.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let isFolderTitle = title.isEmpty || title == "~" || title.hasPrefix("/") || title.hasPrefix("~/") || title.hasPrefix("…/") || title.hasPrefix(".../") || title == URL(fileURLWithPath: path).lastPathComponent
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

private enum GoviPaneMetrics { static let headerHeight: CGFloat = 30 }

private struct GoviPaneDropTarget: Equatable {
    let id: UUID
    let zone: GoviSnapZone
}

private final class GoviPaneDragPreview: ObservableObject {
    static let shared = GoviPaneDragPreview()
    @Published var target: GoviPaneDropTarget?
}

enum GoviPaneCoordinator {
    static let typeID = "dev.govi.terminal.pane"
    static let pasteboardType = NSPasteboard.PasteboardType(typeID)
    private(set) static var draggedID: UUID?
    static func beginDrag(_ surface: Ghostty.SurfaceView) {
        draggedID = surface.id
        GoviPaneDragPreview.shared.target = nil
    }
    static func endDrag() {
        draggedID = nil
        GoviPaneDragPreview.shared.target = nil
    }
    static func dragProvider(for surface: Ghostty.SurfaceView) -> NSItemProvider {
        beginDrag(surface)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeID, visibility: .ownProcess) { completion in
            completion(Data(surface.id.uuidString.utf8), nil); return nil
        }
        provider.suggestedName = GoviPaneNaming.title(surface)
        return provider
    }
    static func owner(of id: UUID) -> TerminalController? { TerminalController.all.first { $0.surfaceTree.find(id: id) != nil } }

    @discardableResult
    static func previewDrop(on target: Ghostty.SurfaceView, at point: CGPoint, in size: CGSize) -> GoviSnapZone? {
        guard let draggedID, draggedID != target.id, owner(of: draggedID) != nil, owner(of: target.id) != nil,
              size.width > 0, size.height > 0, point.x.isFinite, point.y.isFinite else {
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
    static func updateNativeDrop(_ sender: any NSDraggingInfo, on target: Ghostty.SurfaceView) -> NSDragOperation? {
        guard sender.draggingPasteboard.types?.contains(pasteboardType) == true else { return nil }
        guard nativeDragID(sender) == draggedID, draggedID != nil else { leaveDrop(on: target.id); return [] }
        let local = target.convert(sender.draggingLocation, from: nil)
        let y = target.isFlipped ? local.y - target.bounds.minY : target.bounds.maxY - local.y
        let point = CGPoint(x: local.x - target.bounds.minX, y: y + GoviPaneMetrics.headerHeight)
        let size = CGSize(width: target.bounds.width, height: target.bounds.height + GoviPaneMetrics.headerHeight)
        return previewDrop(on: target, at: point, in: size) == nil ? [] : .move
    }
    static func performNativeDrop(_ sender: any NSDraggingInfo, on target: Ghostty.SurfaceView) -> Bool? {
        guard let operation = updateNativeDrop(sender, on: target) else { return nil }
        guard operation == .move, let id = draggedID, let destination = GoviPaneDragPreview.shared.target,
              destination.id == target.id else { return false }
        endDrag()
        // Finish AppKit's drop dispatch before reparenting its destination view.
        DispatchQueue.main.async { move(id, to: target, zone: destination.zone) }
        return true
    }
    private static func nativeDragID(_ sender: any NSDraggingInfo) -> UUID? {
        let board = sender.draggingPasteboard
        let value = board.string(forType: pasteboardType)
            ?? board.data(forType: pasteboardType).flatMap { String(data: $0, encoding: .utf8) }
        return value.flatMap(UUID.init(uuidString:))
    }

    @discardableResult
    static func move(_ id: UUID, to target: Ghostty.SurfaceView, zone: GoviSnapZone) -> Bool {
        guard id != target.id, let source = owner(of: id), let destination = owner(of: target.id),
              let view = source.surfaceTree.first(where: { $0.id == id }) else { return false }
        do {
            if source === destination {
                let tree = try source.surfaceTree.docking(view: view, to: target, zone: zone)
                source.replaceSurfaceTree(tree, moveFocusTo: view, moveFocusFrom: source.focusedSurface, undoAction: "Move Pane")
            } else if zone != .center {
                // Construct both results before changing ownership. Strong references
                // keep the same SurfaceView/PTY alive throughout the transfer.
                let targetTree = try destination.surfaceTree.docking(view: view, to: target, zone: zone)
                let sourceTree = source.surfaceTree.remove(.leaf(view: view))
                source.undoManager?.removeAllActions(withTarget: source)
                destination.undoManager?.removeAllActions(withTarget: destination)
                destination.surfaceTree = targetTree
                source.surfaceTree = sourceTree
                source.focusedSurface = sourceTree.root?.leaves().first
            } else {
                let sourceTree = try source.surfaceTree.replace(node: .leaf(view: view), with: .leaf(view: target))
                let targetTree = try destination.surfaceTree.replace(node: .leaf(view: target), with: .leaf(view: view))
                source.undoManager?.removeAllActions(withTarget: source)
                destination.undoManager?.removeAllActions(withTarget: destination)
                source.surfaceTree = sourceTree; destination.surfaceTree = targetTree
                source.focusedSurface = target
            }
            destination.focusedSurface = view
            destination.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { destination.window?.makeFirstResponder(view) }
            NotificationCenter.default.post(name: .goviLayoutChanged, object: nil)
            return true
        } catch {
            Ghostty.logger.warning("Unable to rearrange terminal panes: \(error.localizedDescription)")
            return false
        }
    }

    static func arrange(_ views: [Ghostty.SurfaceView]) {
        guard let first = views.first, let owner = owner(of: first.id), views.count > 1 else { return }
        typealias Tree = SplitTree<Ghostty.SurfaceView>
        func build(_ items: ArraySlice<Ghostty.SurfaceView>, horizontal: Bool) -> Tree.Node {
            if items.count == 1 { return .leaf(view: items.first!) }
            let mid = (items.count + 1) / 2
            return .split(.init(direction: horizontal ? .horizontal : .vertical, ratio: 0.5,
                                left: build(items.prefix(mid), horizontal: !horizontal), right: build(items.dropFirst(mid), horizontal: !horizontal)))
        }
        owner.replaceSurfaceTree(.init(root: build(views[...], horizontal: true), zoomed: nil),
                                 moveFocusTo: owner.focusedSurface, moveFocusFrom: owner.focusedSurface, undoAction: "Arrange Panes")
        DispatchQueue.main.async { if let focused = owner.focusedSurface { owner.window?.makeFirstResponder(focused) } }
        NotificationCenter.default.post(name: .goviLayoutChanged, object: nil)
    }
}

struct GoviTerminalPane: View {
    @Environment(\.goviPalette) private var ui

    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject private var dragPreview = GoviPaneDragPreview.shared
    var isSplit: Bool
    @Environment(\.goviActivePane) private var activeID
    @State private var hovering = false
    // Re-render when the backdrop or terminal opacity changes in Settings.
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"
    private var active: Bool { activeID == surface.id }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                GoviPaneBar(surface: surface, isSplit: isSplit, showButtons: active || hovering)
                    .onHover { hovering = $0 }
                Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: isSplit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The terminal surface already paints its own translucent background;
            // a second layer here would stack up and hide the backdrop.
            .background(GoviBackdropStore.terminalOpacity < 1 ? Color.clear : GoviInk.color(GoviTheme.current.background), ignoresSafeAreaEdges: [])
            .overlay(alignment: .top) { if isSplit && active { ui.line.frame(height: 1).allowsHitTesting(false) } }
                .overlay(alignment: .topLeading) {
                    if let target = dragPreview.target, target.id == surface.id {
                        let rect = target.zone.rect(in: geometry.size).insetBy(dx: 3, dy: 3)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(ui.accent.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ui.accent.opacity(0.85), lineWidth: 1.5))
                            .frame(width: max(0, rect.width), height: max(0, rect.height))
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onDrop(of: [GoviPaneCoordinator.typeID], delegate: GoviPaneDropDelegate(surface: surface, size: geometry.size))
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Terminal pane: \(GoviPaneNaming.title(surface))")
    }
}

/// SwiftUI handles the title/gaps; the native surface handles terminal content.
/// Both routes publish the same pane-local preview and use the same move logic.
private struct GoviPaneDropDelegate: DropDelegate {
    let surface: Ghostty.SurfaceView
    let size: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [GoviPaneCoordinator.typeID]) && GoviPaneCoordinator.draggedID != nil && GoviPaneCoordinator.draggedID != surface.id
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
              let provider = info.itemProviders(for: [GoviPaneCoordinator.typeID]).first else { GoviPaneCoordinator.leaveDrop(on: surface.id); return false }
        GoviPaneCoordinator.endDrag()
        provider.loadDataRepresentation(forTypeIdentifier: GoviPaneCoordinator.typeID) { data, _ in
            DispatchQueue.main.async {
                guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text),
                      id == source else { return }
                GoviPaneCoordinator.move(id, to: surface, zone: zone)
            }
        }
        return true
    }
}

/// A native mouse drag starts immediately from the title, with no long press or
/// SwiftUI tap recognizer competing with it. The pane's controls stay separate.
private struct GoviPaneDragHandle: NSViewRepresentable {
    let surface: Ghostty.SurfaceView
    let isSplit: Bool

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.registerForDraggedTypes([GoviPaneCoordinator.pasteboardType])
        return view
    }
    func updateNSView(_ view: Handle, context: Context) {
        view.surface = surface; view.isSplit = isSplit
        view.toolTip = "Drag to dock this terminal beside another pane. Drop in the center to swap."
    }

    final class Handle: NSView, NSDraggingSource {
        weak var surface: Ghostty.SurfaceView?
        var isSplit = false
        private var mouseDownPoint: CGPoint?
        private var dragging = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            surface?.window?.makeFirstResponder(surface)
            if event.clickCount == 2, isSplit {
                _ = surface?.surfaceModel?.perform(action: "toggle_split_zoom")
                mouseDownPoint = nil
            } else { mouseDownPoint = convert(event.locationInWindow, from: nil) }
        }
        override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }
        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = mouseDownPoint, let surface else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragging = true
            GoviPaneCoordinator.beginDrag(surface)
            let writer = NSPasteboardItem()
            writer.setString(surface.id.uuidString, forType: GoviPaneCoordinator.pasteboardType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = dragImage(title: GoviPaneNaming.title(surface))
            item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 14, width: image.size.width, height: image.size.height), contents: image)
            NSCursor.closedHand.set()
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false; mouseDownPoint = nil
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
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    var isSplit: Bool
    var showButtons: Bool
    // Re-render when the backdrop or terminal opacity changes in Settings.
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"

    var body: some View {
        let title = GoviPaneNaming.title(surface)
        let path = surface.pwd.map(GoviPaneNaming.shortPath)
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                GoviSymbol(symbol: "arrow.up.and.down.and.arrow.left.and.right").scaleEffect(0.75).frame(width: 14, height: 14).foregroundStyle(ui.muted)
                Text(title).foregroundStyle(ui.ink).lineLimit(1)
                if let path, path != "~" || !title.hasSuffix("~") {
                    Text(path).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: GoviPaneMetrics.headerHeight)
                .overlay { GoviPaneDragHandle(surface: surface, isSplit: isSplit) }
                .help("Drag to dock beside another pane; drop in its center to swap")
            HStack(spacing: 2) {
                button("rectangle.split.2x1", "Split right (\(shortcuts.chord(.splitRight).display))") { perform("new_split:right") }
                button("rectangle.split.1x2", "Split below (\(shortcuts.chord(.splitDown).display))") { perform("new_split:down") }
                button("plus.square.on.square", "New workspace here (\(shortcuts.chord(.newWorkspace).display))") { perform("new_tab") }
                if isSplit {
                    button("arrow.up.left.and.arrow.down.right", "Maximize / restore terminal (\(shortcuts.chord(.zoom).display))") { perform("toggle_split_zoom") }
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
