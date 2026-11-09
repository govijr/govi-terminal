import SwiftUI
import AppKit

/// Persistent sessions through herdr-core (`hc`, Apache-2.0).
///
/// With this on, each new pane's program runs in an `hc` terminal named after
/// the pane, and the pane itself runs `hc attach`. Quitting or updating Govi
/// only ends the attach client; the program keeps running. Restored panes keep
/// their UUIDs (window-save-state = always), so they find and reattach their
/// terminals. Closing a pane on purpose ends its terminal.
///
/// `hc attach` passes titles, OSC 7, OSC 9;4 progress, notifications and the
/// bell through, so the sidebar's activity status keeps working.
enum GoviPersistence {
    static let enabledKey = "GoviPersistentSessions"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) && hcPath != nil }

    /// Set when the app starts terminating, so panes torn down during quit
    /// leave their terminals running.
    nonisolated(unsafe) static var terminating = false

    private static let lock = NSLock()
    /// Panes wrapped during this launch, by surface ID.
    nonisolated(unsafe) private static var attached: [UUID: String] = [:]
    nonisolated(unsafe) private static var confirmed: Set<UUID> = []
    /// Panes whose window or workspace was closed: their terminals keep running.
    nonisolated(unsafe) private static var detachedPanes: Set<UUID> = []
    private static let namesKey = "GoviPersistentNames"
    /// Marks a pane opened to reattach to an existing terminal.
    static let attachEnv = "GOVI_HC_NAME"
    /// Bumped whenever the environment Govi passes to hc changes. A running
    /// shell can't pick up a new environment, so older sessions say so.
    static let environmentVersion = 4

    static var hcPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin"] + path
        let custom = UserDefaults.standard.string(forKey: "GoviHelperPath").map { [$0] } ?? []
        return (custom + candidates.map { $0 + "/hc" }).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Names

    /// Terminal names: 1–32 of a-z 0-9 - _. A pane's UUID without dashes fits exactly.
    static func defaultName(for id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    private static var storedNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: namesKey) }
    }
    static func isPersistent(_ id: UUID) -> Bool { lock.withLock { attached[id] != nil && confirmed.contains(id) } }
    static func recordedName(for id: UUID) -> String? { lock.withLock { attached[id] } ?? storedNames[id.uuidString] }

    @MainActor static func confirm(_ id: UUID, live: Bool, recovered: Bool) {
        lock.withLock {
            if live && attached[id] != nil {
                confirmed.insert(id)
            } else {
                confirmed.remove(id)
                attached[id] = nil
            }
        }
        if let owner = GoviPaneCoordinator.owner(of: id), let pane = owner.surfaceTree.surfaces.first(where: { $0.id == id }) {
            pane.goviRecovered = recovered
        }
        GoviDetachedStore.shared.refresh(force: true)
    }

    /// Window- and workspace-level closes only need to confirm for panes whose
    /// programs would end. Closing a single pane still confirms as usual.
    static func needsConfirmClose(_ surface: Ghostty.SurfaceView) -> Bool {
        surface.needsConfirmQuit && !isPersistent(surface.id)
    }

    /// Closing a window or workspace detaches its persistent panes instead of
    /// ending their programs. They're listed under "Running in background".
    static func detach(_ tree: SplitTree<GoviPaneView>) {
        let ids = tree.map { $0.id }
        lock.withLock {
            for id in ids where attached.removeValue(forKey: id) != nil {
                detachedPanes.insert(id)
                confirmed.remove(id)
            }
        }
        DispatchQueue.main.async { GoviDetachedStore.shared.refresh(force: true) }
    }

    // MARK: Launch

    /// Returns the command a pane runs instead of `command`, or nil to launch normally.
    static func wrap(id: UUID, command: String?, workingDirectory: String?, environment: [String: String]) -> String? {
        var environment = environment
        let requested = environment.removeValue(forKey: attachEnv)
        let restoring = environment.removeValue(forKey: "GOVI_RECOVERED") == "1"
        guard let hc = hcPath, enabled || requested != nil else { return nil }
        let name: String
        if let requested { name = requested } else { name = storedNames[id.uuidString] ?? defaultName(for: id) }
        guard (1...32).contains(name.utf8.count),
            name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        storedNames[id.uuidString] = name
        lock.withLock { attached[id] = name }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let q = GoviAgent.quote
        // hc terminals take their environment from the hc server, not from
        // this client, so pass what Ghostty and Govi would have set.
        environment["TERM_PROGRAM"] = "ghostty"
        environment["COLORTERM"] = "truecolor"
        // hc forwards TERM (xterm-ghostty) but not TERMINFO. Without it zsh
        // reports an unknown terminal and its line editor can't redraw.
        if let terminfo = Bundle.main.resourceURL?.appendingPathComponent("terminfo").path,
            FileManager.default.fileExists(atPath: terminfo)
        {
            environment["TERMINFO"] = terminfo
            environment["TERM"] = "xterm-ghostty"
        } else {
            environment["TERM"] = "xterm-256color"
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path {
            environment["GHOSTTY_RESOURCES_DIR"] = resources
            let integration = resources + "/shell-integration/zsh"
            if URL(fileURLWithPath: shell).lastPathComponent == "zsh",
                FileManager.default.fileExists(atPath: integration + "/ghostty-integration")
            {
                if let original = ProcessInfo.processInfo.environment["ZDOTDIR"] { environment["GHOSTTY_ZSH_ZDOTDIR"] = original }
                environment["ZDOTDIR"] = integration
                environment["GHOSTTY_SHELL_FEATURES"] = "cursor,sudo,title,ssh-env"
            }
        }
        if let socket = environment["GOVI_SUGGEST_SOCKET"], !socket.isEmpty {
            environment["GOVI_SUGGEST_SOCKET"] = stableSocket(for: socket)
        }
        let assignments = environment.sorted { $0.key < $1.key }
            .filter { $0.key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
            .map { q("\($0.key)=\($0.value)") }.joined(separator: " ")
        let program = command.map { "/bin/sh -c " + q($0) } ?? (q(shell) + " -l")
        let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Reattach when the terminal is live; otherwise start it. Ctrl+\ detach
        // would leave an invisible session, so the loop reattaches until the
        // program ends. If hc fails, fall back to a plain shell.
        let reportSocket = environment["GOVI_SUGGEST_SOCKET"] ?? ""
        return GoviSessionScript.make(
            hc: hc, name: name, id: id, shell: shell, directory: directory,
            program: program, assignments: assignments, socket: reportSocket,
            restoring: restoring, version: environmentVersion)
    }

    /// Persistent shells outlive this app instance's socket path, so point
    /// them at a stable symlink that each launch refreshes.
    private static func stableSocket(for socket: String) -> String {
        let folder = GoviDataPaths.supportDirectory
        let link = folder.appendingPathComponent("inline.sock").path
        guard link.utf8.count < 100 else { return socket }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != socket {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: socket)
        }
        return link
    }

    // MARK: Close

    /// Called when a pane is destroyed. Ends its terminal unless Govi is quitting.
    static func surfaceClosed(_ id: UUID) {
        let name: String? = lock.withLock {
            if detachedPanes.remove(id) != nil { return nil }
            confirmed.remove(id)
            return attached.removeValue(forKey: id)
        }
        guard let name, let hc = hcPath else { return }
        // Wait briefly: if the app is on its way out, the process ends first.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            guard !terminating else { return }
            _ = run(hc, ["kill", name])
            _ = run(hc, ["rm", name])
            DispatchQueue.main.async {
                storedNames[id.uuidString] = nil
                GoviDetachedStore.shared.refresh(force: true)
            }
        }
    }

    /// True when every open pane's program would survive quitting.
    @MainActor static func everyPaneSurvivesQuit() -> Bool {
        let panes = TerminalController.all.flatMap { $0.surfaceTree.root?.leaves() ?? [] }
        return !panes.isEmpty && panes.allSatisfy { isPersistent($0.id) }
    }

    // MARK: Detached sessions

    struct Session: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        let agent: String
        let cwd: String
    }

    /// Live Govi terminals that no open pane is showing.
    static func detached() -> [Session] {
        guard let hc = hcPath, let output = run(hc, ["ls", "--json", "--label", "govi=1"]),
            let root = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
            let list = root["terminals"] as? [[String: Any]]
        else { return [] }
        let shown = Set(lock.withLock { attached.values })
        return list.compactMap { item in
            guard item["state"] as? String == "live", let name = item["name"] as? String, !shown.contains(name) else { return nil }
            return Session(name: name, agent: item["agent"] as? String ?? "", cwd: item["cwd"] as? String ?? "")
        }
    }
    static func end(_ name: String) {
        guard let hc = hcPath else { return }
        _ = run(hc, ["kill", name])
        _ = run(hc, ["rm", name])
    }
    @MainActor static func confirmEnd(_ session: Session) -> Bool {
        let alert = NSAlert()
        alert.messageText = "End this background session?"
        alert.informativeText = "Its program will stop. Unsaved work inside the program may be lost."
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func endPanes(_ ids: [UUID]) {
        let names = lock.withLock {
            ids.compactMap { id -> String? in
                confirmed.remove(id)
                return attached.removeValue(forKey: id)
            }
        }
        for id in ids { storedNames[id.uuidString] = nil }
        DispatchQueue.global(qos: .userInitiated).async { for name in names { end(name) } }
    }
    @MainActor static func open(_ session: Session) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = session.cwd
        config.environmentVariables[attachEnv] = session.name
        _ = TerminalController.newTab(ghostty, from: NSApp.mainWindow, withBaseConfig: config)
    }

    @discardableResult private static func run(_ executable: String, _ arguments: [String]) -> String? {
        guard let result = GoviLocalProcess.run(executable, arguments), !result.timedOut, result.status == 0 else { return nil }
        return result.output
    }
}

