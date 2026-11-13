import Foundation

@main struct WorkflowChecks {
    static func main() throws {
        let first = GoviPaneRecord(
            id: UUID(), title: "Agent", directory: "/tmp/project with 'quotes'", launch: .init(agent: "claude", task: "Fix login"),
            persistentName: "first")
        let second = GoviPaneRecord(
            id: UUID(), title: "Server", directory: "/tmp/project", launch: .init(command: "npm run dev"), persistentName: "second")
        let third = GoviPaneRecord(
            id: UUID(), title: "Browser", directory: "/tmp/project", launch: .init(tool: "browser"), persistentName: "third")
        let layout = GoviWorkspaceLayout.split(
            vertical: false, ratio: 0.35, first: .terminal(first),
            second: .split(vertical: true, ratio: 0.6, first: .terminal(second), second: .terminal(third)))
        let saved = GoviWorkspaceRecord(
            id: UUID(), name: "Web", layout: layout, focusedPane: second.id, group: 2, frame: [10, 20, 1200, 800])
        let checkpoint = GoviRecoveryCheckpoint(workspaces: [saved])
        precondition(checkpoint.isValid)
        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(GoviRecoveryCheckpoint.self, from: data)
        precondition(decoded == checkpoint)
        let instance = layout.freshInstance()
        precondition(instance.isValid && instance.panes.count == 3)
        precondition(Set(instance.panes.map(\.id)).isDisjoint(with: Set(layout.panes.map(\.id))))
        precondition(instance.panes.allSatisfy { $0.persistentName == nil })
        precondition(instance.panes.map(\.launch) == layout.panes.map(\.launch))
        precondition(instance.panes.map(\.directory) == layout.panes.map(\.directory))
        precondition(!GoviWorkspaceLayout.split(vertical: false, ratio: 2, first: .terminal(first), second: .terminal(second)).isValid)
        precondition(!GoviWorkspaceLayout.split(vertical: false, ratio: 0.5, first: .terminal(first), second: .terminal(first)).isValid)
        var invalid = first
        invalid.directory = "relative/path"
        precondition(!GoviWorkspaceLayout.terminal(invalid).isValid)
        var version = checkpoint
        version.version = 900
        precondition(!version.isValid)
        precondition(!GoviRecoveryCheckpoint(workspaces: [saved, saved]).isValid)

        // Browser panes (checkpoint version 2) alongside terminals.
        let web = GoviWebPaneRecord(id: UUID(), url: "http://localhost:3000/login?next=%2F", title: "Dev server")
        let blank = GoviWebPaneRecord(id: UUID(), url: "", title: "")
        let mixed = GoviWorkspaceLayout.split(
            vertical: false, ratio: 0.5, first: .terminal(first),
            second: .split(vertical: true, ratio: 0.5, first: .web(web), second: .web(blank)))
        precondition(mixed.isValid && mixed.panes.map(\.id) == [first.id] && mixed.webPanes == [web, blank])
        precondition(mixed.paneIDs == [first.id, web.id, blank.id])
        let mixedCheckpoint = GoviRecoveryCheckpoint(
            workspaces: [.init(id: UUID(), name: "Mixed", layout: mixed, focusedPane: web.id, group: 0, frame: [0, 0, 900, 600])])
        precondition(mixedCheckpoint.version == GoviRecoveryCheckpoint.currentVersion && mixedCheckpoint.isValid)
        let mixedDecoded = try JSONDecoder().decode(GoviRecoveryCheckpoint.self, from: JSONEncoder().encode(mixedCheckpoint))
        precondition(mixedDecoded == mixedCheckpoint)
        // A browser-only workspace is still a workspace.
        precondition(GoviWorkspaceLayout.web(web).isValid)
        // Version 1 checkpoints (written before browser panes) still load.
        var legacy = checkpoint
        legacy.version = 1
        let legacyDecoded = try JSONDecoder().decode(GoviRecoveryCheckpoint.self, from: JSONEncoder().encode(legacy))
        precondition(legacyDecoded.isValid && legacyDecoded.workspaces[0].layout == layout)
        // Only http, https and file addresses are kept, within the size limit.
        for url in [
            "javascript:alert(1)", "data:text/html,hi", "ftp://example.com", "https://", "not a url",
            "https://example.com/" + String(repeating: "a", count: GoviWebPaneRecord.maxURLLength),
        ] {
            precondition(!GoviWorkspaceLayout.web(.init(id: UUID(), url: url, title: "")).isValid, url)
        }
        precondition(GoviWorkspaceLayout.web(.init(id: UUID(), url: "file:///tmp/index.html", title: "")).isValid)
        // Duplicate IDs across terminal and browser panes are rejected.
        precondition(
            !GoviWorkspaceLayout.split(
                vertical: true, ratio: 0.5, first: .terminal(first), second: .web(.init(id: first.id, url: "", title: ""))
            ).isValid)
        // Templates give browser panes new IDs but keep their addresses.
        let mixedInstance = mixed.freshInstance()
        precondition(mixedInstance.isValid)
        precondition(Set(mixedInstance.paneIDs).isDisjoint(with: Set(mixed.paneIDs)))
        precondition(mixedInstance.webPanes.map(\.url) == mixed.webPanes.map(\.url))
        precondition(GoviShell.quote("a'b;$(touch /tmp/no)") == "'a'\\''b;$(touch /tmp/no)'")
        let start = Date()
        let timeout = GoviLocalProcess.run("/bin/sleep", ["10"], timeout: 0.1)
        precondition(timeout?.timedOut == true && Date().timeIntervalSince(start) < 2)
        let noisyStart = Date()
        let noisy = GoviLocalProcess.run("/usr/bin/yes", [], timeout: 0.1)
        precondition(noisy?.timedOut == true && noisy!.output.utf8.count <= 262_144 && Date().timeIntervalSince(noisyStart) < 2)
        let output = GoviLocalProcess.run("/usr/bin/printf", ["%s", "a'b;$(literal)"])
        precondition(output?.status == 0 && output?.output == "a'b;$(literal)")
        let split = GoviLocalProcess.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"], errors: .separate)
        precondition(split?.status == 3 && split?.output == "out" && split?.errors == "err")
        let merged = GoviLocalProcess.run("/bin/sh", ["-c", "printf out; printf err >&2"], errors: .merge)
        precondition(merged?.output.contains("out") == true && merged?.output.contains("err") == true && merged?.errors == "")
        let discarded = GoviLocalProcess.run("/bin/sh", ["-c", "printf err >&2"])
        precondition(discarded?.output == "" && discarded?.errors == "")
        let scratchDirectory = String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)!)
        precondition(
            GoviLocalProcess.run("/bin/pwd", ["-P"], directory: scratchDirectory)?.output
                .trimmingCharacters(in: .whitespacesAndNewlines) == scratchDirectory)
        let cancellation = GoviLocalProcess.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let cancelStart = Date()
        let cancelled = GoviLocalProcess.run("/bin/sleep", ["10"], timeout: 30, cancellation: cancellation)
        precondition(cancelled?.cancelled == true && cancelled?.timedOut == false && Date().timeIntervalSince(cancelStart) < 2)
        precondition(GoviLocalProcess.run("/nonexistent/tool", []) == nil)
        // Git wrappers: trimmed values, untrimmed porcelain, and git's own message on failure.
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("govi-git-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try! GoviGit.run(repository, ["init", "-q"])
        precondition(
            GoviGit.topLevel(repository).map { String(cString: realpath($0, nil)!) }
                == String(cString: realpath(repository, nil)!))
        try! "x".write(toFile: repository + "/é.txt", atomically: true, encoding: .utf8)
        precondition(try! GoviGitRunner.run(repository, ["status", "--porcelain"]) == "?? é.txt\n")
        do {
            _ = try GoviGit.run(repository, ["rev-parse", "--verify", "no-such-ref"])
            preconditionFailure("expected failure")
        } catch { precondition((error as NSError).domain == "GoviGit" && !error.localizedDescription.isEmpty) }
        precondition(GoviGit.topLevel("/") == nil)
        let date = Date(timeIntervalSince1970: 1000)
        var activity = GoviReportedActivity()
        activity.receive(.working, now: date)
        activity.receive(.needsInput, now: date.addingTimeInterval(5))
        precondition(activity.visibleState == .needsInput && activity.startedAt == date)
        activity.acknowledge()
        precondition(activity.visibleState == .idle)
        activity.receive(.needsInput, now: date.addingTimeInterval(6))
        precondition(activity.visibleState == .idle, "Duplicate hooks must not revive acknowledged items.")
        activity.receive(.working, now: date.addingTimeInterval(8))
        precondition(activity.startedAt == date && activity.visibleState == .working)
        activity.receive(.done, now: date.addingTimeInterval(10))
        precondition(activity.endedAt == date.addingTimeInterval(10))
        activity.acknowledge()
        activity.receive(.done, now: date.addingTimeInterval(12))
        precondition(activity.visibleState == .idle && activity.endedAt == date.addingTimeInterval(10))
        activity.receive(.working, now: date.addingTimeInterval(20))
        precondition(activity.startedAt == date.addingTimeInterval(20) && activity.endedAt == nil)
        activity.receive(.error, now: date.addingTimeInterval(21))
        precondition(activity.visibleState == .error)
        let signal = "{\"id\":\"\(first.id.uuidString)\",\"state\":\"done\",\"label\":\"Fix login\"}"
        precondition(GoviActivitySignal.decode(signal)?.state == .done)
        precondition(GoviActivitySignal.decode(signal.replacingOccurrences(of: "done", with: "unknown")) == nil)
        precondition(GoviActivitySignal.decode(signal.replacingOccurrences(of: "Fix login", with: "line\\nfeed")) == nil)
        precondition(GoviActivitySignal.decode(signal.replacingOccurrences(of: first.id.uuidString, with: "bad-id")) == nil)
        let hooks = try JSONSerialization.jsonObject(with: Data(GoviClaudeHooks.settingsJSON.utf8)) as! [String: Any]
        precondition(Set(hooks.keys) == ["hooks"])
        let events = hooks["hooks"] as! [String: [[String: Any]]]
        precondition(events["PermissionRequest"] != nil && events["Stop"] != nil && events["UserPromptSubmit"] != nil)
        let actions = GoviShortcutAction.allCases
        precondition(Set(actions.map(\.defaultChord)).count == actions.count)
        precondition(actions.allSatisfy { $0.defaultChord.isValid && !$0.defaultChord.isReserved })
        precondition(GoviShortcutPreferences.conflict(.init(key: "q", modifiers: 8), for: .splitRight, values: [:]) != nil)
        precondition(GoviShortcutPreferences.conflict(.init(key: "d", modifiers: 12), for: .splitRight, values: [:]) != nil)
        precondition(GoviShortcutPreferences.conflict(.init(key: "r", modifiers: 0), for: .splitRight, values: [:]) != nil)
        let changed = [GoviShortcutAction.splitRight.rawValue: GoviKeyChord(key: "r", modifiers: 8)]
        precondition(GoviShortcutPreferences.conflict(.init(key: "d", modifiers: 8), for: .newWorkspace, values: changed) == nil)
        let configuration = GoviShortcutPreferences.configuration(values: changed)
        precondition(configuration.contains("keybind = super+d=unbind") && configuration.contains("keybind = super+r=new_split:right"))
        precondition(!GoviKeyChord(key: "d\nkeybind = bad", modifiers: 8).isValid)
        if CommandLine.arguments.count > 1 {
            var all = GoviShortcutPreferences.configuration(values: [:])
            for key in Array(GoviKeyChord.characters.keys) + ["a", "0", "9"] { all += "keybind = ctrl+alt+\(key)=ignore\n" }
            try all.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        // Editor panes (checkpoint version 3).
        let editor = GoviEditorPaneRecord(id: UUID(), root: "/tmp/project", file: "/tmp/project/src/app.ts", line: 42)
        let withEditor = GoviWorkspaceLayout.split(vertical: false, ratio: 0.5, first: .terminal(first), second: .editor(editor))
        precondition(withEditor.isValid && withEditor.editorPanes == [editor] && withEditor.paneIDs == [first.id, editor.id])
        precondition(withEditor.panes.map(\.id) == [first.id] && withEditor.webPanes.isEmpty)
        let editorCheckpoint = GoviRecoveryCheckpoint(
            workspaces: [.init(id: UUID(), name: "Code", layout: withEditor, focusedPane: editor.id, group: 0, frame: [0, 0, 900, 600])])
        let editorDecoded = try JSONDecoder().decode(GoviRecoveryCheckpoint.self, from: JSONEncoder().encode(editorCheckpoint))
        precondition(editorDecoded == editorCheckpoint)
        precondition(GoviWorkspaceLayout.editor(.init(id: UUID(), root: "/tmp", file: "", line: 1)).isValid)
        for bad in [
            GoviEditorPaneRecord(id: UUID(), root: "relative", file: "", line: 1),
            GoviEditorPaneRecord(id: UUID(), root: "/tmp", file: "relative.ts", line: 1),
            GoviEditorPaneRecord(id: UUID(), root: "/tmp", file: "/tmp/a\0b", line: 1),
            GoviEditorPaneRecord(id: UUID(), root: "/tmp", file: "", line: 0),
        ] { precondition(!GoviWorkspaceLayout.editor(bad).isValid) }
        let editorInstance = withEditor.freshInstance()
        precondition(editorInstance.isValid && Set(editorInstance.paneIDs).isDisjoint(with: Set(withEditor.paneIDs)))
        precondition(editorInstance.editorPanes.map(\.file) == [editor.file])
        var future = editorCheckpoint
        future.version = GoviRecoveryCheckpoint.currentVersion + 1
        precondition(!future.isValid)

        // Clicked file paths with line and column.
        precondition(
            GoviLinkRouter.fileLocation("./src/app.ts:42:7", relativeTo: "/tmp/project")
                == .init(path: "/tmp/project/src/app.ts", line: 42, column: 7))
        precondition(
            GoviLinkRouter.fileLocation("../lib/a.swift:12:", relativeTo: "/tmp/project")
                == .init(path: "/tmp/lib/a.swift", line: 12, column: nil))
        precondition(GoviLinkRouter.fileLocation("/etc/hosts", relativeTo: nil) == .init(path: "/etc/hosts", line: nil, column: nil))
        precondition(GoviLinkRouter.fileLocation("file:///tmp/a%20b.txt", relativeTo: nil)?.path == "/tmp/a b.txt")
        precondition(GoviLinkRouter.fileLocation("file://otherhost/tmp/a.txt", relativeTo: nil) == nil)
        precondition(GoviLinkRouter.fileLocation("./a.ts", relativeTo: nil) == nil)
        precondition(GoviLinkRouter.fileLocation("./a.ts:0", relativeTo: "/tmp")?.line == nil)
        // Quick Look targets: web addresses, and paths that exist.
        precondition(GoviLinkRouter.previewTarget("(https://example.com/a).", relativeTo: nil)?.absoluteString == "https://example.com/a")
        precondition(GoviLinkRouter.previewTarget("https://", relativeTo: nil) == nil)
        precondition(GoviLinkRouter.previewTarget("'/etc/hosts',", relativeTo: nil)?.path == "/etc/hosts")
        precondition(GoviLinkRouter.previewTarget("/etc/hosts:3", relativeTo: nil)?.path == "/etc/hosts")
        precondition(GoviLinkRouter.previewTarget("hosts", relativeTo: "/etc") == nil)
        precondition(GoviLinkRouter.previewTarget("./hosts", relativeTo: "/etc")?.path == "/etc/hosts")
        precondition(GoviLinkRouter.previewTarget("/no/such/file.png", relativeTo: nil) == nil)
        precondition(
            GoviLinkRouter.previewTarget(".", relativeTo: "/etc") == nil && GoviLinkRouter.previewTarget("/", relativeTo: nil) == nil)
        let printed = "see /etc/hosts and https://example.com\nagain /etc/hosts then 1.5 ./missing.txt"
        precondition(
            GoviLinkRouter.previewTargets(in: printed, relativeTo: "/tmp").map(\.absoluteString) == [
                "https://example.com", "file:///etc/hosts",
            ])
        precondition(GoviLinkRouter.token(in: "open /tmp/a.gif now", atColumn: 9, containing: "a.gif") == "/tmp/a.gif")
        precondition(GoviLinkRouter.token(in: "日本 /tmp/a.gif", atColumn: 12, containing: "a.gif") == "/tmp/a.gif")
        precondition(GoviLinkRouter.token(in: "open /tmp/a.gif now", atColumn: 4, containing: "zzz") == nil)
        // Text files only.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("govi-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let textFile = scratch.appendingPathComponent("a.ts")
        let binaryFile = scratch.appendingPathComponent("b.bin")
        try Data("let x = 1\n".utf8).write(to: textFile)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: binaryFile)
        precondition(
            GoviTextFile.isEditable(textFile.path) && !GoviTextFile.isEditable(binaryFile.path) && !GoviTextFile.isEditable(scratch.path))
        precondition((try? GoviTextFile.read(textFile).get()) == "let x = 1\n")
        if case .success = GoviTextFile.read(binaryFile) { preconditionFailure("binary file read as text") }

        // Local dev-server links found in terminal output.
        let devLog = """
            VITE v5.0.0  ready in 300 ms
              ➜  Local:   http://localhost:5173/
              ➜  Network: http://192.168.1.4:5173/
            then http://0.0.0.0:8000/docs. Also (http://127.0.0.1:3000/api).
            """
        precondition(GoviLinkRouter.latestLocalURL(in: devLog)?.absoluteString == "http://127.0.0.1:3000/api")
        precondition(
            GoviLinkRouter.latestLocalURL(in: "Uvicorn running on http://0.0.0.0:8000/docs.")?.absoluteString
                == "http://localhost:8000/docs")
        precondition(GoviLinkRouter.latestLocalURL(in: "  ➜  Local:   http://localhost:5173/")?.absoluteString == "http://localhost:5173/")
        precondition(GoviLinkRouter.latestLocalURL(in: "see https://example.com and http://192.168.1.4:3000") == nil)
        precondition(GoviLinkRouter.latestLocalURL(in: "at http://app.localhost:8080/x,")?.absoluteString == "http://app.localhost:8080/x")
        precondition(GoviLinkRouter.latestLocalURL(in: "ipv6 http://[::1]:4000/") != nil)
        precondition(GoviLinkRouter.isLocalWeb(URL(string: "http://LOCALHOST:3000")!))
        precondition(!GoviLinkRouter.isLocalWeb(URL(string: "http://localhost.example.com")!))
        precondition(!GoviLinkRouter.isLocalWeb(URL(string: "file:///tmp/a.html")!))
        precondition(!GoviLinkRouter.isLocalWeb(URL(string: "https://example.com")!))
        precondition(
            GoviLinkRouter.origin(URL(string: "http://localhost:3000/a")!)
                == GoviLinkRouter.origin(URL(string: "http://LocalHost:3000/b?c")!))
        precondition(
            GoviLinkRouter.origin(URL(string: "http://localhost:3000")!) != GoviLinkRouter.origin(URL(string: "http://localhost:3001")!))
        print(
            "Passed workspace/template round trips, ID isolation, bounds, quoting, helper timeouts, status transitions, duplicate hooks, event validation, shortcut conflicts, editor records and link detection."
        )
    }
}
