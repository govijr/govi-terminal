import AppKit
import Darwin

/// The local control socket behind the `govi` command and its MCP server.
///
/// Each connection carries one request line and one response line, both JSON:
/// `{"method": "...", "params": {...}, "caller": "<GOVI_SESSION_ID>"}` →
/// `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`.
///
/// The socket lives in Govi's private support folder (0700), is itself 0600,
/// and only accepts peers running as the same user. That is the same trust as
/// the person's own shell, which can already type into any pane.
final class GoviControlServer {
    static let shared = GoviControlServer()
    static let environmentKey = "GOVI_CONTROL_SOCKET"
    /// A request line larger than this is rejected; scripts and text fit easily.
    static let maxRequest = 4 << 20

    private(set) var path: String?
    private var listener: DispatchSourceRead?
    private let accept = DispatchQueue(label: "dev.govi.control.accept")
    private let work = DispatchQueue(label: "dev.govi.control.work", attributes: .concurrent)
    /// Bounds concurrent requests so a misbehaving client can't pile up threads.
    private let slots = DispatchSemaphore(value: 16)

    /// Starts listening if needed and returns the socket path for shells.
    @discardableResult
    func start() -> String? {
        if let path { return path }
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        var folder = GoviDataPaths.supportDirectory
        if folder.appendingPathComponent("control.sock").path.utf8.count >= limit {
            // Long home folders overflow sun_path; the per-user temporary folder is short.
            folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("govi-\(Bundle.main.bundleIdentifier ?? "app")".prefix(40).description)
        }
        let path = folder.appendingPathComponent("control.sock").path
        guard path.utf8.count < limit else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            return nil
        }
        // A previous Govi instance's socket is stale once that instance quits;
        // the newest instance takes over the stable path.
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 32) == 0 else {
            close(descriptor)
            unlink(path)
            return nil
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: accept)
        source.setEventHandler { [weak self] in
            while true {
                let peer = Darwin.accept(descriptor, nil, nil)
                if peer < 0 { return }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(peer, &uid, &gid) == 0, uid == geteuid() else {
                    close(peer)
                    continue
                }
                self?.serve(peer)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        listener = source
        self.path = path
        return path
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let path { unlink(path) }
        path = nil
    }

    private func serve(_ peer: Int32) {
        guard slots.wait(timeout: .now()) == .success else {
            Self.reply(peer, ["ok": false, "error": "Govi is busy; try again."])
            close(peer)
            return
        }
        work.async { [slots] in
            defer {
                close(peer)
                slots.signal()
            }
            _ = fcntl(peer, F_SETFD, FD_CLOEXEC)
            // Accepted sockets inherit the listener's O_NONBLOCK; large replies
            // such as screenshots need blocking writes (bounded by SO_SNDTIMEO).
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) & ~O_NONBLOCK)
            var enabled: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let line = Self.readLine(peer) else {
                Self.reply(peer, ["ok": false, "error": "The request was empty, too large or timed out."])
                return
            }
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                let method = request["method"] as? String
            else {
                Self.reply(peer, ["ok": false, "error": "The request was not valid JSON with a method."])
                return
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let caller = (request["caller"] as? String).flatMap(UUID.init(uuidString:))
            let done = DispatchSemaphore(value: 0)
            var response: [String: Any] = [:]
            Task { @MainActor in
                do {
                    let result = try await GoviControl.handle(method, params: params, caller: caller)
                    response = ["ok": true, "result": result]
                } catch {
                    response = ["ok": false, "error": (error as? GoviControlError)?.message ?? error.localizedDescription]
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 90) == .timedOut {
                response = ["ok": false, "error": "Govi didn't answer within 90 seconds."]
            }
            Self.reply(peer, response)
        }
    }

    private static func readLine(_ peer: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= maxRequest {
            let count = read(peer, &buffer, buffer.count)
            if count <= 0 { return data.isEmpty ? nil : data }
            if let newline = buffer[0..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return nil
    }

    private static func reply(_ peer: Int32, _ object: [String: Any]) {
        var data =
            (try? JSONSerialization.data(withJSONObject: GoviControl.jsonSafe(object), options: [.withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"error":"Govi could not encode the response."}"#.utf8)
        data.append(10)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(peer, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

struct GoviControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Request handlers. Everything here runs on the main actor, like the UI.
@MainActor
enum GoviControl {
    static let protocolVersion = 1
    static let methods = [
        "hello", "panes.list", "pane.focus", "pane.split", "pane.close", "pane.zoom",
        "terminal.send", "terminal.read",
        "browser.open", "browser.navigate", "browser.back", "browser.forward", "browser.reload",
        "browser.snapshot", "browser.click", "browser.type", "browser.eval", "browser.screenshot", "browser.console",
    ]

    static func handle(_ method: String, params: [String: Any], caller: UUID?) async throws -> Any {
        switch method {
        case "hello":
            return [
                "app": "Govi", "protocol": protocolVersion, "methods": methods,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            ]
        case "panes.list":
            return TerminalController.all.flatMap { controller in controller.surfaceTree.map { describe($0, in: controller, caller: caller) } }
        case "pane.focus":
            let (controller, pane) = try find(params["pane"], caller: caller)
            focus(pane, in: controller)
            return describe(pane, in: controller, caller: caller)
        case "pane.split":
            return try split(params, caller: caller)
        case "pane.close":
            let (controller, pane) = try find(params["pane"], caller: caller)
            guard let node = controller.surfaceTree.root?.node(view: pane) else { throw GoviControlError("That pane closed.") }
            // Terminals with a running program ask the person first unless
            // the caller explicitly forces it.
            let force = params["force"] as? Bool == true
            let persistent = GoviPersistence.isPersistent(pane.id)
            let asks = !force && (pane.paneNeedsConfirmClose || persistent)
            // A forced close ends a persistent pane's program instead of orphaning it.
            if force && persistent { GoviPersistence.endPanes([pane.id]) }
            controller.closeSurface(node, withConfirmation: !force)
            return ["pane": pane.id.uuidString, "closed": !asks, "askedToConfirm": asks]
        case "pane.zoom":
            let (controller, pane) = try find(params["pane"], caller: caller)
            guard let node = controller.surfaceTree.root?.node(view: pane) else { throw GoviControlError("That pane closed.") }
            controller.toggleZoom(node, focus: pane)
            return ["pane": pane.id.uuidString, "zoomed": controller.surfaceTree.zoomed != nil]

        case "terminal.send":
            let surface = try terminal(params["pane"], caller: caller)
            guard let text = params["text"] as? String else { throw GoviControlError("Give the text to send.") }
            guard let model = surface.surfaceModel else { throw GoviControlError("That terminal isn't running.") }
            if !text.isEmpty { model.sendText(text) }
            if params["enter"] as? Bool == true {
                // Text arrives as a paste; Return has to be a key press to run it.
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r", unshiftedCodepoint: 13))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
            return ["pane": surface.id.uuidString, "sent": text.count]
        case "terminal.read":
            let surface = try terminal(params["pane"], caller: caller)
            let scrollback = (params["scope"] as? String) == "scrollback"
            var text = scrollback ? surface.cachedScreenContents.get() : surface.cachedVisibleContents.get()
            // The rows below the prompt are blank; drop them so `lines` counts output.
            var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacing(/\s+$/, with: "") }
            while rows.last?.isEmpty == true { rows.removeLast() }
            if let lines = params["lines"] as? Int, lines > 0 { rows = Array(rows.suffix(lines)) }
            text = rows.joined(separator: "\n")
            return ["pane": surface.id.uuidString, "title": surface.paneTitle, "directory": surface.pwd ?? "", "text": text]

        case "browser.open":
            var split = params
            split["kind"] = "browser"
            return try self.split(split, caller: caller)
        case "browser.navigate":
            let web = try browser(params["pane"], caller: caller)
            guard let address = params["url"] as? String, web.load(address) else {
                throw GoviControlError(web.problem ?? "Give a web address, such as localhost:3000.")
            }
            try await web.waitForLoad(timeout: timeout(params))
            return web.summary
        case "browser.back", "browser.forward", "browser.reload":
            let web = try browser(params["pane"], caller: caller)
            switch method {
            case "browser.back": web.goBack()
            case "browser.forward": web.goForward()
            default: web.webView.reload()
            }
            try await web.waitForLoad(timeout: timeout(params))
            return web.summary
        case "browser.snapshot":
            let web = try browser(params["pane"], caller: caller)
            return try await web.snapshot(maxText: params["maxText"] as? Int ?? 20000)
        case "browser.click":
            let web = try browser(params["pane"], caller: caller)
            let result = try await web.click(target: target(params))
            try await web.waitForLoad(timeout: 5, quietly: true)
            return result
        case "browser.type":
            let web = try browser(params["pane"], caller: caller)
            guard let text = params["text"] as? String else { throw GoviControlError("Give the text to type.") }
            let result = try await web.type(text, into: target(params), submit: params["submit"] as? Bool == true)
            try await web.waitForLoad(timeout: 5, quietly: true)
            return result
        case "browser.eval":
            let web = try browser(params["pane"], caller: caller)
            guard let script = params["script"] as? String, !script.isEmpty else { throw GoviControlError("Give a script to run.") }
            return ["result": try await web.evaluate(script)]
        case "browser.screenshot":
            let web = try browser(params["pane"], caller: caller)
            let png = try await web.screenshotPNG()
            return ["pane": web.id.uuidString, "format": "png", "base64": png.base64EncodedString()]
        case "browser.console":
            let web = try browser(params["pane"], caller: caller)
            let entries = web.consoleEntries
            if params["clear"] as? Bool == true { web.consoleEntries.removeAll() }
            return ["pane": web.id.uuidString, "entries": entries]
        default:
            throw GoviControlError("Unknown method \(method). Run `govi help` for the commands this Govi supports.")
        }
    }

    // MARK: Panes

    static func describe(_ pane: GoviPaneView, in controller: TerminalController, caller: UUID?) -> [String: Any] {
        var info: [String: Any] = [
            "id": pane.id.uuidString,
            "kind": pane is GoviWebPaneView ? "browser" : pane is GoviEditorPaneView ? "editor" : "terminal",
            "title": pane.paneTitle,
            "focused": controller.focusedPane === pane && controller.window?.isKeyWindow == true,
            "self": pane.id == caller,
            "workspace": controller.goviName ?? controller.window?.title ?? "",
            "window": controller.window?.windowNumber ?? 0,
        ]
        if let directory = pane.paneDirectory { info["directory"] = directory }
        if let web = pane as? GoviWebPaneView {
            info["url"] = web.url?.absoluteString ?? ""
            info["loading"] = web.isLoading
        }
        return info
    }

    /// Finds a pane by full ID or unique prefix. With no ID: the caller's own
    /// pane, else the focused pane of the frontmost workspace.
    static func find(_ spec: Any?, caller: UUID?) throws -> (TerminalController, GoviPaneView) {
        let all = TerminalController.all.flatMap { controller in controller.surfaceTree.map { (controller, $0) } }
        if let text = (spec as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty {
            let matches = all.filter { $0.1.id.uuidString.lowercased().hasPrefix(text) }
            guard text.count >= 4 || matches.count == 1 else { throw GoviControlError("Use at least 4 characters of a pane ID.") }
            if matches.count == 1 { return matches[0] }
            throw GoviControlError(matches.isEmpty ? "No pane has the ID \(text). Run `govi panes`." : "\(text) matches several panes.")
        }
        if let caller, let own = all.first(where: { $0.1.id == caller }) { return own }
        if let controller = TerminalController.preferredParent, let pane = controller.focusedPane ?? controller.surfaceTree.first {
            return (controller, pane)
        }
        throw GoviControlError("Govi has no open panes.")
    }

    static func terminal(_ spec: Any?, caller: UUID?) throws -> Ghostty.SurfaceView {
        let (_, pane) = try find(spec, caller: caller)
        guard let surface = pane as? Ghostty.SurfaceView else { throw GoviControlError("Pane \(pane.id.uuidString.prefix(8)) is a browser, not a terminal.") }
        return surface
    }

    /// With no ID, the browser beside the caller (same workspace), else the
    /// most recently focused browser anywhere.
    static func browser(_ spec: Any?, caller: UUID?) throws -> GoviWebPaneView {
        if spec != nil {
            let (_, pane) = try find(spec, caller: caller)
            guard let web = pane as? GoviWebPaneView else { throw GoviControlError("Pane \(pane.id.uuidString.prefix(8)) is a terminal, not a browser.") }
            return web
        }
        let controllers = TerminalController.all
        let own = caller.flatMap { id in controllers.first { $0.surfaceTree.find(id: id) != nil } }
        if let own, let web = (own.focusedPane as? GoviWebPaneView) ?? own.surfaceTree.lazy.compactMap({ $0 as? GoviWebPaneView }).first {
            return web
        }
        let browsers = controllers.flatMap { $0.surfaceTree.compactMap { $0 as? GoviWebPaneView } }
        if let recent = browsers.max(by: { $0.lastActive < $1.lastActive }) { return recent }
        throw GoviControlError("No browser pane is open. Open one with `govi browser open <url>`.")
    }

    static func focus(_ pane: GoviPaneView, in controller: TerminalController) {
        guard let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        controller.focusedPane = pane
        DispatchQueue.main.async { window.makeFirstResponder(pane.paneFocusTarget) }
    }

    static func split(_ params: [String: Any], caller: UUID?) throws -> [String: Any] {
        let (controller, anchor) = try find(params["pane"], caller: caller)
        let direction: SplitTree<GoviPaneView>.NewDirection =
            switch (params["direction"] as? String)?.lowercased() {
            case "down", "below": .down
            case "left": .left
            case "up", "above": .up
            default: .right
            }
        let focusNew = params["focus"] as? Bool ?? false
        let created: GoviPaneView
        if (params["kind"] as? String) == "browser" {
            let web = GoviWebPaneView()
            if let address = params["url"] as? String, !address.isEmpty, !web.load(address) {
                throw GoviControlError(web.problem ?? "That isn't a web address.")
            }
            let tree = try controller.surfaceTree.insert(view: web, at: anchor, direction: direction)
            controller.replaceSurfaceTree(
                tree, moveFocusTo: focusNew ? web : nil, moveFocusFrom: controller.focusedPane, undoAction: "Open Browser")
            created = web
        } else {
            var config = Ghostty.SurfaceConfiguration()
            let directory = (params["cwd"] as? String) ?? anchor.paneDirectory ?? controller.surfaceTree.surfaces.first?.pwd
            var isDirectory: ObjCBool = false
            if let directory, FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                config.workingDirectory = directory
            } else if params["cwd"] != nil {
                throw GoviControlError("The folder \(directory ?? "") doesn't exist.")
            }
            if let command = params["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Run inside a login shell and keep the pane open afterwards.
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                config.command = GoviShell.quote(shell) + " -lic " + GoviShell.quote(command + "; exec " + GoviShell.quote(shell) + " -l")
                config.goviLaunch.command = command
            }
            let previous = controller.focusedPane
            guard let surface = controller.newSplit(at: anchor, direction: direction, baseConfig: config) else {
                throw GoviControlError("Govi couldn't split that pane.")
            }
            if !focusNew, let previous {
                // newSplit focuses the new terminal; an agent's split shouldn't take the person's keys.
                DispatchQueue.main.async { Ghostty.moveFocus(to: previous, from: surface) }
            }
            created = surface
        }
        return describe(created, in: controller, caller: caller)
    }

    // MARK: Parameters

    static func target(_ params: [String: Any]) throws -> GoviWebTarget {
        if let ref = params["ref"] as? String, !ref.isEmpty { return .ref(ref) }
        if let selector = params["selector"] as? String, !selector.isEmpty { return .selector(selector) }
        throw GoviControlError("Give an element ref from `govi browser snapshot`, or a CSS selector.")
    }

    static func timeout(_ params: [String: Any]) -> TimeInterval {
        min(60, max(1, (params["timeout"] as? Double) ?? Double(params["timeout"] as? Int ?? 15)))
    }

    /// Converts WebKit and Foundation values into something JSON can carry.
    nonisolated static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let value as [String: Any]: return value.mapValues(jsonSafe)
        case let value as [Any]: return value.map(jsonSafe)
        case let value as String: return value
        case let value as NSNumber: return value.doubleValue.isFinite ? value : NSNull()
        case let value as Date: return ISO8601DateFormatter().string(from: value)
        case is NSNull: return NSNull()
        case let value as URL: return value.absoluteString
        default: return String(describing: value)
        }
    }
}
