import Foundation

final class LinearFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct IntegrationChecks {
    static func main() async throws {
        let repository = GoviGitHubRepository("git@github.com:example/project.git")!
        precondition(repository.fullName == "example/project")
        precondition(GoviGitHubRepository("https://github.com/example/project.git") == repository)
        precondition(GoviGitHubRepository("ssh://git@github.com/example/project.git") == repository)
        for bad in ["--help", "example/project/other", "example/..", "https://github.com.evil.test/example/project", "x/y;touch-file", "x/y\n--help", "https://github.com/x/y?token=secret"] {
            precondition(GoviGitHubRepository(bad) == nil, bad)
        }
        precondition(GoviTaskText.webURL("javascript:alert(1)", provider: "github") == nil)
        precondition(GoviTaskText.webURL("https://github.com.evil.test/x", provider: "github") == nil)
        precondition(GoviTaskText.webURL("https://token@linear.app/x", provider: "linear") == nil)
        precondition(GoviTaskText.webURL("https://linear.app/team/issue/A-1/title", provider: "linear") != nil)
        precondition(GoviTaskText.clean("hello\u{1b}[31m\u{0}world\n") == "hello[31mworld\n")
        precondition(GoviTaskText.branch(for: "../../APP-142; $(touch nope)").range(of: "^govi/[a-z0-9-]+$", options: .regularExpression) != nil)
        let brief = GoviTaskText.brief(title: "Task", url: "https://linear.app/issue/A-1", body: String(repeating: "body", count: 20_000), comments: Array(repeating: String(repeating: "x", count: 2_000), count: 30))
        precondition(brief.count <= 30_000 && !brief.contains("\u{1b}"))
        let link = GoviTaskLink(id: "issue-id", provider: "linear", identifier: "APP-142", title: "Fix", url: "https://linear.app/issue/APP-142")
        let launch = GoviPaneLaunch(agent: "claude", task: "Fix", issue: link)
        let roundTrip = try JSONDecoder().decode(GoviPaneLaunch.self, from: JSONEncoder().encode(launch))
        precondition(roundTrip == launch)
        let oldLaunch = try JSONDecoder().decode(GoviPaneLaunch.self, from: Data("{\"agent\":\"claude\",\"task\":\"Existing\"}".utf8))
        precondition(oldLaunch.issue == nil)

        let fixtureIssue: [String: Any] = ["id": "issue-id", "identifier": "APP-142", "title": "Fix checkout", "url": "https://linear.app/issue/APP-142", "description": "Expected behavior", "team": ["id": "team-id"], "state": ["name": "Todo"], "comments": ["nodes": [["body": "new", "user": ["name": "Ada"]], ["body": "old", "user": ["name": "Lin"]]]]]
        let issue = try GoviLinearParser.issue(fixtureIssue)
        precondition(issue.comments.first == "Lin:\nold" && issue.teamID == "team-id")
        for status in [401, 403, 429, 500] {
            do { _ = try GoviLinearParser.data(Data("{}".utf8), status: status); preconditionFailure("HTTP failure must not be success") }
            catch { precondition(error.localizedDescription.count > 0) }
        }
        do {
            let partial = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "partial"]], "errors": [["message": "Permission denied"]]])
            _ = try GoviLinearParser.data(partial, status: 200)
            preconditionFailure("Partial GraphQL errors must fail")
        } catch {}

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinearFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var requests: [[String: Any]] = []
        LinearFixtureProtocol.handler = { request in
            precondition(request.url!.absoluteString == "https://api.linear.app/graphql")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "fixture-key")
            precondition(request.httpMethod == "POST")
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
                bytes = data
            }
            let body = try JSONSerialization.jsonObject(with: bytes!) as! [String: Any]
            requests.append(body)
            let query = body["query"] as! String
            if query.contains("viewer") { return (200, ["data": ["viewer": ["id": "me", "name": "Ada", "organization": ["name": "Example"]]]]) }
            if query.contains("issues(first:") { return (200, ["data": ["issues": ["nodes": [fixtureIssue]]]]) }
            if query.contains("issue(id:") { return (200, ["data": ["issue": fixtureIssue]]) }
            if query.contains("team(id:") { return (200, ["data": ["team": ["states": ["nodes": [["id": "done", "name": "Done", "type": "completed"]]]]]]) }
            if query.contains("commentCreate") { return (200, ["data": ["commentCreate": ["success": true]]]) }
            if query.contains("issueUpdate") { return (200, ["data": ["issueUpdate": ["success": true]]]) }
            preconditionFailure("Unexpected query: " + query)
        }
        let client = GoviLinearClient(key: "fixture-key", session: session)
        let profile = try await client.profile()
        precondition(profile.id == "me" && profile.name == "Ada · Example")
        let issues = try await client.issues(assigned: true)
        precondition(issues.count == 1 && issues[0].link.identifier == "APP-142")
        let filter = (requests.last!["variables"] as! [String: Any])["filter"] as! [String: Any]
        precondition(((filter["assignee"] as! [String: Any])["id"] as! [String: String])["eq"] == "me")
        let fetched = try await client.issue("APP-142")
        precondition(fetched.link.id == "issue-id")
        let states = try await client.states(team: "team-id")
        precondition(states.first?.id == "done")
        let literal = "Quotes ' \"\n$(touch /tmp/never-run-this)"
        try await client.comment(link, body: literal)
        let input = (requests.last!["variables"] as! [String: Any])["input"] as! [String: String]
        precondition(input["body"] == literal && input["issueId"] == "issue-id")
        try await client.updateState(link, state: "done")
        let update = (requests.last!["variables"] as! [String: Any])["input"] as! [String: String]
        precondition(update["stateId"] == "done")
        LinearFixtureProtocol.handler = { _ in (200, ["data": ["issueUpdate": ["success": false]]]) }
        do { try await client.updateState(link, state: "done"); preconditionFailure("Failed mutation must not report success") } catch {}

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("govi-integration-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("gh")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        args = sys.argv[1:]
        record = {"args":args,"host":os.environ.get("GH_HOST"),"no_prompt":os.environ.get("GH_PROMPT_DISABLED")}
        if '--body-file' in args:
            path = args[args.index('--body-file')+1]
            record['body_file'] = path
            record['body'] = open(path).read()
            record['mode'] = os.stat(path).st_mode & 0o777
        with open(__file__+'.log','a') as file: file.write(json.dumps(record)+'\n')
        issue = {"number":142,"title":"Fix checkout","url":"https://github.com/example/project/issues/142","body":"Fix details","comments":[{"body":"Keep behavior","author":{"login":"Ada"}}]}
        pr = {"number":7,"title":"Checkout fix","url":"https://github.com/example/project/pull/7","headRefName":"fix-checkout","baseRefName":"main","state":"OPEN","isDraft":True,"statusCheckRollup":[{"name":"Tests","status":"COMPLETED","conclusion":"FAILURE"},{"context":"Legacy","state":"SUCCESS"}]}
        if args[:2] == ['issue','list']: print(json.dumps([issue]))
        elif args[:2] == ['issue','view']: print(json.dumps(issue))
        elif args[:2] == ['pr','list']: print(json.dumps([pr]))
        elif args[:2] == ['pr','view']: print(json.dumps(pr))
        elif args[:2] == ['pr','create']: print('https://github.com/example/project/pull/7')
        elif args[:2] == ['repo','view']: print('main')
        elif '/comments' in ' '.join(args): print(json.dumps([[{"body":"Fix null","user":{"login":"Lin"},"path":"app.swift","line":12}]]))
        elif args[:1] == ['api']: print('fixture-user')
        else: print('https://github.com/example/project/issues/142#issuecomment-1')
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let github = GoviGitHubClient(executable: executable.path)
        let account = try await github.account()
        precondition(account == "fixture-user")
        let ghIssues = try await github.issues(repository, assigned: true)
        precondition(ghIssues.count == 1)
        let ghIssue = try await github.issue("142", repository: repository)
        precondition(ghIssue.comments.first == "Ada:\nKeep behavior")
        let prs = try await github.pullRequests(repository)
        precondition(prs.first!.checks.first!.failed && !prs.first!.checks.last!.failed)
        let (pr, comments) = try await github.review(7, repository: repository)
        precondition(pr.task(repository: repository, inlineComments: comments).brief.contains("app.swift:12"))
        try await github.comment(ghIssue.link, body: literal)
        _ = try await github.createPullRequest(repository: repository, head: "feature", base: "main", title: "Fix", body: literal, draft: true)
        let log = try String(contentsOfFile: executable.path + ".log", encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(log.allSatisfy { $0["host"] as? String == "github.com" && $0["no_prompt"] as? String == "1" })
        for record in log where record["body_file"] != nil {
            precondition(record["body"] as? String == literal && record["mode"] as? Int == 0o600)
            precondition(!FileManager.default.fileExists(atPath: record["body_file"] as! String))
        }
        let createArgs = log.last!["args"] as! [String]
        precondition(createArgs.contains("--head") && createArgs.contains("--draft") && !createArgs.contains("--fill"))
        let marker = folder.appendingPathComponent("must-not-exist")
        let malicious = "a'b;$(touch " + marker.path + ")\nnext"
        let quoted = GoviLocalProcess.run("/bin/zsh", ["-c", "/usr/bin/printf %s " + GoviShell.quote(malicious)])
        precondition(quoted?.output == malicious && !FileManager.default.fileExists(atPath: marker.path))
        let checkout = folder.appendingPathComponent("local checkout 'quoted'")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        func git(_ args: [String]) throws -> String { try GoviIntegrationGit.run(checkout.path, args) }
        _ = try git(["init", "-b", "feature"])
        _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"])
        _ = try git(["remote", "add", "origin", "https://github.com/example/project.git"])
        let context = try await GoviIntegrationGit.context(checkout.path)
        precondition(context.repository == repository && context.branch == "feature")
        do { try await GoviIntegrationGit.verifyPullRequest(context); preconditionFailure("Unpushed branch must be rejected") } catch {}
        let sha = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/remotes/origin/feature", sha])
        _ = try git(["config", "branch.feature.remote", "origin"])
        _ = try git(["config", "branch.feature.merge", "refs/heads/feature"])
        let verifiedSHA = try await GoviIntegrationGit.verifyPullRequest(context)
        precondition(verifiedSHA == sha)
        _ = try git(["checkout", "-b", "different"])
        do { try await GoviIntegrationGit.verifyPullRequest(context); preconditionFailure("Changed branch must be rejected") } catch {}
        print("Passed integration URL/argument validation, recovery compatibility, HTTP/GraphQL failures, Linear queries and mutations, GitHub issue/PR/review fixtures, private draft cleanup, shell-injection checks and local branch/push guards. No live accounts or remote writes used.")
    }
}
