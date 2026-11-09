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
        print(
            "Passed workspace/template round trips, ID isolation, bounds, quoting, helper timeouts, status transitions, duplicate hooks, event validation and shortcut conflicts."
        )
    }
}
