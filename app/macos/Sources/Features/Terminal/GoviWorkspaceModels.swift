import Foundation
import Darwin

enum GoviDataPaths {
    /// Separate bundle identities (including local review builds) never share
    /// recovery checkpoints or the stable connection used by persistent shells.
    static var supportDirectory: URL {
        let identity = Bundle.main.bundleIdentifier ?? "dev.govi.terminal"
        let name = identity == "dev.govi.terminal" ? "Govi" : "Govi-" + identity
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/" + name, isDirectory: true)
    }
}

/// Launch intent is separate from terminal output and shell history. Recovery
/// restores shells; only an explicit template launch executes a saved command.
struct GoviPaneLaunch: Codable, Equatable {
    var agent: String?
    var tool: String?
    var command: String?
    var task: String?
    /// An SSH or tailnet host this pane connects to. Recovery keeps it so the
    /// pane can offer to reconnect; only an explicit action opens a connection.
    var remote: GoviRemoteTarget?
    /// Restore the reference, never the remote description or initial prompt.
    var issue: GoviTaskLink?
}

struct GoviTaskLink: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var provider: String
    var identifier: String
    var title: String
    var url: String
    var repository: String?
}

struct GoviPaneRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var directory: String
    var launch: GoviPaneLaunch
    var persistentName: String?
}

/// A browser pane. Only the address and title are kept: page content, cookies
/// and history are not, and only http, https and file addresses are written.
struct GoviWebPaneRecord: Codable, Equatable, Identifiable {
    static let maxURLLength = 8192
    var id: UUID
    /// Empty for a browser that never loaded a page.
    var url: String
    var title: String

    static func isAllowed(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= maxURLLength, let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme) && (scheme == "file" || url.host != nil)
    }

    var isValid: Bool {
        guard title.utf8.count < 4096 else { return false }
        return url.isEmpty || URL(string: url).map(Self.isAllowed) == true
    }
}

/// An editor pane: its folder, and the open file and line. Unsaved edits are
/// never written here; closing or quitting asks about them first.
struct GoviEditorPaneRecord: Codable, Equatable, Identifiable {
    var id: UUID
    /// The folder shown in the file tree.
    var root: String
    /// The open file, or empty.
    var file: String
    var line: Int

    var isValid: Bool {
        let path = { (text: String) in text.hasPrefix("/") && !text.contains("\0") && text.utf8.count < 4096 }
        return path(root) && (file.isEmpty || path(file)) && line >= 1 && line < 10_000_000
    }
}

