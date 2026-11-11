// govi — control Govi's panes, terminals and browser panes from a shell, a
// script or an agent. `govi mcp` serves the same commands over MCP (stdio).
//
// It talks to the running app over the control socket that every Govi shell
// gets as $GOVI_CONTROL_SOCKET. Built by govi/build.sh into Govi.app's
// Contents/MacOS, which Govi puts on each shell's PATH.

import Darwin
import Foundation

let version = "1"

// MARK: - Control socket client

struct GoviFailure: Error {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}

enum Client {
    static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["GOVI_CONTROL_SOCKET"], !path.isEmpty { return path }
        return NSHomeDirectory() + "/Library/Application Support/Govi/control.sock"
    }

    static var caller: String? {
        ProcessInfo.processInfo.environment["GOVI_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Sends one request and returns its result, or throws Govi's error message.
    static func call(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        var request: [String: Any] = ["method": method, "params": params]
        if let caller { request["caller"] = caller }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)

        let path = socketPath
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GoviFailure("Couldn't create a socket.", code: 3) }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 100, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw GoviFailure("The socket path is too long: \(path)", code: 3)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes + [0]) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            throw GoviFailure("Govi isn't running, or its control socket isn't at \(path).", code: 3)
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { throw GoviFailure("Govi closed the connection.", code: 3) }
                offset += written
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<count])
            if buffer[count - 1] == 10 { break }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] else {
            throw GoviFailure(response.isEmpty ? "Govi didn't answer." : "Govi sent a reply this govi can't read.")
        }
        if object["ok"] as? Bool == true { return object["result"] ?? NSNull() }
        throw GoviFailure(object["error"] as? String ?? "Govi reported an error.")
    }
}

// MARK: - Output

func json(_ value: Any, pretty: Bool = true) -> String {
    let options: JSONSerialization.WritingOptions =
        pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed] : [.withoutEscapingSlashes, .fragmentsAllowed]
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("govi: " + message + "\n").utf8))
}

func short(_ id: Any?) -> String { String((id as? String ?? "").prefix(8)).lowercased() }

