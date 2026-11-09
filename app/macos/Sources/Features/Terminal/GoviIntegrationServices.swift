import Foundation
import Security
import LocalAuthentication

enum GoviLinearKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "dev.govi.terminal") + ".integrations",
         kSecAttrAccount as String: "linear"]
    }
    static var exists: Bool {
        let context = LAContext(); context.interactionNotAllowed = true
        let status = SecItemCopyMatching(query.merging([kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context]) { _, new in new } as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    static func read() throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw GoviIntegrationError.message("Connect Linear in Connections to continue.")
        }
        return key
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging([kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GoviIntegrationError.message("Keychain could not save the Linear key. The previous connection is unchanged.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoviIntegrationError.message("Keychain could not disconnect Linear. Try again.") }
    }
}

struct GoviGitHubClient {
    var executable: String?
    init(executable: String? = Self.findExecutable()) { self.executable = executable }
    static func findExecutable() -> String? {
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return folders.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("gh").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func run(_ arguments: [String], operation: String = "complete this request", mutation: Bool = false) async throws -> String {
        guard let executable else { throw GoviIntegrationError.message("Install GitHub CLI, then connect GitHub in Connections.") }
        return try await Task.detached(priority: .utility) {
            var environment = ProcessInfo.processInfo.environment
            environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_HOST"] = "github.com"
            environment["GH_PAGER"] = "cat"; environment["GH_BROWSER"] = "/usr/bin/false"
            guard let result = GoviLocalProcess.run(executable, arguments, timeout: 30, limit: 4_194_304, environment: environment) else {
                throw GoviIntegrationError.message("GitHub CLI could not start. Check its installation in Connections.")
            }
            if result.timedOut {
                throw GoviIntegrationError.message(mutation ? "GitHub did not confirm the result. Check GitHub before sending again." : "GitHub took too long to respond. Try again.")
            }
            guard result.status == 0 else {
                throw GoviIntegrationError.message("GitHub couldn't \(operation). Check sign-in and repository access. For a new pull request, push the branch from Changes first.")
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
    func account() async throws -> String {
        try await run(["api", "--hostname", "github.com", "user", "--jq", ".login"], operation: "verify sign-in")
    }
    func issues(_ repo: GoviGitHubRepository, assigned: Bool) async throws -> [GoviTaskIssue] {
        var args = ["issue", "list", "--repo", repo.fullName, "--state", "open", "--limit", "100", "--json", "number,title,url,body,labels,author,updatedAt"]
        if assigned { args += ["--assignee", "@me"] }
        let text = try await run(args, operation: "load issues")
        return try JSONDecoder().decode([GoviGitHubIssue].self, from: Data(text.utf8)).map { $0.task(repository: repo) }
    }
    func issue(_ number: String, repository: GoviGitHubRepository) async throws -> GoviTaskIssue {
        guard Int(number).map({ $0 > 0 }) == true else { throw GoviIntegrationError.message("Enter a GitHub issue number, such as 142.") }
        let text = try await run(["issue", "view", number, "--repo", repository.fullName, "--json", "number,title,url,body,comments,labels,author,updatedAt"], operation: "load this issue")
        return try JSONDecoder().decode(GoviGitHubIssue.self, from: Data(text.utf8)).task(repository: repository)
    }
    private var prFields: String { "number,title,url,body,headRefName,baseRefName,state,isDraft,reviewDecision,statusCheckRollup,comments,reviews,author,updatedAt" }
    func pullRequests(_ repo: GoviGitHubRepository) async throws -> [GoviPullRequest] {
        let text = try await run(["pr", "list", "--repo", repo.fullName, "--state", "open", "--limit", "50", "--json", prFields], operation: "load pull requests")
        return try JSONDecoder().decode([GoviPullRequest].self, from: Data(text.utf8))
    }
    func review(_ number: Int, repository: GoviGitHubRepository) async throws -> (GoviPullRequest, [GoviGitHubComment]) {
        let text = try await run(["pr", "view", String(number), "--repo", repository.fullName, "--json", prFields], operation: "load this pull request")
        let pr = try JSONDecoder().decode(GoviPullRequest.self, from: Data(text.utf8))
        let inline = try await run(["api", "--hostname", "github.com", "repos/\(repository.fullName)/pulls/\(number)/comments", "--paginate", "--slurp"], operation: "load review comments")
        let pages = try JSONDecoder().decode([[GoviGitHubComment]].self, from: Data(inline.utf8))
        return (pr, pages.flatMap { $0 })
    }
    /// Repositories you own, collaborate on or reach through an organization, most recently pushed first.
    func repositories() async throws -> [String] {
        let text = try await run(["api", "--hostname", "github.com", "user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
                                  "--jq", ".[].full_name"], operation: "list your repositories")
        return text.split(separator: "\n").map(String.init).filter { GoviGitHubRepository($0) != nil }
    }
    func defaultBranch(_ repo: GoviGitHubRepository) async throws -> String {
        try await run(["repo", "view", repo.fullName, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], operation: "read the default branch")
    }
    func branchSHA(_ branch: String, repository: GoviGitHubRepository) async throws -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))
        guard let ref = branch.addingPercentEncoding(withAllowedCharacters: allowed) else { throw GoviIntegrationError.invalidResponse }
        return try await run(["api", "--hostname", "github.com", "repos/\(repository.fullName)/git/ref/heads/\(ref)", "--jq", ".object.sha"], operation: "verify the pushed branch")
    }
    func comment(_ link: GoviTaskLink, body: String) async throws {
        guard let repo = link.repository.flatMap(GoviGitHubRepository.init), Int(link.id).map({ $0 > 0 }) == true else { throw GoviIntegrationError.invalidResponse }
        let file = try GoviIntegrationDraft.write(body)
        defer { GoviIntegrationDraft.remove(file) }
        let kind = link.identifier.hasPrefix("PR ") ? "pr" : "issue"
        _ = try await run([kind, "comment", link.id, "--repo", repo.fullName, "--body-file", file.path], operation: "post the comment", mutation: true)
    }
    func createPullRequest(repository: GoviGitHubRepository, head: String, base: String, title: String, body: String, draft: Bool) async throws -> String {
        let file = try GoviIntegrationDraft.write(body)
        defer { GoviIntegrationDraft.remove(file) }
        // Explicit head disables gh's automatic pushing and forking behavior.
        var args = ["pr", "create", "--repo", repository.fullName, "--head", head, "--base", base, "--title", title, "--body-file", file.path]
        if draft { args.append("--draft") }
        return try await run(args, operation: "create the pull request", mutation: true)
    }
}

struct GoviIntegrationGitContext: Equatable {
    var root: String
    var branch: String
    var repository: GoviGitHubRepository?
}

enum GoviIntegrationGit {
    static func run(_ directory: String, _ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let result = GoviLocalProcess.run("/usr/bin/git", ["-C", directory] + arguments, timeout: 8, environment: environment),
              !result.timedOut, result.status == 0 else {
            throw GoviIntegrationError.message("Choose a local Git repository with an existing commit to continue.")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func context(_ directory: String) async throws -> GoviIntegrationGitContext {
        try await Task.detached(priority: .utility) {
            let root = try run(directory, ["rev-parse", "--show-toplevel"])
            let branch = (try? run(root, ["symbolic-ref", "--quiet", "--short", "HEAD"])) ?? ""
            let remote = (try? run(root, ["remote", "get-url", "origin"])) ?? ""
            return GoviIntegrationGitContext(root: root, branch: branch, repository: GoviGitHubRepository(remote))
        }.value
    }
    @discardableResult static func verifyPullRequest(_ expected: GoviIntegrationGitContext) async throws -> String {
        let actual = try await context(expected.root)
        guard actual == expected, !actual.branch.isEmpty else {
            throw GoviIntegrationError.message("The repository or branch changed. Reopen New Pull Request and review it again.")
        }
        return try await Task.detached(priority: .utility) {
            let head = try run(expected.root, ["rev-parse", "HEAD"])
            guard let upstream = try? run(expected.root, ["rev-parse", "@{upstream}"]), upstream == head,
                  let upstreamName = try? run(expected.root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]), upstreamName == "origin/" + expected.branch else {
                throw GoviIntegrationError.message("Push this branch from Changes before creating the pull request.")
            }
            return head
        }.value
    }
}

enum GoviIntegrationDraft {
    static func write(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("govi-draft-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("body.md")
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}

struct GoviLinearClient {
    let key: String
    var session: URLSession = URLSession(configuration: .ephemeral)
    func request(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("mutation") {
                throw GoviIntegrationError.message("Linear did not confirm the result. Check the issue before sending again.")
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse, data.count <= 4_194_304 else { throw GoviIntegrationError.invalidResponse }
        return try GoviLinearParser.data(data, status: http.statusCode)
    }
    func profile() async throws -> (id: String, name: String) {
        let data = try await request("query { viewer { id name organization { name } } }")
        guard let viewer = data["viewer"] as? [String: Any], let id = viewer["id"] as? String, let name = viewer["name"] as? String else { throw GoviIntegrationError.invalidResponse }
        let org = (viewer["organization"] as? [String: Any])?["name"] as? String
        return (id, name + (org.map { " · " + $0 } ?? ""))
    }
    private var fields: String { "id identifier title url description updatedAt creator { name } labels { nodes { name } } team { id } state { id name type }" }
    func issues(assigned: Bool) async throws -> [GoviTaskIssue] {
        var filter: [String: Any] = ["state": ["type": ["nin": ["completed", "canceled"]]]]
        if assigned { filter["assignee"] = ["id": ["eq": try await profile().id]] }
        let data = try await request("query($filter: IssueFilter!) { issues(first: 100, orderBy: updatedAt, filter: $filter) { nodes { \(fields) } } }", variables: ["filter": filter])
        guard let connection = data["issues"] as? [String: Any], let nodes = connection["nodes"] as? [[String: Any]] else { throw GoviIntegrationError.invalidResponse }
        return try nodes.map(GoviLinearParser.issue)
    }
    func issue(_ identifier: String) async throws -> GoviTaskIssue {
        let data = try await request("query($id: String!) { issue(id: $id) { \(fields) comments(first: 20, orderBy: createdAt) { nodes { body user { name } } } } }", variables: ["id": identifier])
        guard let value = data["issue"] as? [String: Any] else { throw GoviIntegrationError.message("That Linear issue wasn't found, or the key cannot access its team.") }
        return try GoviLinearParser.issue(value)
    }
    func states(team: String) async throws -> [GoviLinearState] {
        let data = try await request("query($id: String!) { team(id: $id) { states { nodes { id name type } } } }", variables: ["id": team])
        guard let team = data["team"] as? [String: Any], let states = team["states"] as? [String: Any], let nodes = states["nodes"] as? [[String: Any]] else { throw GoviIntegrationError.invalidResponse }
        return nodes.compactMap { value in
            guard let id = value["id"] as? String, let name = value["name"] as? String, let type = value["type"] as? String else { return nil }
            return .init(id: id, name: name, type: type)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func comment(_ link: GoviTaskLink, body: String) async throws {
        let data = try await request("mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }", variables: ["input": ["issueId": link.id, "body": body]])
        try success(data, key: "commentCreate")
    }
    func updateState(_ link: GoviTaskLink, state: String) async throws {
        let data = try await request("mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }", variables: ["id": link.id, "input": ["stateId": state]])
        try success(data, key: "issueUpdate")
    }
    private func success(_ data: [String: Any], key: String) throws {
        guard (data[key] as? [String: Any])?["success"] as? Bool == true else { throw GoviIntegrationError.message("Linear did not save the change. Check the key's write permissions.") }
    }
}
