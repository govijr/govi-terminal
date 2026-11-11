import SwiftUI
import AppKit
import GhosttyKit

struct GoviSidebarTerminal: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject private var activity = GoviActivityCenter.shared
    @State private var hovering = false
    let active: Bool
    private var info: GoviActivityCenter.Info { activity.info[surface.id] ?? .init() }
    /// Second line: activity first, else the folder unless the title already shows it.
    private var subtitle: String? {
        if surface.processExited { return "Exited" }
        if info.state != .idle { return info.state.label }
        let path = GoviPaneNaming.shortPath(surface.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let title = GoviPaneNaming.title(surface)
        return path == "~" && title.hasSuffix("~") ? nil : path
    }
    private var statusShown: Bool { !surface.processExited && info.state != .idle }
    /// The agent running in a terminal: the one it reported, else one named by its title.
    static func agent(in surface: Ghostty.SurfaceView, info: GoviActivityCenter.Info) -> GoviAgent? {
        if let agent = info.agent { return agent }
        let title = GoviPaneNaming.title(surface).lowercased()
        return GoviAgent.allCases.first { title == $0.rawValue || title.hasPrefix($0.rawValue + " ") || title == $0.name.lowercased() }
    }
    let action: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    sessionIcon.frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(GoviPaneNaming.title(surface)).lineLimit(1).truncationMode(.tail)
                        if let label = info.label {
                            Label(label, systemImage: surface.goviLaunch.remote == nil ? "arrow.triangle.branch" : "network").labelStyle(
                                .titleAndIcon
                            )
                            .font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                        } else if let subtitle {
                            // An agent's state is the line worth reading first, so it takes the state's colour.
                            Text(subtitle).font(GoviInk.font(10.5).weight(statusShown ? .medium : .regular))
                                .foregroundStyle(statusShown ? info.state.tint(ui) : ui.muted).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 0)
                    if GoviPersistence.isPersistent(surface.id) && hovering {
                        Image(systemName: "infinity").font(.system(size: 9, weight: .semibold)).foregroundStyle(ui.muted)
                            .help("Keeps running when you close the window or quit Govi")
                            .accessibilityLabel("Persistent session")
                    }
                    if surface.processExited {
                        Image(systemName: "stop.circle").font(.system(size: 10)).help("Process exited")
                    } else if info.state != .idle {
                        GoviActivityBadge(state: info.state)
                    } else if surface.bell {
                        Circle().fill(Color.orange).frame(width: 5, height: 5).help("Terminal bell")
                    }
                }.padding(.vertical, 5).padding(.trailing, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("\(surface.pwd ?? "")\(info.state == .idle ? "" : "\n" + info.state.label)\nDrag to move this terminal")
                .onDrag { GoviPaneCoordinator.dragProvider(for: surface) }
                .padding(.trailing, hovering ? 44 : 0)
        }.overlay(alignment: .trailing) {
          HStack(spacing: 0) {
            Menu {
                Button("Split right") { perform("new_split:right") }
                Button("Split below") { perform("new_split:down") }
                Button("Maximize / restore pane") { perform("toggle_split_zoom") }
                Button("Rename terminal…") { surface.promptTitle() }
                if let path = surface.pwd {
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Session actions").accessibilityLabel("Session actions")
            Button {
                perform("close_surface")
            } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close terminal").accessibilityLabel("Close terminal")
          }.opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }.modifier(GoviSidebarPaneRowStyle(active: active, hovering: hovering))
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Split right") { perform("new_split:right") }
                Button("Split below") { perform("new_split:down") }
                Button("Maximize / restore pane") { perform("toggle_split_zoom") }
                Button("Rename terminal…") { surface.promptTitle() }
                Divider()
                Button("Close terminal") { perform("close_surface") }
            }
    }
    @ViewBuilder private var sessionIcon: some View {
        if let agent = Self.agent(in: surface, info: info) {
            GoviAgentGlyph(agent: agent).foregroundStyle(ui.tone(for: agent.rawValue))
        } else {
            GoviGlyph(kind: surface.goviLaunch.remote == nil ? .terminal : .server)
                .foregroundStyle(ui.color(for: surface.goviLaunch.remote == nil ? .terminal : .server))
        }
    }
    private func perform(_ command: String) {
        action()
        _ = surface.surfaceModel?.perform(action: command)
    }
}