func describePanes(_ panes: [[String: Any]]) -> String {
    guard !panes.isEmpty else { return "No panes are open." }
    var lines: [String] = []
    var workspace: String?
    for pane in panes {
        let name = pane["workspace"] as? String ?? ""
        if name != workspace {
            workspace = name
            lines.append((lines.isEmpty ? "" : "\n") + (name.isEmpty ? "Workspace" : name))
        }
        let marks = (pane["focused"] as? Bool == true ? "*" : " ") + (pane["self"] as? Bool == true ? ">" : " ")
        let kind = (pane["kind"] as? String ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
        let place = (pane["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pane["directory"] as? String ?? ""
        lines.append("\(marks)\(short(pane["id"]))  \(kind) \(pane["title"] as? String ?? "")\(place.isEmpty ? "" : "  — " + place)")
    }
    lines.append("\n* focused   > this pane")
    return lines.joined(separator: "\n")
}

func describeSnapshot(_ snapshot: [String: Any]) -> String {
    var lines = ["\(snapshot["title"] as? String ?? "")", "\(snapshot["url"] as? String ?? "")", ""]
    let elements = snapshot["elements"] as? [[String: Any]] ?? []
    lines.append(elements.isEmpty ? "No interactive elements." : "Elements (use the ref with `govi browser click` or `type`):")
    for element in elements {
        var line = "  [\(element["ref"] as? String ?? "")] \(element["role"] as? String ?? element["tag"] as? String ?? "")"
        if let type = element["type"] as? String { line += "(\(type))" }
        if let name = element["name"] as? String, !name.isEmpty { line += " \"\(name)\"" }
        if let value = element["value"] as? String, !value.isEmpty { line += " value=\"\(value)\"" }
        if let href = element["href"] as? String, !href.isEmpty { line += " → \(href)" }
        if element["checked"] as? Bool == true { line += " checked" }
        if element["disabled"] as? Bool == true { line += " disabled" }
        lines.append(line)
    }
    lines.append("")
    lines.append(snapshot["text"] as? String ?? "")
    if snapshot["truncated"] as? Bool == true { lines.append("… (text truncated; pass --max-text to see more)") }
    return lines.joined(separator: "\n")
}

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    /// Everything after a bare `--`.
    var rest: [String]?

    /// `valued` options take the next argument; anything else starting with
    /// `-` is a flag.
    init(_ arguments: [String], valued: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                rest = Array(arguments[index...])
                break
            }
            if argument.hasPrefix("-"), argument != "-", Double(argument) == nil {
                var name = argument
                var value: String?
                if let equals = argument.firstIndex(of: "=") {
                    name = String(argument[..<equals])
                    value = String(argument[argument.index(after: equals)...])
                }
                if valued.contains(name) {
                    if value == nil {
                        guard index < arguments.count else { throw GoviFailure("\(name) needs a value.", code: 2) }
                        value = arguments[index]
                        index += 1
                    }
                    options[name] = value
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
        }
    }

    func has(_ names: String...) -> Bool { names.contains(where: flags.contains) }
    func value(_ names: String...) -> String? { names.lazy.compactMap { options[$0] }.first }
}

func readStandardInput() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

/// `e12` is a snapshot ref; anything else is a CSS selector.
func target(_ text: String) -> [String: Any] {
    let isRef = text.first == "e" && text.count > 1 && text.dropFirst().allSatisfy(\.isNumber)
    return isRef ? ["ref": text] : ["selector": text]
}

func direction(_ arguments: Arguments) -> String {
    if arguments.has("--down", "-d") { return "down" }
    if arguments.has("--up") { return "up" }
    if arguments.has("--left") { return "left" }
    return "right"
}

let usage = """
    govi — control Govi from the shell or an agent

    Panes
      govi panes                         List panes (* focused, > this pane)
      govi focus PANE                    Focus a pane (ID or first 4+ characters)
      govi split [--down] [--cwd DIR] [--focus] [-- COMMAND...]
                                         Open a terminal beside this pane, optionally running COMMAND
      govi close [PANE] [--force]        Close a pane (asks first if a program is running)
      govi zoom [PANE]                   Zoom a pane, or restore the layout

    Terminals (default: this pane)
      govi send [--pane P] [--enter] TEXT...   Type TEXT into a terminal ("-" reads stdin)
      govi read [--pane P] [--scrollback] [--lines N]
                                               Print what a terminal shows

    Browser panes (default: the browser in this workspace, else the latest)
      govi browser open [URL] [--down] [--focus]   Open a browser pane beside this pane
      govi browser go URL                          Navigate and wait for the page to load
      govi browser back | forward | reload
      govi browser snapshot [--max-text N]         Page text plus interactive elements with refs
      govi browser click REF|SELECTOR              Click an element (ref like e3, or CSS)
      govi browser type REF|SELECTOR TEXT [--submit]
      govi browser eval SCRIPT                     Run JavaScript and print the value ("-" reads stdin)
      govi browser screenshot [--out FILE]         Save a PNG of the page
      govi browser console [--clear]               Recent console output and errors
      Browser commands take --pane P to pick a browser pane.

    Other
      govi mcp                           Serve these commands to an agent over MCP (stdio)
      govi hello                         Check the connection
      --json                             Print Govi's raw JSON result

    Example: let Claude Code drive Govi
      claude mcp add govi -- govi mcp
    """

// MARK: - Commands

func run(_ argv: [String]) throws -> Int32 {
    guard let command = argv.first else {
        print(usage)
        return 0
    }
    let valued: Set<String> = ["--pane", "-p", "--cwd", "--lines", "-n", "--out", "-o", "--max-text", "--timeout", "--selector", "--url"]
    var arguments = try Arguments(Array(argv.dropFirst()), valued: valued)
    let raw = arguments.has("--json")
    let pane = arguments.value("--pane", "-p")

    func send(_ method: String, _ params: [String: Any], show: (Any) -> String) throws -> Int32 {
        var params = params
        if let pane, params["pane"] == nil { params["pane"] = pane }
        let result = try Client.call(method, params)
        print(raw ? json(result) : show(result))
        return 0
    }
    func paneLine(_ result: Any) -> String {
        guard let info = result as? [String: Any] else { return json(result) }
        return "\(short(info["id"] ?? info["pane"]))  \(info["kind"] as? String ?? "")  \(info["title"] as? String ?? "")"
    }
    func pageLine(_ result: Any) -> String {
        guard let info = result as? [String: Any] else { return json(result) }
        let problem = (info["problem"] as? String).map { "\n" + $0 } ?? ""
        return "\(info["title"] as? String ?? "")\n\(info["url"] as? String ?? "")\(problem)"
    }

    switch command {
    case "help", "-h", "--help":
        print(usage)
        return 0
    case "version", "--version", "-v":
        print("govi \(version)")
        return 0
    case "mcp":
        MCPServer().serve()
        return 0
    case "hello":
        return try send("hello", [:]) { result in
            let info = result as? [String: Any] ?? [:]
            return "Connected to Govi \(info["version"] as? String ?? "") at \(Client.socketPath)"
        }
    case "panes", "ls", "list":
        return try send("panes.list", [:]) { describePanes($0 as? [[String: Any]] ?? []) }
    case "focus":
        guard let id = arguments.positional.first ?? pane else { throw GoviFailure("Say which pane, e.g. `govi focus 3fa2`.", code: 2) }
        return try send("pane.focus", ["pane": id], show: paneLine)
    case "close":
        var params: [String: Any] = ["force": arguments.has("--force", "-f")]
        if let id = arguments.positional.first { params["pane"] = id }
        return try send("pane.close", params) { result in
            (result as? [String: Any])?["askedToConfirm"] as? Bool == true
                ? "Govi asked in its window whether to close it (a program may be running). Use --force to close without asking." : ""
        }
    case "zoom":
        return try send("pane.zoom", arguments.positional.first.map { ["pane": $0] } ?? [:]) { result in
            (result as? [String: Any])?["zoomed"] as? Bool == true ? "Zoomed." : "Layout restored."
        }
    case "split":
        var params: [String: Any] = ["direction": direction(arguments), "focus": arguments.has("--focus")]
        if let cwd = arguments.value("--cwd") {
            params["cwd"] =
                URL(fileURLWithPath: cwd, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                .path
        }
        let commandWords = arguments.rest ?? arguments.positional
        if !commandWords.isEmpty { params["command"] = commandWords.joined(separator: " ") }
        return try send("pane.split", params, show: paneLine)
    case "send", "type":
        var text = arguments.positional.joined(separator: " ")
        if text == "-" { text = readStandardInput() }
        if let rest = arguments.rest { text = ([text] + rest).filter { !$0.isEmpty }.joined(separator: " ") }
        let enter = arguments.has("--enter", "-e")
        guard !text.isEmpty || enter else { throw GoviFailure("Give the text to send, e.g. `govi send --enter ls`.", code: 2) }
        return try send("terminal.send", ["text": text, "enter": enter]) { _ in "" }
    case "read":
        var params: [String: Any] = ["scope": arguments.has("--scrollback", "--screen", "-s") ? "scrollback" : "visible"]
        if let lines = arguments.value("--lines", "-n").flatMap(Int.init) { params["lines"] = lines }
        return try send("terminal.read", params) { ($0 as? [String: Any])?["text"] as? String ?? "" }
    case "browser", "b":
        arguments.positional = Array(arguments.positional)
        return try browser(arguments, send: send, pageLine: pageLine, paneLine: paneLine)
    default:
        throw GoviFailure("Unknown command \(command). Run `govi help`.", code: 2)
    }
}

func browser(
    _ arguments: Arguments, send: (String, [String: Any], (Any) -> String) throws -> Int32,
    pageLine: @escaping (Any) -> String, paneLine: @escaping (Any) -> String
) throws -> Int32 {
    var words = arguments.positional
    guard !words.isEmpty else { throw GoviFailure("Say what to do, e.g. `govi browser open localhost:3000`. Run `govi help`.", code: 2) }
    let action = words.removeFirst()
    var timeout: [String: Any] = [:]
    if let seconds = arguments.value("--timeout").flatMap(Double.init) { timeout["timeout"] = seconds }
    func targetParams() throws -> [String: Any] {
        if let selector = arguments.value("--selector") { return ["selector": selector] }
        guard !words.isEmpty else {
            throw GoviFailure("Give an element ref from `govi browser snapshot` (like e3) or a CSS selector.", code: 2)
        }
        return target(words.removeFirst())
    }

    switch action {
    case "open", "new":
        var params: [String: Any] = ["direction": direction(arguments), "focus": arguments.has("--focus")]
        if let url = words.first ?? arguments.value("--url") { params["url"] = url }
        return try send("browser.open", params, paneLine)
    case "go", "navigate", "goto":
        guard let url = words.first ?? arguments.value("--url") else {
            throw GoviFailure("Give an address, e.g. `govi browser go localhost:3000`.", code: 2)
        }
        return try send("browser.navigate", timeout.merging(["url": url]) { $1 }, pageLine)
    case "back", "forward", "reload":
        return try send("browser.\(action)", timeout, pageLine)
    case "snapshot", "snap", "look":
        var params: [String: Any] = [:]
        if let size = arguments.value("--max-text").flatMap(Int.init) { params["maxText"] = size }
        return try send("browser.snapshot", params) { describeSnapshot($0 as? [String: Any] ?? [:]) }
    case "click":
        return try send("browser.click", try targetParams()) { result in
            let info = result as? [String: Any] ?? [:]
            return
                "Clicked \(info["clicked"] as? String ?? "element")\((info["text"] as? String).map { $0.isEmpty ? "" : " \"\($0)\"" } ?? "")."
        }
    case "type", "fill":
        var params = try targetParams()
        var text = words.joined(separator: " ")
        if text == "-" { text = readStandardInput() }
        params["text"] = text
        params["submit"] = arguments.has("--submit", "--enter", "-e")
        return try send("browser.type", params) { _ in "" }
    case "eval", "js":
        var script = words.joined(separator: " ")
        if script == "-" || (script.isEmpty && isatty(0) == 0) { script = readStandardInput() }
        guard !script.isEmpty else { throw GoviFailure("Give a script, e.g. `govi browser eval document.title`.", code: 2) }
        return try send("browser.eval", ["script": script]) { result in
            let value = (result as? [String: Any])?["result"] ?? NSNull()
            return value as? String ?? json(value)
        }
    case "screenshot", "shot":
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let out = arguments.value("--out", "-o") ?? words.first ?? "govi-screenshot-\(formatter.string(from: Date())).png"
        return try send("browser.screenshot", [:]) { result in
            guard let base64 = (result as? [String: Any])?["base64"] as? String, let data = Data(base64Encoded: base64) else {
                return "Govi didn't return a picture."
            }
            let url = URL(fileURLWithPath: out, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
            do {
                try data.write(to: url)
                return url.path
            } catch {
                return "Couldn't save \(url.path): \(error.localizedDescription)"
            }
        }
    case "console", "logs":
        return try send("browser.console", ["clear": arguments.has("--clear")]) { result in
            let entries = (result as? [String: Any])?["entries"] as? [[String: Any]] ?? []
            if entries.isEmpty { return "No console output." }
            return entries.map { "[\($0["level"] as? String ?? "log")] \($0["text"] as? String ?? "")" }.joined(separator: "\n")
        }
    default:
        throw GoviFailure("Unknown browser command \(action). Run `govi help`.", code: 2)
    }
}

// MARK: - MCP server (JSON-RPC 2.0 over newline-delimited stdio)

struct MCPTool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    /// Maps tool arguments to a control call.
    let call: ([String: Any]) -> (method: String, params: [String: Any])
}

func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }

