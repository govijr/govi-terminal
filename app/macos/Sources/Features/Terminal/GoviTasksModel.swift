import SwiftUI
import AppKit

@MainActor final class GoviTasksModel: ObservableObject {
    /// Shared so leaving Tasks (for Settings or a terminal) and coming back keeps the list and selection.
    static let shared = GoviTasksModel()
    @Published var issues: [GoviTaskIssue] = []
    @Published var pullRequests: [GoviPullRequest] = []
    @Published var issue: GoviTaskIssue?
    @Published var pullRequest: GoviPullRequest?
    @Published var states: [GoviLinearState] = []
    @Published var stateID = ""
    @Published var brief = ""
    @Published var requiredBranch: String?
    @Published var busy: String?
    @Published var error: String?
    @Published var notice: String?
    /// True once a list request finished, so empty states don't flash before the first load.
    @Published var loaded = false
    /// Which provider/repository/filter the current list belongs to, and when it was fetched.
    private(set) var loadedKey: String?
    private(set) var loadedAt: Date?
    private var generation = UUID()

    static func key(provider: GoviIntegrationProvider, repository: String, assigned: Bool, reviews: Bool) -> String {
        provider == .github
            ? "github|\(repository.lowercased())|\(reviews ? "prs" : assigned ? "mine" : "all")" : "linear|\(assigned ? "mine" : "all")"
    }
    func isFresh(_ key: String) -> Bool {
        loadedKey == key && (loadedAt.map { Date().timeIntervalSince($0) < 120 } ?? false)
    }

    var loadingDetail: Bool { busy == "Reading issue…" || busy == "Reading review feedback…" }

