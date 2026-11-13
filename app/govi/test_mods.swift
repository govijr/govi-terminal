import Foundation

@main struct ModChecks {
    static func main() throws {
        func parse(_ text: String, govi: String? = nil) throws -> GoviModManifest {
            try GoviModManifest.parse(Data(text.utf8), goviVersion: govi)
        }
        func problem(_ text: String, govi: String? = nil) -> String {
            do {
                _ = try parse(text, govi: govi)
                return ""
            } catch { return (error as? GoviModError)?.message ?? "\(error)" }
        }

        // A full manifest loads, with every section defaulting to empty.
        let full = try parse(
            """
            {"id": "dev.example.android", "name": "Android", "version": "1.2.0", "minGoviVersion": "1.0",
             "panes": [{"id": "screen", "title": "Screen", "icon": "iphone", "page": "ui/index.html?x=1"},
                       {"id": "server", "title": "Server", "url": "http://localhost:8080/"},
                       {"id": "logcat", "title": "Logcat", "command": ["adb", "logcat"]}],
             "commands": [{"id": "open", "title": "Open", "shortcut": "cmd+shift+e", "pane": "screen"},
                          {"id": "restart", "title": "Restart", "run": ["./restart.sh", "--now"]}],
             "events": [{"on": "agent.state", "run": ["./notify.sh"]}],
             "links": [{"pattern": "^https://example\\\\.com/", "command": "open"}],
             "service": {"run": ["node", "server.js"]}}
            """, govi: "1.0.3")
        precondition(full.panes.map(\.kind) == [.web, .web, .terminal] && full.pane("logcat")?.command == ["adb", "logcat"])
        precondition(full.command("open")?.pane == "screen" && full.command("nope") == nil)
        precondition(full.programs == [["adb", "logcat"], ["./restart.sh", "--now"], ["./notify.sh"], ["node", "server.js"]])
        let minimal = try parse(#"{"id": "a", "name": "A"}"#)
        precondition(minimal.version == "0.0.0" && minimal.panes.isEmpty && minimal.commands.isEmpty && minimal.service == nil)
        let again = try JSONDecoder().decode(GoviModManifest.self, from: JSONEncoder().encode(full))
        precondition(again == full)

        // Problems are reported in plain words, all at once.
        precondition(problem("{").contains("isn't valid JSON"))
        precondition(problem(#"{"name": "A"}"#).contains("\"id\" is missing"))
        precondition(problem(#"{"id": "a", "name": "A", "panes": {}}"#).contains("panes has the wrong type"))
        for id in ["", "Upper", "has space", "-lead", "a/b", "../x", String(repeating: "a", count: 65)] {
            precondition(problem(#"{"id": "\#(id)", "name": "A"}"#).contains("\"id\" must be"), id)
        }
        precondition(problem(#"{"id": "a", "name": "A", "minGoviVersion": "2.0"}"#, govi: "1.9.9").contains("needs Govi 2.0"))
        precondition(problem(#"{"id": "a", "name": "A", "minGoviVersion": "2.0"}"#, govi: "2.0.0").isEmpty)
        let pane = { (body: String) in problem(#"{"id": "a", "name": "A", "panes": [\#(body)]}"#) }
        precondition(pane(#"{"id": "p", "title": "P"}"#).contains("exactly one of"))
        precondition(pane(#"{"id": "p", "title": "P", "page": "a.html", "command": ["x"]}"#).contains("exactly one of"))
        for page in ["/etc/passwd", "../secret.html", "ui/../../x", "ui//x", "a\\\\b"] {
            precondition(pane(#"{"id": "p", "title": "P", "page": "\#(page)"}"#).contains("inside the mod's folder"), page)
        }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "localhost:3000", "ftp://x"] {
            precondition(pane(#"{"id": "p", "title": "P", "url": "\#(url)"}"#).contains("http or https"), url)
        }
        precondition(pane(#"{"id": "p", "title": "P", "command": []}"#).contains("non-empty list"))
        precondition(
            pane(#"{"id": "p", "title": "P", "page": "a.html"}, {"id": "p", "title": "Q", "page": "b.html"}"#).contains("declared twice"))
        let command = { (body: String) in
            problem(#"{"id": "a", "name": "A", "panes": [{"id": "p", "title": "P", "page": "a.html"}], "commands": [\#(body)]}"#)
        }
        precondition(command(#"{"id": "c", "title": "C", "pane": "p"}"#).isEmpty)
        precondition(command(#"{"id": "c", "title": "C"}"#).contains("exactly one of"))
        precondition(command(#"{"id": "c", "title": "C", "pane": "p", "run": ["x"]}"#).contains("exactly one of"))
        precondition(command(#"{"id": "c", "title": "C", "pane": "missing"}"#).contains("doesn't declare"))
        precondition(command(#"{"id": "c", "title": "C", "pane": "p", "shortcut": "e"}"#).contains("isn't a usable shortcut"))
        precondition(command(#"{"id": "c", "title": "C", "pane": "p", "shortcut": "cmd+q"}"#).contains("isn't a usable shortcut"))
        precondition(
            command(
                #"{"id": "c", "title": "C", "pane": "p", "shortcut": "cmd+shift+e"}, {"id": "d", "title": "D", "run": ["x"], "shortcut": "shift+command+E"}"#
            )
            .contains("used twice"))
        precondition(problem(#"{"id": "a", "name": "A", "events": [{"on": "pane.exploded", "run": ["x"]}]}"#).contains("doesn't exist"))
        precondition(problem(#"{"id": "a", "name": "A", "links": [{"pattern": "(", "command": "c"}]}"#).contains("regular expression"))
        precondition(problem(#"{"id": "a", "name": "A", "links": [{"pattern": "x", "command": "c"}]}"#).contains("doesn't declare"))
        precondition(problem(#"{"id": "a", "name": "A", "service": {"run": [""]}}"#).contains("service.run"))
        let many = (0..<33).map { #"{"id": "p\#($0)", "title": "P", "page": "a.html"}"# }.joined(separator: ",")
        precondition(problem(#"{"id": "a", "name": "A", "panes": [\#(many)]}"#).contains("at most 32 panes"))

        // Shortcuts.
        precondition(GoviModShortcut.chord("cmd+shift+e") == GoviKeyChord(key: "e", modifiers: 12))
        precondition(GoviModShortcut.chord("Ctrl + Alt + arrow_left") == GoviKeyChord(key: "arrow_left", modifiers: 3))
        for bad in ["e", "shift+e", "cmd+", "hyper+e", "cmd+ee", "cmd+c"] { precondition(GoviModShortcut.chord(bad) == nil, bad) }

        // Versions.
        precondition(
            GoviModVersion.isAtLeast("1.2", "1.2.0") && GoviModVersion.isAtLeast("1.10", "1.9") && GoviModVersion.isAtLeast("2.0-beta", "2")
        )
        precondition(!GoviModVersion.isAtLeast("1.9", "1.10") && !GoviModVersion.isAtLeast("", "0.1"))

        // Pages can't leave the mod's folder, directly or through a link.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("govi-mod-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("mods/sample")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: work.appendingPathComponent("secret.txt"))
        try Data("<p>hi</p>".utf8).write(to: root.appendingPathComponent("ui/index.html"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: work)
        precondition(GoviModPaths.file("ui/index.html", in: root)?.lastPathComponent == "index.html")
        for path in ["../../secret.txt", "/etc/passwd", "escape/secret.txt", "ui/../../../secret.txt", "", "ui/index.html?x"] {
            precondition(GoviModPaths.file(path, in: root) == nil, path)
        }
        precondition(
            GoviModPaths.slug("  My Mod! v2 ") == "my-mod-v2" && GoviModPaths.slug("日本") == "" && GoviModPaths.slug("--a--") == "a")

        // The starter mod is itself a valid mod, whatever it's called.
        for name in ["Android Emulator", "It's \"quoted\" <b>&"] {
            let id = GoviModPaths.slug(name)
            let files = GoviModTemplate.files(id: id, name: name)
            let manifest = try GoviModManifest.parse(Data(files["mod.json"]!.utf8))
            precondition(manifest.id == id && manifest.name == name && manifest.pane("main")?.page == "ui/index.html")
            precondition(files[manifest.pane("main")!.page!] != nil && GoviModTemplate.executables.allSatisfy { files[$0] != nil })
            precondition(manifest.commands.compactMap(\.run).allSatisfy { files[String($0[0].dropFirst(2))] != nil })
            precondition(!files["ui/index.html"]!.contains("<b>"))
        }
        for path in ["mod.json", "ui/index.html", "hello.sh"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(GoviModTemplate.files(id: "sample", name: "Sample")[path]!.utf8).write(to: root.appendingPathComponent(path))
        }
        let loaded = try GoviModManifest.load(from: root)
        precondition(loaded.id == "sample")
        precondition((try? GoviModManifest.load(from: work)) == nil)

        // Mod panes in saved layouts.
        let terminal = GoviPaneRecord(id: UUID(), title: "zsh", directory: "/tmp", launch: .init(), persistentName: nil)
        let record = GoviModPaneRecord(id: UUID(), mod: "sample", pane: "main", title: "Sample", directory: "/tmp", state: #"{"n":1}"#)
        let layout = GoviWorkspaceLayout.split(vertical: false, ratio: 0.5, first: .terminal(terminal), second: .mod(record))
        precondition(layout.isValid && layout.paneIDs == [terminal.id, record.id] && layout.panes.map(\.id) == [terminal.id])
        precondition(layout.webPanes.isEmpty && layout.editorPanes.isEmpty)
        let decoded = try JSONDecoder().decode(GoviWorkspaceLayout.self, from: JSONEncoder().encode(layout))
        precondition(decoded == layout)
        let copy = layout.freshInstance()
        precondition(Set(copy.paneIDs).isDisjoint(with: layout.paneIDs) && copy.isValid)
        var bad = record
        bad.state = String(repeating: "x", count: GoviModPaneRecord.maxStateSize + 1)
        precondition(!GoviWorkspaceLayout.mod(bad).isValid)
        bad = record
        bad.directory = "relative"
        precondition(!GoviWorkspaceLayout.mod(bad).isValid)
        bad = record
        bad.mod = ""
        precondition(!GoviWorkspaceLayout.mod(bad).isValid)
        let checkpoint = GoviRecoveryCheckpoint(
            workspaces: [.init(id: UUID(), name: "W", layout: layout, focusedPane: record.id, group: 0, frame: [])])
        precondition(checkpoint.version == 4 && checkpoint.isValid)

        print(
            "Passed mod manifest parsing and validation, shortcuts, versions, page containment, the starter mod and mod panes in layouts.")
    }
}