let paneProperty = string("Pane ID or its first 4+ characters, from govi_panes. Omit for your own pane.")
let browserProperty = string("Browser pane ID or prefix. Omit for the browser in your workspace, else the most recent one.")
let directionProperty: [String: Any] = [
    "type": "string", "enum": ["right", "down", "left", "up"], "description": "Where the new pane goes. Default right.",
]
let targetProperties: [String: Any] = [
    "ref": string("Element ref from govi_browser_snapshot, like e3."),
    "selector": string("CSS selector, used when there's no ref."),
    "pane": browserProperty,
]

let tools: [MCPTool] = [
    MCPTool(
        name: "govi_panes",
        description:
            "List every Govi pane (terminals and browsers) with ID, kind, title, folder or URL, workspace, and whether it is focused or is your own pane.",
        properties: [:], required: []
    ) { _ in ("panes.list", [:]) },
    MCPTool(
        name: "govi_split",
        description:
            "Open a new terminal or browser pane beside a pane. A terminal can run a command (it stays open afterwards). The person's focus isn't moved unless focus is true.",
        properties: [
            "pane": paneProperty, "direction": directionProperty,
            "kind": ["type": "string", "enum": ["terminal", "browser"], "description": "Default terminal."],
            "command": string("Shell command for a new terminal, e.g. `npm run dev`."),
            "cwd": string("Folder for a new terminal. Default: the pane's folder."),
            "url": string("Address for a new browser pane, e.g. localhost:3000."),
            "focus": boolean("Move keyboard focus to the new pane."),
        ], required: []
    ) { ("pane.split", $0) },
    MCPTool(
        name: "govi_focus", description: "Bring a pane to the front and focus it.", properties: ["pane": paneProperty], required: ["pane"]
    ) { ("pane.focus", $0) },
    MCPTool(
        name: "govi_close",
        description:
            "Close a pane. Terminals running a program ask the person to confirm unless force is true; only force-close panes you opened.",
        properties: ["pane": paneProperty, "force": boolean("Close without asking, ending any running program.")], required: ["pane"]
    ) { ("pane.close", $0) },
    MCPTool(
        name: "govi_terminal_send",
        description: "Type text into a terminal pane, as if from the keyboard. Set enter to press Return afterwards (to run a command).",
        properties: ["pane": paneProperty, "text": string("Text to type."), "enter": boolean("Press Return after the text.")],
        required: ["text"]
    ) { ("terminal.send", $0) },
    MCPTool(
        name: "govi_terminal_read", description: "Read the text a terminal pane shows, or its scrollback.",
        properties: [
            "pane": paneProperty,
            "scope": ["type": "string", "enum": ["visible", "scrollback"], "description": "Default visible."],
            "lines": integer("Only the last N lines."),
        ], required: []
    ) { ("terminal.read", $0) },
    MCPTool(
        name: "govi_browser_open",
        description: "Open a browser pane in Govi beside a pane, optionally at an address. The person can see and use it too.",
        properties: [
            "url": string("Address, e.g. localhost:3000 or https://example.com."), "pane": paneProperty, "direction": directionProperty,
            "focus": boolean("Focus the new pane."),
        ],
        required: []
    ) { ("browser.open", $0) },
    MCPTool(
        name: "govi_browser_navigate", description: "Load an address in a browser pane and wait for it to finish loading.",
        properties: [
            "url": string("Address to load."), "pane": browserProperty, "timeout": integer("Seconds to wait, up to 60. Default 15."),
        ], required: ["url"]
    ) { ("browser.navigate", $0) },
    MCPTool(
        name: "govi_browser_history", description: "Go back, go forward or reload in a browser pane.",
        properties: ["action": ["type": "string", "enum": ["back", "forward", "reload"]], "pane": browserProperty], required: ["action"]
    ) { arguments in ("browser.\(arguments["action"] as? String ?? "reload")", arguments) },
    MCPTool(
        name: "govi_browser_snapshot",
        description:
            "Read a browser pane: URL, title, visible text, and its interactive elements, each with a ref for govi_browser_click and govi_browser_type. Take a new snapshot after the page changes.",
        properties: ["pane": browserProperty, "maxText": integer("Maximum characters of page text. Default 20000.")], required: []
    ) { ("browser.snapshot", $0) },
    MCPTool(
        name: "govi_browser_click", description: "Click an element in a browser pane by ref or CSS selector.", properties: targetProperties,
        required: []
    ) {
        ("browser.click", $0)
    },
    MCPTool(
        name: "govi_browser_type",
        description:
            "Fill a text field in a browser pane by ref or CSS selector, replacing its value. Set submit to press Enter / submit the form.",
        properties: targetProperties.merging(["text": string("Text to enter."), "submit": boolean("Submit after typing.")]) { $1 },
        required: ["text"]
    ) { ("browser.type", $0) },
    MCPTool(
        name: "govi_browser_eval",
        description:
            "Run JavaScript in a browser pane's page and return the result as JSON. Expressions return their value; for statements, use return. Promises are awaited.",
        properties: ["script": string("JavaScript to run."), "pane": browserProperty], required: ["script"]
    ) { ("browser.eval", $0) },
    MCPTool(
        name: "govi_browser_screenshot", description: "Take a screenshot of a browser pane.", properties: ["pane": browserProperty],
        required: []
    ) {
        ("browser.screenshot", $0)
    },
    MCPTool(
        name: "govi_browser_console", description: "Recent console messages and uncaught errors from a browser pane's page.",
        properties: ["pane": browserProperty, "clear": boolean("Clear the messages after reading.")], required: []
    ) { ("browser.console", $0) },
]