/// How the sidebar arranges open panes. Projects is the folder tree; the others are flat
/// groups, so the same panes can be read by who runs them, where, or how they're doing.
enum GoviSidebarGrouping: String, CaseIterable, Identifiable {
    case project, agent, machine, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: "Project"
        case .agent: "Agent"
        case .machine: "Machine"
        case .status: "Status"
        }
    }
    var section: String {
        switch self {
        case .project: "Open projects"
        case .agent: "Agents"
        case .machine: "Machines"
        case .status: "Status"
        }
    }
}

extension GoviActivityState {
    /// One colour per state everywhere in the sidebar: text, dots and group headers.
    func tint(_ ui: GoviUIPalette) -> Color {
        switch self {
        case .idle: ui.muted
        case .working: ui.accent
        case .needsInput: .orange
        case .done: .green
        case .error: .red
        }
    }
    /// Most urgent first, for the Status grouping and the summary line.
    static let byUrgency: [GoviActivityState] = [.needsInput, .error, .working, .done, .idle]
}

/// One grid for every sidebar row: 6pt inner padding, 28pt rows, 16pt per level,
/// 16pt icon column. Each level's chevron or icon sits under the icon above it.
enum GoviSidebarMetrics {
    static let inset: CGFloat = 6
    static let row: CGFloat = 28
    static let indent: CGFloat = 16
    static let icon: CGFloat = 16
}

/// Hands its content a hover flag, so a row can reveal its icons only under the pointer.
struct GoviHoverRow<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false
    var body: some View { content(hovering).onHover { hovering = $0 } }
}

