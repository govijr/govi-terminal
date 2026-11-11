import SwiftUI
import AppKit

/// Panes popped out of the split layout into a floating panel.
///
/// A floating pane stays a leaf of its controller's split tree, so closing,
/// focus, restoration and the control socket treat it exactly as before. The
/// split view leaves it out of the layout and draws it above instead. Docking
/// it again puts it beside the docked pane nearest the panel, or back where it
/// came from when the panel was never moved.
final class GoviFloatingPanes: ObservableObject {
    struct Entry: Equatable {
        /// Origin (top-left) and size in the split area; nil until first placed.
        var frame: CGRect?
        var minimized = false
        var order = 0
        /// True once the person moved or resized the panel.
        var moved = false
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    weak var controller: BaseTerminalController?
    /// The split area (flipped), for converting between panel and window coordinates.
    weak var areaView: NSView?
    private var nextOrder = 0

    static let minimumSize = CGSize(width: 320, height: 200)

    var ids: Set<UUID> { Set(entries.keys) }
    var minimizedIDs: [UUID] { entries.filter { $0.value.minimized }.sorted { $0.value.order < $1.value.order }.map(\.key) }
    func isFloating(_ id: UUID) -> Bool { entries[id] != nil }
    func isMinimized(_ id: UUID) -> Bool { entries[id]?.minimized == true }

    func float(_ id: UUID, frame: CGRect? = nil) {
        nextOrder += 1
        entries[id] = Entry(frame: frame, minimized: false, order: nextOrder)
    }
    func dock(_ id: UUID) { entries[id] = nil }
    func raise(_ id: UUID) {
        guard var entry = entries[id], entry.order != nextOrder else { return }
        nextOrder += 1
        entry.order = nextOrder
        entries[id] = entry
    }
    func setFrame(_ id: UUID, _ frame: CGRect, moved: Bool = true) {
        guard var entry = entries[id], entry.frame != frame else { return }
        entry.frame = frame
        if moved { entry.moved = true }
        entries[id] = entry
    }
    func setMinimized(_ id: UUID, _ minimized: Bool) {
        guard entries[id] != nil else { return }
        if !minimized { raise(id) }
        entries[id]?.minimized = minimized
    }
    /// Forget panes that left the window (closed or moved elsewhere).
    func prune(keeping ids: Set<UUID>) {
        let stale = entries.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { entries[id] = nil }
    }

    /// The panel's frame in an area of the given size: the stored frame kept
    /// inside the area, or a centered default cascaded by stacking order.
    func frame(for id: UUID, in area: CGSize) -> CGRect {
        let stored = entries[id]?.frame
        let size =
            stored?.size
            ?? CGSize(width: min(max(area.width * 0.5, 420), 760), height: min(max(area.height * 0.55, 280), 520))
        let cascade = CGFloat(entries.values.filter { $0.order < (entries[id]?.order ?? 0) && !$0.minimized }.count % 6) * 26
        let origin =
            stored?.origin
            ?? CGPoint(x: (area.width - size.width) / 2 + cascade, y: (area.height - size.height) / 2 + cascade)
        return Self.clamp(CGRect(origin: origin, size: size), to: area)
    }

