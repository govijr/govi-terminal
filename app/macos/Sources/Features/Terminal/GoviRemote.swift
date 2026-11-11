import SwiftUI
import AppKit

/// One row in the remote host lists: a saved host, a tailnet device or an
/// alias from `~/.ssh/config`.
struct GoviRemoteEntry: Identifiable, Equatable {
    enum Kind { case saved, tailnet, sshConfig }
    var id: String
    var kind: Kind
    var target: GoviRemoteTarget
    var savedID: UUID?
    var detail: String
    /// nil when Govi can't tell (not a tailnet device).
    var online: Bool?
    var tailscaleSSH = false
    var os: String?

    var symbol: String {
        switch os?.lowercased() {
        case "macos": "laptopcomputer"
        case "ios": "iphone"
        case "android": "smartphone"
        case "windows": "pc"
        case "linux": "server.rack"
        default: kind == .tailnet ? "desktopcomputer" : "server.rack"
        }
    }
}

@MainActor final class GoviRemoteStore: ObservableObject {
    static let shared = GoviRemoteStore()
    enum TailscaleState: Equatable { case unknown, missing, unavailable(String), running }

    @Published var saved: [GoviRemoteHost] {
        didSet { if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "GoviRemoteHostsV1") } }
    }
    @Published private(set) var recents: [GoviRemoteTarget] {
        didSet { if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: "GoviRemoteRecentsV1") } }
    }
    @Published private(set) var configured: [GoviSSHConfig.Entry] = []
    @Published private(set) var tailnet: GoviTailnet?
    @Published private(set) var tailscalePath: String?
    @Published private(set) var tailscaleState: TailscaleState = .unknown
    @Published private(set) var refreshing = false
    private var lastRefresh: Date?

    init() {
        func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        saved = (read("GoviRemoteHostsV1", as: [GoviRemoteHost].self) ?? []).filter { $0.target.validationError == nil }
        recents = (read("GoviRemoteRecentsV1", as: [GoviRemoteTarget].self) ?? []).filter { $0.validationError == nil }
    }

    /// Reads `~/.ssh/config` and asks Tailscale for the tailnet. Throttled
    /// unless forced; the sidebar calls this on its regular refresh.
    func refresh(force: Bool = false) {
        guard !refreshing else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        refreshing = true
        lastRefresh = Date()
        Task {
            let (entries, path, net, state) = await Task.detached(priority: .utility) {
                () -> ([GoviSSHConfig.Entry], String?, GoviTailnet?, TailscaleState) in
                let entries = GoviSSHConfig.load()
                guard let path = GoviTailnet.executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                    return (entries, nil, nil, .missing)
                }
                guard let result = GoviLocalProcess.run(path, ["status", "--json"], timeout: 5, limit: 16_777_216), !result.timedOut,
                    let net = GoviTailnet.decode(Data(result.output.utf8))
                else {
                    return (entries, path, nil, .unavailable("Tailscale didn't respond. Open the Tailscale app, then refresh."))
                }
                let state: TailscaleState =
                    switch net.backendState {
                    case "Running": .running
                    case "NeedsLogin": .unavailable("Sign in to Tailscale to see your devices.")
                    case "NeedsMachineAuth": .unavailable("This Mac is waiting for approval from your tailnet admin.")
                    case "Starting": .unavailable("Tailscale is starting…")
                    default: .unavailable("Tailscale is turned off.")
                    }
                if state == .running { Self.writeKnownHosts(net.knownHosts) }
                return (entries, path, state == .running ? net : nil, state)
            }.value
            configured = entries
            tailscalePath = path
            tailnet = net
            tailscaleState = state
            refreshing = false
        }
    }

    /// Host keys published by tailnet devices, so ssh trusts them without a prompt.
    /// Only devices running Tailscale SSH publish keys.
    nonisolated private static func writeKnownHosts(_ text: String) {
        guard let path = GoviRemoteCommand.tailnetKnownHostsPath else { return }
        let url = URL(fileURLWithPath: path)
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {}
    }

    func device(for target: GoviRemoteTarget) -> GoviTailnet.Device? {
        guard let tailnet else { return nil }
        let host = target.host.lowercased()
        return tailnet.devices.first { device in
            device.dnsName?.lowercased() == host || device.addresses.contains(host) || device.name.lowercased() == host
        }
    }

    var entries: [GoviRemoteEntry] {
        var result: [GoviRemoteEntry] = []
        for host in saved {
            let device = device(for: host.target)
            var detail = [host.target.destination]
            if let directory = host.target.directory { detail.append(directory) }
            result.append(
                .init(
                    id: "saved:" + host.id.uuidString, kind: .saved, target: host.target, savedID: host.id,
                    detail: detail.joined(separator: " · "), online: device?.online,
                    tailscaleSSH: device?.runsTailscaleSSH ?? false, os: device?.os))
        }
        let savedHosts = Set(saved.map { $0.target.host.lowercased() })
        for device in tailnet?.devices ?? [] where !device.isSelf {
            guard let target = device.target, !savedHosts.contains(target.host.lowercased()) else { continue }
            let detail = [device.online ? "Online" : "Offline", device.os, device.addresses.first].compactMap { $0 }.joined(
                separator: " · ")
            result.append(
                .init(
                    id: "tailnet:" + device.id, kind: .tailnet, target: target, detail: detail,
                    online: device.online, tailscaleSSH: device.runsTailscaleSSH, os: device.os))
        }
        for entry in configured where !savedHosts.contains(entry.alias.lowercased()) {
            let target = GoviRemoteTarget(name: entry.alias, host: entry.alias)
            guard target.validationError == nil else { continue }
            let detail = [entry.user.map { $0 + "@" + (entry.hostName ?? entry.alias) } ?? entry.hostName, entry.port.map { "port \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            result.append(
                .init(
                    id: "config:" + entry.alias, kind: .sshConfig, target: target,
                    detail: detail.isEmpty ? "~/.ssh/config" : detail, online: device(for: target)?.online))
        }
        return result
    }

    /// Hosts for quick menus: recent connections first, then saved hosts.
    var quickTargets: [GoviRemoteTarget] {
        var seen = Set<GoviRemoteTarget>()
        var result: [GoviRemoteTarget] = []
        for target in recents + saved.map(\.target) where seen.insert(target).inserted { result.append(target) }
        return Array(result.prefix(5))
    }

    func markUsed(_ target: GoviRemoteTarget) {
        recents = Array(([target] + recents.filter { $0 != target }).prefix(8))
    }
    func forget(_ target: GoviRemoteTarget) { recents.removeAll { $0 == target } }

    func save(_ target: GoviRemoteTarget, id: UUID? = nil) -> UUID {
        let target = target.normalized()
        if let id, let index = saved.firstIndex(where: { $0.id == id }) {
            let old = saved[index].target
            if old != target { recents = recents.map { $0 == old ? target : $0 } }
            saved[index].target = target
            return id
        }
        let host = GoviRemoteHost(target: target)
        saved.append(host)
        return host.id
    }

    func openTailscale() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
        {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
        }
    }
}