final class MCPServer {
    static let protocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let output = FileHandle.standardOutput

    func serve() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            // Notifications (no id) need no reply.
            guard let id = message["id"], let method = message["method"] as? String else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            do {
                send(["jsonrpc": "2.0", "id": id, "result": try handle(method, params)])
            } catch let failure as GoviFailure {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": failure.code == 2 ? -32602 : -32601, "message": failure.message]])
            } catch {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]])
            }
        }
    }

    func handle(_ method: String, _ params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.protocols.contains(requested) ? requested : Self.protocols[0],
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "govi", "version": version],
                "instructions":
                    "Controls the Govi terminal app you are running in: its panes, terminals and built-in browser panes. Use govi_panes to see what's open. To check a web app, open it with govi_browser_open, then use govi_browser_snapshot to read it and the ref values to click or type. Panes default to your own pane, and browser tools to the browser in your workspace.",
            ]
        case "ping":
            return [:] as [String: Any]
        case "tools/list":
            return [
                "tools": tools.map { tool in
                    [
                        "name": tool.name, "description": tool.description,
                        "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required] as [String: Any],
                    ] as [String: Any]
                }
            ]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                throw GoviFailure("Unknown tool \(params["name"] as? String ?? "").", code: 2)
            }
            let (control, arguments) = tool.call(params["arguments"] as? [String: Any] ?? [:])
            do {
                let result = try Client.call(control, arguments)
                if control == "browser.screenshot", let base64 = (result as? [String: Any])?["base64"] as? String {
                    return ["content": [["type": "image", "data": base64, "mimeType": "image/png"]]]
                }
                return ["content": [["type": "text", "text": text(for: control, result)]]]
            } catch let failure as GoviFailure {
                return ["content": [["type": "text", "text": failure.message]], "isError": true]
            }
        default:
            throw GoviFailure("Method not found: \(method)")
        }
    }

    /// Readable text where it helps the model; JSON otherwise.
    func text(for method: String, _ result: Any) -> String {
        switch method {
        case "browser.snapshot": return describeSnapshot(result as? [String: Any] ?? [:])
        case "terminal.read": return (result as? [String: Any])?["text"] as? String ?? ""
        case "browser.eval":
            let value = (result as? [String: Any])?["result"] ?? NSNull()
            return value as? String ?? json(value)
        default: return json(result)
        }
    }

    func send(_ message: [String: Any]) {
        var data = Data(json(message, pretty: false).utf8)
        data.append(10)
        output.write(data)
    }
}

// MARK: - Entry

signal(SIGPIPE, SIG_IGN)
do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch let failure as GoviFailure {
    printError(failure.message)
    exit(failure.code)
} catch {
    printError(error.localizedDescription)
    exit(1)
}