indirect enum GoviWorkspaceLayout: Codable, Equatable {
    case terminal(GoviPaneRecord)
    case web(GoviWebPaneRecord)
    case editor(GoviEditorPaneRecord)
    /// A web pane that belongs to a mod.
    case mod(GoviModPaneRecord)
    case split(vertical: Bool, ratio: Double, first: GoviWorkspaceLayout, second: GoviWorkspaceLayout)

    /// Terminal panes, in layout order.
    var panes: [GoviPaneRecord] {
        switch self {
        case .terminal(let pane): return [pane]
        case .web, .editor, .mod: return []
        case .split(_, _, let first, let second): return first.panes + second.panes
        }
    }

    /// Browser panes, in layout order.
    var webPanes: [GoviWebPaneRecord] {
        switch self {
        case .terminal, .editor, .mod: return []
        case .web(let pane): return [pane]
        case .split(_, _, let first, let second): return first.webPanes + second.webPanes
        }
    }

    /// Editor panes, in layout order.
    var editorPanes: [GoviEditorPaneRecord] {
        switch self {
        case .terminal, .web, .mod: return []
        case .editor(let pane): return [pane]
        case .split(_, _, let first, let second): return first.editorPanes + second.editorPanes
        }
    }

    /// Every pane's ID, terminals and browsers alike.
    var paneIDs: [UUID] {
        switch self {
        case .terminal(let pane): return [pane.id]
        case .web(let pane): return [pane.id]
        case .editor(let pane): return [pane.id]
        case .mod(let pane): return [pane.id]
        case .split(_, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    /// Transforms terminal panes; other panes pass through unchanged.
    func replacingPanes(_ transform: (GoviPaneRecord) -> GoviPaneRecord) -> Self {
        switch self {
        case .terminal(let pane): return .terminal(transform(pane))
        case .web, .editor, .mod: return self
        case .split(let vertical, let ratio, let first, let second):
            return .split(
                vertical: vertical, ratio: ratio, first: first.replacingPanes(transform), second: second.replacingPanes(transform))
        }
    }

    func replacingModPanes(_ transform: (GoviModPaneRecord) -> GoviModPaneRecord) -> Self {
        switch self {
        case .terminal, .web, .editor: return self
        case .mod(let pane): return .mod(transform(pane))
        case .split(let vertical, let ratio, let first, let second):
            return .split(
                vertical: vertical, ratio: ratio, first: first.replacingModPanes(transform),
                second: second.replacingModPanes(transform))
        }
    }

    func replacingWebPanes(_ transform: (GoviWebPaneRecord) -> GoviWebPaneRecord) -> Self {
        switch self {
        case .terminal, .editor, .mod: return self
        case .web(let pane): return .web(transform(pane))
        case .split(let vertical, let ratio, let first, let second):
            return .split(
                vertical: vertical, ratio: ratio, first: first.replacingWebPanes(transform),
                second: second.replacingWebPanes(transform))
        }
    }

    func replacingEditorPanes(_ transform: (GoviEditorPaneRecord) -> GoviEditorPaneRecord) -> Self {
        switch self {
        case .terminal, .web, .mod: return self
        case .editor(let pane): return .editor(transform(pane))
        case .split(let vertical, let ratio, let first, let second):
            return .split(
                vertical: vertical, ratio: ratio, first: first.replacingEditorPanes(transform),
                second: second.replacingEditorPanes(transform))
        }
    }

    var isValid: Bool {
        let ids = paneIDs
        return validate(depth: 0) && !ids.isEmpty && ids.count <= 64 && Set(ids).count == ids.count
    }
    private func validate(depth: Int) -> Bool {
        guard depth < 32 else { return false }
        switch self {
        case .terminal(let pane):
            return pane.directory.hasPrefix("/") && !pane.directory.contains("\0") && pane.directory.utf8.count < 4096
        case .web(let pane):
            return pane.isValid
        case .editor(let pane):
            return pane.isValid
        case .mod(let pane):
            return pane.isValid
        case .split(_, let ratio, let first, let second):
            return ratio.isFinite && ratio >= 0.05 && ratio <= 0.95 && first.validate(depth: depth + 1) && second.validate(depth: depth + 1)
        }
    }

    /// Templates always create new programs and IDs, never attach to the source.
    func freshInstance() -> Self {
        replacingPanes { pane in
            var copy = pane
            copy.id = UUID()
            copy.persistentName = nil
            return copy
        }.replacingWebPanes { pane in
            var copy = pane
            copy.id = UUID()
            return copy
        }.replacingEditorPanes { pane in
            var copy = pane
            copy.id = UUID()
            return copy
        }.replacingModPanes { pane in
            var copy = pane
            copy.id = UUID()
            return copy
        }
    }
}

struct GoviWorkspaceRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var layout: GoviWorkspaceLayout
    var focusedPane: UUID?
    var group: Int
    var frame: [Double]
}

struct GoviRecoveryCheckpoint: Codable, Equatable {
    /// Version 2 adds browser panes, version 3 editor panes and version 4 mod panes. Older
    /// checkpoints still load; an older Govi rejects a newer version rather
    /// than misreading it.
    static let currentVersion = 4
    var version = Self.currentVersion
    var savedAt = Date()
    var workspaces: [GoviWorkspaceRecord]
    var isValid: Bool {
        (1...Self.currentVersion).contains(version) && workspaces.count <= 64 && workspaces.allSatisfy { $0.layout.isValid }
            && Set(workspaces.flatMap(\.layout.paneIDs)).count == workspaces.reduce(0) { $0 + $1.layout.paneIDs.count }
    }
}

struct GoviWorkspaceTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var layout: GoviWorkspaceLayout
}

enum GoviShell {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static let agentExitStatus =
        "govi_exit=$?; if [ -n \"$GOVI_NOTIFY\" ]; then if [ \"$govi_exit\" -ne 0 ]; then /bin/zsh -f \"$GOVI_NOTIFY\" error; else /bin/zsh -f \"$GOVI_NOTIFY\" idle; fi; fi; "
}

/// Shared with the reconnect regression: the script under test is the script
/// launched by production panes.
enum GoviSessionScript {
    static func make(
        hc: String, name: String, id: UUID, shell: String, directory: String,
        program: String, assignments: String, socket: String, restoring: Bool, version: Int
    ) -> String {
        let q = GoviShell.quote
        let reportSocket = socket
        let script = """
            hc=\(q(hc)); n=\(q(name))
            own() { "$hc" get --json "$n" 2>/dev/null | /usr/bin/grep -Eq '"govi"[[:space:]]*:[[:space:]]*"1"'; }
            live() { "$hc" get --json "$n" 2>/dev/null | /usr/bin/grep -Eq '"state"[[:space:]]*:[[:space:]]*"live"'; }
            report() { printf 'P\\t0\\t{"id":"\(id.uuidString)","live":%s,"recovered":%s}\\n' "$1" "$2" | /usr/bin/nc -w 1 -U \(q(reportSocket)) >/dev/null 2>&1; }
            recovered=false
            if ! live; then
              own && "$hc" rm "$n" >/dev/null 2>&1
              if ! "$hc" run --bg --keep --no-parent --name "$n" --label govi=1 --label goviv=\(version) --cwd \(q(directory)) -- env \(assignments) \(program) >/dev/null 2>&1; then
                report false \(restoring ? "true" : "false")
                printf '\\033[2mGovi could not keep this terminal running in the background. This shell will close when Govi quits.\\033[0m\\r\\n'
                exec \(q(shell)) -l
              fi
              recovered=\(restoring ? "true" : "false")
            elif ! own; then
              report false true
              printf 'Govi could not reconnect to its saved session. Opening a fresh shell.\\r\\n'
              exec \(q(shell)) -l
            fi
            report true "$recovered"
            while live; do "$hc" attach --history 5000 "$n" || sleep 1; done
            report false true
            exec \(q(shell)) -l
            """
        return "/bin/sh -c " + q(script)
    }
}

enum GoviActivityState: String, Codable, Equatable {
    case idle, working, needsInput, done, error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .done: "Done"
        case .error: "Error"
        }
    }
    /// States the user hasn't seen yet. These count toward the Dock badge.
    var wantsAttention: Bool { self == .needsInput || self == .done || self == .error }
}

