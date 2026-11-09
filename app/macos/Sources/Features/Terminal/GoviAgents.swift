import SwiftUI
import AppKit
import Security
import SQLite3
import CryptoKit
import LocalAuthentication
import Darwin

// Provider wire formats and glyphs reference vinzdg/codenotch (MIT).
// See Govi/Licenses/CodeNotch-LICENSE.txt and Brand/SOURCES.md.
extension GoviGit {
    static func defaultBranch(for agent: GoviAgent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmm"
        return "\(agent.rawValue)/\(formatter.string(from: Date()))"
    }
}

enum GoviAgent: String, CaseIterable, Identifiable {
    case claude, pi, cursor, grok, codex, opencode
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .pi: "Pi"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
    var commands: [String] { self == .cursor ? ["cursor-agent", "agent"] : [rawValue] }
    /// Interactive session pickers; never choose an arbitrary last conversation.
    var resumeArguments: [String]? {
        switch self {
        case .claude: ["--resume"]
        case .codex: ["resume"]
        default: nil
        }
    }
    var launchArguments: [String] {
        self == .claude && UserDefaults.standard.object(forKey: "GoviClaudeStatusHooks") as? Bool != false
            ? ["--settings", GoviClaudeHooks.settingsJSON] : []
    }
    var installationURL: URL {
        let address =
            switch self {
            case .claude: "https://code.claude.com/docs/en/setup"
            case .codex: "https://developers.openai.com/codex/cli/"
            case .cursor: "https://cursor.com/docs/cli/installation"
            case .grok: "https://github.com/xai-org/grok-build"
            case .pi: "https://github.com/earendil-works/pi"
            case .opencode: "https://opencode.ai/docs/"
            }
        return URL(string: address)!
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Terminal tools Govi can open in a split. Nothing is bundled: the
/// `Tools/govi-tool` script in the new pane starts the tool if it's
/// installed, or offers its official installer and waits for a yes.
enum GoviTool: String, CaseIterable, Identifiable {
    case code, browser, phone, mac
    var id: String { rawValue }
    var name: String {
        switch self {
        case .code: "Code Editor"
        case .browser: "Browser"
        case .phone: "iPhone Simulator"
        case .mac: "Virtual Mac"
        }
    }
    var summary: String {
        switch self {
        case .code: "VS Code in a split, using terminal-code (tode)."
        case .browser: "A real browser in a split, using terminal-browser."
        case .phone: "An iOS simulator in a split, using terminal-phone."
        case .mac: "A macOS virtual machine in a split, using terminal-mac."
        }
    }

    /// Splits `surface` to the right and runs this tool there, in the same folder.
    @MainActor @discardableResult
    func open(beside surface: Ghostty.SurfaceView) -> Ghostty.SurfaceView? {
        guard let controller = GoviPaneCoordinator.owner(of: surface.id) else { return nil }
        let script = GoviResources.resourceURL.appendingPathComponent("Tools/govi-tool").path
        // A login shell gives the tool the same PATH (Homebrew, ~/.local/bin) as a normal pane.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = surface.pwd
        config.goviLaunch.tool = rawValue
        config.command = GoviAgent.quote(shell) + " -lic " + GoviAgent.quote("exec /bin/bash " + GoviAgent.quote(script) + " " + rawValue)
        guard let created = controller.newSplit(at: surface, direction: .right, baseConfig: config) else { return nil }
        GoviActivityCenter.shared.tag(created, agent: nil, label: name)
        return created
    }
}

@MainActor final class GoviAgentCatalog: ObservableObject {
    static let shared = GoviAgentCatalog()
    @Published var installed: [GoviAgent: String] = [:]
    @Published var checking = false
    func locate(_ agent: GoviAgent) {
        let panel = NSOpenPanel()
        panel.title = "Locate \(agent.name)"
        panel.message = "Choose the installed command-line executable (\(agent.commands.joined(separator: " or ")))."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        var custom = UserDefaults.standard.dictionary(forKey: "GoviAgentExecutables") as? [String: String] ?? [:]
        custom[agent.rawValue] = url.path
        UserDefaults.standard.set(custom, forKey: "GoviAgentExecutables")
        refresh()
    }
    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            let found = await Task.detached(priority: .utility) { () -> [GoviAgent: String] in
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                // Ask the login shell for executables so nvm, mise and user PATHs work.
                // Only fixed command names enter this script. No credentials are read.
                let script = GoviAgent.allCases.flatMap(\.commands).map { name in
                    "p=$(command -v " + name + "); case \"$p\" in /*) printf '%s\\t%s\\n' " + name + " \"$p\";; esac"
                }.joined(separator: "\n")
                var paths: [String: String] = [:]
                if let result = GoviLocalProcess.run(shell, ["-ilc", script], timeout: 4), !result.timedOut {
                    for line in result.output.split(separator: "\n") {
                        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                        if parts.count == 2, parts[1].hasPrefix("/"), FileManager.default.isExecutableFile(atPath: parts[1]) {
                            paths[parts[0]] = parts[1]
                        }
                    }
                }
                let directories =
                    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
                        home + "/.local/bin", home + "/.bun/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin",
                        "/usr/bin",
                    ]
                var result: [GoviAgent: String] = [:]
                let custom = UserDefaults.standard.dictionary(forKey: "GoviAgentExecutables") as? [String: String] ?? [:]
                for agent in GoviAgent.allCases {
                    if let path = custom[agent.rawValue], FileManager.default.isExecutableFile(atPath: path) {
                        result[agent] = path
                        continue
                    }
                    for name in agent.commands {
                        if let path = paths[name] {
                            result[agent] = path
                            break
                        }
                        if let path = directories.map({ $0 + "/" + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }
                        ) {
                            result[agent] = path
                            break
                        }
                    }
                }
                return result
            }.value
            installed = found
            checking = false
        }
    }
}