@MainActor enum GoviRemoteLauncher {
    /// Opens `target` in a new workspace, or in a split beside `surface`.
    /// Returns a message when the connection can't be started.
    @discardableResult
    static func open(
        _ target: GoviRemoteTarget, ghostty: Ghostty.App, from window: NSWindow?, beside surface: Ghostty.SurfaceView? = nil
    ) -> String? {
        let target = target.normalized()
        if let error = target.validationError { return error }
        guard let command = GoviRemoteCommand.pane(target) else { return "Govi could not build the ssh command for \(target.name)." }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        config.goviLaunch.remote = target
        config.goviLaunch.task = target.name
        config.command = command
        let created: Ghostty.SurfaceView?
        if let surface, let owner = GoviPaneCoordinator.owner(of: surface.id) {
            created = owner.newSplit(at: surface, direction: .right, baseConfig: config)
        } else {
            created = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)?.surfaceTree.surfaces.first
        }
        guard let created else { return "Govi could not open a terminal for \(target.name)." }
        GoviActivityCenter.shared.tag(created, agent: nil, label: target.name)
        GoviRemoteStore.shared.markUsed(target)
        NotificationCenter.default.post(name: .goviLayoutChanged, object: nil)
        return nil
    }

    static func copyCommand(_ target: GoviRemoteTarget) {
        guard let text = GoviRemoteCommand.display(target) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Notification.Name {
    /// Opens the remote hosts window; `object` may be a `GoviRemoteEntry.id` to select.
    static let goviRemoteHosts = Notification.Name("goviRemoteHosts")
}

// MARK: - Remote hosts window

struct GoviRemoteHostsView: View {
    let ghostty: Ghostty.App
    let window: NSWindow?
    let surface: Ghostty.SurfaceView?
    var initialSelection: String?
    @ObservedObject private var store = GoviRemoteStore.shared
    @Environment(\.goviPalette) private var ui
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var draft = GoviRemoteTarget(name: "", host: "")
    @State private var draftSavedID: UUID?
    @State private var adding = false
    @State private var query = ""
    @State private var failure: String?
    @State private var copied = false

    private var visible: [GoviRemoteEntry] {
        let all = store.entries
        guard !query.isEmpty else { return all }
        return all.filter { "\($0.target.name) \($0.target.host) \($0.detail)".localizedCaseInsensitiveContains(query) }
    }
    private var selected: GoviRemoteEntry? { store.entries.first { $0.id == selection } }
    private var editing: Bool { adding || selection != nil }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280).background(ui.sidebar)
            Divider()
            detail.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.font(GoviInk.font(12)).foregroundStyle(ui.ink).background(ui.paper)
            .frame(width: 900, height: 640).modifier(GoviChromeAppearance())
            .onAppear {
                store.refresh(force: true)
                if let initialSelection, let entry = store.entries.first(where: { $0.id == initialSelection }) { select(entry) }
            }
            .onChange(of: store.entries) { entries in
                // A discovered host that was just saved moves to the Saved list.
                if let id = selection, !entries.contains(where: { $0.id == id }), let saved = draftSavedID {
                    selection = "saved:" + saved.uuidString
                }
                if selection == nil, !adding, let initialSelection, let entry = entries.first(where: { $0.id == initialSelection }) {
                    select(entry)
                }
            }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Remote hosts").font(GoviInk.font(17).weight(.medium))
                Spacer()
                Button {
                    store.refresh(force: true)
                } label: {
                    if store.refreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.plain).help("Refresh ~/.ssh/config and Tailscale").disabled(store.refreshing)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ui.muted)
                TextField("Filter hosts…", text: $query).textFieldStyle(.plain)
            }.padding(.horizontal, 10).frame(height: 30)
                .background(ui.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            tailscaleCard
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Saved", entries: visible.filter { $0.kind == .saved })
                    section(
                        store.tailnet?.tailnetName.map { "Tailnet · " + $0 } ?? "Tailnet", entries: visible.filter { $0.kind == .tailnet })
                    section("~/.ssh/config", entries: visible.filter { $0.kind == .sshConfig })
                    if visible.isEmpty {
                        Text(
                            query.isEmpty
                                ? "Add a host, list machines in ~/.ssh/config, or connect Tailscale to see your devices here."
                                : "No hosts match."
                        )
                        .font(GoviInk.font(11)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button("Add Host…") { startAdding() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(18)
    }

    @ViewBuilder private var tailscaleCard: some View {
        let card: (String, String, String?, (() -> Void)?) -> AnyView = { symbol, text, button, action in
            AnyView(
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(ui.accent).frame(width: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text).font(GoviInk.font(11)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true)
                        if let button, let action { Button(button, action: action).controlSize(.small) }
                    }
                    Spacer(minLength: 0)
                }.padding(10).background(ui.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        }
        switch store.tailscaleState {
        case .unknown: EmptyView()
        case .missing:
            card(
                "point.3.connected.trianglepath.dotted", "Install Tailscale to reach your devices from anywhere, without opening ports.",
                "Get Tailscale", store.openTailscale)
        case .unavailable(let message): card("exclamationmark.triangle", message, "Open Tailscale", store.openTailscale)
        case .running:
            let online = store.tailnet?.devices.filter { $0.online && !$0.isSelf }.count ?? 0
            card(
                "point.3.connected.trianglepath.dotted", "Tailscale is connected · \(online) device\(online == 1 ? "" : "s") online", nil,
                nil)
        }
    }

    @ViewBuilder private func section(_ title: String, entries: [GoviRemoteEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(GoviInk.font(11).weight(.medium)).foregroundStyle(ui.muted).padding(.horizontal, 6).padding(.bottom, 2)
                ForEach(entries) { entry in
                    Button {
                        select(entry)
                    } label: {
                        GoviRemoteRow(entry: entry, compact: false)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 5)
                    .background(
                        selection == entry.id ? ui.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contextMenu {
                        Button("Connect") { connect(entry.target) }
                        Button("Copy ssh Command") { GoviRemoteLauncher.copyCommand(entry.target) }
                    }
                }
            }
        }
    }

    // MARK: Editor

    @ViewBuilder private var detail: some View {
        if editing {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Name", text: $draft.name).font(GoviInk.font(18).weight(.medium)).textFieldStyle(.roundedBorder)
                    if let selected, let online = selected.online {
                        Label(online ? "Online" : "Offline", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                            .font(GoviInk.font(11)).foregroundStyle(online ? .green : ui.muted)
                    }
                }
                if let selected { discoveredNote(selected) }
                form
                commandPreview
                if let failure { Text(failure).font(GoviInk.font(11)).foregroundStyle(.red).textSelection(.enabled) }
                Spacer(minLength: 0)
                Text(
                    "Govi never stores passwords or keys. ssh-agent, your Keychain and ~/.ssh/config handle sign-in, and password prompts appear in the terminal."
                )
                .font(GoviInk.font(10)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let id = draftSavedID { Button("Delete…") { delete(id) } }
                    Spacer()
                    Button(draftSavedID == nil ? "Save Host" : "Save Changes", action: saveDraft)
                        .disabled(
                            draft.normalized().validationError != nil
                                || (draftSavedID != nil && store.saved.first { $0.id == draftSavedID }?.target == draft.normalized()))
                    if surface != nil {
                        Button("Connect in Split") { connect(draft, split: true) }.disabled(draft.normalized().validationError != nil)
                    }
                    Button("Connect") { connect(draft) }.keyboardShortcut(.defaultAction).disabled(
                        draft.normalized().validationError != nil)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your machines, one click away.").font(GoviInk.font(21).weight(.medium))
                Text(
                    "Pick a host to connect, or add one. Govi lists aliases from ~/.ssh/config and, with Tailscale, every device on your tailnet with its online status. Tailnet connections trust the host keys Tailscale publishes, so there is no first-connection prompt."
                )
                .foregroundStyle(ui.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Button("Add Host…") { startAdding() }.padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func discoveredNote(_ entry: GoviRemoteEntry) -> some View {
        let text: String? =
            switch entry.kind {
            case .saved: entry.tailscaleSSH ? "Tailnet device running Tailscale SSH." : nil
            case .tailnet:
                entry.tailscaleSSH
                    ? "Runs Tailscale SSH: your tailnet identity signs you in, no keys needed."
                    : "This device doesn't run Tailscale SSH, so sign-in uses your SSH keys or password over the tailnet."
            case .sshConfig: "From ~/.ssh/config. Options set there (keys, ProxyJump, ports) apply automatically."
            }
        if let text { Text(text).font(GoviInk.font(11)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true) }
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Connect with").foregroundStyle(ui.muted)
                Picker("", selection: $draft.transport) {
                    Text("SSH").tag(GoviRemoteTarget.Transport.ssh)
                    Text("Tailscale").tag(GoviRemoteTarget.Transport.tailscale)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .help("Tailscale connects to a tailnet device and trusts the host keys your tailnet publishes.")
            }
            GridRow {
                Text("Host").foregroundStyle(ui.muted)
                TextField(
                    draft.transport == .tailscale ? "device or device.tailnet.ts.net" : "example.com, 10.0.0.5 or an ssh config alias",
                    text: $draft.host
                ).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("User").foregroundStyle(ui.muted)
                TextField(
                    "Default: \(draft.transport == .tailscale ? NSUserName() : "from ssh config, else " + NSUserName())",
                    text: optional(\.user)
                ).textFieldStyle(.roundedBorder)
            }
            if draft.transport == .ssh {
                GridRow {
                    Text("Port").foregroundStyle(ui.muted)
                    TextField(
                        "22", text: Binding(get: { draft.port.map(String.init) ?? "" }, set: { draft.port = Int($0.filter(\.isNumber)) })
                    )
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                }
                GridRow {
                    Text("Identity file").foregroundStyle(ui.muted)
                    HStack {
                        TextField("Default keys and ssh-agent", text: optional(\.identityFile)).textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseIdentity).controlSize(.small)
                    }
                }
                GridRow {
                    Text("Jump host").foregroundStyle(ui.muted)
                    TextField("Optional, e.g. user@bastion:22", text: optional(\.jumpHost)).textFieldStyle(.roundedBorder)
                }
            }
            GridRow {
                Text("Start in").foregroundStyle(ui.muted)
                TextField("Remote home folder", text: optional(\.directory)).textFieldStyle(.roundedBorder)
                    .help("A folder on the remote machine, like ~/projects/app or /srv/www.")
            }
        }
    }

    @ViewBuilder private var commandPreview: some View {
        let target = draft.normalized()
        if let error = target.validationError {
            if !target.host.isEmpty || !target.name.isEmpty { Text(error).font(GoviInk.font(11)).foregroundStyle(.orange) }
        } else if let command = GoviRemoteCommand.display(target) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Runs").font(GoviInk.font(11)).foregroundStyle(ui.muted)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        GoviRemoteLauncher.copyCommand(target)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }.controlSize(.small)
                }
                Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(ui.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func optional(_ path: WritableKeyPath<GoviRemoteTarget, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: path] ?? "" },
            set: {
                draft[keyPath: path] = $0.isEmpty ? nil : $0
                failure = nil
            })
    }

    // MARK: Actions

    private func select(_ entry: GoviRemoteEntry) {
        adding = false
        selection = entry.id
        draft = entry.target
        draftSavedID = entry.savedID
        failure = nil
    }
    private func startAdding() {
        selection = nil
        adding = true
        draftSavedID = nil
        failure = nil
        draft = .init(name: "", host: "", transport: store.tailscaleState == .running ? .tailscale : .ssh)
    }
    private func saveDraft() {
        var target = draft.normalized()
        if target.name.isEmpty { target.name = target.host }
        if let error = target.validationError {
            failure = error
            return
        }
        draftSavedID = store.save(target, id: draftSavedID)
        draft = target
        adding = false
        selection = "saved:" + draftSavedID!.uuidString
        failure = nil
    }
    private func connect(_ target: GoviRemoteTarget, split: Bool = false) {
        var target = target.normalized()
        if target.name.isEmpty { target.name = target.host }
        failure = GoviRemoteLauncher.open(target, ghostty: ghostty, from: window, beside: split ? surface : nil)
        if failure == nil { dismiss() }
    }
    private func delete(_ id: UUID) {
        guard let host = store.saved.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(host.target.name)?"
        alert.informativeText = "Open connections stay open. Your ~/.ssh/config and keys are not changed."
        alert.addButton(withTitle: "Delete Host")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.saved.removeAll { $0.id == id }
        store.forget(host.target)
        selection = nil
        draftSavedID = nil
        adding = false
    }
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a private key file. Govi stores only its path."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        draft.identityFile = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Name, detail and status for one host. Used by the window and the sidebar.
struct GoviRemoteRow: View {
    let entry: GoviRemoteEntry
    let compact: Bool
    @Environment(\.goviPalette) private var ui
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if compact {
                    GoviGlyph(kind: .server).foregroundStyle(ui.color(for: .server))
                } else {
                    Image(systemName: entry.symbol).font(.system(size: 11)).foregroundStyle(ui.tone(for: entry.target.host))
                }
            }.frame(width: GoviSidebarMetrics.icon)
                .overlay(alignment: .bottomTrailing) {
                    if let online = entry.online {
                        Circle().fill(online ? Color.green : ui.muted.opacity(0.6)).frame(width: 5, height: 5)
                            .overlay(Circle().stroke(ui.paper, lineWidth: 1)).offset(x: 2, y: 1)
                            .accessibilityLabel(online ? "Online" : "Offline")
                    }
                }
            if compact {
                Text(entry.target.name).lineLimit(1).truncationMode(.middle)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.target.name).font(GoviInk.font(12.5)).foregroundStyle(ui.ink).lineLimit(1).truncationMode(.middle)
                    Text(entry.detail).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if entry.tailscaleSSH && !compact {
                Image(systemName: "checkmark.shield").font(.system(size: 10)).foregroundStyle(ui.muted).help("Runs Tailscale SSH")
            }
        }.contentShape(Rectangle())
    }
}