struct GoviActivitySignal: Decodable {
    let id: UUID
    let state: GoviActivityState
    let label: String?
    static func decode(_ value: String) -> Self? {
        guard value.utf8.count <= 2048, let data = value.data(using: .utf8),
            let signal = try? JSONDecoder().decode(Self.self, from: data),
            signal.label.map({ $0.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true
        else { return nil }
        return signal
    }
}

/// Explicit events are authoritative until the next reported transition. Seeing
/// a finished item acknowledges it without allowing a stale spinner to revive it.
struct GoviReportedActivity: Equatable {
    var state: GoviActivityState = .idle
    var startedAt: Date?
    var endedAt: Date?
    var changedAt = Date()
    var acknowledged = false
    var visibleState: GoviActivityState { state.wantsAttention && acknowledged ? .idle : state }
    mutating func receive(_ next: GoviActivityState, now: Date = Date()) {
        guard next != state else { return }
        if next == .working && state != .working && state != .needsInput {
            startedAt = now
            endedAt = nil
        }
        if next == .done || next == .error { endedAt = now }
        if next != state { changedAt = now }
        state = next
        acknowledged = false
    }
    mutating func acknowledge() { if state.wantsAttention { acknowledged = true } }
}

enum GoviClaudeHooks {
    /// Per-session hooks merge with the user's existing hooks. No permission,
    /// model, tool or startup-file settings are changed by this payload.
    static var settingsJSON: String {
        let events: [String: (String, String?)] = [
            "UserPromptSubmit": ("working", nil), "PreToolUse": ("working", ""),
            "PostToolUse": ("working", ""), "PermissionRequest": ("needsInput", ""),
            "Notification": ("needsInput", "permission_prompt|idle_prompt"),
            "Stop": ("done", nil), "SessionEnd": ("idle", nil),
        ]
        var hooks: [String: Any] = [:]
        for (event, value) in events {
            let command = "if [ -n \"$GOVI_NOTIFY\" ]; then /bin/zsh -f \"$GOVI_NOTIFY\" " + value.0 + "; fi"
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 2]]]
            if let matcher = value.1 { group["matcher"] = matcher }
            hooks[event] = [group]
        }
        // Only strings, numbers and nested containers, so encoding cannot fail;
        // an empty hook set is the safe fallback all the same.
        guard let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys]) else {
            return #"{"hooks":{}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct GoviKeyChord: Codable, Hashable {
    var key: String
    /// Control, Option, Shift, Command, in that order.
    var modifiers: Int
    static let characters: [String: String] = [
        "comma": ",", "period": ".", "slash": "/", "semicolon": ";", "quote": "'", "bracket_left": "[", "bracket_right": "]",
        "backslash": "\\", "minus": "-", "equal": "=", "backquote": "`", "enter": "\r", "space": " ", "tab": "\t", "arrow_left": "\u{f702}",
        "arrow_right": "\u{f703}", "arrow_up": "\u{f700}", "arrow_down": "\u{f701}",
    ]
    var character: String { Self.characters[key] ?? key }
    var isValid: Bool {
        let validKey =
            (key.count == 1 && key.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }) || Self.characters[key] != nil
        return validKey && modifiers >= 1 && modifiers < 16 && modifiers & 9 != 0
    }
    var binding: String {
        var pieces: [String] = []
        for (mask, word) in [(1, "ctrl"), (2, "alt"), (4, "shift"), (8, "super")] where modifiers & mask != 0 { pieces.append(word) }
        pieces.append(key)
        return pieces.joined(separator: "+")
    }
    var symbols: [String] {
        var pieces: [String] = []
        for (mask, word) in [(1, "⌃"), (2, "⌥"), (4, "⇧"), (8, "⌘")] where modifiers & mask != 0 { pieces.append(word) }
        pieces.append(
            ["enter": "⏎", "space": "␣", "tab": "⇥", "arrow_left": "◀", "arrow_right": "▶", "arrow_up": "▲", "arrow_down": "▼"][key]
                ?? character.uppercased())
        return pieces
    }
    var display: String { symbols.joined() }
    var isReserved: Bool {
        if modifiers == 8 && ["q", "h", "m", "c", "v", "x", "a", "z", "tab", "space", "equal", "minus", "0"].contains(key) { return true }
        if modifiers == 12 && ["z", "h", "tab", "equal"].contains(key) { return true }
        if modifiers == 10 && ["h", "space"].contains(key) { return true }
        if modifiers == 9 && key == "f" { return true }
        if modifiers == 1 && ["c", "d", "z", "space"].contains(key) { return true }
        return false
    }
}