struct GoviAgentGlyph: View {
    let agent: GoviAgent
    var body: some View {
        Image("Agent-" + agent.rawValue).resizable().scaledToFit().frame(width: 16, height: 16).accessibilityHidden(true)
    }
}
struct GoviWordmark: View {
    @Environment(\.goviPalette) private var ui
    private static let image = NSImage(contentsOf: GoviResources.resourceURL.appendingPathComponent("Brand/GoviWordmark.png"))
    var body: some View {
        if let image = Self.image {
            ui.ink.mask(Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48).colorInvert().luminanceToAlpha())
                .frame(width: 48, height: 20).clipped().accessibilityLabel("Govi")
        }
    }
}
/// The "+" menu: a custom glass panel shown by the workbench under its toolbar button.
struct GoviAgentMenu: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var catalog = GoviAgentCatalog.shared
    @AppStorage("GoviAgentWorktree") private var useWorktree = false
    @State private var repository: String?
    @State private var branch = ""
    @State private var creating: GoviAgent?
    @State private var failure: String?
    @State private var taskLabel = ""
    @State private var setupAgent: GoviAgent?
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    let directory: String
    let launch: (GoviLaunch) -> Void
    let addProject: () -> Void
    let connect: (GoviRemoteTarget) -> Void
    let dismiss: () -> Void
    @ObservedObject private var remote = GoviRemoteStore.shared
    private var worktree: Bool { useWorktree && repository != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            GoviMenuRow(title: "New workspace", trailing: shortcuts.chord(.newWorkspace).display, icon: { Image(systemName: "terminal") }) {
                dismiss()
                launch(.init())
            }
            GoviMenuRow(title: "Project templates…", icon: { Image(systemName: "rectangle.3.group") }) {
                dismiss()
                NotificationCenter.default.post(name: .goviTemplates, object: nil)
            }
            GoviMenuDivider()
            GoviMenuHeader(title: "Start an agent")
            TextField("Task label (optional)", text: $taskLabel).textFieldStyle(.plain).font(GoviInk.font(11.5))
                .padding(.horizontal, 10).frame(height: 28)
            worktreeOptions
            ForEach(GoviAgent.allCases) { agent in
                let installed = catalog.installed[agent] != nil
                GoviMenuRow(
                    title: agent.name, disabled: catalog.checking || creating != nil, icon: { GoviAgentGlyph(agent: agent) },
                    trailing: {
                        if creating == agent {
                            ProgressView().controlSize(.mini)
                        } else if !installed {
                            Text(catalog.checking ? "Checking…" : "Set up…").font(GoviInk.font(10.5)).foregroundStyle(ui.muted)
                        } else if worktree {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(ui.muted)
                        }
                    }
                ) { if installed { start(agent) } else { setupAgent = agent } }
            }
            if let failure {
                Text(failure).font(GoviInk.font(10.5)).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 4)
            }
            GoviMenuDivider()
            GoviMenuHeader(title: "Connect to a remote host")
            ForEach(remote.quickTargets, id: \.self) { target in
                GoviMenuRow(
                    title: target.name,
                    icon: {
                        Image(systemName: target.transport == .tailscale ? "point.3.connected.trianglepath.dotted" : "network")
                    },
                    trailing: {
                        if let device = remote.device(for: target) {
                            Circle().fill(device.online ? Color.green : ui.muted.opacity(0.6)).frame(width: 6, height: 6)
                                .help(device.online ? "Online" : "Offline")
                        }
                    }
                ) {
                    dismiss()
                    connect(target)
                }
            }
            GoviMenuRow(title: "Browser", trailing: shortcuts.chord(.browser).display, icon: { Image(systemName: "globe") }) {
                dismiss()
                TerminalController.preferredParent?.openWebPane()
            }
            GoviMenuRow(title: "Remote hosts…", trailing: shortcuts.chord(.remoteHosts).display, icon: { Image(systemName: "server.rack") })
            {
                dismiss()
                NotificationCenter.default.post(name: .goviRemoteHosts, object: nil)
            }
            GoviMenuDivider()
            GoviMenuRow(title: "Add project…", icon: { Image(systemName: "folder.badge.plus") }) {
                dismiss()
                addProject()
            }
        }
        .font(GoviInk.font(13)).foregroundStyle(ui.ink)
        .padding(6).frame(width: 290)
        .modifier(GoviGlassPanel())
        .onAppear {
            catalog.refresh()
            checkRepository()
        }
        .sheet(item: $setupAgent) { agent in GoviAgentSetupView(agent: agent) }
    }
    @ViewBuilder private var worktreeOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $useWorktree) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("In a new worktree").font(GoviInk.font(12))
                    Text(
                        repository.map { "Branches from \(URL(fileURLWithPath: $0).lastPathComponent)" }
                            ?? "Open a Git project to use worktrees"
                    )
                    .font(GoviInk.font(10)).foregroundStyle(ui.muted).lineLimit(1)
                }
            }.toggleStyle(.switch).controlSize(.mini).disabled(repository == nil)
            if worktree {
                TextField("Branch name (optional)", text: $branch).textFieldStyle(.plain).font(GoviInk.font(11.5))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(ui.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help("Leave empty to name it after the agent and time. The worktree goes in <repo>.worktrees next to the repository.")
            }
        }.padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 6)
    }
    private func checkRepository() {
        let path = directory
        DispatchQueue.global(qos: .userInitiated).async {
            let top = GoviGit.topLevel(path)
            DispatchQueue.main.async { repository = top }
        }
    }
    private func start(_ agent: GoviAgent) {
        guard let path = catalog.installed[agent] else { return }
        failure = nil
        guard worktree, let top = repository else {
            dismiss()
            launch(.init(executable: path, agent: agent, label: taskLabel.isEmpty ? nil : taskLabel))
            return
        }
        let name =
            branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GoviGit.defaultBranch(for: agent) : branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.hasPrefix("-"), !name.contains(where: { $0.isWhitespace }) else {
            failure = "Branch names can't start with “-” or contain spaces."
            return
        }
        creating = agent
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GoviGit.createWorktree(repository: top, branch: name) }
            DispatchQueue.main.async {
                creating = nil
                switch result {
                case .success(let folder):
                    branch = ""
                    dismiss()
                    launch(.init(executable: path, agent: agent, directory: folder, label: taskLabel.isEmpty ? name : taskLabel))
                case .failure(let error):
                    failure = error.localizedDescription
                }
            }
        }
    }
}

