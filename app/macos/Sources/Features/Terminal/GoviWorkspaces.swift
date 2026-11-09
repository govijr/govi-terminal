import AppKit
import SwiftUI
import GhosttyKit

/// An atomic, metadata-only checkpoint independent of AppKit's saved state.
/// No screen contents, shell environment, credentials or history are recorded.
@MainActor final class GoviWorkspaceStore: ObservableObject {
    static let shared = GoviWorkspaceStore()
    @Published private(set) var error: String?
    @Published var templates: [GoviWorkspaceTemplate] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(data, forKey: "GoviWorkspaceTemplatesV1") }
        }
    }
    private let folder: URL
    private let io = DispatchQueue(label: "app.govi.workspaces", qos: .utility)
    private var timer: Timer?
    private var lastData: Data?
    private var checkpoint: GoviRecoveryCheckpoint?
    private let closing = NSHashTable<NSWindow>.weakObjects()
    private var observing: NSObjectProtocol?

    init() {
        folder = GoviDataPaths.supportDirectory
        if let data = UserDefaults.standard.data(forKey: "GoviWorkspaceTemplatesV1"),
           let saved = try? JSONDecoder().decode([GoviWorkspaceTemplate].self, from: data) {
            templates = saved.filter { $0.layout.isValid }
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Recovery.json")), data.count <= 2_097_152 {
            if let value = try? JSONDecoder().decode(GoviRecoveryCheckpoint.self, from: data), value.isValid { checkpoint = value }
            else { error = "The previous recovery checkpoint could not be read. macOS window restoration is still available." }
        }
    }

    func record(for id: UUID) -> GoviPaneRecord? {
        checkpoint?.workspaces.lazy.flatMap { $0.layout.panes }.first { $0.id == id }
    }

    func start() {
        guard timer == nil else { return }
        observing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.windowController is TerminalController else { return }
            Task { @MainActor in
                guard let self, !GoviPersistence.terminating else { return }
                self.closing.add(window); self.save()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
        save()
    }

    /// AppKit restoration takes precedence. This fallback runs only when it did
    /// not restore any terminal windows, preventing duplicate programs.
    @discardableResult func restoreIfNeeded(_ ghostty: Ghostty.App) -> Bool {
        guard TerminalController.all.isEmpty, let checkpoint, !checkpoint.workspaces.isEmpty else { return false }
        var parents: [Int: NSWindow] = [:]
        for saved in checkpoint.workspaces {
            if let controller = open(saved, ghostty: ghostty, parent: parents[saved.group], runCommands: false) {
                if parents[saved.group] == nil { parents[saved.group] = controller.window }
            }
        }
        return !TerminalController.all.isEmpty
    }

    func capture(_ controller: TerminalController, group: Int = 0, forRecovery: Bool = false) -> GoviWorkspaceRecord? {
        guard let root = controller.surfaceTree.root else { return nil }
        func captureNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> GoviWorkspaceLayout {
            switch node {
            case .leaf(let pane):
                var launch = pane.goviLaunch
                if forRecovery { launch.command = nil }
                return .terminal(.init(id: pane.id, title: GoviPaneNaming.title(pane),
                                       directory: pane.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                       launch: launch, persistentName: GoviPersistence.recordedName(for: pane.id)))
            case .split(let split):
                return .split(vertical: split.direction == .vertical, ratio: min(0.95, max(0.05, split.ratio)),
                              first: captureNode(split.left), second: captureNode(split.right))
            }
        }
        let frame = controller.window?.frame ?? .zero
        let layout = captureNode(root)
        let name = controller.goviName ?? URL(fileURLWithPath: layout.panes.first?.directory ?? "").lastPathComponent
        return .init(id: controller.goviID, name: name, layout: layout, focusedPane: controller.focusedSurface?.id,
                     group: group, frame: [frame.origin.x, frame.origin.y, frame.width, frame.height])
    }

    func save(wait: Bool = false) {
        let controllers = TerminalController.all.filter { controller in
            guard let window = controller.window else { return false }
            return !closing.contains(window) && window.contentView != nil && !controller.surfaceTree.isEmpty
        }
        var groups: [Int: Int] = [:]
        let records = controllers.compactMap { controller -> GoviWorkspaceRecord? in
            let key = controller.window?.tabGroup?.windows.first?.windowNumber ?? controller.window?.windowNumber ?? 0
            if groups[key] == nil { groups[key] = groups.count }
            return capture(controller, group: groups[key]!, forRecovery: true)
        }
        let value = GoviRecoveryCheckpoint(workspaces: records)
        guard value.isValid else { return }
        // Compare content without its timestamp to avoid writing every timer tick.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let contents = try? encoder.encode(records), contents != lastData else { if wait { io.sync {} }; return }
        lastData = contents; checkpoint = value
        guard let data = try? encoder.encode(value) else { return }
        let destination = folder.appendingPathComponent("Recovery.json"), folder = self.folder
        io.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch {
                Task { @MainActor in
                    self?.lastData = nil
                    self?.error = "Govi could not save workspace recovery. Check available disk space and folder access."
                }
            }
        }
        if wait { io.sync {} }
    }

    @discardableResult func open(_ saved: GoviWorkspaceRecord, ghostty: Ghostty.App, parent: NSWindow?, runCommands: Bool) -> TerminalController? {
        guard saved.layout.isValid, let app = ghostty.app else { return nil }
        func build(_ node: GoviWorkspaceLayout) -> SplitTree<Ghostty.SurfaceView>.Node {
            switch node {
            case .terminal(let record):
                var config = Ghostty.SurfaceConfiguration()
                var isDirectory: ObjCBool = false
                config.workingDirectory = FileManager.default.fileExists(atPath: record.directory, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? record.directory : FileManager.default.homeDirectoryForCurrentUser.path
                config.goviLaunch = record.launch
                if runCommands { config.command = Self.command(for: record.launch) }
                else {
                    config.environmentVariables["GOVI_RECOVERED"] = "1"
                    if let name = record.persistentName { config.environmentVariables[GoviPersistence.attachEnv] = name }
                }
                let pane = Ghostty.SurfaceView(app, baseConfig: config, uuid: record.id)
                if runCommands && !record.title.isEmpty { pane.setGoviTitle(record.title) }
                GoviActivityCenter.shared.tag(pane, agent: record.launch.agent.flatMap(GoviAgent.init(rawValue:)), label: record.launch.task)
                return .leaf(view: pane)
            case .split(let vertical, let ratio, let first, let second):
                return .split(.init(direction: vertical ? .vertical : .horizontal, ratio: ratio, left: build(first), right: build(second)))
            }
        }
        let controller = TerminalController(ghostty, withSurfaceTree: .init(root: build(saved.layout), zoomed: nil))
        controller.goviID = saved.id; controller.goviName = saved.name
        guard let window = controller.window else { return nil }
        if let parent, window.tabbingMode != .disallowed { parent.addTabbedWindow(window, ordered: .above) }
        else if saved.frame.count == 4 && saved.frame.allSatisfy(\.isFinite), saved.frame[2] >= 400, saved.frame[3] >= 250 {
            let proposed = NSRect(x: saved.frame[0], y: saved.frame[1], width: saved.frame[2], height: saved.frame[3])
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(proposed) }) { window.setFrame(proposed, display: false) }
        }
        if let id = saved.focusedPane, let pane = controller.surfaceTree.first(where: { $0.id == id }) { controller.focusedSurface = pane }
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.makeFirstResponder(controller.focusedSurface ?? controller.surfaceTree.first) }
        return controller
    }

    static func command(for launch: GoviPaneLaunch) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let remote = launch.remote { return GoviRemoteCommand.pane(remote, shell: shell) }
        let inner: String
        if let agent = launch.agent.flatMap(GoviAgent.init(rawValue:)) {
            inner = ([GoviAgentCatalog.shared.installed[agent] ?? agent.commands[0]] + agent.launchArguments).map(GoviShell.quote).joined(separator: " ")
        }
        else if let tool = launch.tool, GoviTool(rawValue: tool) != nil {
            inner = "/bin/bash " + GoviShell.quote(GoviResources.resourceURL.appendingPathComponent("Tools/govi-tool").path) + " " + GoviShell.quote(tool)
        } else if let command = launch.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inner = command }
        else { return nil }
        let finish = launch.agent != nil ? GoviShell.agentExitStatus : ""
        return GoviShell.quote(shell) + " -lic " + GoviShell.quote(inner + "; " + finish + "exec " + GoviShell.quote(shell) + " -l")
    }

    func resume(_ surface: Ghostty.SurfaceView) {
        guard let agent = surface.goviLaunch.agent.flatMap(GoviAgent.init(rawValue:)), let arguments = agent.resumeArguments,
              let owner = GoviPaneCoordinator.owner(of: surface.id) else { return }
        var config = Ghostty.SurfaceConfiguration(); config.workingDirectory = surface.pwd
        config.goviLaunch = surface.goviLaunch
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable = GoviAgentCatalog.shared.installed[agent] ?? agent.commands[0]
        let command = ([executable] + agent.launchArguments + arguments).map(GoviShell.quote).joined(separator: " ")
        config.command = GoviShell.quote(shell) + " -lic " + GoviShell.quote(command + "; " + GoviShell.agentExitStatus + "exec " + GoviShell.quote(shell) + " -l")
        if let controller = TerminalController.newTab(owner.ghostty, from: surface.window, withBaseConfig: config), let pane = controller.surfaceTree.first {
            GoviActivityCenter.shared.tag(pane, agent: agent, label: surface.goviLaunch.task)
            surface.goviRecovered = false
        }
    }

    func openTemplate(_ template: GoviWorkspaceTemplate, from controller: TerminalController) -> String? {
        guard template.layout.isValid else { return "This template has an invalid pane layout." }
        for pane in template.layout.panes {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: pane.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "The folder for \(pane.title) is unavailable: \(pane.directory)"
            }
            if let agent = pane.launch.agent.flatMap(GoviAgent.init(rawValue:)), GoviAgentCatalog.shared.installed[agent] == nil {
                return "\(agent.name) is not available. Use the agent launcher to install or locate it, then check again."
            }
        }
        let record = GoviWorkspaceRecord(id: UUID(), name: template.name, layout: template.layout.freshInstance(), focusedPane: nil, group: 0, frame: [])
        guard open(record, ghostty: controller.ghostty, parent: controller.window, runCommands: true) != nil else { return "Govi could not open this workspace." }
        save()
        return nil
    }
}