    func clear() {
        generation = UUID()
        busy = nil
        issues = []
        pullRequests = []
        issue = nil
        loaded = false
        loadedKey = nil
        loadedAt = nil
        pullRequest = nil
        states = []
        stateID = ""
        brief = ""
        requiredBranch = nil
        error = nil
        notice = nil
    }
    func perform(_ label: String, _ action: @escaping @MainActor () async throws -> Void) async {
        guard busy == nil else { return }
        busy = label
        error = nil
        notice = nil
        let token = generation
        do { try await action() } catch { if token == generation { self.error = error.localizedDescription } }
        if token == generation { busy = nil }
    }
    func refresh(provider: GoviIntegrationProvider, repository: String, assigned: Bool, reviews: Bool) async {
        let key = Self.key(provider: provider, repository: repository, assigned: assigned, reviews: reviews)
        await perform("Loading…") {
            let token = self.generation
            defer { if token == self.generation { self.loaded = true } }
            // Refreshing the same list keeps what's on screen; a different list starts clean.
            if key != self.loadedKey {
                self.issue = nil
                self.pullRequest = nil
                self.requiredBranch = nil
                self.brief = ""
                self.issues = []
                self.pullRequests = []
            }
            if provider == .github {
                guard GoviIntegrations.shared.githubEnabled else {
                    throw GoviIntegrationError.message("Connect GitHub in Connections first.")
                }
                guard let repo = GoviGitHubRepository(repository) else {
                    throw GoviIntegrationError.message("Enter a GitHub repository as owner/repository.")
                }
                if reviews {
                    let items = try await GoviGitHubClient().pullRequests(repo)
                    if token == self.generation { self.pullRequests = items }
                } else {
                    let items = try await GoviGitHubClient().issues(repo, assigned: assigned)
                    if token == self.generation { self.issues = items }
                }
            } else {
                let items = try await GoviLinearClient(key: GoviLinearKey.read()).issues(assigned: assigned)
                if token == self.generation { self.issues = items }
            }
            if token == self.generation {
                self.loadedKey = key
                self.loadedAt = Date()
            }
        }
    }
    func select(_ item: GoviTaskIssue) async {
        // Show what the list already knows at once; the full issue (with comments) replaces it.
        if !item.link.title.isEmpty {
            issue = item
            brief = item.brief
            pullRequest = nil
        }
        await perform("Reading issue…") {
            let token = self.generation
            let value: GoviTaskIssue
            self.pullRequest = nil
            self.requiredBranch = nil
            self.states = []
            self.stateID = ""
            if item.link.provider == "github", let repo = item.link.repository.flatMap(GoviGitHubRepository.init) {
                guard GoviIntegrations.shared.githubEnabled else {
                    throw GoviIntegrationError.message("Connect GitHub in Connections first.")
                }
                value = try await GoviGitHubClient().issue(item.link.id, repository: repo)
            } else {
                value = try await GoviLinearClient(key: GoviLinearKey.read()).issue(item.link.id)
            }
            guard token == self.generation else { return }
            self.issue = value
            self.brief = value.brief
            if let team = value.teamID {
                let states = try await GoviLinearClient(key: GoviLinearKey.read()).states(team: team)
                guard token == self.generation else { return }
                self.states = states
                self.stateID = self.states.first { $0.name == value.stateName }?.id ?? ""
            }
        }
    }
    func open(_ identifier: String, provider: GoviIntegrationProvider, repository: String) async {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if provider == .github {
            guard let repo = GoviGitHubRepository(repository), Int(raw).map({ $0 > 0 }) == true else {
                error = "Enter a positive issue number and a repository."
                return
            }
            await select(
                .init(
                    link: .init(id: raw, provider: "github", identifier: "#" + raw, title: "", url: "", repository: repo.fullName), body: ""
                ))
        } else {
            guard raw.range(of: "^[A-Za-z][A-Za-z0-9]*-[0-9]+$", options: .regularExpression) != nil else {
                error = "Enter a Linear identifier, such as APP-142."
                return
            }
            await select(
                .init(link: .init(id: raw.uppercased(), provider: "linear", identifier: raw.uppercased(), title: "", url: ""), body: ""))
        }
    }
    func selectReview(_ pr: GoviPullRequest) {
        issue = nil
        pullRequest = pr
        requiredBranch = nil
        brief = ""
        error = nil
        notice = nil
    }
    func prepareReview(repository: String) async {
        guard let pr = pullRequest, let repo = GoviGitHubRepository(repository) else { return }
        await perform("Reading review feedback…") {
            let token = self.generation
            let (fresh, comments) = try await GoviGitHubClient().review(pr.number, repository: repo)
            guard token == self.generation else { return }
            self.pullRequest = fresh
            self.issue = fresh.task(repository: repo, inlineComments: comments)
            self.brief = self.issue!.brief
            self.requiredBranch = fresh.headRefName
        }
    }
    func postComment(_ text: String) async {
        guard let issue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await perform("Posting comment…") {
            let token = self.generation
            if issue.link.provider == "github" {
                guard GoviIntegrations.shared.githubEnabled else {
                    throw GoviIntegrationError.message("Connect GitHub in Connections first.")
                }
                try await GoviGitHubClient().comment(issue.link, body: text)
            } else {
                try await GoviLinearClient(key: GoviLinearKey.read()).comment(issue.link, body: text)
            }
            guard token == self.generation else { return }
            self.issue?.comments.append("You:\n" + text)
            self.notice = "Comment posted to \(issue.link.identifier)"
        }
    }
    func updateState() async {
        guard let issue, let state = states.first(where: { $0.id == stateID }) else { return }
        await perform("Updating status…") {
            let token = self.generation
            try await GoviLinearClient(key: GoviLinearKey.read()).updateState(issue.link, state: state.id)
            guard token == self.generation else { return }
            self.issue?.stateName = state.name
            if let index = self.issues.firstIndex(where: { $0.id == issue.id }) { self.issues[index].stateName = state.name }
            self.notice = "\(issue.link.identifier) moved to \(state.name)"
        }
    }
}

/// Starred and recently used repositories (kept on this Mac), plus the account's own list from GitHub.
@MainActor final class GoviRepositoryStore: ObservableObject {
    static let shared = GoviRepositoryStore()
    private static let savedKey = "GoviTasksSavedRepositories"
    private static let recentKey = "GoviTasksRecentRepositories"
    @Published private(set) var saved: [String]
    @Published private(set) var recent: [String]
    @Published private(set) var mine: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var loadedAt: Date?

    init() {
        saved = UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? []
        recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }
    func isSaved(_ repo: String) -> Bool { saved.contains { $0.caseInsensitiveCompare(repo) == .orderedSame } }
    func toggleSaved(_ repo: String) {
        if isSaved(repo) { saved.removeAll { $0.caseInsensitiveCompare(repo) == .orderedSame } } else { saved.append(repo) }
        UserDefaults.standard.set(saved, forKey: Self.savedKey)
    }
    func used(_ repo: String) {
        recent = Array(([repo] + recent.filter { $0.caseInsensitiveCompare(repo) != .orderedSame }).prefix(6))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }
    func load(force: Bool = false) async {
        guard GoviIntegrations.shared.githubEnabled, !loading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        loading = true
        defer { loading = false }
        do {
            mine = try await GoviGitHubClient().repositories()
            loadedAt = Date()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