    static func clamp(_ frame: CGRect, to area: CGSize) -> CGRect {
        guard area.width > 0, area.height > 0 else { return frame }
        let width = min(max(frame.width, min(minimumSize.width, area.width)), area.width)
        let height = min(max(frame.height, min(minimumSize.height, area.height)), area.height)
        let x = min(max(frame.minX, 0), area.width - width)
        let y = min(max(frame.minY, 0), area.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct GoviFloatingPanesKey: EnvironmentKey { static let defaultValue: GoviFloatingPanes? = nil }
private struct GoviFloatingDragKey: EnvironmentKey { static let defaultValue: GoviFloatingDrag? = nil }
extension EnvironmentValues {
    /// The window's floating panes, for the bottom bar's minimized chips.
    var goviFloatingPanes: GoviFloatingPanes? {
        get { self[GoviFloatingPanesKey.self] }
        set { self[GoviFloatingPanesKey.self] = newValue }
    }
    /// Set inside a floating panel: the title bar moves the panel instead of
    /// starting a docking drag.
    var goviFloatingDrag: GoviFloatingDrag? {
        get { self[GoviFloatingDragKey.self] }
        set { self[GoviFloatingDragKey.self] = newValue }
    }
}

/// Callbacks a floating panel gives its title bar's drag handle.
final class GoviFloatingDrag {
    /// Kept current by the panel so the callbacks see the latest layout.
    var area: CGSize = .zero
    var start: CGRect?
    var began: () -> Void = {}
    /// Offset from the press point (x right, y down).
    var moved: (_ offset: CGSize) -> Void = { _ in }
    var ended: () -> Void = {}
    var doubleClicked: () -> Void = {}
}

// MARK: - Controller operations

extension BaseTerminalController {
    /// Panes still laid out in the split view.
    var dockedPanes: [GoviPaneView] { surfaceTree.filter { !floating.isFloating($0.id) } }

    func canDetachPane(_ pane: GoviPaneView) -> Bool {
        !floating.isFloating(pane.id) && dockedPanes.count > 1 && surfaceTree.contains { $0.id == pane.id }
    }

    /// Pop a pane out of the layout into a floating panel that starts over
    /// the spot it left, slightly smaller so it reads as lifted out.
    func detachPane(_ pane: GoviPaneView) {
        guard canDetachPane(pane) else { return }
        var start: CGRect?
        if let rect = GoviPaneFrames.windowRect(of: pane, in: self), let area = floating.areaView, area.window === window {
            let local = area.convert(rect, from: nil)
            start = local.insetBy(dx: local.width * 0.06, dy: local.height * 0.06).offsetBy(dx: 14, dy: 14)
        }
        if surfaceTree.zoomed != nil { surfaceTree = .init(root: surfaceTree.root, zoomed: nil) }
        floating.float(pane.id, frame: start)
        focusPaneSoon(pane)
    }

    /// The detach button pressed again: dock beside the docked pane nearest the
    /// panel, on that pane's side closest to it. A panel that was never moved
    /// goes back where it came from.
    func redockPane(_ pane: GoviPaneView) {
        guard let entry = floating.entries[pane.id] else { return }
        if entry.moved, !entry.minimized, let spot = nearestDockSpot(for: pane) {
            dockPane(pane, beside: spot.pane, zone: spot.zone)
        } else {
            dockPane(pane)
        }
    }

    private func nearestDockSpot(for pane: GoviPaneView) -> (pane: GoviPaneView, zone: GoviSnapZone)? {
        guard let area = floating.areaView, area.window === window, let frame = floating.entries[pane.id]?.frame else { return nil }
        let panel = area.convert(frame, to: nil)
        let center = CGPoint(x: panel.midX, y: panel.midY)
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - center.x, 0, center.x - rect.maxX), max(rect.minY - center.y, 0, center.y - rect.maxY))
        }
        let candidates = dockedPanes.compactMap { docked in
            GoviPaneFrames.windowRect(of: docked, in: self).map { (pane: docked, rect: $0) }
        }
        guard let best = candidates.min(by: { distance($0.rect) < distance($1.rect) }) else { return nil }
        let rect = best.rect
        // Window coordinates grow upward, so the top edge is maxY.
        let x = min(max((center.x - rect.minX) / max(rect.width, 1), 0), 1)
        let fromTop = min(max((rect.maxY - center.y) / max(rect.height, 1), 0), 1)
        let zone = [(GoviSnapZone.left, x), (.right, 1 - x), (.top, fromTop), (.bottom, 1 - fromTop)].min { $0.1 < $1.1 }!.0
        return (best.pane, zone)
    }

    /// Put a floating pane back in the layout: beside `target` on `zone`, or
    /// where it was before it was detached.
    func dockPane(_ pane: GoviPaneView, beside target: GoviPaneView? = nil, zone: GoviSnapZone = .center) {
        guard floating.isFloating(pane.id) else { return }
        floating.dock(pane.id)
        if let target, zone != .center, target.id != pane.id {
            do {
                let tree = try surfaceTree.docking(view: pane, to: target, zone: zone)
                replaceSurfaceTree(tree, moveFocusTo: nil, moveFocusFrom: nil, undoAction: "Move Pane")
            } catch {
                Ghostty.logger.warning("Unable to dock floating pane: \(error.localizedDescription)")
            }
        }
        focusPaneSoon(pane)
        NotificationCenter.default.post(name: .goviLayoutChanged, object: nil)
    }

    /// Tuck a floating pane into the bottom bar. Docked panes float first.
    func minimizePane(_ pane: GoviPaneView) {
        if !floating.isFloating(pane.id) {
            guard canDetachPane(pane) else { return }
            if surfaceTree.zoomed != nil { surfaceTree = .init(root: surfaceTree.root, zoomed: nil) }
            floating.float(pane.id)
        }
        floating.setMinimized(pane.id, true)
        if focusedPane === pane || focusedPane == nil,
            let next = dockedPanes.last ?? surfaceTree.first(where: { !floating.isMinimized($0.id) })
        {
            DispatchQueue.main.async { Ghostty.moveFocus(to: next, from: pane) }
        }
    }

    func restorePane(_ pane: GoviPaneView) {
        floating.setMinimized(pane.id, false)
        focusPaneSoon(pane)
    }

