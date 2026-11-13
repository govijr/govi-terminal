import AppKit
import Combine
import CoreServices

/// Finds the mods in Govi's `Mods` folder and runs what the enabled ones
/// declare: panes, palette commands, shortcuts, event hooks, link handlers
/// and a background service.
///
/// Mods are the person's own code. Nothing in a mod runs until they enable
/// it; after that its programs run as them, like anything typed in a terminal.
@MainActor final class GoviMods: ObservableObject {
    static let shared = GoviMods()
    static let enabledKey = "GoviEnabledMods"

    struct Entry: Identifiable, Equatable {
        /// The mod's folder inside `Mods` (possibly a symbolic link).
        var folder: URL
        /// Nil when `mod.json` has never been readable.
        var manifest: GoviModManifest?
        /// Why the current `mod.json` can't be used. With a manifest, that's the last good one.
        var problem: String?
        var enabled: Bool
        var id: String { folder.path }
        var name: String { manifest?.name ?? folder.lastPathComponent }
    }

    /// A palette command of an enabled mod.
    struct CommandItem: Identifiable {
        let mod: GoviModManifest
        let folder: URL
        let command: GoviModManifest.Command
        var id: String { mod.id + "/" + command.id }
        var chord: GoviKeyChord? { command.shortcut.flatMap(GoviModShortcut.chord) }
    }

    @Published private(set) var entries: [Entry] = []
    /// Recent output of each mod's programs, newest last.
    @Published private(set) var logs: [String: [String]] = [:]
    @Published private(set) var runningServices: Set<String> = []

    private var started = false
    private var lastGood: [String: GoviModManifest] = [:]
    private var services: [String: Process] = [:]
    /// Keeps each service's standard input open; it closes if Govi exits, so a service can notice.
    private var serviceInputs: [String: Pipe] = [:]
    private var activeRuns: [String: Int] = [:]
    private var watcher: GoviModWatcher?
    private var searchPath = GoviMods.fallbackPath
    private var knownPanes: [UUID: [String: Any]]?
    private var paneCheckQueued = false
    private var lastFocused: UUID?
    private var layoutObserver: NSObjectProtocol?

    nonisolated static var directory: URL { GoviDataPaths.supportDirectory.appendingPathComponent("Mods", isDirectory: true) }

