import Foundation

/// A mod's `mod.json`: what it adds to Govi. Everything here is plain data so
/// it can be checked without a running app; `GoviMods` acts on it.
///
/// A mod is a folder in Govi's `Mods` directory. Its commands are argument
/// arrays (never shell text) that run as the person, with the mod's folder as
/// the working directory. See `govi/MODS.md` for the author's guide.
struct GoviModManifest: Codable, Equatable {
    static let fileName = "mod.json"
    static let maxFileSize = 256 * 1024

    /// A pane the mod can open in a split.
    struct Pane: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case web, terminal }
        var id: String
        var title: String
        /// An SF Symbol name for title bars and the sidebar.
        var icon: String?
        /// A page inside the mod's folder, shown in a web view with the `govi` bridge.
        var page: String?
        /// An http(s) address to show instead of a bundled page, e.g. the mod's own server.
        var url: String?
        /// A program to run in a terminal pane.
        var command: [String]?

        var kind: Kind { command == nil ? .web : .terminal }
    }

    /// An entry in the command palette, optionally with a shortcut.
    struct Command: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var description: String?
        /// For example `cmd+shift+e`. Govi's own shortcuts win a conflict.
        var shortcut: String?
        /// Opens this pane of the mod…
        var pane: String?
        /// …or runs this program in the background.
        var run: [String]?
    }

    /// A program run when something happens in Govi.
    struct Hook: Codable, Equatable {
        var on: String
        var run: [String]
    }

    /// Sends Command-clicked links that match `pattern` to one of the mod's commands.
    struct LinkHandler: Codable, Equatable {
        var pattern: String
        var command: String
    }

    /// A program kept running while the mod is enabled.
    struct Service: Codable, Equatable {
        var run: [String]
    }

    var id: String
    var name: String
    var version: String
    var description: String?
    /// The oldest Govi this mod works with, e.g. `1.2`.
    var minGoviVersion: String?
    var panes: [Pane]
    var commands: [Command]
    var events: [Hook]
    var links: [LinkHandler]
    var service: Service?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, minGoviVersion, panes, commands, events, links, service
    }

    init(
        id: String, name: String, version: String, description: String? = nil, minGoviVersion: String? = nil,
        panes: [Pane] = [], commands: [Command] = [], events: [Hook] = [], links: [LinkHandler] = [], service: Service? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.minGoviVersion = minGoviVersion
        self.panes = panes
        self.commands = commands
        self.events = events
        self.links = links
        self.service = service
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        minGoviVersion = try container.decodeIfPresent(String.self, forKey: .minGoviVersion)
        panes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? []
        commands = try container.decodeIfPresent([Command].self, forKey: .commands) ?? []
        events = try container.decodeIfPresent([Hook].self, forKey: .events) ?? []
        links = try container.decodeIfPresent([LinkHandler].self, forKey: .links) ?? []
        service = try container.decodeIfPresent(Service.self, forKey: .service)
    }

    func pane(_ id: String) -> Pane? { panes.first { $0.id == id } }
    func command(_ id: String) -> Command? { commands.first { $0.id == id } }

    /// Every program this mod can start, for showing the person before they enable it.
    var programs: [[String]] {
        var all = panes.compactMap(\.command) + commands.compactMap(\.run) + events.map(\.run)
        if let service { all.append(service.run) }
        var seen = Set<[String]>()
        return all.filter { seen.insert($0).inserted }
    }
}

struct GoviModError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The events a mod can hook, and what each one carries.
enum GoviModEvent {
    static let loaded = "mod.loaded"
    static let paneOpened = "pane.opened"
    static let paneClosed = "pane.closed"
    static let paneFocused = "pane.focused"
    static let agentState = "agent.state"
    static let all = [loaded, paneOpened, paneClosed, paneFocused, agentState]
}