    private func focusPaneSoon(_ pane: GoviPaneView) {
        // Wait for SwiftUI to move the view into its new container first.
        DispatchQueue.main.async { [weak self] in
            guard let self, pane.window === self.window else { return }
            Ghostty.moveFocus(to: pane, from: self.focusedPane)
        }
    }
}

// MARK: - Frames of docked panes

/// Where each pane's frame (title bar included) is in its window, for placing
/// a detached panel and for docking it beside the nearest pane.
enum GoviPaneFrames {
    private static let views = NSMapTable<NSUUID, NSView>.strongToWeakObjects()
    static func register(_ view: NSView, for id: UUID) { views.setObject(view, forKey: id as NSUUID) }
    static func view(for id: UUID) -> NSView? { views.object(forKey: id as NSUUID) }

    /// A pane's frame, title bar included, in its window's coordinates.
    static func windowRect(of pane: GoviPaneView, in controller: BaseTerminalController) -> CGRect? {
        let probe = view(for: pane.id).flatMap { $0.window === controller.window && $0.bounds.width > 0 ? $0 : nil }
        guard let host = probe ?? (pane.window === controller.window ? pane : nil) else { return nil }
        var rect = host.convert(host.bounds, to: nil)
        if probe == nil { rect.size.height += GoviPaneMetrics.headerHeight }
        return rect
    }
}

/// Hands the split area's view to the floating model for coordinate conversion.
struct GoviFloatingAreaProbe: NSViewRepresentable {
    let floating: GoviFloatingPanes
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { floating.areaView = view }
    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// An invisible view that records a pane frame's position for `GoviPaneFrames`.
struct GoviPaneFrameProbe: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.paneID = id
        GoviPaneFrames.register(view, for: id)
    }
    final class Probe: NSView {
        var paneID: UUID?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, let paneID { GoviPaneFrames.register(self, for: paneID) }
        }
    }
}

// MARK: - Views

/// Any pane, rendered with its usual frame and title bar.
struct GoviPaneLeaf: View {
    let pane: GoviPaneView
    var isSplit: Bool

    var body: some View {
        if let surface = pane as? Ghostty.SurfaceView {
            GoviTerminalPane(surface: surface, isSplit: isSplit)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Terminal pane")
        } else if let web = pane as? GoviWebPaneView {
            GoviWebPane(pane: web, isSplit: isSplit)
        } else if let editor = pane as? GoviEditorPaneView {
            GoviEditorPane(pane: editor, isSplit: isSplit)
        }
    }
}

/// A detached pane above the split layout. Its title bar moves it freely;
/// it only rejoins the layout when the person docks it.
struct GoviFloatingPaneWindow: View {
    @Environment(\.goviPalette) private var ui
    @Environment(\.goviActivePane) private var activeID
    @ObservedObject var floating: GoviFloatingPanes
    let pane: GoviPaneView
    let area: CGSize
    @State private var drag = GoviFloatingDrag()
    @State private var resizeStart: CGRect?

    var body: some View {
        let frame = floating.frame(for: pane.id, in: area)
        let active = activeID == pane.id
        GoviPaneLeaf(pane: pane, isSplit: true)
            .environment(\.goviFloatingDrag, drag)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? ui.accent.opacity(0.7) : ui.ink.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .bottomTrailing) { resizeGrip(frame) }
            .shadow(color: .black.opacity(active ? 0.42 : 0.3), radius: active ? 22 : 14, y: 8)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .zIndex(Double(floating.entries[pane.id]?.order ?? 0))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .onAppear {
                drag.area = area
                configureDrag()
                // Pin the first placement so later panels don't shift this one's cascade.
                if floating.entries[pane.id]?.frame == nil, area.width > 0 { floating.setFrame(pane.id, frame, moved: false) }
            }
            .onChange(of: area) { drag.area = $0 }
            .onChange(of: active) { if $0 { floating.raise(pane.id) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Floating pane: \(GoviPaneNaming.title(pane))")
    }

    private func resizeGrip(_ frame: CGRect) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(90))
            .foregroundStyle(ui.muted.opacity(0.8))
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? frame
                        if resizeStart == nil {
                            resizeStart = frame
                            floating.raise(pane.id)
                        }
                        var next = start
                        next.size.width = max(GoviFloatingPanes.minimumSize.width, start.width + value.translation.width)
                        next.size.height = max(GoviFloatingPanes.minimumSize.height, start.height + value.translation.height)
                        next.size.width = min(next.width, area.width - next.minX)
                        next.size.height = min(next.height, area.height - next.minY)
                        floating.setFrame(pane.id, next)
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .onHover { inside in inside ? NSCursor.crosshair.push() : NSCursor.pop() }
            .help("Drag to resize")
            .accessibilityLabel("Resize floating pane")
    }

    private func configureDrag() {
        let id = pane.id
        let floating = self.floating
        let pane = self.pane
        let drag = self.drag
        drag.began = { [weak floating, unowned drag] in
            floating?.raise(id)
            drag.start = floating?.frame(for: id, in: drag.area)
        }
        drag.moved = { [weak floating, unowned drag] offset in
            guard let floating, let start = drag.start else { return }
            floating.setFrame(id, GoviFloatingPanes.clamp(start.offsetBy(dx: offset.width, dy: offset.height), to: drag.area))
        }
        drag.ended = { [unowned drag] in drag.start = nil }
        drag.doubleClicked = { [weak floating, weak pane] in
            guard let pane, let controller = floating?.controller else { return }
            withAnimation(.easeOut(duration: 0.16)) { controller.redockPane(pane) }
        }
    }
}