struct GoviAgentSetupView: View {
    let agent: GoviAgent
    @ObservedObject private var catalog = GoviAgentCatalog.shared
    @Environment(\.goviPalette) private var ui
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                GoviAgentGlyph(agent: agent)
                Text(agent.name).font(GoviInk.font(20).weight(.medium))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let path = catalog.installed[agent] {
                Label("Ready to launch", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text(path).font(GoviInk.font(11)).foregroundStyle(ui.muted).textSelection(.enabled)
            } else {
                Text(
                    "Govi could not find this agent's command-line tool. Install it using the provider's guide, or locate an existing installation."
                )
                .foregroundStyle(ui.muted).lineSpacing(5)
            }
            HStack {
                Button("Installation Guide") { NSWorkspace.shared.open(agent.installationURL) }
                Button("Locate Executable…") { catalog.locate(agent) }
                Button(catalog.checking ? "Checking…" : "Check Again") { catalog.refresh() }.disabled(catalog.checking)
            }
            Text(
                "An account or usage meter can be available even when the command-line tool is missing. Installing the tool and signing in happen through the provider."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
        }.padding(26).frame(width: 570).font(GoviInk.font(12)).foregroundStyle(ui.ink).background(ui.paper).modifier(GoviChromeAppearance())
    }
}