/// Saving captures the split tree. Editing changes launch intent without
/// executing it; Open Template is the explicit boundary for starting programs.
struct GoviTemplatesView: View {
    let controller: TerminalController
    var saveCurrentOnAppear = false
    @ObservedObject private var store = GoviWorkspaceStore.shared
    @ObservedObject private var remote = GoviRemoteStore.shared
    @Environment(\.goviPalette) private var ui
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GoviWorkspaceTemplate?
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Project templates").font(GoviInk.font(17).weight(.medium))
                Button("Save Current Workspace…", action: capture)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.templates) { template in
                            Button { draft = template; failure = nil } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.name).font(GoviInk.font(12).weight(.medium))
                                    Text("\(template.layout.panes.count) terminals").font(GoviInk.font(10)).foregroundStyle(ui.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(draft?.id == template.id ? ui.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if store.templates.isEmpty { Text("Save a workspace to reopen its folders, pane arrangement, commands and agents together.").font(GoviInk.font(11)).foregroundStyle(ui.muted) }
                Spacer(minLength: 0)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 230).background(ui.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let draft {
                    TextField("Template name", text: bindingName).font(GoviInk.font(18).weight(.medium)).textFieldStyle(.roundedBorder)
                    Text("Opening this template creates a new workspace. Review what each terminal starts below.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            ForEach(draft.layout.panes) { pane in paneEditor(pane) }
                        }
                    }
                    Text("Startup commands are stored on this Mac. Keep passwords and API keys in your shell or Keychain.").font(GoviInk.font(10)).foregroundStyle(ui.muted)
                    if let failure { Text(failure).font(GoviInk.font(11)).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        if store.templates.contains(where: { $0.id == draft.id }) {
                            Button("Delete…") { delete(draft) }
                        }
                        Spacer()
                        Button("Save Template", action: save).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Open Template") {
                            failure = store.openTemplate(draft, from: controller)
                            if failure == nil { dismiss() }
                        }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Text("Your project, ready to work.").font(GoviInk.font(21).weight(.medium))
                    Text("Choose a template or save the current workspace. Pane sizes and positions are preserved; every launch starts fresh terminals.")
                        .foregroundStyle(ui.muted).lineSpacing(5)
                    Spacer()
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.font(GoviInk.font(12)).foregroundStyle(ui.ink).background(ui.paper)
            .frame(width: 880, height: 640).modifier(GoviChromeAppearance())
            .onAppear { GoviAgentCatalog.shared.refresh(); if saveCurrentOnAppear { capture() } else { draft = store.templates.first } }
    }

    private var bindingName: Binding<String> { Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }) }
    private func paneEditor(_ pane: GoviPaneRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Terminal name", text: field(pane.id, \.title)).font(GoviInk.font(13).weight(.medium))
            HStack {
                TextField("Folder", text: field(pane.id, \.directory)).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDirectory(pane.id) }.controlSize(.small)
            }
            Picker("Start", selection: startBinding(pane)) {
                Text("Shell").tag("shell")
                Text("Command").tag("command")
                ForEach(GoviAgent.allCases) { agent in Text(agent.name).tag("agent:" + agent.rawValue) }
                ForEach(GoviTool.allCases) { tool in Text(tool.name).tag("tool:" + tool.rawValue) }
                ForEach(remote.saved) { host in Text("SSH: " + host.target.name).tag("remote:" + host.id.uuidString) }
                if let current = pane.launch.remote, !remote.saved.contains(where: { $0.target == current }) {
                    Text("SSH: " + current.name).tag("remote:current")
                }
            }
            if pane.launch.command != nil {
                TextField("Startup command", text: Binding(get: { self.draft?.layout.panes.first { $0.id == pane.id }?.launch.command ?? "" }, set: { value in update(pane.id) { $0.launch.command = value } }))
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Task label (optional)", text: Binding(get: { self.draft?.layout.panes.first { $0.id == pane.id }?.launch.task ?? "" }, set: { value in update(pane.id) { $0.launch.task = value.isEmpty ? nil : value } }))
                .textFieldStyle(.roundedBorder)
        }.padding(12).background(ui.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
    private func field(_ id: UUID, _ path: WritableKeyPath<GoviPaneRecord, String>) -> Binding<String> {
        Binding(get: { draft?.layout.panes.first { $0.id == id }?[keyPath: path] ?? "" }, set: { value in update(id) { $0[keyPath: path] = value } })
    }
    private func startBinding(_ pane: GoviPaneRecord) -> Binding<String> {
        Binding(get: {
            guard let current = draft?.layout.panes.first(where: { $0.id == pane.id }) else { return "shell" }
            if let target = current.launch.remote {
                return remote.saved.first { $0.target == target }.map { "remote:" + $0.id.uuidString } ?? "remote:current"
            }
            if let agent = current.launch.agent { return "agent:" + agent }
            if let tool = current.launch.tool { return "tool:" + tool }
            return current.launch.command != nil ? "command" : "shell"
        }, set: { choice in
            if choice == "remote:current" { return }
            update(pane.id) {
                let task = $0.launch.task
                $0.launch = .init(task: task)
                if choice.hasPrefix("remote:"), let host = remote.saved.first(where: { "remote:" + $0.id.uuidString == choice }) {
                    $0.launch.remote = host.target; $0.launch.task = task ?? host.target.name
                }
                if choice.hasPrefix("agent:") { $0.launch.agent = String(choice.dropFirst(6)) }
                else if choice.hasPrefix("tool:") { $0.launch.tool = String(choice.dropFirst(5)) }
                else if choice == "command" { $0.launch.command = "" }
            }
        })
    }
    private func update(_ id: UUID, _ edit: (inout GoviPaneRecord) -> Void) {
        guard var value = draft else { return }
        value.layout = value.layout.replacingPanes { pane in
            guard pane.id == id else { return pane }; var pane = pane; edit(&pane); return pane
        }
        draft = value
        failure = nil
    }
    private func capture() {
        guard let record = store.capture(controller) else { return }
        draft = .init(name: controller.goviName ?? record.name, layout: record.layout.replacingPanes { pane in var copy = pane; copy.persistentName = nil; return copy })
        failure = nil
    }
    private func save() {
        guard var value = draft else { return }
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.layout = value.layout.replacingPanes { pane in var copy = pane; copy.directory = (pane.directory as NSString).expandingTildeInPath; return copy }
        guard !value.name.isEmpty, value.layout.isValid else { failure = "Choose an absolute folder path for every terminal."; return }
        if let index = store.templates.firstIndex(where: { $0.id == value.id }) { store.templates[index] = value }
        else { store.templates.append(value) }
        draft = value; failure = nil
    }
    private func delete(_ template: GoviWorkspaceTemplate) {
        let alert = NSAlert(); alert.messageText = "Delete \(template.name)?"
        alert.informativeText = "Open workspaces and their running programs are kept."
        alert.addButton(withTitle: "Delete Template"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.templates.removeAll { $0.id == template.id }; draft = store.templates.first
    }
    private func chooseDirectory(_ id: UUID) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update(id) { $0.directory = url.path }
    }
}

struct GoviRecoveryNotice: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    @Environment(\.goviPalette) private var ui
    var body: some View {
        if surface.goviRecovered {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise")
                Text("Workspace restored. The previous program is no longer attached.").font(GoviInk.font(11))
                Spacer(minLength: 4)
                if let target = surface.goviLaunch.remote, let ghostty = GoviPaneCoordinator.owner(of: surface.id)?.ghostty {
                    Button("Reconnect to \(target.name)") {
                        if GoviRemoteLauncher.open(target, ghostty: ghostty, from: surface.window) == nil { surface.goviRecovered = false }
                    }.help("Open a new connection to this host in a new workspace.")
                }
                if let agent = surface.goviLaunch.agent.flatMap(GoviAgent.init(rawValue:)), agent.resumeArguments != nil {
                    Button("Resume \(agent.name)…") { GoviWorkspaceStore.shared.resume(surface) }
                        .help("Open the agent's session chooser in a new workspace.")
                }
                Button { surface.goviRecovered = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss recovery notice")
            }.padding(10).foregroundStyle(ui.ink).background(ui.paper)
        }
    }
}
