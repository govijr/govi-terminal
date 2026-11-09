import SwiftUI
import AppKit
import GhosttyKit

struct GoviSpace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
}
struct GoviSavedCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}
final class GoviNotebook: ObservableObject {
    static let shared = GoviNotebook()
    @Published var spaces: [GoviSpace] { didSet { save(spaces, key: "GoviSpaces") } }
    @Published var commands: [GoviSavedCommand] { didSet { save(commands, key: "GoviCommands") } }
    init() {
        func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        spaces = read("GoviSpaces", as: [GoviSpace].self) ?? []
        commands = read("GoviCommands", as: [GoviSavedCommand].self) ?? []
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct GoviWorkbench<Content: View>: View {
    @Environment(\.goviPalette) private var ui

    @ObservedObject var ghostty: Ghostty.App
    var surface: Ghostty.SurfaceView?
    var pwd: String?
    var tree: SplitTree<GoviPaneView>
    var showPalette: () -> Void
    @ViewBuilder var content: () -> Content
    @ObservedObject private var notebook = GoviNotebook.shared
    @ObservedObject private var activity = GoviActivityCenter.shared
    @ObservedObject private var detached = GoviDetachedStore.shared
    @ObservedObject private var navigation = GoviNavigation.shared
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    @ObservedObject private var remote = GoviRemoteStore.shared
    @State private var remoteHostsOpen = false
    @State private var remoteSelection: String?
    @State private var searching = false
    @State private var launcherOpen = false
    @State private var gitOpen = false
    @State private var settingsOpen = false
    @ObservedObject private var tasksTabs = GoviTasksTabs.shared
    private var windowNumber: Int? { surface?.window?.windowNumber }
    /// Whether this workspace's Tasks tab is in front. The tab itself lives in GoviTasksTabs
    /// so every workspace's sidebar can list it.
    private var tasksOpen: Bool {
        get { windowNumber.map { tasksTabs.showing.contains($0) } ?? false }
        nonmutating set { if let windowNumber { tasksTabs.setShowing(windowNumber, newValue) } }
    }
    @AppStorage("GoviGitExpanded") private var gitExpanded = false
    @StateObject private var changes = GoviGitChanges()
    @StateObject private var visibility = GoviWindowVisibility()
    @State private var collapsedSections: Set<String> = []
    @AppStorage("GoviTheme") private var themeID = "paper"
    @AppStorage("GoviSidebar") private var sidebar = true
    @AppStorage("GoviSidebarWidth") private var sidebarWidth: Double = 228
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var splash = GoviLaunchSplash.claim()
    @State private var focusMode = false
    @State private var collapsedDirectories: Set<String> = []
    /// Each workspace's directory, fixed when first known so `cd` doesn't regroup it.
    @State private var workspaceRoots: [Int: String] = [:]
    @State private var sidebarDragStart: Double?
    @State private var windows: [NSWindow] = []
    @State private var addingCommand = false
    @State private var commandName = ""
    @State private var commandText = ""
    @State private var menuKeyMonitor: Any?
    @State private var templatesOpen = false
    @State private var saveTemplateOnOpen = false
    @State private var attentionOpen = false
    @State private var outputSearch: GoviOutputSnapshot?
    @State private var filter = ""
    @State private var filterVisible = false
    private let sidebarRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var directory: String { pwd ?? surface?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path }

    private var workspaceLayout: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                let showingSidebar = sidebar && !focusMode
                ZStack {
                    GoviWindowDragRegion()
                    HStack(spacing: 8) {
                        // With the sidebar open, the left group spans its column so the
                        // window controls end in line with the sidebar's edge.
                        if showingSidebar {
                            windowHeader.frame(width: 12 + sidebarColumnWidth(geometry), alignment: .leading)
                        } else {
                            windowHeader.fixedSize(horizontal: true, vertical: false)
                        }
                        navigationButtons
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            GoviIconButton(symbol: "list.bullet.rectangle", help: "Tasks · GitHub and Linear", on: tasksOpen) {
                                if tasksOpen { closeTasks() } else { openTasks() }
                            }
                            GoviIconButton(
                                symbol: activity.attentionCount > 0 ? "bell.badge" : "bell",
                                help: "Notifications · \(activity.attentionCount)", on: attentionOpen
                            ) { toggleAttention() }
                            GoviIconButton(symbol: "plus", help: "New terminal or agent", on: launcherOpen) {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                                    attentionOpen = false
                                    launcherOpen.toggle()
                                }
                            }
                            GoviIconButton(
                                symbol: focusMode ? "arrow.down.right.and.arrow.up.left" : "viewfinder", help: "Toggle focus mode",
                                on: focusMode
                            ) {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { focusMode.toggle() }
                                focusTerminal()
                            }
                            GoviIconButton(symbol: "slider.horizontal.3", help: "Settings", on: settingsOpen) { toggleSettings() }
                        }.modifier(GoviGlassGroup()).padding(.trailing, 12)
                    }
                }.frame(height: 48)
                    // Keep the top bar (traffic lights, sidebar toggle, settings) above the panes.
                    .zIndex(1)
                HStack(alignment: .top, spacing: 0) {
                    if sidebar && !focusMode {
                        sidebarView
                            .frame(width: sidebarColumnWidth(geometry))
                            .frame(maxHeight: .infinity)
                            .padding(.bottom, 14)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        sidebarDivider.padding(.horizontal, 5)
                    }
                    terminalArea
                }.padding(.horizontal, 12)
            }
            .background { GoviBackdrop() }
        }
    }

    private var terminalArea: some View {
        VStack(spacing: 8) {
            if let surface { GoviRecoveryNotice(surface: surface) }
            if !settingsOpen && !tasksOpen, let link = surface?.goviLaunch.issue {
                GoviLinkedTaskBanner(link: link, openTasks: openTasks) {
                    gitOpen = true
                    gitExpanded = true
                }
            }
            content().environment(\.goviActivePane, surface?.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Settings take the terminal's place inline; the panes stay
                // alive underneath and come back untouched on close.
                .opacity(settingsOpen || tasksOpen ? 0 : 1)
                .allowsHitTesting(!settingsOpen && !tasksOpen)
                .overlay {
                    if tasksOpen {
                        GoviTasksView(
                            directory: directory, linked: surface?.goviLaunch.issue,
                            launch: { request in
                                let opened = launchTerminal(request)
                                if opened { tasksOpen = false }
                                return opened
                            }, close: closeTasksTab)
                    }
                }
                .overlay {
                    if settingsOpen {
                        GoviSettingsView(ghostty: ghostty, close: closeSettings, inline: true)
                            .transition(.opacity)
                    }
                }
                // Full-size git pane: fills the terminal area and stays until closed.
                .overlay {
                    if gitOpen && gitExpanded {
                        GoviGitPanel(changes: changes, directory: directory, expanded: true, toggleExpanded: toggleGitExpanded) {
                            gitOpen = false
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            if !focusMode {
                HStack {
                    Spacer(minLength: 0)
                    GoviRepositoryDock(directory: directory, openFolder: openFolder, changes: changes, visible: visibility.visible) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { gitOpen.toggle() }
                    }
                }
                .frame(height: 42)
            }
        }.padding(.bottom, 10)
    }

    private var decoratedWorkspace: some View {
        workspaceLayout
            .font(GoviInk.font()).foregroundStyle(ui.ink).background(ui.canvas)
            .overlay(alignment: .top) { if searching { searchPanel } }
            .overlay(alignment: .bottomTrailing) {
                if gitOpen && !gitExpanded {
                    ZStack(alignment: .bottomTrailing) {
                        Color.black.opacity(0.001).onTapGesture { gitOpen = false }
                        GoviGitPanel(changes: changes, directory: directory, expanded: false, toggleExpanded: toggleGitExpanded) {
                            gitOpen = false
                        }
                        .padding(.bottom, 62).padding(.trailing, 12)
                    }
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .onChange(of: gitOpen) { open in if !open { focusTerminal() } }
            .overlay(alignment: .topTrailing) {
                if launcherOpen || attentionOpen {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.001).onTapGesture { closeMenus() }
                        Group {
                            if launcherOpen {
                                GoviAgentMenu(
                                    directory: directory, launch: { _ = launchTerminal($0) }, addProject: addSpace,
                                    connect: { connectRemote($0) }
                                ) { launcherOpen = false }
                            } else {
                                GoviAttentionMenu { attentionOpen = false }
                            }
                        }.padding(.top, 46).padding(.trailing, 12)
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .overlay { if splash { GoviLaunchSplash { splash = false } } }
    }

    private var lifecycleWorkspace: some View {
        decoratedWorkspace
            .onAppear {
                refreshWindows()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { refreshWindows() }
                if surface?.window?.isKeyWindow == true { navigation.record(surface?.id, panel: openPanel) }
            }
            .onChange(of: tasksOpen) { open in
                // Shown from the sidebar row: stop the hidden terminal taking keys and record the visit.
                guard open else { return }
                closeMenus()
                gitOpen = false
                settingsOpen = false
                surface?.window?.makeFirstResponder(nil)
                navigation.record(surface?.id, panel: .tasks)
            }
            .onChange(of: surface?.id) { id in
                if settingsOpen { settingsOpen = false }
                if tasksOpen { tasksOpen = false }
                if surface?.window?.isKeyWindow == true { navigation.record(id) }
            }
            .onChange(of: searching) { open in
                guard !open else { return }
                // A chosen result focuses its own session; otherwise return to this one.
                DispatchQueue.main.async {
                    if !(surface?.window?.firstResponder is Ghostty.SurfaceView) { focusTerminal() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window = note.object as? NSWindow, window === surface?.window { navigation.record(surface?.id, panel: openPanel) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviShowPlace)) { note in
                guard let place = note.object as? GoviPlace, place.session == surface?.id else { return }
                show(place.panel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviSearchSessions)) { _ in
                if surface?.window == NSApp.keyWindow { searching.toggle() }
            }
            .onChange(of: launcherOpen || attentionOpen) { _ in updateMenuKeyMonitor() }
            .onDisappear {
                if let menuKeyMonitor {
                    NSEvent.removeMonitor(menuKeyMonitor)
                    self.menuKeyMonitor = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if let window = note.object as? NSWindow, window === surface?.window { closeMenus() }
            }
            .onReceive(sidebarRefresh) { _ in
                guard visibility.visible else { return }
                refreshWindows()
                detached.refresh()
                remote.refresh()
            }
            .background(GoviWindowVisibilityReader(visibility: visibility))
            .onChange(of: visibility.visible) { visible in
                changes.isVisible = visible
                if visible {
                    refreshWindows()
                    detached.refresh()
                    remote.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in refreshWindows() }
            .onReceive(NotificationCenter.default.publisher(for: .goviLayoutChanged)) { _ in refreshWindows() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                DispatchQueue.main.async { refreshWindows() }
            }
    }

    private var observedWorkspace: some View {
        lifecycleWorkspace
            .onReceive(NotificationCenter.default.publisher(for: .goviShowSettings)) { _ in
                if surface?.window == NSApp.keyWindow { toggleSettings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviTasks)) { _ in
                if surface?.window == NSApp.keyWindow { openTasks() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviRemoteHosts)) { note in
                if surface?.window == NSApp.keyWindow { showRemoteHosts(note.object as? String) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviTemplates)) { _ in
                if surface?.window == NSApp.keyWindow {
                    saveTemplateOnOpen = false
                    templatesOpen = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviSaveTemplate)) { _ in
                if surface?.window == NSApp.keyWindow {
                    saveTemplateOnOpen = true
                    templatesOpen = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviAttention)) { _ in
                if surface?.window == NSApp.keyWindow { toggleAttention() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviFindOutput)) { _ in
                if surface?.window == NSApp.keyWindow { findOutput() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviToggleFocus)) { _ in
                if surface?.window == NSApp.keyWindow {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { focusMode.toggle() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .goviToggleSidebar)) { _ in
                if surface?.window == NSApp.keyWindow {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        sidebar.toggle()
                        focusMode = false
                    }
                }
            }
    }

    var body: some View {
        observedWorkspace
            .sheet(isPresented: $addingCommand, onDismiss: focusTerminal) { commandEditor }
            .sheet(isPresented: $templatesOpen, onDismiss: focusTerminal) {
                if let owner = surface.flatMap({ GoviPaneCoordinator.owner(of: $0.id) }) {
                    GoviTemplatesView(controller: owner, saveCurrentOnAppear: saveTemplateOnOpen)
                }
            }
            .sheet(item: $outputSearch, onDismiss: focusTerminal) { GoviOutputSearch(text: $0.text) }
            .sheet(isPresented: $remoteHostsOpen, onDismiss: focusTerminal) {
                GoviRemoteHostsView(ghostty: ghostty, window: surface?.window, surface: surface, initialSelection: remoteSelection)
            }
    }

    private func showRemoteHosts(_ selection: String? = nil) {
        closeMenus()
        remoteSelection = selection
        remoteHostsOpen = true
    }
    private func connectRemote(_ target: GoviRemoteTarget, split: Bool = false) {
        if let failure = GoviRemoteLauncher.open(target, ghostty: ghostty, from: surface?.window, beside: split ? surface : nil) {
            let alert = NSAlert()
            alert.messageText = "Couldn't connect to \(target.name)"
            alert.informativeText = failure
            alert.runModal()
        }
        refreshWindows()
    }

    private func closeMenus() {
        launcherOpen = false
        attentionOpen = false
    }
    private func toggleAttention() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            launcherOpen = false
            attentionOpen.toggle()
        }
    }
    private var openPanel: GoviPanel? { settingsOpen ? .settings : tasksOpen ? .tasks : nil }
    /// Shows a panel (or the bare terminal) without recording history; back/forward uses this.
    private func show(_ panel: GoviPanel?) {
        closeMenus()
        gitOpen = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            settingsOpen = panel == .settings
            tasksOpen = panel == .tasks
        }
        // Let the hidden terminal stop taking keystrokes (Esc, typing) while a panel shows.
        if panel == nil { focusTerminal() } else { surface?.window?.makeFirstResponder(nil) }
    }
    private func openSettings() {
        show(.settings)
        navigation.record(surface?.id, panel: .settings)
    }
    private func closeSettings() {
        show(nil)
        navigation.record(surface?.id)
    }
    private func toggleSettings() { if settingsOpen { closeSettings() } else { openSettings() } }
    private func openTasks() {
        show(.tasks)
        navigation.record(surface?.id, panel: .tasks)
    }
    private func closeTasks() {
        show(nil)
        navigation.record(surface?.id)
    }
    private func closeTasksTab() {
        if let windowNumber { tasksTabs.close(windowNumber) }
        show(nil)
        navigation.record(surface?.id)
    }
    private func updateMenuKeyMonitor() {
        if let menuKeyMonitor {
            NSEvent.removeMonitor(menuKeyMonitor)
            self.menuKeyMonitor = nil
        }
        guard launcherOpen || attentionOpen else { return }
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === surface?.window else { return event }
            closeMenus()
            return nil
        }
    }

    private func toggleGitExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) { gitExpanded.toggle() }
    }

    private func sidebarColumnWidth(_ geometry: GeometryProxy) -> CGFloat {
        min(CGFloat(sidebarWidth), max(170, geometry.size.width * 0.28))
    }

    private var windowHeader: some View {
        HStack(spacing: 2) {
            GoviTrafficLights().frame(width: 56, height: 26)
            GoviWordmark().padding(.leading, 10)
            Spacer(minLength: 14)
            HStack(spacing: 0) {
                GoviSidebarToggle(isOpen: sidebar && !focusMode) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        if focusMode {
                            focusMode = false
                            sidebar = true
                        } else {
                            sidebar.toggle()
                        }
                    }
                    focusTerminal()
                }.frame(width: GoviChromeMetrics.button, height: GoviChromeMetrics.button)
                    .modifier(GoviHoverHighlight())
                GoviIconButton(symbol: "command", help: "Command palette · \(shortcuts.chord(.palette).display)", action: showPalette)
            }.modifier(GoviGlassGroup())
        }.padding(.leading, 16).frame(height: 48)
    }

    private var navigationButtons: some View {
        HStack(spacing: 0) {
            GoviIconButton(symbol: "chevron.left", help: "Back") { navigation.goBack() }
                .disabled(!navigation.canGoBack).opacity(navigation.canGoBack ? 1 : 0.4)
            Rectangle().fill(ui.line).frame(width: 0.5, height: 14)
            GoviIconButton(symbol: "chevron.right", help: "Forward") { navigation.goForward() }
                .disabled(!navigation.canGoForward).opacity(navigation.canGoForward ? 1 : 0.4)
        }.modifier(GoviGlassGroup())
    }

    private var searchPanel: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001).onTapGesture { searching = false }
            CommandPaletteView(isPresented: $searching, backgroundColor: ui.paper, options: searchOptions)
                .frame(width: 600).padding(.top, 34)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Every open session in every workspace, then background sessions, projects and saved commands.
    private var searchOptions: [CommandOption] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var options: [CommandOption] = []
        for controller in TerminalController.all {
            let leaves = controller.surfaceTree.surfaces
            let root = controller.window.flatMap { workspaceRoots[$0.windowNumber] } ?? leaves.first?.pwd ?? home
            for leaf in leaves {
                let state = activity.info[leaf.id]?.state ?? .idle
                var detail = [directoryName(root), GoviPaneNaming.shortPath(leaf.pwd ?? root)]
                if state != .idle { detail.append(state.label) }
                if leaf.id == surface?.id { detail.append("Current") }
                let id = leaf.id
                options.append(
                    .init(title: GoviPaneNaming.title(leaf), description: detail.joined(separator: " · "), symbols: nil) {
                        GoviNavigation.focus(id)
                    })
            }
        }
        for session in detached.sessions {
            let agent = GoviAgent.allCases.first { $0.commands.contains(session.agent) || $0.rawValue == session.agent }
            let name = agent?.name ?? (session.agent.isEmpty ? "Terminal" : session.agent)
            options.append(
                .init(title: name, description: "Running in background · \(GoviPaneNaming.shortPath(session.cwd))", symbols: nil) {
                    detached.open(session)
                })
        }
        for space in notebook.spaces {
            options.append(
                .init(title: "Open \(space.name)", description: "Saved project · \(GoviPaneNaming.shortPath(space.path))", symbols: nil) {
                    openFolder(space.path)
                })
        }
        for item in notebook.commands {
            options.append(.init(title: item.name, description: "Saved command · \(item.command)", symbols: nil) { stage(item.command) })
        }
        for entry in remote.entries where entry.kind != .tailnet || entry.online == true {
            let kind = entry.kind == .tailnet ? "Tailnet" : entry.kind == .sshConfig ? "ssh config" : "Remote host"
            options.append(
                .init(title: "Connect to \(entry.target.name)", description: "\(kind) · \(entry.detail)", symbols: nil) {
                    connectRemote(entry.target)
                })
        }
        options.append(
            .init(title: "Remote hosts…", description: "SSH and Tailscale connections", symbols: shortcuts.chord(.remoteHosts).symbols) {
                showRemoteHosts()
            })
        options.append(
            .init(
                title: "New workspace", description: "Start a terminal in \(GoviPaneNaming.shortPath(directory))",
                symbols: shortcuts.chord(.newWorkspace).symbols
            ) {
                launchTerminal(.init())
            })
        return options
    }

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text("Workspaces").font(GoviInk.font(14).weight(.semibold)).foregroundStyle(ui.ink)
                Spacer(minLength: 0)
                GoviIconButton(symbol: "line.3.horizontal.decrease", help: "Filter terminals", on: filterVisible) {
                    filterVisible.toggle()
                    if !filterVisible { filter = "" }
                }
                GoviIconButton(symbol: "folder.badge.plus", help: "Add project folder", action: addSpace)
            }.padding(.leading, 16).padding(.trailing, 8).frame(height: 46)
            Button {
                launchTerminal(.init())
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: GoviSidebarMetrics.icon)
                    Text("New workspace")
                    Spacer(minLength: 0)
                    Text(shortcuts.chord(.newWorkspace).display).font(GoviInk.font(11)).foregroundStyle(ui.muted)
                }.font(GoviInk.font(13)).foregroundStyle(ui.ink)
                    .padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(GoviProminentRowStyle()).padding(.horizontal, 8)
                .help("New workspace in the current folder")
            if filterVisible {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ui.muted)
                    TextField("Filter terminals…", text: $filter).textFieldStyle(.plain).font(GoviInk.font(12))
                }.padding(.horizontal, 10).frame(height: 30)
                    .background(ui.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 8).padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sidebarSection("Open projects", icon: "rectangle.stack") {
                        ForEach(directoryGroups) { group in directorySection(group) }
                    }
                    if !detached.sessions.isEmpty {
                        sidebarSection("Running in background", icon: "clock.arrow.circlepath") { backgroundSessions }
                    }
                    if !notebook.spaces.isEmpty {
                        sidebarSection("Saved projects", icon: "bookmark") { projectShortcuts }
                    }
                    if filter.isEmpty {
                        sidebarSection("Remote", icon: "network") {
                            GoviRemoteSidebarRows(open: { connectRemote($0, split: $1) }, edit: showRemoteHosts)
                        }
                    }
                }.padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 8)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                savedCommandsMenu
                Spacer()
                Text(sessionCountLabel).font(GoviInk.font(11)).foregroundStyle(ui.muted).padding(.trailing, 8)
            }.padding(.horizontal, 8).frame(height: 44)
        }.foregroundStyle(ui.ink)
            .modifier(GoviSidebarGlass())
    }

    private var sessionCountLabel: String {
        let count = windows.reduce(0) { $0 + leaves($1).count }
        return "\(count) terminal\(count == 1 ? "" : "s")"
    }

    /// A collapsible group with an icon header, like a mail or browser sidebar.
    @ViewBuilder private func sidebarSection<Rows: View>(_ title: String, icon: String, @ViewBuilder rows: () -> Rows) -> some View {
        let open = !collapsedSections.contains(title) || !filter.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            GoviHoverRow { hovering in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                        if collapsedSections.contains(title) { collapsedSections.remove(title) } else { collapsedSections.insert(title) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon).font(.system(size: 12)).frame(width: GoviSidebarMetrics.icon)
                        Text(title).font(GoviInk.font(12.5))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0)).opacity(hovering || !open ? 1 : 0)
                        Spacer(minLength: 0)
                    }.foregroundStyle(ui.muted)
                        .padding(.horizontal, GoviSidebarMetrics.inset).frame(height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(open ? "Collapse \(title)" : "Expand \(title)")
            }
            if open { rows() }
        }
    }

    private struct DirectoryGroup: Identifiable {
        let id: String
        let workspaces: [NSWindow]
    }
    /// Directory → workspaces (windows in this tab group) → tabs (their terminal panes).
    private var directoryGroups: [DirectoryGroup] {
        var order: [String] = []
        var members: [String: [NSWindow]] = [:]
        for window in windows {
            let root = workspaceRoot(window)
            if members[root] == nil { order.append(root) }
            members[root, default: []].append(window)
        }
        return order.map { DirectoryGroup(id: $0, workspaces: members[$0] ?? []) }
    }
    private func workspaceRoot(_ window: NSWindow) -> String {
        if let root = workspaceRoots[window.windowNumber] { return root }
        let controller = window.windowController as? TerminalController
        return controller?.surfaceTree.surfaces.first.map(rootKey) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    /// Remote panes group under their host, not the local folder ssh started in.
    private func rootKey(_ pane: Ghostty.SurfaceView) -> String {
        if let remote = pane.goviLaunch.remote { return Self.remotePrefix + remote.name }
        return pane.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    private static var remotePrefix: String { "ssh://" }
    private func remoteTarget(_ group: DirectoryGroup) -> GoviRemoteTarget? {
        guard group.id.hasPrefix(Self.remotePrefix) else { return nil }
        return group.workspaces.lazy.flatMap(leaves).compactMap { $0.goviLaunch.remote }.first
    }
    private func leaves(_ window: NSWindow) -> [Ghostty.SurfaceView] {
        (window.windowController as? TerminalController)?.surfaceTree.surfaces ?? []
    }
    private func visibleLeaves(_ window: NSWindow) -> [Ghostty.SurfaceView] {
        leaves(window).filter {
            filter.isEmpty || GoviPaneNaming.title($0).localizedCaseInsensitiveContains(filter)
                || ($0.pwd ?? "").localizedCaseInsensitiveContains(filter)
        }
    }
    private func visibleWebPanes(_ window: NSWindow) -> [GoviWebPaneView] {
        let panes = (window.windowController as? TerminalController)?.surfaceTree.compactMap { $0 as? GoviWebPaneView } ?? []
        return panes.filter {
            filter.isEmpty || $0.paneTitle.localizedCaseInsensitiveContains(filter)
                || ($0.url?.absoluteString ?? "").localizedCaseInsensitiveContains(filter)
        }
    }
    private func directoryName(_ path: String) -> String {
        if path.hasPrefix(Self.remotePrefix) { return String(path.dropFirst(Self.remotePrefix.count)) }
        return path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : URL(fileURLWithPath: path).lastPathComponent
    }
    private func waitingBadge(_ count: Int) -> some View {
        Text("\(count)").font(GoviInk.font(9.5).weight(.medium)).monospacedDigit()
            .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange, in: Capsule())
            .help("\(count) terminal\(count == 1 ? "" : "s") need attention")
    }
    private func chevron(_ open: Bool, label: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12, height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func rowMenu<Items: View>(_ help: String, @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 22, height: 22) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(help).accessibilityLabel(help)
    }

    @ViewBuilder private func directorySection(_ group: DirectoryGroup) -> some View {
        let shown = group.workspaces.filter { !visibleLeaves($0).isEmpty || !visibleWebPanes($0).isEmpty }
        if !shown.isEmpty {
            let open = !collapsedDirectories.contains(group.id) || !filter.isEmpty
            let waiting = group.workspaces.flatMap(leaves).filter { activity.info[$0.id]?.state.wantsAttention == true }.count
            let target = remoteTarget(group)
            VStack(alignment: .leading, spacing: 1) {
                GoviHoverRow { hovering in
                    HStack(spacing: 4) {
                        chevron(open, label: "Toggle \(directoryName(group.id))") {
                            if collapsedDirectories.contains(group.id) {
                                collapsedDirectories.remove(group.id)
                            } else {
                                collapsedDirectories.insert(group.id)
                            }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: target == nil ? "folder.fill" : "network").font(.system(size: 11)).frame(
                                width: GoviSidebarMetrics.icon
                            )
                            .foregroundStyle(ui.tone(for: group.id))
                            Text(directoryName(group.id)).font(GoviInk.font(13)).foregroundStyle(ui.ink).lineLimit(1).truncationMode(
                                .middle)
                        }
                        if !open && waiting > 0 { waitingBadge(waiting) }
                        Spacer(minLength: 0)
                        if let target {
                            rowMenu("Host actions") {
                                Button("New connection") { connectRemote(target) }
                                Button("Copy ssh Command") { GoviRemoteLauncher.copyCommand(target) }
                            }.opacity(hovering ? 1 : 0)
                        } else {
                            rowMenu("Directory actions") {
                                Button("New terminal here") { newWorkspace(in: group.id) }
                                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.id) }
                            }.opacity(hovering ? 1 : 0)
                        }
                    }.foregroundStyle(ui.muted).modifier(GoviSidebarRowStyle())
                        .help(target.flatMap(GoviRemoteCommand.display) ?? GoviPaneNaming.shortPath(group.id))
                }
                if open {
                    ForEach(shown, id: \.windowNumber) { window in
                        ForEach(visibleLeaves(window)) { item in
                            GoviSidebarTerminal(
                                surface: item, active: item.id == surface?.id && !tasksTabs.showing.contains(window.windowNumber)
                            ) {
                                tasksTabs.setShowing(window.windowNumber, false)
                                selectWorkspace(window)
                                (window.windowController as? TerminalController)?.focusedSurface = item
                                window.makeFirstResponder(item)
                            }.padding(.leading, GoviSidebarMetrics.indent)
                        }
                        ForEach(visibleWebPanes(window)) { item in
                            let controller = window.windowController as? TerminalController
                            GoviSidebarBrowser(
                                pane: item,
                                active: controller?.focusedPane === item && !tasksTabs.showing.contains(window.windowNumber)
                            ) {
                                tasksTabs.setShowing(window.windowNumber, false)
                                selectWorkspace(window)
                                controller?.focusedPane = item
                                window.makeFirstResponder(item.paneFocusTarget)
                            }.padding(.leading, GoviSidebarMetrics.indent)
                        }
                        if tasksTabs.tabs.contains(window.windowNumber)
                            && (filter.isEmpty || "tasks".localizedCaseInsensitiveContains(filter))
                        {
                            GoviSidebarTasksTab(active: tasksTabs.showing.contains(window.windowNumber)) {
                                selectWorkspace(window)
                                tasksTabs.setShowing(window.windowNumber, true)
                            } close: {
                                tasksTabs.close(window.windowNumber)
                                if window === surface?.window {
                                    show(nil)
                                    navigation.record(surface?.id)
                                }
                            }.padding(.leading, GoviSidebarMetrics.indent)
                        }
                    }
                }
            }
        }
    }

    private func newWorkspace(in path: String) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        _ = TerminalController.newTab(ghostty, from: surface?.window, withBaseConfig: config)
        refreshWindows()
    }

    /// Persistent sessions whose window was closed. They keep running in herdr-core.
    private var backgroundSessions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(detached.sessions) { session in
                let agent = GoviAgent.allCases.first { $0.commands.contains(session.agent) || $0.rawValue == session.agent }
                GoviHoverRow { hovering in
                    Button {
                        detached.open(session)
                    } label: {
                        HStack(spacing: 8) {
                            Group {
                                if let agent {
                                    GoviAgentGlyph(agent: agent).foregroundStyle(ui.tone(for: agent.rawValue))
                                } else {
                                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(ui.accent)
                                }
                            }.frame(width: GoviSidebarMetrics.icon)
                            Text(agent?.name ?? (session.agent.isEmpty ? "Terminal" : session.agent)).foregroundStyle(ui.ink.opacity(0.85))
                                .lineLimit(1)
                            Text(GoviPaneNaming.shortPath(session.cwd)).font(GoviInk.font(10.5)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }.font(GoviInk.font(12.5).weight(.light)).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(ui.muted).modifier(GoviSidebarRowStyle())
                        .help("Still running. Click to open it in a new workspace.")
                        .contextMenu {
                            Button("Open") { detached.open(session) }
                            Button("End session") { detached.end(session) }
                        }
                }
            }
        }
    }

    private var projectShortcuts: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(notebook.spaces) { space in
                GoviHoverRow { hovering in
                    Button {
                        openFolder(space.path)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").font(.system(size: 11)).frame(width: GoviSidebarMetrics.icon)
                                .foregroundStyle(ui.tone(for: space.path))
                            Text(space.name).foregroundStyle(hovering ? ui.ink : ui.muted).lineLimit(1)
                            Spacer(minLength: 0)
                        }.font(GoviInk.font(12.5).weight(.light)).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(ui.muted).modifier(GoviSidebarRowStyle()).help(space.path)
                        .contextMenu {
                            Button("Open in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: space.path) }
                            Button("Remove shortcut") { notebook.spaces.removeAll { $0.id == space.id } }
                        }
                }
            }
        }
    }

    private var savedCommandsMenu: some View {
        Menu {
            ForEach(notebook.commands) { item in Button(item.name) { stage(item.command) } }
            if !notebook.commands.isEmpty { Divider() }
            Button("Save a command…") { addingCommand = true }
            if !notebook.commands.isEmpty {
                Menu("Remove command") {
                    ForEach(notebook.commands) { item in Button(item.name) { notebook.commands.removeAll { $0.id == item.id } } }
                }
            }
        } label: {
            GoviSymbol(symbol: "bookmark").frame(width: GoviChromeMetrics.button, height: GoviChromeMetrics.button).modifier(
                GoviHoverHighlight())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Saved commands").accessibilityLabel("Saved commands")
    }

    private var sidebarDivider: some View {
        Rectangle().fill(Color.clear).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle()).backport.pointerStyle(.resizeLeftRight)
                    .gesture(
                        DragGesture().onChanged { value in
                            if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                            sidebarWidth = min(360, max(185, (sidebarDragStart ?? sidebarWidth) + value.translation.width))
                        }.onEnded { _ in sidebarDragStart = nil })
            }
    }

    private var commandEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save command").font(GoviInk.font(17).weight(.medium))
            TextField("Name", text: $commandName)
            TextField("Command", text: $commandText)
            Text("Selecting a saved command fills the terminal input. Press Return to run it.").font(GoviInk.font(11)).foregroundStyle(
                ui.muted)
            HStack {
                Button("Cancel") { addingCommand = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    notebook.commands.append(.init(name: commandName.trimmingCharacters(in: .whitespacesAndNewlines), command: commandText))
                    commandName = ""
                    commandText = ""
                    addingCommand = false
                }.keyboardShortcut(.defaultAction)
                    .disabled(
                        commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandText.contains("\n")
                            || commandText.contains("\r"))
            }
        }.padding(26).frame(width: 440).background(ui.paper).foregroundStyle(ui.ink).font(GoviInk.font(12))
    }
    private func workspaceName(_ window: NSWindow?) -> String {
        if let name = (window?.windowController as? TerminalController)?.goviName, !name.isEmpty { return name }
        if let controller = window?.windowController as? TerminalController,
            let path = controller.focusedSurface?.pwd ?? controller.surfaceTree.surfaces.first?.pwd
        {
            return path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : URL(fileURLWithPath: path).lastPathComponent
        }
        guard let window, let index = windows.firstIndex(of: window), windows.count > 1 else { return "Terminal" }
        return "Workspace \(index + 1)"
    }
    private func selectWorkspace(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    private func perform(_ action: String) {
        _ = surface?.surfaceModel?.perform(action: action)
        focusTerminal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { refreshWindows() }
    }
    private func focusTerminal() {
        DispatchQueue.main.async {
            guard !settingsOpen && !tasksOpen else { return }
            if let surface { surface.window?.makeFirstResponder(surface) }
        }
    }
    private func stage(_ command: String) {
        surface?.surfaceModel?.sendText(command)
        focusTerminal()
    }
    private func findOutput() {
        guard let terminal = surface?.surface else { return }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(terminal, selection, &text) else { return }
        defer { ghostty_surface_free_text(terminal, &text) }
        outputSearch = GoviOutputSnapshot(text: String(cString: text.text))
    }
    private func refreshWindows() {
        guard let window = surface?.window else { return }
        windows = (window.tabbedWindows ?? [window]).filter { $0.windowController is TerminalController }
        let numbers = Set(windows.map(\.windowNumber))
        tasksTabs.prune(keeping: Set(TerminalController.all.compactMap { $0.window?.windowNumber }))
        var roots = workspaceRoots.filter { numbers.contains($0.key) }
        for window in windows where roots[window.windowNumber] == nil {
            if let pane = leaves(window).first, pane.goviLaunch.remote != nil || pane.pwd != nil {
                roots[window.windowNumber] = rootKey(pane)
            }
        }
        if roots != workspaceRoots { workspaceRoots = roots }
    }
    private func addSpace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder."
        panel.prompt = "Add project"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                focusTerminal()
                return
            }
            if !notebook.spaces.contains(where: { $0.path == url.path }) {
                notebook.spaces.append(.init(name: url.lastPathComponent, path: url.path))
            }
            openFolder(url.path)
        }
        if let window = surface?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    @discardableResult private func launchTerminal(_ request: GoviLaunch) -> Bool {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = request.directory ?? directory
        config.goviLaunch.agent = request.agent?.rawValue
        config.goviLaunch.task = request.label
        config.goviLaunch.issue = request.issue
        if let executable = request.executable {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let invocation = ([executable] + (request.agent?.launchArguments ?? []) + request.arguments).map(GoviShell.quote).joined(
                separator: " ")
            let script = invocation + "; " + GoviShell.agentExitStatus + "exec " + GoviAgent.quote(shell) + " -l"
            config.command = GoviAgent.quote(shell) + " -lic " + GoviAgent.quote(script)
        }
        let controller = TerminalController.newTab(ghostty, from: surface?.window, withBaseConfig: config)
        if request.agent != nil || request.label != nil,
            let created = controller?.surfaceTree.surfaces.first
        {
            GoviActivityCenter.shared.tag(created, agent: request.agent, label: request.label)
        }
        refreshWindows()
        return controller != nil
    }
    private func openFolder(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let alert = NSAlert()
            alert.messageText = "Folder not found"
            alert.informativeText = path
            alert.runModal()
            return
        }
        if let existing = windows.first(where: {
            ($0.windowController as? TerminalController)?.surfaceTree.surfaces.contains(where: { $0.pwd == path }) == true
        }) {
            selectWorkspace(existing)
            return
        }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        _ = TerminalController.newTab(ghostty, from: surface?.window, withBaseConfig: config)
        refreshWindows()
    }
}