extension GoviModManifest {
    private static func isID(_ text: String, dots: Bool) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 64, let first = text.utf8.first else { return false }
        let letterOrDigit = { (byte: UInt8) in (97...122).contains(byte) || (48...57).contains(byte) }
        guard letterOrDigit(first) else { return false }
        return text.utf8.allSatisfy { letterOrDigit($0) || $0 == 45 || $0 == 95 || (dots && $0 == 46) }
    }

    private static func isProgram(_ argv: [String]) -> Bool {
        guard let first = argv.first, !first.isEmpty, argv.count <= 64 else { return false }
        return argv.allSatisfy { !$0.contains("\0") && $0.utf8.count <= 8192 }
    }

    /// A page path that stays inside the mod's folder.
    static func isPagePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return false }
        let file = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return !file.isEmpty && !file.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    /// Everything wrong with the manifest, in plain sentences. Empty when it can be loaded.
    func problems(goviVersion: String? = nil) -> [String] {
        var found: [String] = []
        if !Self.isID(id, dots: true) {
            found.append("\"id\" must be 1–64 lowercase letters, digits, dots, dashes or underscores, starting with a letter or digit.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 80 {
            found.append("\"name\" must be 1–80 characters.")
        }
        if version.isEmpty || version.utf8.count > 32 { found.append("\"version\" must be 1–32 characters.") }
        if (description ?? "").utf8.count > 500 { found.append("\"description\" must be at most 500 characters.") }
        if let minGoviVersion, let goviVersion, !GoviModVersion.isAtLeast(goviVersion, minGoviVersion) {
            found.append("This mod needs Govi \(minGoviVersion) or newer; this is Govi \(goviVersion).")
        }
        if panes.count > 32 { found.append("A mod can have at most 32 panes.") }
        if commands.count > 64 { found.append("A mod can have at most 64 commands.") }
        if events.count > 32 { found.append("A mod can have at most 32 event hooks.") }
        if links.count > 16 { found.append("A mod can have at most 16 link handlers.") }

        var paneIDs = Set<String>()
        for pane in panes.prefix(32) {
            let label = "Pane \"\(pane.id)\""
            if !Self.isID(pane.id, dots: false) {
                found.append("\(label): the id must be lowercase letters, digits, dashes or underscores.")
            }
            if !paneIDs.insert(pane.id).inserted { found.append("\(label) is declared twice.") }
            if pane.title.isEmpty || pane.title.utf8.count > 80 { found.append("\(label): \"title\" must be 1–80 characters.") }
            if let icon = pane.icon, icon.isEmpty || icon.utf8.count > 64 { found.append("\(label): \"icon\" must be an SF Symbol name.") }
            let sources = [pane.page != nil, pane.url != nil, pane.command != nil].filter { $0 }.count
            if sources != 1 {
                found.append("\(label) needs exactly one of \"page\", \"url\" or \"command\".")
                continue
            }
            if let page = pane.page, !Self.isPagePath(page) {
                found.append("\(label): \"page\" must be a file inside the mod's folder, such as \"ui/index.html\".")
            }
            if let address = pane.url {
                let url = URL(string: address)
                if address.utf8.count > 2048 || url?.host == nil || !["http", "https"].contains(url?.scheme?.lowercased() ?? "") {
                    found.append("\(label): \"url\" must be an http or https address.")
                }
            }
            if let command = pane.command, !Self.isProgram(command) {
                found.append("\(label): \"command\" must be a non-empty list of arguments.")
            }
        }

        var commandIDs = Set<String>()
        var chords = Set<GoviKeyChord>()
        for command in commands.prefix(64) {
            let label = "Command \"\(command.id)\""
            if !Self.isID(command.id, dots: false) {
                found.append("\(label): the id must be lowercase letters, digits, dashes or underscores.")
            }
            if !commandIDs.insert(command.id).inserted { found.append("\(label) is declared twice.") }
            if command.title.isEmpty || command.title.utf8.count > 80 { found.append("\(label): \"title\" must be 1–80 characters.") }
            if (command.description ?? "").utf8.count > 200 { found.append("\(label): \"description\" must be at most 200 characters.") }
            if (command.pane != nil) == (command.run != nil) {
                found.append("\(label) needs exactly one of \"pane\" or \"run\".")
            } else if let pane = command.pane, !paneIDs.contains(pane) {
                found.append("\(label) opens the pane \"\(pane)\", which this mod doesn't declare.")
            } else if let run = command.run, !Self.isProgram(run) {
                found.append("\(label): \"run\" must be a non-empty list of arguments.")
            }
            if let shortcut = command.shortcut {
                if let chord = GoviModShortcut.chord(shortcut) {
                    if !chords.insert(chord).inserted { found.append("\(label): the shortcut \(shortcut) is used twice in this mod.") }
                } else {
                    found.append(
                        "\(label): \"\(shortcut)\" isn't a usable shortcut. Use Command or Control with a letter, digit or named key, such as \"cmd+shift+e\"."
                    )
                }
            }
        }

        for hook in events.prefix(32) {
            if !GoviModEvent.all.contains(hook.on) {
                found.append("Event \"\(hook.on)\" doesn't exist. Events: \(GoviModEvent.all.joined(separator: ", ")).")
            }
            if !Self.isProgram(hook.run) { found.append("Event \"\(hook.on)\": \"run\" must be a non-empty list of arguments.") }
        }

        for link in links.prefix(16) {
            if link.pattern.isEmpty || link.pattern.utf8.count > 1024 || (try? NSRegularExpression(pattern: link.pattern)) == nil {
                found.append("Link pattern \"\(link.pattern.prefix(60))\" isn't a valid regular expression.")
            }
            if !commandIDs.contains(link.command) {
                found.append("A link handler names the command \"\(link.command)\", which this mod doesn't declare.")
            }
        }

        if let service, !Self.isProgram(service.run) { found.append("\"service.run\" must be a non-empty list of arguments.") }
        return found
    }

    /// Reads and checks `mod.json` in `directory`.
    static func load(from directory: URL, goviVersion: String? = nil) throws -> GoviModManifest {
        let file = directory.appendingPathComponent(fileName)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileSize else { throw GoviModError("\(fileName) is larger than 256 KB.") }
        guard let data = try? Data(contentsOf: file) else { throw GoviModError("There is no readable \(fileName) in this folder.") }
        return try parse(data, goviVersion: goviVersion)
    }

    static func parse(_ data: Data, goviVersion: String? = nil) throws -> GoviModManifest {
        let manifest: GoviModManifest
        do {
            manifest = try JSONDecoder().decode(GoviModManifest.self, from: data)
        } catch let error as DecodingError {
            throw GoviModError("\(fileName) couldn't be read: \(describe(error))")
        } catch {
            throw GoviModError("\(fileName) isn't valid JSON.")
        }
        let problems = manifest.problems(goviVersion: goviVersion)
        guard problems.isEmpty else { throw GoviModError(problems.joined(separator: "\n")) }
        return manifest
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "the top level" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case .keyNotFound(let key, let context): return "\"\(key.stringValue)\" is missing at \(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "the value at \(path(context)) has the wrong type."
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "it isn't valid JSON." : "the value at \(path(context)) is invalid."
        @unknown default: return "it isn't a valid manifest."
        }
    }
}