/// Detached sessions, for the sidebar. Refreshes off the main thread, at most every few seconds.
@MainActor final class GoviDetachedStore: ObservableObject {
    static let shared = GoviDetachedStore()
    @Published private(set) var sessions: [GoviPersistence.Session] = []
    private var loading = false
    private var last = Date.distantPast

    func refresh(force: Bool = false) {
        guard GoviPersistence.hcPath != nil else {
            if !sessions.isEmpty { sessions = [] }
            return
        }
        guard !loading, force || Date().timeIntervalSince(last) > 5 else { return }
        loading = true
        last = Date()
        DispatchQueue.global(qos: .utility).async {
            let found = GoviPersistence.detached()
            DispatchQueue.main.async {
                self.loading = false
                if self.sessions != found { self.sessions = found }
            }
        }
    }
    func open(_ session: GoviPersistence.Session) {
        sessions.removeAll { $0 == session }
        GoviPersistence.open(session)
    }
    func end(_ session: GoviPersistence.Session) {
        guard GoviPersistence.confirmEnd(session) else { return }
        sessions.removeAll { $0 == session }
        let name = session.name
        DispatchQueue.global(qos: .userInitiated).async {
            GoviPersistence.end(name)
            DispatchQueue.main.async { self.refresh(force: true) }
        }
    }
}