/// Detach / dock / minimize buttons for a pane title bar.
struct GoviFloatingButtons: View {
    @Environment(\.goviFloatingDrag) private var floatingDrag
    @Environment(\.goviPalette) private var ui
    let pane: GoviPaneView
    var isSplit: Bool

    var body: some View {
        if floatingDrag != nil {
            button("minus", "Minimize to the bottom bar") { controller?.minimizePane(pane) }
            button("square.on.square", "Dock into the layout beside the nearest pane", highlighted: true) {
                withAnimation(.easeOut(duration: 0.16)) { controller?.redockPane(pane) }
            }
        } else if isSplit {
            button("square.on.square", "Detach into a floating pane") {
                withAnimation(.easeOut(duration: 0.16)) { controller?.detachPane(pane) }
            }
        }
    }

    /// Looked up on click: the pane may not have been in a window when this was drawn.
    private var controller: BaseTerminalController? {
        (pane.window?.windowController as? BaseTerminalController)
            ?? TerminalController.all.first { $0.surfaceTree.contains { $0.id == pane.id } }
    }

    private func button(_ symbol: String, _ help: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .foregroundStyle(highlighted ? ui.accent : ui.ink)
                .frame(width: 24, height: 24).modifier(GoviHoverHighlight())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

/// Minimized panes as chips in the bottom bar, beside the usage indicators.
struct GoviMinimizedPaneChips: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var floating: GoviFloatingPanes
    var trailingSeparator = true

    var body: some View {
        let panes = minimizedPanes
        if !panes.isEmpty {
            HStack(spacing: 4) {
                ForEach(panes, id: \.id) { pane in chip(pane) }
            }
            if trailingSeparator { Rectangle().fill(ui.line).frame(width: 0.5, height: 12) }
        }
    }

    private var minimizedPanes: [GoviPaneView] {
        guard let controller = floating.controller else { return [] }
        return floating.minimizedIDs.compactMap { id in controller.surfaceTree.first { $0.id == id } }
    }

    @ViewBuilder private func chip(_ pane: GoviPaneView) -> some View {
        if let surface = pane as? Ghostty.SurfaceView {
            GoviMinimizedChip(model: surface, pane: pane, floating: floating)
        } else if let web = pane as? GoviWebPaneView {
            GoviMinimizedChip(model: web, pane: pane, floating: floating)
        } else if let editor = pane as? GoviEditorPaneView {
            GoviMinimizedChip(model: editor, pane: pane, floating: floating)
        }
    }
}

private struct GoviMinimizedChip<Model: ObservableObject>: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var model: Model
    let pane: GoviPaneView
    let floating: GoviFloatingPanes
    @State private var hovering = false

    var body: some View {
        let title = GoviPaneNaming.title(pane)
        let controller = floating.controller
        Button {
            withAnimation(.easeOut(duration: 0.16)) { controller?.restorePane(pane) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pane.paneIcon).font(.system(size: 10, weight: .medium))
                Text(title).font(GoviInk.font(11)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading)
            }
            .foregroundStyle(hovering ? ui.ink : ui.muted)
            .padding(.horizontal, 8).frame(height: 24)
            .background(ui.ink.opacity(hovering ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Restore \(title)")
        .accessibilityLabel("Restore minimized pane \(title)")
        .contextMenu {
            Button("Restore") { controller?.restorePane(pane) }
            Button("Dock into Layout") { controller?.dockPane(pane) }
            Divider()
            Button("Close") { controller?.performPaneCommand(.closeTerminal, on: pane) }
        }
    }
}

/// In focus mode the bottom bar is hidden; minimized panes still need a way back.
struct GoviFocusModeMinimizedBar: View {
    @ObservedObject var floating: GoviFloatingPanes

    var body: some View {
        if !floating.minimizedIDs.isEmpty {
            HStack {
                Spacer(minLength: 0)
                GoviMinimizedPaneChips(floating: floating, trailingSeparator: false)
                    .padding(.horizontal, 10).frame(height: 40)
                    .modifier(GoviGlassControl())
            }
            .frame(height: 42)
        }
    }
}