/// Chrome shared by every pane row (terminal, browser, editor, Tasks): one fill marks the
/// focused pane, a fainter one the pointer.
struct GoviSidebarPaneRowStyle: ViewModifier {
    @Environment(\.goviPalette) private var ui
    let active: Bool
    let hovering: Bool
    func body(content: Content) -> some View {
        content
            .font(GoviInk.font(12.5))
            .foregroundStyle(active ? ui.ink : ui.muted)
            .padding(.horizontal, GoviSidebarMetrics.inset)
            .frame(minHeight: GoviSidebarMetrics.row)
            .background(
                active ? ui.accent.opacity(0.20) : ui.ink.opacity(hovering ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ui.accent.opacity(0.28), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
    }
}

extension GoviUIPalette {
    /// One theme hue per kind of pane, so a glance at the sidebar tells terminals,
    /// browsers and editors apart. Falls back to the accent on themes without ANSI hues.
    func color(for kind: GoviGlyph.Kind) -> Color {
        let index: Int
        switch kind {
        case .terminal: index = 0
        case .tasks: index = 1
        case .globe: index = 2
        case .code: index = 3
        case .server: index = 4
        case .folder, .more, .bookmark, .file, .image, .laptop: return accent
        }
        return hue(index)
    }
}

/// Sidebar icons, drawn here so every row shares one weight: a 16pt grid, a 1.3pt round
/// stroke, and a soft fill of the same colour behind the outline.
struct GoviGlyph: View {
    enum Kind { case terminal, folder, code, globe, tasks, server, more, bookmark, file, image, laptop }
    let kind: Kind
    var body: some View {
        ZStack {
            GoviGlyphShape(kind: kind, detail: false).opacity(0.24)
            GoviGlyphShape(kind: kind, detail: true).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }.frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon).accessibilityHidden(true)
    }
}

private struct GoviGlyphShape: Shape {
    let kind: GoviGlyph.Kind
    /// Off: only the closed outline, for the fill. On: the outline plus its inner strokes.
    let detail: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x, y: y) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            p.addRoundedRect(in: .init(x: x, y: y, width: w, height: h), cornerSize: .init(width: r, height: r), style: .continuous)
        }
        func line(_ points: [CGPoint]) {
            p.move(to: points[0])
            points.dropFirst().forEach { p.addLine(to: $0) }
        }
        func dot(_ x: CGFloat, _ y: CGFloat) { line([pt(x, y), pt(x + 0.01, y)]) }
        switch kind {
        case .terminal:
            box(1.5, 2.5, 13, 11, 3.2)
            if detail {
                line([pt(4.6, 6), pt(6.8, 8), pt(4.6, 10)])
                line([pt(8.6, 10.2), pt(11.4, 10.2)])
            }
        case .folder:
            p.move(to: pt(1.5, 6))
            p.addArc(tangent1End: pt(1.5, 2.5), tangent2End: pt(4, 2.5), radius: 2)
            p.addLine(to: pt(5.6, 2.5))
            p.addQuadCurve(to: pt(7.3, 3.4), control: pt(6.6, 2.5))
            p.addQuadCurve(to: pt(9, 4.3), control: pt(8, 4.3))
            p.addArc(tangent1End: pt(14.5, 4.3), tangent2End: pt(14.5, 7), radius: 2)
            p.addArc(tangent1End: pt(14.5, 13.5), tangent2End: pt(11, 13.5), radius: 2.2)
            p.addArc(tangent1End: pt(1.5, 13.5), tangent2End: pt(1.5, 10), radius: 2.2)
            p.closeSubpath()
        case .code:
            box(2.5, 1.5, 11, 13, 3)
            if detail {
                line([pt(6.6, 6.2), pt(4.9, 8), pt(6.6, 9.8)])
                line([pt(9.4, 6.2), pt(11.1, 8), pt(9.4, 9.8)])
            }
        case .globe:
            p.addEllipse(in: .init(x: 1.5, y: 1.5, width: 13, height: 13))
            if detail {
                p.addEllipse(in: .init(x: 5.4, y: 1.5, width: 5.2, height: 13))
                line([pt(1.5, 8), pt(14.5, 8)])
            }
        case .tasks:
            box(2, 2, 12, 12, 3.4)
            if detail { line([pt(5.2, 8.2), pt(7.2, 10.2), pt(10.9, 6)]) }
        case .server:
            box(2, 2.4, 12, 4.9, 2)
            box(2, 8.7, 12, 4.9, 2)
            if detail {
                dot(4.7, 4.85)
                dot(4.7, 11.15)
            }
        case .more:
            p.addEllipse(in: .init(x: 1.5, y: 1.5, width: 13, height: 13))
            if detail { [5, 8, 11].forEach { dot($0, 8) } }
        case .bookmark:
            p.move(to: pt(4, 13.6))
            p.addArc(tangent1End: pt(4, 2), tangent2End: pt(6, 2), radius: 2)
            p.addArc(tangent1End: pt(12, 2), tangent2End: pt(12, 4), radius: 2)
            p.addLine(to: pt(12, 13.6))
            p.addLine(to: pt(8, 10.8))
            p.closeSubpath()
        case .file:
            p.move(to: pt(3, 5))
            p.addArc(tangent1End: pt(3, 1.5), tangent2End: pt(6, 1.5), radius: 2)
            p.addLine(to: pt(9, 1.5))
            p.addLine(to: pt(13, 5.5))
            p.addArc(tangent1End: pt(13, 14.5), tangent2End: pt(10, 14.5), radius: 2)
            p.addArc(tangent1End: pt(3, 14.5), tangent2End: pt(3, 11), radius: 2)
            p.closeSubpath()
            if detail { line([pt(9, 1.8), pt(9, 5.5), pt(12.7, 5.5)]) }
        case .laptop:
            box(3, 3, 10, 7.6, 2)
            if detail { line([pt(1.5, 13), pt(14.5, 13)]) }
        case .image:
            box(1.5, 2.5, 13, 11, 3)
            if detail {
                dot(5.3, 6.3)
                line([pt(2.4, 11.6), pt(6, 8.6), pt(8.4, 10.6), pt(10.6, 8.8), pt(13.6, 11.4)])
            }
        }
        return p.applying(.init(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

struct GoviSidebarRowStyle: ViewModifier {
    @Environment(\.goviPalette) private var ui
    var indent: CGFloat = 0
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, GoviSidebarMetrics.inset)
            .frame(minHeight: GoviSidebarMetrics.row)
            .background(ui.ink.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.leading, indent)
    }
}