enum GoviShortcutAction: String, CaseIterable, Identifiable, Codable {
    case newWorkspace, newWindow, closeTerminal, splitRight, splitDown, zoom, left, right, up, down, palette
    case find, search, settings, focusMode, sidebar, attention, nextAttention, templates, remoteHosts, browser, editor, quickLook
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newWorkspace: "New workspace"
        case .newWindow: "New window"
        case .closeTerminal: "Close terminal"
        case .splitRight: "Split right"
        case .splitDown: "Split below"
        case .zoom: "Zoom focused terminal"
        case .left: "Focus left terminal"
        case .right: "Focus right terminal"
        case .up: "Focus terminal above"
        case .down: "Focus terminal below"
        case .palette: "Command palette"
        case .find: "Find in output"
        case .search: "Search terminals"
        case .settings: "Settings"
        case .focusMode: "Focus mode"
        case .sidebar: "Toggle sidebar"
        case .attention: "Needs attention"
        case .nextAttention: "Next terminal needing attention"
        case .templates: "Project templates"
        case .remoteHosts: "Remote hosts"
        case .browser: "Open browser pane"
        case .editor: "Open editor pane"
        case .quickLook: "Quick Look links"
        }
    }
    var defaultChord: GoviKeyChord {
        let pair: (String, Int) =
            switch self {
            case .newWorkspace: ("t", 8)
            case .newWindow: ("n", 8)
            case .closeTerminal: ("w", 8)
            case .splitRight: ("d", 8)
            case .splitDown: ("d", 12)
            case .zoom: ("enter", 12)
            case .left: ("arrow_left", 10)
            case .right: ("arrow_right", 10)
            case .up: ("arrow_up", 10)
            case .down: ("arrow_down", 10)
            case .palette: ("k", 8)
            case .find: ("f", 8)
            case .search: ("p", 8)
            case .settings: ("comma", 8)
            case .focusMode: ("f", 12)
            case .sidebar: ("s", 10)
            case .attention: ("a", 12)
            case .nextAttention: ("j", 10)
            case .templates: ("t", 10)
            case .remoteHosts: ("r", 12)
            case .browser: ("b", 12)
            case .editor: ("e", 12)
            case .quickLook: ("y", 8)
            }
        return .init(key: pair.0, modifiers: pair.1)
    }
    var terminalAction: String? {
        switch self {
        case .newWorkspace: "new_tab"
        case .newWindow: "new_window"
        case .closeTerminal: "close_surface"
        case .splitRight: "new_split:right"
        case .splitDown: "new_split:down"
        case .zoom: "toggle_split_zoom"
        case .left: "goto_split:left"
        case .right: "goto_split:right"
        case .up: "goto_split:up"
        case .down: "goto_split:down"
        case .palette: "toggle_command_palette"
        default: nil
        }
    }
}

