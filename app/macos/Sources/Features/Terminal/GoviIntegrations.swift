import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    static let goviTasks = Notification.Name("app.govi.tasks")
}

@MainActor final class GoviIntegrations: ObservableObject {
    static let shared = GoviIntegrations()
    @Published private(set) var githubName: String?
    @Published private(set) var linearName: String?
    @Published private(set) var hasLinearKey = GoviLinearKey.exists
    @Published private(set) var githubEnabled: Bool
    @Published private(set) var checking = false
    @Published var error: String?
    private var generation = UUID()
    private let defaults = UserDefaults.standard
    private var repositories: [String: String]

    init() {
        githubEnabled = UserDefaults.standard.bool(forKey: "GoviGitHubEnabled")
        linearName = UserDefaults.standard.string(forKey: "GoviLinearAccount")
        repositories = UserDefaults.standard.dictionary(forKey: "GoviTaskRepositories") as? [String: String] ?? [:]
    }
    func checkGitHub() async {
        guard !checking else { return }
        let token = UUID(); generation = token; checking = true; error = nil
        defer { if generation == token { checking = false } }
        do {
            let name = try await GoviGitHubClient().account()
            guard generation == token else { return }
            githubName = name; githubEnabled = true; defaults.set(true, forKey: "GoviGitHubEnabled")
        } catch { if generation == token { self.error = error.localizedDescription } }
    }
    func disconnectGitHub() {
        generation = UUID(); checking = false; githubName = nil; githubEnabled = false
        defaults.set(false, forKey: "GoviGitHubEnabled"); error = nil
    }
    func connectLinear(_ input: String) async -> Bool {
        guard !checking else { return false }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }), key.count <= 4096 else { error = "Enter a valid Linear personal API key."; return false }
        let token = UUID(); generation = token; checking = true; error = nil
        defer { if generation == token { checking = false } }
        do {
            let profile = try await GoviLinearClient(key: key).profile()
            guard generation == token else { return false }
            try GoviLinearKey.save(key)
            hasLinearKey = true; linearName = profile.name; defaults.set(profile.name, forKey: "GoviLinearAccount")
            return true
        } catch { if generation == token { self.error = error.localizedDescription }; return false }
    }
    func disconnectLinear() {
        do {
            try GoviLinearKey.remove(); generation = UUID(); checking = false
            hasLinearKey = false; linearName = nil; defaults.removeObject(forKey: "GoviLinearAccount"); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func repository(for issue: GoviTaskIssue) -> String? {
        repositories[mappingKey(issue)]
    }
    func remember(_ path: String, for issue: GoviTaskIssue) {
        repositories[mappingKey(issue)] = path
        defaults.set(repositories, forKey: "GoviTaskRepositories")
    }
    private func mappingKey(_ issue: GoviTaskIssue) -> String {
        issue.link.provider + ":" + (issue.link.repository ?? issue.teamID ?? issue.link.id)
    }
}

enum GoviTaskAgent {
    /// Only agents whose interactive initial-prompt interface is supported here.
    static let supported: [GoviAgent] = [.claude, .codex, .cursor, .pi]
}

struct GoviIntegrationSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var connections = GoviIntegrations.shared
    @State private var key = ""
    var signInGitHub: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Connect your work to your terminals.").font(GoviInk.font(15))
                VStack(alignment: .leading, spacing: 12) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right").font(GoviInk.font(14).weight(.medium))
                    Text(connections.githubEnabled ? "Connected" + (connections.githubName.map { " as " + $0 } ?? " through GitHub CLI") : "Use your GitHub CLI account for issues, pull requests, reviews and checks.")
                        .foregroundStyle(ui.muted)
                    HStack {
                        if GoviGitHubClient.findExecutable() == nil {
                            Button("Install GitHub CLI…") { NSWorkspace.shared.open(URL(string: "https://cli.github.com/")!) }
                        } else if let signInGitHub {
                            Button("Sign In in Terminal…", action: signInGitHub)
                        }
                        Button(connections.githubEnabled ? "Check Connection" : "Connect GitHub") { Task { await connections.checkGitHub() } }
                        if connections.githubEnabled { Button("Disconnect") { connections.disconnectGitHub() } }
                    }.disabled(connections.checking)
                    Text("Sign in with gh auth login --hostname github.com in a terminal, then connect. Disconnecting Govi leaves other tools' GitHub sign-in intact. GitHub.com is supported.")
                        .font(GoviInk.font(11)).foregroundStyle(ui.muted).textSelection(.enabled)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(ui.canvas, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 12) {
                    Label("Linear", systemImage: "line.3.horizontal.decrease.circle").font(GoviInk.font(14).weight(.medium))
                    Text(connections.hasLinearKey ? (connections.linearName ?? "A Linear key is saved in Keychain") : "Connect with a personal API key from Linear's security settings.")
                        .foregroundStyle(ui.muted)
                    SecureField(connections.hasLinearKey ? "Replacement personal API key" : "Personal API key", text: $key).textFieldStyle(.roundedBorder)
                        .onSubmit { connectLinear() }
                    HStack {
                        Button("Create API Key…") { NSWorkspace.shared.open(URL(string: "https://linear.app/settings/account/security")!) }
                        Button(connections.hasLinearKey ? "Replace Key" : "Connect Linear", action: connectLinear).disabled(key.isEmpty || connections.checking)
                        if connections.hasLinearKey { Button("Disconnect") { key = ""; connections.disconnectLinear() }.disabled(connections.checking) }
                    }
                    Text("Choose the teams this key can access. Read access loads issues; Write and Create comments permissions enable status updates and comments. The key stays in this Mac's Keychain and is not added to agent prompts.")
                        .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(3)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(ui.canvas, in: RoundedRectangle(cornerRadius: 10))
                if connections.checking { ProgressView("Checking connection…").controlSize(.small) }
                if let error = connections.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text("Open Tasks from the toolbar to select an issue and preview its brief. Comments, pull requests and Linear status changes are sent only when you use their action buttons.")
                    .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(3)
            }.padding(.bottom, 16)
        }.onDisappear { key = "" }
    }
    private func connectLinear() {
        let value = key
        Task { if await connections.connectLinear(value) { key = "" } }
    }
}

struct GoviLinkedTaskBanner: View {
    @Environment(\.goviPalette) private var ui
    let link: GoviTaskLink
    let openTasks: () -> Void
    let review: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").foregroundStyle(ui.muted)
            Button(action: openTasks) { Text(link.identifier + " · " + link.title).lineLimit(1).truncationMode(.middle) }.buttonStyle(.plain)
            Spacer(minLength: 0)
            Button("Review Changes", action: review).buttonStyle(.plain).foregroundStyle(ui.muted)
            if let url = GoviTaskText.webURL(link.url, provider: link.provider) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("Open linked task")
            }
        }.font(GoviInk.font(11)).padding(.horizontal, 12).padding(.vertical, 7)
            .background(ui.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}