    /// Where a mod keeps its own data; never touched by updates to the mod.
    nonisolated static func dataDirectory(_ id: String) -> URL {
        GoviDataPaths.supportDirectory.appendingPathComponent("ModData", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    static var goviVersion: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var enabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.enabledKey) }
    }

    // MARK: Lookup

    var enabled: [Entry] { entries.filter { $0.enabled && $0.manifest != nil } }

    func entry(_ modID: String) -> Entry? { entries.first { $0.manifest?.id == modID } }

    /// The entry for a folder directly inside `Mods`, however its URL was spelled.
    private func entry(in folder: URL) -> Entry? {
        entries.first { $0.folder.lastPathComponent == folder.lastPathComponent }
    }

    /// The folder and manifest of an enabled mod.
    func active(_ modID: String) -> (manifest: GoviModManifest, folder: URL)? {
        guard let entry = entry(modID), entry.enabled, let manifest = entry.manifest else { return nil }
        return (manifest, entry.folder)
    }

    var commandItems: [CommandItem] {
        enabled.flatMap { entry in
            entry.manifest!.commands.map { CommandItem(mod: entry.manifest!, folder: entry.folder, command: $0) }
        }
    }

    // MARK: Lifecycle

    /// Called once at launch. Nothing a mod declares runs before this.
    func start() {
        guard !started else { return }
        started = true
        layoutObserver = NotificationCenter.default.addObserver(forName: .goviLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queuePaneCheck() }
        }
        Task {
            // Programs such as node or adb live on the login shell's PATH, not the app's.
            if let path = await Self.loginShellPath() { searchPath = path }
            reload()
        }
    }

    /// Called when Govi quits: services don't outlive the app.
    func stop() {
        watcher?.stop()
        for (_, process) in services where process.isRunning { process.terminate() }
        services = [:]
        serviceInputs = [:]
    }

    /// Reads every `mod.json` again and applies what changed.
    func reload(changed paths: [String] = []) {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let folders =
            ((try? manager.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let wanted = enabledIDs
        var next: [Entry] = []
        var seen = Set<String>()
        for folder in folders {
            var manifest: GoviModManifest?
            var problem: String?
            do {
                manifest = try GoviModManifest.load(from: folder, goviVersion: Self.goviVersion)
            } catch {
                problem = (error as? GoviModError)?.message ?? error.localizedDescription
                // A broken edit keeps the last version that worked.
                manifest = lastGood[folder.path]
            }
            if let found = manifest, !seen.insert(found.id).inserted {
                problem = "Another mod already uses the id \"\(found.id)\"."
                manifest = nil
            }
            if problem == nil, let manifest { lastGood[folder.path] = manifest }
            next.append(
                .init(folder: folder, manifest: manifest, problem: problem, enabled: manifest.map { wanted.contains($0.id) } ?? false))
        }
        let previous = entries
        if next != previous { entries = next }
        apply(from: previous, to: next, changed: paths)
        watch(next)
    }

    private func apply(from old: [Entry], to new: [Entry], changed paths: [String]) {
        let before = Dictionary(
            uniqueKeysWithValues: old.compactMap { entry in entry.enabled ? entry.manifest.map { ($0.id, entry) } : nil })
        let after = Dictionary(
            uniqueKeysWithValues: new.compactMap { entry in entry.enabled ? entry.manifest.map { ($0.id, entry) } : nil })
        for id in before.keys where after[id] == nil {
            stopService(id)
            GoviModPaneView.all(of: id).forEach { $0.modDidChange() }
        }
        for (id, entry) in after {
            guard let manifest = entry.manifest else { continue }
            let was = before[id]
            let isNew = was == nil
            if isNew || was?.manifest?.service != manifest.service || was?.folder != entry.folder {
                stopService(id)
                startService(manifest, folder: entry.folder)
            }
            let root = entry.folder.resolvingSymlinksInPath().path + "/"
            let touched = paths.contains { $0.hasPrefix(root) && !Self.isNoise($0.dropFirst(root.count)) }
            let edited = !isNew && was?.manifest != manifest
            if isNew || touched || edited { GoviModPaneView.all(of: id).forEach { $0.modDidChange() } }
            if isNew || edited {
                log(id, isNew ? "Enabled \(manifest.name) \(manifest.version)." : "Reloaded mod.json.")
                emit(GoviModEvent.loaded, ["mod": id, "version": manifest.version], only: id)
            }
        }
    }

    /// Changes inside these folders are a mod's dependencies or history, not an edit to reload for.
    private static func isNoise(_ relative: Substring) -> Bool {
        relative.split(separator: "/").contains { $0 == "node_modules" || $0 == ".git" || $0 == ".build" || $0 == "target" }
    }

    private func watch(_ entries: [Entry]) {
        // FSEvents doesn't follow symbolic links, so linked mods are watched where they really are.
        let paths = Set([Self.directory.resolvingSymlinksInPath().path] + entries.map { $0.folder.resolvingSymlinksInPath().path })
        if watcher == nil { watcher = GoviModWatcher { [weak self] changed in self?.reload(changed: changed) } }
        watcher?.watch(paths.sorted())
    }

    // MARK: Enabling

    func setEnabled(_ modID: String, _ on: Bool) {
        var ids = enabledIDs
        if on { ids.insert(modID) } else { ids.remove(modID) }
        enabledIDs = ids
        reload()
    }

    /// Asks before a script or agent turns a mod on, showing what it will be able to run.
    func confirmEnable(_ entry: Entry) async -> Bool {
        guard let manifest = entry.manifest else { return false }
        let alert = NSAlert()
        alert.messageText = "Enable the mod “\(manifest.name)”?"
        let programs = manifest.programs.prefix(8).map { "• " + $0.joined(separator: " ") }.joined(separator: "\n")
        var text =
            "Mods run as you, with the same access as a program you start in a terminal. Only enable mods you trust.\n\n\(entry.folder.path)"
        if !programs.isEmpty { text += "\n\nIt can run:\n" + programs }
        if !manifest.panes.filter({ $0.kind == .web }).isEmpty { text += "\n\nIts panes can run any program on this Mac." }
        alert.informativeText = text
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let window = TerminalController.preferredParent?.window
        return await GoviEditorPaneView.present(alert, in: window) == .alertFirstButtonReturn
    }

    // MARK: Creating and installing

    /// Writes a small working mod into `Mods/<slug>` and returns its folder.
    @discardableResult
    func create(named name: String, enable: Bool) throws -> URL {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = GoviModPaths.slug(title)
        guard !id.isEmpty, title.utf8.count <= 80 else {
            throw GoviControlError("Give the mod a name with letters or digits, up to 80 characters.")
        }
        let folder = Self.directory.appendingPathComponent(id, isDirectory: true)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path) else { throw GoviControlError("A mod folder named \(id) already exists.") }
        guard entry(id) == nil else { throw GoviControlError("Another mod already uses the id \(id).") }
        do {
            for (path, text) in GoviModTemplate.files(id: id, name: title) {
                let file = folder.appendingPathComponent(path)
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
                if GoviModTemplate.executables.contains(path) {
                    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                }
            }
        } catch {
            throw GoviControlError("Couldn't write the mod to \(folder.path): \(error.localizedDescription)")
        }
        if enable { enabledIDs.insert(id) }
        reload()
        return folder
    }

    /// Clones a mod from a git address (or GitHub `owner/repo`) into `Mods`. It stays disabled.
    func install(_ source: String) async throws -> Entry {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-"), !text.contains("\0"), text.utf8.count <= 2048 else {
            throw GoviControlError("Give a git address or a GitHub owner/repo.")
        }
        let shorthand = text.split(separator: "/", omittingEmptySubsequences: false)
        let isShorthand = shorthand.count == 2 && !text.contains(":") && shorthand.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
        let address = isShorthand ? "https://github.com/\(text).git" : text
        guard isShorthand || address.contains("://") || address.contains("@") else {
            throw GoviControlError("Give a git address or a GitHub owner/repo. To use a local folder, run `govi mod link PATH`.")
        }
        var last = address.split(separator: "/").last.map(String.init) ?? ""
        if let colon = last.lastIndex(of: ":") { last = String(last[last.index(after: colon)...]) }
        if last.hasSuffix(".git") { last.removeLast(4) }
        let name = GoviModPaths.slug(last)
        guard !name.isEmpty else { throw GoviControlError("Couldn't tell the mod's folder name from \(text).") }
        let folder = Self.directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw GoviControlError("A mod folder named \(name) already exists. Update it with `git pull` in \(folder.path).")
        }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = await GoviLocalProcess.runAsync(
            "/usr/bin/env", ["git", "clone", "--depth", "1", "--", address, folder.path], timeout: 80,
            environment: environment, errors: .merge)
        guard let result, result.status == 0, !result.timedOut else {
            // Only what this clone just created is removed.
            try? FileManager.default.removeItem(at: folder)
            let detail = result?.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400) ?? "git couldn't be started."
            throw GoviControlError("Couldn't download \(address).\n\(detail)")
        }
        reload()
        guard let entry = entry(in: folder) else { throw GoviControlError("The download didn't produce a folder.") }
        if entry.manifest == nil {
            throw GoviControlError("Downloaded to \(folder.path), but it isn't a usable mod: \(entry.problem ?? "no mod.json").")
        }
        return entry
    }

    /// Adds a folder that lives elsewhere (a working copy) to `Mods` as a symbolic link.
    func link(_ path: String) throws -> Entry {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: target.appendingPathComponent(GoviModManifest.fileName).path)
        else {
            throw GoviControlError("There is no \(GoviModManifest.fileName) in \(path).")
        }
        let name = GoviModPaths.slug(target.lastPathComponent)
        guard !name.isEmpty else { throw GoviControlError("Rename the folder to use letters or digits.") }
        let folder = Self.directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw GoviControlError("A mod folder named \(name) already exists.")
        }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)
        } catch {
            throw GoviControlError("Couldn't link \(path): \(error.localizedDescription)")
        }
        reload()
        guard let entry = entry(in: folder) else { throw GoviControlError("The link wasn't created.") }
        return entry
    }

    // MARK: Running programs

    static var fallbackPath: String {
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(
            String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !folders.contains(extra) { folders.append(extra) }
        return withGoviTools(folders.joined(separator: ":"))
    }

    /// Puts the folder holding the `govi` command first.
    private static func withGoviTools(_ path: String) -> String {
        guard let tools = Bundle.main.executableURL?.deletingLastPathComponent().path else { return path }
        return ([tools] + path.split(separator: ":").map(String.init).filter { $0 != tools }).joined(separator: ":")
    }

    private static func loginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__GOVI_PATH__"
        let result = await GoviLocalProcess.runAsync(shell, ["-lic", "printf '\\n\(marker)%s\\n' \"$PATH\""], timeout: 6)
        guard let line = result?.output.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        let path = String(line.dropFirst(marker.count))
        return path.isEmpty ? nil : withGoviTools(path)
    }

    func environment(for mod: GoviModManifest, folder: URL, extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        if let socket = GoviControlServer.shared.start() { environment[GoviControlServer.environmentKey] = socket }
        let data = Self.dataDirectory(mod.id)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        environment["GOVI_MOD_ID"] = mod.id
        environment["GOVI_MOD_ROOT"] = folder.path
        environment["GOVI_MOD_DATA"] = data.path
        // With no pane named, the `govi` command acts on the pane the person is in.
        environment["GOVI_SESSION_ID"] = TerminalController.preferredParent?.focusedPane?.id.uuidString
        return environment.merging(extra) { _, new in new }
    }

    /// Runs one of a mod's programs in the background and logs how it went.
    func run(_ argv: [String], mod: GoviModManifest, folder: URL, label: String, extra: [String: String] = [:]) {
        guard activeRuns[mod.id, default: 0] < 8 else {
            log(mod.id, "Skipped \(label): eight of this mod's programs are already running.")
            return
        }
        activeRuns[mod.id, default: 0] += 1
        let environment = environment(for: mod, folder: folder, extra: extra)
        Task {
            let result = await GoviLocalProcess.runAsync(
                "/usr/bin/env", argv, timeout: 60, limit: 65536, environment: environment, directory: folder.path, errors: .merge)
            activeRuns[mod.id, default: 1] -= 1
            let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let result, result.status == 0, !result.timedOut {
                if !output.isEmpty { log(mod.id, "\(label): \(output.suffix(2000))") }
            } else {
                let reason =
                    result == nil
                    ? "couldn't start \(argv[0])" : result!.timedOut ? "stopped after 60 seconds" : "exited with status \(result!.status)"
                log(mod.id, "\(label) \(reason).\(output.isEmpty ? "" : "\n" + output.suffix(2000))")
            }
        }
    }

    /// What a mod's page gets from `govi.exec`.
    func exec(_ argv: [String], options: [String: Any], mod: GoviModManifest, folder: URL, pane: UUID) async throws -> [String: Any] {
        guard let program = argv.first, !program.isEmpty, argv.count <= 256 else {
            throw GoviControlError("Give the program and its arguments as a list.")
        }
        let seconds = (options["timeout"] as? Double) ?? Double(options["timeout"] as? Int ?? 30)
        let limit = min(16 << 20, max(1024, options["limit"] as? Int ?? (1 << 20)))
        var directory = folder.path
        if let cwd = options["cwd"] as? String, cwd.hasPrefix("/") { directory = cwd }
        var extra = ["GOVI_SESSION_ID": pane.uuidString]
        for (key, value) in options["env"] as? [String: String] ?? [:] { extra[key] = value }
        let result = await GoviLocalProcess.runAsync(
            "/usr/bin/env", argv, timeout: min(300, max(1, seconds)), limit: limit,
            environment: environment(for: mod, folder: folder, extra: extra), directory: directory, errors: .separate)
        guard let result else { throw GoviControlError("Couldn't start \(program).") }
        return ["status": Int(result.status), "output": result.output, "errors": result.errors, "timedOut": result.timedOut]
    }

    // MARK: Services

    private func startService(_ mod: GoviModManifest, folder: URL) {
        guard let service = mod.service, services[mod.id] == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = service.run
        process.environment = environment(for: mod, folder: folder)
        process.currentDirectoryURL = folder
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let id = mod.id
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data.suffix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { Task { @MainActor in GoviMods.shared.log(id, text) } }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in GoviMods.shared.serviceEnded(id, process: finished, status: status) }
        }
        do {
            try process.run()
        } catch {
            log(id, "The service couldn't start: \(error.localizedDescription)")
            return
        }
        services[id] = process
        serviceInputs[id] = input
        runningServices.insert(id)
        log(id, "Service started: \(service.run.joined(separator: " "))")
    }

    private func serviceEnded(_ id: String, process: Process, status: Int32) {
        // A replaced service ends after its successor started; leave the successor alone.
        guard services[id] === process else { return }
        services[id] = nil
        serviceInputs[id] = nil
        runningServices.remove(id)
        log(id, "Service exited with status \(status). Reload the mod to start it again.")
    }

    private func stopService(_ id: String) {
        guard let process = services.removeValue(forKey: id) else { return }
        serviceInputs[id] = nil
        runningServices.remove(id)
        guard process.isRunning else { return }
        process.terminate()
        // A service that ignores the request to stop is ended after two seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        log(id, "Service stopped.")
    }

    /// Stops and starts a mod's service, and reloads its panes.
    func restart(_ modID: String) {
        guard let mod = active(modID) else { return }
        stopService(modID)
        startService(mod.manifest, folder: mod.folder)
        GoviModPaneView.all(of: modID).forEach { $0.modDidChange() }
    }

    func log(_ modID: String, _ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        var lines = logs[modID] ?? []
        lines.append("\(time)  \(text)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        logs[modID] = lines
    }

    // MARK: Commands, shortcuts and links

    /// Runs a palette command: opens its pane, or starts its program.
    func perform(_ item: CommandItem, in controller: BaseTerminalController?, context: [String: Any] = [:]) {
        if let pane = item.command.pane {
            guard let controller = controller ?? TerminalController.preferredParent else { return }
            do {
                _ = try openPane(pane, of: item.mod.id, in: controller, context: context)
            } catch {
                log(item.mod.id, "\(item.command.title): \((error as? GoviControlError)?.message ?? error.localizedDescription)")
            }
        } else if let run = item.command.run {
            var extra: [String: String] = ["GOVI_MOD_COMMAND": item.command.id]
            if !context.isEmpty, let data = try? JSONSerialization.data(withJSONObject: GoviControl.jsonSafe(context)) {
                extra["GOVI_CONTEXT_JSON"] = String(decoding: data, as: UTF8.self)
            }
            if let link = context["link"] as? String { extra["GOVI_LINK"] = link }
            if let pane = controller?.focusedPane { extra["GOVI_SESSION_ID"] = pane.id.uuidString }
            self.run(run, mod: item.mod, folder: item.folder, label: item.command.title, extra: extra)
        }
    }

    /// Opens one of a mod's panes beside `anchor` (or the focused pane).
    @discardableResult
    func openPane(
        _ paneID: String, of modID: String, in controller: BaseTerminalController, beside anchor: GoviPaneView? = nil,
        direction: SplitTree<GoviPaneView>.NewDirection = .right, focus: Bool = true, context: [String: Any] = [:]
    ) throws -> GoviPaneView {
        guard let mod = active(modID) else { throw GoviControlError("The mod \(modID) isn't installed and enabled.") }
        guard let pane = mod.manifest.pane(paneID) else { throw GoviControlError("The mod \(modID) has no pane named \(paneID).") }
        let anchor =
            anchor.flatMap { controller.surfaceTree.contains($0) ? $0 : nil } ?? controller.focusedPane ?? controller.surfaceTree.first
        let directory = anchor?.paneDirectory ?? controller.surfaceTree.surfaces.first?.pwd
        if let command = pane.command {
            guard let anchor else { throw GoviControlError("There is no pane to split.") }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = directory
            for (key, value) in environment(for: mod.manifest, folder: mod.folder) where key.hasPrefix("GOVI_MOD_") {
                config.environmentVariables[key] = value
            }
            // A login shell finds the program on the person's PATH and keeps the pane open afterwards.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let line = command.map(GoviShell.quote).joined(separator: " ")
            config.command = GoviShell.quote(shell) + " -lic " + GoviShell.quote(line + "; exec " + GoviShell.quote(shell) + " -l")
            config.goviLaunch.command = line
            let previous = controller.focusedPane
            guard let surface = controller.newSplit(at: anchor, direction: direction, baseConfig: config) else {
                throw GoviControlError("Govi couldn't split that pane.")
            }
            surface.setGoviTitle(pane.title)
            if !focus, let previous { DispatchQueue.main.async { Ghostty.moveFocus(to: previous, from: surface) } }
            return surface
        }
        let view = GoviModPaneView(modID: modID, paneID: paneID, title: pane.title, directory: directory, context: context)
        guard controller.insertPane(view, beside: anchor, direction: direction, undoAction: "Open \(pane.title)", focus: focus) else {
            throw GoviControlError("Govi couldn't open that pane.")
        }
        return view
    }

    /// A mod shortcut for `chord`, if one is declared. Govi's own shortcuts are checked first.
    func handleKey(_ chord: GoviKeyChord, in controller: BaseTerminalController) -> Bool {
        guard let item = commandItems.first(where: { $0.chord == chord }) else { return false }
        perform(item, in: controller)
        return true
    }

    /// Hands a Command-clicked link to the first mod whose pattern matches it.
    func handleLink(_ link: String, from pane: GoviPaneView) -> Bool {
        guard link.utf8.count <= 8192 else { return false }
        let range = NSRange(link.startIndex..., in: link)
        for entry in enabled {
            guard let manifest = entry.manifest else { continue }
            for handler in manifest.links {
                guard let pattern = try? NSRegularExpression(pattern: handler.pattern),
                    pattern.firstMatch(in: link, range: range) != nil, let command = manifest.command(handler.command)
                else { continue }
                let controller = pane.window?.windowController as? BaseTerminalController
                perform(
                    .init(mod: manifest, folder: entry.folder, command: command), in: controller,
                    context: ["link": link, "pane": pane.id.uuidString])
                return true
            }
        }
        return false
    }

    // MARK: Events

    /// Tells enabled mods that something happened: their hooks run and their pages get the event.
    func emit(_ event: String, _ payload: [String: Any], only modID: String? = nil) {
        guard started else { return }
        let payload = GoviControl.jsonSafe(payload) as? [String: Any] ?? [:]
        var json: String?
        for entry in enabled {
            guard let manifest = entry.manifest, modID == nil || modID == manifest.id else { continue }
            for hook in manifest.events where hook.on == event {
                if json == nil {
                    json = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                }
                var extra = ["GOVI_EVENT": event, "GOVI_EVENT_JSON": json ?? "{}"]
                if let pane = payload["pane"] as? String { extra["GOVI_SESSION_ID"] = pane }
                run(hook.run, mod: manifest, folder: entry.folder, label: "on \(event)", extra: extra)
            }
        }
        for view in GoviModPaneView.all() where modID == nil || modID == view.modID { view.deliver(event, payload) }
    }

    private static func describe(_ pane: GoviPaneView) -> [String: Any] {
        var info: [String: Any] = ["pane": pane.id.uuidString, "kind": pane.paneKindName, "title": pane.paneTitle]
        if let directory = pane.paneDirectory { info["directory"] = directory }
        return info
    }

    private func queuePaneCheck() {
        guard !paneCheckQueued else { return }
        paneCheckQueued = true
        // After the current change settles, so a pane moved between windows isn't closed and reopened.
        DispatchQueue.main.async { [weak self] in self?.checkPanes() }
    }

    private func checkPanes() {
        paneCheckQueued = false
        var current: [UUID: [String: Any]] = [:]
        for controller in TerminalController.all {
            for pane in controller.surfaceTree { current[pane.id] = Self.describe(pane) }
        }
        defer { knownPanes = current }
        guard let known = knownPanes else { return }
        for (id, info) in known where current[id] == nil { emit(GoviModEvent.paneClosed, info) }
        for (id, info) in current where known[id] == nil { emit(GoviModEvent.paneOpened, info) }
    }

    func noteFocus(_ pane: GoviPaneView) {
        guard started, pane.id != lastFocused else { return }
        lastFocused = pane.id
        emit(GoviModEvent.paneFocused, Self.describe(pane))
    }

    func noteAgentState(_ pane: UUID, state: String, agent: String?, label: String?, project: String?, branch: String?) {
        var payload: [String: Any] = ["pane": pane.uuidString, "state": state]
        if let agent { payload["agent"] = agent }
        if let label { payload["label"] = label }
        if let project { payload["project"] = project }
        if let branch { payload["branch"] = branch }
        emit(GoviModEvent.agentState, payload)
    }

    // MARK: Control methods

    static let methods = [
        "mods.list", "mods.reload", "mods.enable", "mods.disable", "mods.new", "mods.install", "mods.link", "mod.open", "mod.run",
    ]

    func describe(_ entry: Entry) -> [String: Any] {
        var info: [String: Any] = ["folder": entry.folder.path, "enabled": entry.enabled, "name": entry.name]
        if let problem = entry.problem { info["problem"] = problem }
        guard let manifest = entry.manifest else { return info }
        info["id"] = manifest.id
        info["version"] = manifest.version
        info["description"] = manifest.description ?? ""
        info["panes"] = manifest.panes.map { ["id": $0.id, "title": $0.title, "kind": $0.kind.rawValue] }
        info["commands"] = manifest.commands.map { command in
            var item = ["id": command.id, "title": command.title]
            if let shortcut = command.shortcut { item["shortcut"] = shortcut }
            return item
        }
        info["events"] = manifest.events.map(\.on)
        if manifest.service != nil { info["service"] = runningServices.contains(manifest.id) ? "running" : "stopped" }
        return info
    }

    private func named(_ value: Any?) throws -> Entry {
        guard let id = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw GoviControlError("Say which mod, by its id. Run `govi mod list`.")
        }
        guard let entry = entry(id) ?? entries.first(where: { $0.folder.lastPathComponent == id }) else {
            throw GoviControlError("No mod has the id \(id). Run `govi mod list`.")
        }
        return entry
    }

    func control(_ method: String, params: [String: Any], caller: UUID?) async throws -> Any {
        switch method {
        case "mods.list":
            return ["directory": Self.directory.path, "mods": entries.map(describe)]
        case "mods.reload":
            reload()
            if let id = params["mod"] as? String, !id.isEmpty { restart(try named(id).manifest?.id ?? "") }
            return ["directory": Self.directory.path, "mods": entries.map(describe)]
        case "mods.enable":
            let entry = try named(params["mod"])
            guard let manifest = entry.manifest else { throw GoviControlError(entry.problem ?? "That mod has no usable mod.json.") }
            if !entry.enabled {
                guard await confirmEnable(entry) else {
                    throw GoviControlError("The mod wasn't enabled: the request was declined in Govi.")
                }
                setEnabled(manifest.id, true)
            }
            return describe(self.entry(manifest.id) ?? entry)
        case "mods.disable":
            let entry = try named(params["mod"])
            if let id = entry.manifest?.id { setEnabled(id, false) }
            return describe(entry.manifest.flatMap { self.entry($0.id) } ?? entry)
        case "mods.new":
            guard let name = params["name"] as? String else { throw GoviControlError("Give the new mod a name.") }
            let folder = try create(named: name, enable: false)
            return describe(entry(in: folder) ?? .init(folder: folder, manifest: nil, problem: nil, enabled: false))
        case "mods.install":
            guard let source = params["source"] as? String else { throw GoviControlError("Give a git address or a GitHub owner/repo.") }
            return describe(try await install(source))
        case "mods.link":
            guard let path = params["path"] as? String else { throw GoviControlError("Give the folder to link.") }
            return describe(try link(path))
        case "mod.open":
            guard let modID = params["mod"] as? String, let paneID = params["modPane"] as? String ?? active(modID)?.manifest.panes.first?.id
            else { throw GoviControlError("Say which mod and pane to open, e.g. `govi mod open my-mod/main`.") }
            let (controller, anchor) = try GoviControl.find(params["pane"], caller: caller)
            let direction: SplitTree<GoviPaneView>.NewDirection =
                switch (params["direction"] as? String)?.lowercased() {
                case "down", "below": .down
                case "left": .left
                case "up", "above": .up
                default: .right
                }
            let pane = try openPane(
                paneID, of: modID, in: controller, beside: anchor, direction: direction, focus: params["focus"] as? Bool ?? false,
                context: params["context"] as? [String: Any] ?? [:])
            return GoviControl.describe(pane, in: controller, caller: caller)
        case "mod.run":
            guard let modID = params["mod"] as? String, let commandID = params["command"] as? String else {
                throw GoviControlError("Say which mod command to run, e.g. `govi mod run my-mod/hello`.")
            }
            guard let mod = active(modID) else { throw GoviControlError("The mod \(modID) isn't installed and enabled.") }
            guard let command = mod.manifest.command(commandID) else {
                throw GoviControlError("The mod \(modID) has no command named \(commandID).")
            }
            let controller = (try? GoviControl.find(params["pane"], caller: caller))?.0
            perform(
                .init(mod: mod.manifest, folder: mod.folder, command: command), in: controller,
                context: params["context"] as? [String: Any] ?? [:])
            return ["mod": modID, "command": commandID, "started": true]
        default:
            throw GoviControlError("Unknown method \(method).")
        }
    }
}

/// Coalesced file events for the mod folders. The handler runs on the main queue.
private final class GoviModWatcher {
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let handler: @MainActor ([String]) -> Void

    init(handler: @escaping @MainActor ([String]) -> Void) { self.handler = handler }
    deinit { stop() }

    func watch(_ wanted: [String]) {
        guard wanted != paths else { return }
        stop()
        paths = wanted
        guard !wanted.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard
            let stream = FSEventStreamCreate(
                nil,
                { _, info, count, paths, _, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<GoviModWatcher>.fromOpaque(info).takeUnretainedValue()
                    let changed = Array(((unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []).prefix(count))
                    MainActor.assumeIsolated { watcher.handler(changed) }
                }, &context, wanted as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        paths = []
    }
}