/// Sidebar list: saved hosts and online tailnet devices.
struct GoviRemoteSidebarRows: View {
    let open: (GoviRemoteTarget, Bool) -> Void
    let edit: (String?) -> Void
    @ObservedObject private var store = GoviRemoteStore.shared
    @Environment(\.goviPalette) private var ui

    static func visibleEntries(_ store: GoviRemoteStore) -> [GoviRemoteEntry] {
        store.entries.filter { $0.kind == .saved || ($0.kind == .tailnet && $0.online == true) }.prefix(12).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Self.visibleEntries(store)) { entry in
                GoviHoverRow { hovering in
                    Button {
                        open(entry.target, false)
                    } label: {
                        GoviRemoteRow(entry: entry, compact: true).foregroundStyle(hovering ? ui.ink : ui.muted)
                            .font(GoviInk.font(12.5)).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).modifier(GoviSidebarRowStyle())
                        .help("\(entry.detail)\nClick to connect in a new workspace")
                        .contextMenu {
                            Button("Connect") { open(entry.target, false) }
                            Button("Connect in Split") { open(entry.target, true) }
                            Button("Copy ssh Command") { GoviRemoteLauncher.copyCommand(entry.target) }
                            Divider()
                            if entry.kind == .saved {
                                Button("Edit…") { edit(entry.id) }
                            } else {
                                Button("Save Host") { _ = store.save(entry.target) }
                            }
                        }
                }
            }
            GoviHoverRow { hovering in
                Button {
                    edit(nil)
                } label: {
                    HStack(spacing: 8) {
                        GoviGlyph(kind: .more)
                        Text("All remote hosts…")
                        Spacer(minLength: 0)
                        Text(GoviShortcuts.shared.chord(.remoteHosts).display).font(GoviInk.font(10.5)).opacity(hovering ? 1 : 0)
                    }.foregroundStyle(hovering ? ui.ink : ui.muted).font(GoviInk.font(12.5)).contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(GoviSidebarRowStyle())
            }
        }
    }
}