/// Mod shortcuts are written as `cmd+shift+e`.
enum GoviModShortcut {
    static func chord(_ text: String) -> GoviKeyChord? {
        let words = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let key = words.last, !key.isEmpty, words.count >= 2 else { return nil }
        var modifiers = 0
        for word in words.dropLast() {
            switch word {
            case "ctrl", "control": modifiers |= 1
            case "alt", "opt", "option": modifiers |= 2
            case "shift": modifiers |= 4
            case "cmd", "command", "super": modifiers |= 8
            default: return nil
            }
        }
        let chord = GoviKeyChord(key: key, modifiers: modifiers)
        return chord.isValid && !chord.isReserved ? chord : nil
    }
}

enum GoviModVersion {
    /// Compares dotted numbers; missing or non-numeric parts count as zero.
    static func isAtLeast(_ current: String, _ required: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let have = parts(current)
        let need = parts(required)
        for index in 0..<max(have.count, need.count) {
            let left = index < have.count ? have[index] : 0
            let right = index < need.count ? need[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}

enum GoviModPaths {
    /// The file a page path names, or nil when it would leave `root` (also through a symbolic link).
    static func file(_ path: String, in root: URL) -> URL? {
        guard GoviModManifest.isPagePath(path), !path.contains("?") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return file.path.hasPrefix(prefix) ? file : nil
    }

    /// A folder name for a mod made from a person's title, e.g. "My Mod!" → "my-mod".
    static func slug(_ name: String) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return String(slug.prefix(48))
    }
}

/// A mod's web pane in a saved layout. The page's own state is whatever JSON
/// text it handed to `govi.setState`; nothing else about the page is kept.
struct GoviModPaneRecord: Codable, Equatable, Identifiable {
    static let maxStateSize = 64 * 1024
    var id: UUID
    var mod: String
    var pane: String
    var title: String
    var directory: String?
    var state: String?

    var isValid: Bool {
        let short = { (text: String) in !text.isEmpty && text.utf8.count <= 64 && !text.contains("\0") }
        guard short(mod), short(pane), title.utf8.count < 4096, (state ?? "").utf8.count <= Self.maxStateSize else { return false }
        guard let directory else { return true }
        return directory.hasPrefix("/") && !directory.contains("\0") && directory.utf8.count < 4096
    }
}

/// The files `govi mod new` writes: a small working mod to start from.
enum GoviModTemplate {
    static func files(id: String, name: String) -> [String: String] {
        let manifest: [String: Any] = [
            "id": id, "name": name, "version": "0.1.0",
            "description": "A starting point: a web pane, a palette command and a script.",
            "panes": [["id": "main", "title": name, "icon": "puzzlepiece.extension", "page": "ui/index.html"]],
            "commands": [
                ["id": "open", "title": "Open \(name)", "description": "Open this mod's pane beside the focused pane.", "pane": "main"],
                ["id": "hello", "title": "Say Hello in the Terminal", "run": ["./hello.sh"]],
            ],
        ]
        let json =
            (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["mod.json": json + "\n", "hello.sh": script, "ui/index.html": page(name)]
    }

    /// Paths in `files` that must be executable.
    static let executables: Set<String> = ["hello.sh"]

    private static let script = """
        #!/bin/sh
        # Runs with the mod's folder as the working directory. `govi` talks to the
        # app; with no --pane it acts on the pane that was focused.
        govi send "echo 'Hello from the $GOVI_MOD_ID mod'"

        """

    private static func page(_ name: String) -> String {
        let title = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
            <!doctype html>
            <meta charset="utf-8">
            <title>\(title)</title>
            <style>
              body { margin: 0; padding: 20px; font: 13px -apple-system, sans-serif; }
              button { font: inherit; padding: 4px 10px; }
              pre { white-space: pre-wrap; opacity: 0.8; }
            </style>
            <h3>\(title)</h3>
            <p>Edit <code>ui/index.html</code> in this mod's folder; the pane reloads when you save.</p>
            <button id="list">List panes</button>
            <button id="date">Run <code>date</code></button>
            <pre id="out"></pre>
            <script>
              const out = document.getElementById("out");
              const show = (value) => { out.textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2); };
              const paint = (theme) => {
                document.body.style.background = theme.background;
                document.body.style.color = theme.foreground;
              };
              paint(govi.theme);
              govi.on("theme", paint);
              // Any control method works here: the same ones the `govi` command uses.
              document.getElementById("list").onclick = () => govi.call("panes.list").then(show, (error) => show(String(error)));
              // Run a program on this Mac, from the mod's folder.
              document.getElementById("date").onclick = () => govi.exec(["date"]).then((result) => show(result.output));
              // Keep a little state across relaunches.
              const state = govi.getState() || { opened: 0 };
              govi.setState({ opened: state.opened + 1 });
              govi.setTitle(document.title + " · opened " + (state.opened + 1) + "×");
            </script>

            """
    }
}
