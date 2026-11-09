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
    let action: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    sessionIcon.frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(GoviPaneNaming.title(surface)).lineLimit(1).truncationMode(.middle)
                        if let label = info.label {
                            Label(label, systemImage: surface.goviLaunch.remote == nil ? "arrow.triangle.branch" : "network").labelStyle(
                                .titleAndIcon
                            )
                            .font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                        } else if let subtitle {
                            Text(subtitle).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.head)
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
            .opacity(hovering ? 1 : 0)
            Button {
                perform("close_surface")
            } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close terminal").accessibilityLabel("Close terminal")
                .opacity(hovering ? 1 : 0)
        }.font(GoviInk.font(12.5).weight(.light))
            .foregroundStyle(active ? ui.ink : ui.muted)
            .padding(.horizontal, GoviSidebarMetrics.inset)
            .frame(minHeight: GoviSidebarMetrics.row)
            .background(
                active ? ui.ink.opacity(0.10) : ui.ink.opacity(hovering ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if active { Capsule().fill(ui.accent).frame(width: 2.5, height: 16).offset(x: -1) }
            }
            .contentShape(Rectangle()).onHover { hovering = $0 }
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
        let title = GoviPaneNaming.title(surface).lowercased()
        if let agent = info.agent
            ?? GoviAgent.allCases.first(where: {
                title == $0.rawValue || title.hasPrefix($0.rawValue + " ") || title == $0.name.lowercased()
            })
        {
            GoviAgentGlyph(agent: agent).foregroundStyle(ui.tone(for: agent.rawValue))
        } else if let remote = surface.goviLaunch.remote {
            Image(systemName: "network").font(.system(size: 11)).foregroundStyle(ui.tone(for: remote.host))
        } else {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(ui.accent)
        }
    }
    private func perform(_ command: String) {
        action()
        _ = surface.surfaceModel?.perform(action: command)
    }
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

/// The sidebar's primary action: a soft filled row that brightens on hover.
struct GoviProminentRowStyle: ViewModifier {
    @Environment(\.goviPalette) private var ui
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(ui.ink.opacity(hovering ? 0.11 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ui.ink.opacity(0.06), lineWidth: 0.5))
            .onHover { hovering = $0 }
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
                    Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(ui.accent)
                        .frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tasks").lineLimit(1)
                        Text(subtitle).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5).padding(.trailing, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).help("GitHub and Linear tasks")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close Tasks").accessibilityLabel("Close Tasks")
                .opacity(hovering ? 1 : 0)
        }.font(GoviInk.font(12.5).weight(.light))
            .foregroundStyle(active ? ui.ink : ui.muted)
            .padding(.horizontal, GoviSidebarMetrics.inset)
            .frame(minHeight: GoviSidebarMetrics.row)
            .background(
                active ? ui.ink.opacity(0.10) : ui.ink.opacity(hovering ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if active { Capsule().fill(ui.accent).frame(width: 2.5, height: 16).offset(x: -1) }
            }
            .contentShape(Rectangle()).onHover { hovering = $0 }
            .contextMenu { Button("Close Tasks", action: close) }
    }
}