/// Tasks tabs, one per workspace window at most. Kept outside the window's view so the
/// sidebar (drawn by whichever workspace is key) can list and switch every workspace's tab.
final class GoviTasksTabs: ObservableObject {
    static let shared = GoviTasksTabs()
    /// Windows that have a Tasks tab.
    @Published private(set) var tabs: Set<Int> = []
    /// Windows whose Tasks tab is in front of their terminals.
    @Published private(set) var showing: Set<Int> = []

    func setShowing(_ window: Int, _ shown: Bool) {
        if shown {
            tabs.insert(window)
            showing.insert(window)
        } else {
            showing.remove(window)
        }
    }
    func close(_ window: Int) {
        tabs.remove(window)
        showing.remove(window)
    }
    func prune(keeping windows: Set<Int>) {
        let keptTabs = tabs.intersection(windows)
        let keptShowing = showing.intersection(windows)
        if keptTabs != tabs { tabs = keptTabs }
        if keptShowing != showing { showing = keptShowing }
    }
}

/// The sidebar row for a workspace's Tasks tab, styled like a terminal row.
struct GoviSidebarTasksTab: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage("GoviTasksProvider") private var provider = "github"
    @AppStorage("GoviTasksRepository") private var repository = ""
    @State private var hovering = false
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    private var subtitle: String { provider == "linear" ? "Linear" : (repository.isEmpty ? "GitHub" : repository) }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    GoviGlyph(kind: .tasks).foregroundStyle(ui.color(for: .tasks))
                        .frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tasks").lineLimit(1)
                        Text(subtitle).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5).padding(.trailing, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).help("GitHub and Linear tasks").padding(.trailing, hovering ? 22 : 0)
        }.overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close Tasks").accessibilityLabel("Close Tasks")
                .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }.modifier(GoviSidebarPaneRowStyle(active: active, hovering: hovering))
            .onHover { hovering = $0 }
            .contextMenu { Button("Close Tasks", action: close) }
    }
}

/// A browser pane in the sidebar, styled like the terminal rows above it.
struct GoviSidebarBrowser: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviWebPaneView
    @State private var hovering = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    GoviGlyph(kind: .globe).foregroundStyle(ui.color(for: .globe))
                        .frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pane.paneTitle).lineLimit(1).truncationMode(.tail)
                        if let host = pane.url?.host {
                            Text(host + (pane.url?.port.map { ":\($0)" } ?? ""))
                                .font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if pane.isLoading { ProgressView().controlSize(.mini) }
                }.padding(.vertical, 5).padding(.trailing, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("\(pane.url?.absoluteString ?? "Browser")\nDrag to move this pane")
                .onDrag { GoviPaneCoordinator.dragProvider(for: pane) }
                .padding(.trailing, hovering ? 22 : 0)
        }.overlay(alignment: .trailing) {
            Button {
                command(.closeTerminal)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close browser").accessibilityLabel("Close browser")
                .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }.modifier(GoviSidebarPaneRowStyle(active: active, hovering: hovering))
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Split right") { command(.splitRight) }
                Button("Split below") { command(.splitDown) }
                Button("Maximize / restore pane") { command(.zoom) }
                Button("Reload") { pane.reload() }
                if let url = pane.url, url.scheme == "http" || url.scheme == "https" {
                    Button("Open in default browser") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Close browser") { command(.closeTerminal) }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("Browser: \(pane.paneTitle)")
    }

    private func command(_ action: GoviShortcutAction) {
        (pane.window?.windowController as? BaseTerminalController)?.performPaneCommand(action, on: pane)
    }
}