struct GoviPersistenceSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviPersistence.enabledKey) private var enabled = false
    @State private var sessions: [GoviPersistence.Session] = []
    @State private var loading = false
    @State private var helper = GoviPersistence.hcPath

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session recovery").font(GoviInk.font(13).weight(.medium))
            Text("Workspaces and folders are saved automatically. Commands are never rerun automatically after a restart.")
                .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            Toggle("Keep new terminals running after Govi quits", isOn: $enabled)
                .disabled(helper == nil)
            Text(
                helper != nil
                    ? "Ready. New terminals can reconnect after quitting or updating Govi. Closing a workspace keeps them in Running in background; closing a terminal lets you keep or end its program. A computer restart ends local programs."
                    : "Install the session helper to keep programs running while Govi is closed. Setup opens a terminal and asks before installing."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4).textSelection(.enabled)
            HStack {
                if helper == nil { Button("Set Up Session Recovery…", action: installHelper) }
                Button("Locate Helper…", action: locateHelper)
                Button("Check Again", action: reload).disabled(loading)
            }.controlSize(.small)
            if let error = GoviWorkspaceStore.shared.error { Text(error).font(GoviInk.font(11)).foregroundStyle(.red) }
            if helper != nil {
                HStack {
                    Text(sessions.isEmpty ? "No detached sessions." : "\(sessions.count) detached session\(sessions.count == 1 ? "" : "s")")
                        .font(GoviInk.font(11)).foregroundStyle(ui.muted)
                    Spacer()
                    if loading { ProgressView().controlSize(.mini) }
                    Button("Refresh", action: reload).controlSize(.small)
                }
                ForEach(sessions) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.agent.isEmpty ? session.name : session.agent).lineLimit(1)
                            Text(GoviPaneNaming.shortPath(session.cwd)).font(GoviInk.font(10)).foregroundStyle(ui.muted).lineLimit(1)
                        }
                        Spacer()
                        Button("Open") {
                            GoviPersistence.open(session)
                            sessions.removeAll { $0 == session }
                        }.controlSize(.small)
                        Button("End") {
                            guard GoviPersistence.confirmEnd(session) else { return }
                            let name = session.name
                            DispatchQueue.global(qos: .userInitiated).async {
                                GoviPersistence.end(name)
                                DispatchQueue.main.async(execute: reload)
                            }
                        }.controlSize(.small)
                    }.font(GoviInk.font(12))
                }
            }
        }.onAppear(perform: reload)
    }
    private func reload() {
        helper = GoviPersistence.hcPath
        guard helper != nil else {
            sessions = []
            return
        }
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = GoviPersistence.detached()
            DispatchQueue.main.async {
                sessions = found
                loading = false
            }
        }
    }
    private func locateHelper() {
        let panel = NSOpenPanel()
        panel.title = "Locate session helper"
        panel.message = "Choose the installed hc executable."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, url.lastPathComponent == "hc",
            FileManager.default.isExecutableFile(atPath: url.path)
        else { return }
        UserDefaults.standard.set(url.path, forKey: "GoviHelperPath")
        reload()
    }
    private func installHelper() {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.command =
            "/bin/bash " + GoviShell.quote(GoviResources.resourceURL.appendingPathComponent("Tools/govi-tool").path) + " recovery"
        config.waitAfterCommand = true
        _ = TerminalController.newTab(ghostty, from: TerminalController.preferredParent?.window, withBaseConfig: config)
    }
}