struct GoviUsageWindow: Identifiable {
    var id: String { label }
    let label: String
    let usedPercent: Double
    let reset: Date?
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    var remainingFraction: Double { remainingPercent / 100 }
    var remainingText: String { "\(Int(remainingPercent.rounded()))%" }
    var remainingDescription: String { "\(remainingText) left" }
}
// BEGIN USAGE PARSERS
/// Only server-reported values become measurements. Missing is never zero.
enum GoviUsageParser {
    static func number(_ value: Any?) -> Double? {
        let n = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return n.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    // ISO8601DateFormatter is thread-safe and costly to create, so build each once.
    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondDates = ISO8601DateFormatter()
    private static let claudeQuotaLine = try! NSRegularExpression(
        pattern: #"^Current (session|week \(([^)]+)\)):[ \t]*(\d+(?:\.\d+)?)%[ \t]*used(?:[ \t]*·[ \t]*resets[ \t]+([^\r\n]+))?[ \t]*$"#,
        options: [.anchorsMatchLines])

    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 1_000_000_000 { return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n) }
        guard let text = value as? String else { return nil }
        return fractionalDates.date(from: text) ?? wholeSecondDates.date(from: text)
    }
    /// Only Claude Code's explicit quota lines count; token/cost statistics are unrelated.
    static func claudeCLI(_ text: String, now: Date = Date()) -> [GoviUsageWindow] {
        let expression = claudeQuotaLine
        var windows: [GoviUsageWindow] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
            guard let percent = number(group(3)), percent <= 1_000_000 else { continue }
            let week = group(2)
            let label = week.map { $0.lowercased() == "all models" ? "Weekly limit" : "\($0) weekly" } ?? "5-hour limit"
            guard !windows.contains(where: { $0.label == label }) else { continue }
            windows.append(.init(label: label, usedPercent: percent, reset: group(4).flatMap { claudeResetDate($0, now: now) }))
        }
        guard windows.contains(where: { $0.label == "5-hour limit" }) else { return [] }
        func order(_ window: GoviUsageWindow) -> Int { window.label == "5-hour limit" ? 0 : window.label == "Weekly limit" ? 1 : 2 }
        return windows.sorted { order($0) < order($1) }
    }
    static func claudeResetDate(_ text: String, now: Date) -> Date? {
        if let reset = date(text) { return reset }
        var stamp = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var zone = TimeZone.current
        if let open = stamp.lastIndex(of: "("), stamp.hasSuffix(")") {
            zone = TimeZone(identifier: String(stamp[stamp.index(after: open)...].dropLast())) ?? zone
            stamp = String(stamp[..<open]).trimmingCharacters(in: .whitespaces)
        }
        stamp = stamp.replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        guard
            let parsed = ["MMM d 'at' h:mma", "MMM d 'at' ha"].lazy.compactMap({ format -> Date? in
                formatter.dateFormat = format
                return formatter.date(from: stamp)
            }).first
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
        let year = calendar.component(.year, from: now)
        return [year - 1, year, year + 1].compactMap { year -> Date? in
            parts.year = year
            return calendar.date(from: parts)
        }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }
    static func parse(_ agent: GoviAgent, _ root: [String: Any], now: Date = Date()) -> [GoviUsageWindow] {
        var out: [GoviUsageWindow] = []
        func add(_ label: String, _ percent: Any?, _ reset: Any?) {
            if let value = number(percent), value <= 1_000_000 { out.append(.init(label: label, usedPercent: value, reset: date(reset))) }
        }
        switch agent {
        case .claude:
            for (key, label) in [
                ("five_hour", "5-hour limit"), ("seven_day", "Weekly limit"), ("seven_day_sonnet", "Sonnet weekly"),
                ("seven_day_opus", "Opus weekly"),
            ] {
                if let window = root[key] as? [String: Any] { add(label, window["utilization"], window["resets_at"]) }
            }
        case .codex:
            func windows(_ limit: [String: Any], prefix: String = "") {
                for key in ["primary_window", "secondary_window"] {
                    guard let window = limit[key] as? [String: Any] else { continue }
                    let seconds = number(window["limit_window_seconds"]).flatMap { $0 <= 315360000 ? $0 : nil }
                    let role = key == "primary_window" ? "Primary" : "Secondary"
                    let label =
                        seconds.map { role + " · " + ($0 >= 604800 ? "Weekly limit" : "\(Int($0 / 3600))-hour limit") } ?? role + " limit"
                    let relativeReset = number(window["reset_after_seconds"]).map { now.timeIntervalSince1970 + $0 }
                    let reset: Any? = window["reset_at"] ?? relativeReset as Any?
                    add(prefix + label, window["used_percent"], reset)
                }
            }
            if let limit = root["rate_limit"] as? [String: Any] { windows(limit) }
            if let spend = root["spend_control"] as? [String: Any], let limit = spend["individual_limit"] as? [String: Any] {
                if let percent = number(limit["used_percent"]) {
                    add("Workspace credits", percent, limit["reset_at"])
                } else if let used = number(limit["used"]), let total = number(limit["limit"]), total > 0 {
                    add("Workspace credits", used / total * 100, limit["reset_at"])
                }
            }
            for extra in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
                if let limit = extra["rate_limit"] as? [String: Any] {
                    windows(limit, prefix: (extra["limit_name"] as? String ?? "Additional") + " · ")
                }
            }
        case .cursor:
            let usage = root["individualUsage"] as? [String: Any] ?? [:]
            let plan = usage["plan"] as? [String: Any] ?? [:]
            let reset = root["billingCycleEnd"]
            add("Auto usage", plan["autoPercentUsed"], reset)
            add("API usage", plan["apiPercentUsed"], reset)
            for key in ["overall", "onDemand"] {
                if let value = usage[key] as? [String: Any], value["enabled"] as? Bool != false,
                    let used = number(value["used"]), let limit = number(value["limit"]), limit > 0
                {
                    add(key == "overall" ? "Included usage" : "On demand", used / limit * 100, reset)
                }
            }
        case .grok:
            let config = root["config"] as? [String: Any] ?? [:]
            let period = config["currentPeriod"] as? [String: Any] ?? [:]
            let periodType = period["type"] as? String ?? ""
            let label = periodType.contains("WEEKLY") ? "Weekly limit" : periodType.contains("MONTHLY") ? "Monthly limit" : "Grok Build"
            add(label, config["creditUsagePercent"], period["end"] ?? config["billingPeriodEnd"])
            if out.isEmpty {
                for product in config["productUsage"] as? [[String: Any]] ?? [] {
                    add(product["product"] as? String ?? "Usage", product["usagePercent"], period["end"] ?? config["billingPeriodEnd"])
                }
            }
        case .opencode:
            let usage = root["usage"] as? [String: Any] ?? [:]
            for (key, label) in [("rolling", "5-hour limit"), ("weekly", "Weekly limit"), ("monthly", "Monthly limit")] {
                if let window = usage[key] as? [String: Any] { add(label, window["percent"], window["resetsAt"]) }
            }
        case .pi: break
        }
        return out
    }
}
// END USAGE PARSERS