enum GoviShortcutPreferences {
    static func load() -> [String: GoviKeyChord] {
        guard let data = UserDefaults.standard.data(forKey: "GoviShortcutsV1"),
            let values = try? JSONDecoder().decode([String: GoviKeyChord].self, from: data)
        else { return [:] }
        return values.filter { GoviShortcutAction(rawValue: $0.key) != nil && $0.value.isValid && !$0.value.isReserved }
    }
    static func chord(_ action: GoviShortcutAction, values: [String: GoviKeyChord]) -> GoviKeyChord {
        values[action.rawValue] ?? action.defaultChord
    }
    static func conflict(_ chord: GoviKeyChord, for action: GoviShortcutAction, values: [String: GoviKeyChord]) -> String? {
        guard chord.isValid else { return "Use Command or Control with a letter, number, punctuation, arrow, Return, Space or Tab." }
        guard !chord.isReserved else { return "This combination is reserved for macOS, text editing or terminal control." }
        for other in GoviShortcutAction.allCases where other != action {
            if Self.chord(other, values: values) == chord { return "Already assigned to \(other.title). Change that shortcut first." }
        }
        return nil
    }
    static func configuration(values: [String: GoviKeyChord]) -> String {
        var lines: [String] = []
        for action in GoviShortcutAction.allCases where values[action.rawValue] != nil {
            lines.append("keybind = \(action.defaultChord.binding)=unbind")
            if action == .palette { lines.append("keybind = super+shift+p=unbind") }
        }
        // Clear first, then assign, so an old shortcut may be reused safely.
        for action in GoviShortcutAction.allCases {
            let binding = Self.chord(action, values: values).binding
            lines.append("keybind = \(binding)=\(action.terminalAction ?? "unbind")")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