extension Notification.Name {
    static let goviAttention = Notification.Name("goviAttention")
    static let goviTemplates = Notification.Name("goviTemplates")
    static let goviSaveTemplate = Notification.Name("goviSaveTemplate")
    static let goviToggleFocus = Notification.Name("goviToggleFocus")
    static let goviToggleSidebar = Notification.Name("goviToggleSidebar")
    static let goviShowSettings = Notification.Name("goviShowSettings")
    static let goviFindOutput = Notification.Name("goviFindOutput")
    static let goviLayoutChanged = Notification.Name("goviLayoutChanged")
}
struct GoviOutputSnapshot: Identifiable {
    let id = UUID()
    let text: String
}
struct GoviOutputSearch: View {
    @Environment(\.goviPalette) private var ui

    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool
    private var matchingLines: [String] {
        let lines = text.components(separatedBy: "\n")
        return query.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Find in terminal output").font(GoviInk.font(17).weight(.medium))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search output…", text: $query).focused($focused).textFieldStyle(.roundedBorder)
            HStack {
                Text(query.isEmpty ? "Scrollback snapshot" : "\(matchingLines.count) matching lines")
                Spacer()
                Button("Copy results") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(matchingLines.joined(separator: "\n"), forType: .string)
                }.disabled(matchingLines.isEmpty)
            }.font(GoviInk.font(11)).foregroundStyle(ui.muted)
            ScrollView([.horizontal, .vertical]) {
                Text(matchingLines.isEmpty ? "No matches" : matchingLines.joined(separator: "\n"))
                    .font(.custom(GoviFontCatalog.selected, size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(15)
            }.background(ui.canvas, in: RoundedRectangle(cornerRadius: 8))
            Text("Snapshot of the focused terminal. Running processes continue.").font(GoviInk.font(10)).foregroundStyle(ui.muted)
        }.font(GoviInk.font(12)).foregroundStyle(ui.ink).padding(25)
            .frame(width: 720, height: 520).background(ui.paper).onAppear { focused = true }
    }
}