private enum GoviUsageFailure: Error { case signIn, unauthorized, expired, keychain, response(Int), empty, rateLimited(TimeInterval) }
private final class GoviUsageRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
private enum GoviUsageSource {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    static func file(_ url: URL) -> [String: Any]? { (try? Data(contentsOf: url)).flatMap(json) }
    static func token(_ value: Any?) throws -> String {
        guard let s = value as? String, !s.isEmpty, !s.contains("\n"), !s.contains("\r") else { throw GoviUsageFailure.signIn }
        return s
    }
    static func keychain(_ service: String, account: String? = nil, interactive: Bool) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw GoviUsageFailure.keychain
        }
        guard status == errSecSuccess, let data = result as? Data else { throw GoviUsageFailure.signIn }
        return data
    }
    static func rows(_ url: URL, sql: String, columns: Int) -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<columns).map { sqlite3_column_text(statement, Int32($0)).map { String(cString: $0) } ?? "" })
        }
        return result
    }
    /// Ask the installed CLI for its built-in /usage report. It renews its own
    /// sign-in; Govi never refreshes or writes another app's OAuth credentials.
    static func claudeCLI(binary: URL? = nil, directory: URL? = nil) throws -> [GoviUsageWindow]? {
        let paths =
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" } + [
                home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            ]
        guard
            let executable = binary
                ?? paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) })
        else { return nil }
        let scratch = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("govi-claude-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // The -- separator keeps /usage out of the variadic --tools argument.
        // No project settings, hooks, MCP servers, tools, or saved conversation.
        let arguments = [
            "--print", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
            "--settings", #"{"disableAllHooks":true}"#, "--tools", "", "--", "/usage",
        ]
        guard let result = GoviLocalProcess.run(executable.path, arguments, timeout: 20, directory: scratch.path) else { return nil }
        let text = result.output
        let windows = GoviUsageParser.claudeCLI(text)
        if result.status == 0, !result.timedOut, !windows.isEmpty { return windows }
        if text.localizedCaseInsensitiveContains("rate limit") || text.contains("429") { throw GoviUsageFailure.rateLimited(300) }
        return nil
    }
    static func request(_ agent: GoviAgent, interactive: Bool) throws -> URLRequest {
        var endpoint = ""
        var headers: [String: String] = [:]
        switch agent {
        case .claude:
            let folder =
                ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude")
            var data = file(folder.appendingPathComponent(".credentials.json"))
            if data == nil {
                let suffix = SHA256.hash(data: Data(folder.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
                let isDefault = folder.standardizedFileURL == home.appendingPathComponent(".claude").standardizedFileURL
                let services = ["Claude Code-credentials-" + suffix] + (isDefault ? ["Claude Code-credentials"] : [])
                // Read through the Keychain API only, so macOS asks the user before
                // Govi can see another app's sign-in. Background refreshes never
                // prompt; they surface "Click to connect" instead.
                do { data = json(try keychain(services[0], interactive: interactive)) } catch GoviUsageFailure.signIn {
                    guard isDefault else { throw GoviUsageFailure.signIn }
                    data = json(try keychain("Claude Code-credentials", interactive: interactive))
                }
            }
            let stored = data ?? [:]
            let oauth = stored["claudeAiOauth"] as? [String: Any] ?? [:]
            // Claude Code refreshes its own token; an expired one only earns 401/429s.
            if let expires = GoviUsageParser.number(oauth["expiresAt"]), expires / 1000 < Date().timeIntervalSince1970 {
                throw GoviUsageFailure.expired
            }
            endpoint = "https://api.anthropic.com/api/oauth/usage"
            headers = ["Authorization": "Bearer " + (try token(oauth["accessToken"])), "anthropic-beta": "oauth-2025-04-20"]
        case .codex:
            let folder =
                ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            let root = file(folder.appendingPathComponent("auth.json")) ?? [:]
            let tokens = root["tokens"] as? [String: Any] ?? [:]
            endpoint = "https://chatgpt.com/backend-api/wham/usage"
            headers = [
                "Authorization": "Bearer " + (try token(tokens["access_token"])), "ChatGPT-Account-Id": try token(tokens["account_id"]),
            ]
        case .cursor:
            let values = rows(
                home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
                sql: "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/stripeMembershipAuthId')",
                columns: 2)
            var credentials: [String: String] = [:]
            for row in values { credentials[row[0]] = row[1] }
            var access = credentials["cursorAuth/accessToken"]
            var account = credentials["cursorAuth/stripeMembershipAuthId"]
            if access == nil || account == nil {
                access = String(
                    data: try keychain("cursor-access-token", account: "cursor-user", interactive: interactive), encoding: .utf8)
                let info = file(home.appendingPathComponent(".cursor/cli-config.json"))?["authInfo"] as? [String: Any] ?? [:]
                account = info["authId"] as? String ?? (info["userId"] as? NSNumber)?.stringValue ?? info["userId"] as? String
            }
            endpoint = "https://cursor.com/api/usage-summary"
            headers = ["Cookie": "WorkosCursorSessionToken=" + (try token(account)) + "::" + (try token(access))]
        case .grok:
            let root = file(home.appendingPathComponent(".grok/auth.json")) ?? [:]
            let entry =
                root.first { key, value in
                    key.components(separatedBy: "::").first == "https://auth.x.ai"
                        || (value as? [String: Any])?["oidc_issuer"] as? String == "https://auth.x.ai"
                }?.value as? [String: Any] ?? [:]
            endpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
            headers = ["Authorization": "Bearer " + (try token(entry["key"])), "X-XAI-Token-Auth": "xai-grok-cli"]
        case .opencode:
            let folder =
                (ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".local/share")).appendingPathComponent("opencode")
            let stored = rows(
                folder.appendingPathComponent("opencode.db"),
                sql:
                    "SELECT integration_id, value FROM credential WHERE integration_id IN ('opencode-go','opencode') AND COALESCE(active,1) != 0 ORDER BY time_updated DESC",
                columns: 2)
            var entry: [String: Any]?
            for key in ["opencode-go", "opencode"] {
                if let row = stored.first(where: { $0[0] == key }), let value = json(Data(row[1].utf8)) {
                    entry = value
                    break
                }
            }
            if entry == nil {
                let auth = file(folder.appendingPathComponent("auth.json")) ?? [:]
                entry = auth["opencode-go"] as? [String: Any] ?? auth["opencode"] as? [String: Any]
            }
            let value = entry ?? [:]
            let oauth = value["type"] as? String == "oauth"
            let metadata = value["metadata"] as? [String: Any] ?? [:]
            if let server = metadata["server"] as? String, URL(string: server)?.host != "opencode.ai" { throw GoviUsageFailure.signIn }
            endpoint = oauth ? "https://opencode.ai/inference/go/v1/usage" : "https://opencode.ai/zen/go/v1/usage"
            headers = ["Authorization": "Bearer " + (try token(oauth ? value["access"] : value["key"]))]
            if let org = metadata["orgID"] as? String { headers["x-opencode-org-id"] = try token(org) }
        case .pi: throw GoviUsageFailure.empty
        }
        var request = URLRequest(url: URL(string: endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        headers["Accept"] = "application/json"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
    static func fetch(_ agent: GoviAgent, interactive: Bool) async throws -> [GoviUsageWindow] {
        if agent == .claude, !interactive {
            do { if let windows = try claudeCLI() { return windows } } catch GoviUsageFailure.rateLimited(let delay) {
                throw GoviUsageFailure.rateLimited(delay)
            } catch { /* An unavailable CLI can still have a readable OAuth sign-in. */  }
        }
        let request = try request(agent, interactive: interactive)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: GoviUsageRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoviUsageFailure.response(0) }
        if http.statusCode == 429 {
            throw GoviUsageFailure.rateLimited(max(60, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300))
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw GoviUsageFailure.unauthorized }
        guard http.statusCode == 200, let root = json(data) else { throw GoviUsageFailure.response(http.statusCode) }
        let windows = GoviUsageParser.parse(agent, root)
        guard !windows.isEmpty else { throw GoviUsageFailure.empty }
        return windows
    }
}

@MainActor final class GoviUsageStore: ObservableObject {
    static let shared = GoviUsageStore()
    struct Reading {
        var windows: [GoviUsageWindow] = []
        var date: Date?
        var message = "Not checked"
        var busy = false
        var nextRefresh: Date?
        var retry: Date?
        var hasAccount = false
        /// Credentials exist but Govi needs the user's click (Keychain prompt) to read them.
        var needsConnect = false
        /// Signed in, but the provider's session must be renewed by its own CLI first.
        var expired = false
        /// Preserve provider order: the primary/session window leads, even when weekly usage is higher.
        var headline: GoviUsageWindow? { windows.first }
        var ringWindows: [GoviUsageWindow] { Array(windows.prefix(2)) }
        var isVisible: Bool { hasAccount || !windows.isEmpty || needsConnect || expired }
        mutating func failed(_ error: Error, agent: GoviAgent, now: Date = Date()) {
            busy = false
            needsConnect = false
            expired = false
            nextRefresh = now.addingTimeInterval(agent == .claude ? 300 : 60)
            switch error {
            case GoviUsageFailure.signIn:
                message = "Sign in or refresh your session in \(agent.name)."
                windows = []
                date = nil
                hasAccount = false
            case GoviUsageFailure.unauthorized:
                message = "Sign in or refresh your session in \(agent.name)."
                windows = []
                date = nil
                hasAccount = true
            case GoviUsageFailure.expired:
                message = "Session expired. Run \(agent.name) once to renew it; usage appears automatically."
                expired = true
                hasAccount = true
            case GoviUsageFailure.keychain:
                message = "Keychain access needed. Click to connect."
                needsConnect = true
                hasAccount = true
            case GoviUsageFailure.empty:
                message = "No supported quota reported for this account."
                windows = []
                date = nil
                hasAccount = true
            case GoviUsageFailure.rateLimited(let delay):
                message = "Rate limited. Will retry later."
                retry = now.addingTimeInterval(delay)
                hasAccount = true
            default:
                message = "Couldn’t refresh usage. Try again later."
                hasAccount = true
            }
        }
    }
    @Published var readings: [GoviAgent: Reading] = [:]
    /// Providers worth a ring: ones with a quota reading, or a sign-in only a click can unlock.
    var visibleAgents: [GoviAgent] {
        GoviAgent.allCases.filter { agent in
            guard let reading = readings[agent] else { return false }
            return reading.isVisible
        }
    }
    func refresh(_ agent: GoviAgent, interactive: Bool = false, force: Bool = false) {
        guard agent != .pi, readings[agent]?.busy != true, (readings[agent]?.retry ?? .distantPast) <= Date() else { return }
        guard force || (readings[agent]?.nextRefresh ?? .distantPast) <= Date() else { return }
        var reading = readings[agent] ?? Reading()
        reading.busy = true
        readings[agent] = reading
        Task {
            do {
                let windows = try await Task.detached(priority: .utility) {
                    try await GoviUsageSource.fetch(agent, interactive: interactive)
                }.value
                readings[agent] = .init(
                    windows: windows, date: Date(), message: "", nextRefresh: Date().addingTimeInterval(agent == .claude ? 300 : 60),
                    hasAccount: true)
            } catch {
                var result = readings[agent] ?? Reading()
                result.failed(error, agent: agent)
                readings[agent] = result
            }
        }
    }
    func connect(_ agent: GoviAgent) { refresh(agent, interactive: true, force: true) }
}
/// One ring per provider, tracking whichever limit is closest to running out.
/// Hovering shows a card with every limit (e.g. 5-hour and weekly) and its reset time.
struct GoviUsageRings: View {
    @ObservedObject private var store = GoviUsageStore.shared
    @State private var hovered: GoviAgent?
    var body: some View {
        HStack(spacing: 7) {
            ForEach(store.visibleAgents) { agent in
                GoviUsageRing(agent: agent).onHover { inside in
                    if inside { hovered = agent } else if hovered == agent { hovered = nil }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let hovered {
                GoviUsageCard(agent: hovered).fixedSize()
                    .offset(x: 10, y: -46)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

extension GoviUsageStore.Reading {
    /// The limit with the least remaining; it drives the ring.
    var tightest: GoviUsageWindow? { windows.min { $0.remainingPercent < $1.remainingPercent } }
}

private func goviUsageColor(_ window: GoviUsageWindow, ink: Color) -> Color {
    window.remainingPercent <= 10 ? .red : window.remainingPercent <= 25 ? .orange : ink
}

private struct GoviUsageRing: View {
    let agent: GoviAgent
    @Environment(\.goviPalette) private var ui
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var store = GoviUsageStore.shared
    @State private var hovering = false
    private var reading: GoviUsageStore.Reading? { store.readings[agent] }
    private var accessibilityValue: String {
        guard let reading, !reading.windows.isEmpty else { return reading?.message ?? "Usage unavailable" }
        return reading.windows.map { "\($0.label): \($0.remainingDescription)" }.joined(separator: ", ")
    }
    var body: some View {
        Button {
            if reading?.needsConnect == true { store.connect(agent) } else { store.refresh(agent, force: true) }
        } label: {
            ZStack {
                if let window = reading?.tightest {
                    let color = goviUsageColor(window, ink: ui.ink)
                    Circle().stroke(ui.ink.opacity(0.14), lineWidth: 2)
                    Circle().trim(from: 0, to: window.remainingFraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if hovering {
                        Text(window.remainingText)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.7).lineLimit(1).padding(3)
                    } else {
                        GoviAgentGlyph(agent: agent)
                    }
                } else {
                    GoviAgentGlyph(agent: agent).opacity(contrast == .increased ? 0.75 : 0.45)
                    if reading?.busy != true {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 8))
                            .offset(x: 10, y: -10)
                    }
                }
            }.foregroundStyle(ui.ink).frame(width: 29, height: 29).contentShape(Circle())
        }.buttonStyle(.plain)
            .disabled(agent == .pi || reading?.busy == true)
            .accessibilityLabel(agent.name)
            .accessibilityValue(accessibilityValue)
            .onHover { hovering = $0 }
    }
}

/// Glass hover card listing every quota window for one provider.
private struct GoviUsageCard: View {
    let agent: GoviAgent
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var store = GoviUsageStore.shared
    private var reading: GoviUsageStore.Reading? { store.readings[agent] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GoviAgentGlyph(agent: agent)
                Text(agent.name).font(GoviInk.font(13).weight(.semibold))
                Spacer(minLength: 12)
                if let date = reading?.date {
                    Text(date.formatted(date: .omitted, time: .shortened)).font(GoviInk.font(10.5)).foregroundStyle(ui.muted)
                }
            }
            if let reading, !reading.windows.isEmpty {
                ForEach(reading.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(window.label).font(GoviInk.font(12))
                            Spacer(minLength: 10)
                            Text(window.remainingDescription).font(GoviInk.font(12).weight(.medium)).monospacedDigit()
                                .foregroundStyle(goviUsageColor(window, ink: ui.ink))
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(ui.ink.opacity(0.12))
                                Capsule().fill(goviUsageColor(window, ink: ui.ink))
                                    .frame(width: max(4, geometry.size.width * window.remainingFraction))
                            }
                        }.frame(height: 5)
                        if let reset = window.reset {
                            Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                                .font(GoviInk.font(10.5)).foregroundStyle(ui.muted)
                        }
                    }
                }
                if !reading.message.isEmpty {
                    Text(reading.message).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(
                    agent == .pi
                        ? "Uses your model provider’s account; no unified Pi quota."
                        : reading?.busy == true ? "Checking usage…" : (reading?.message ?? "Checking connection…")
                )
                .font(GoviInk.font(11.5)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text(reading?.needsConnect == true ? "Click to connect using your existing sign-in." : "Click to refresh.")
                .font(GoviInk.font(10)).foregroundStyle(ui.muted.opacity(0.8))
        }
        .foregroundStyle(ui.ink)
        .padding(14).frame(width: 250)
        .modifier(GoviGlassPanel())
    }
}
