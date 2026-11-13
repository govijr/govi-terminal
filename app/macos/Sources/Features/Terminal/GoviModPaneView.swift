import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A mod's web pane: the mod's own page in a web view, with a `govi` object
/// the page uses to drive the app and run programs.
///
/// The page is served from the mod's folder under `govi-mod://mod/…`. Only
/// that page, or a page on this Mac's loopback address when the mod declares
/// a `url`, ever gets the bridge; a page on the internet never does.
final class GoviModPaneView: GoviPaneView, ObservableObject, Codable {
    static let kindName = "mod"
    static let scheme = "govi-mod"
    private static let registry = NSHashTable<GoviModPaneView>.weakObjects()

    /// Every mod pane, including one that is between windows while a layout change settles.
    static func all() -> [GoviModPaneView] { registry.allObjects }
    static func all(of modID: String) -> [GoviModPaneView] { registry.allObjects.filter { $0.modID == modID } }

    let modID: String
    let paneID: String
    /// The folder of the pane this one was opened beside; new terminals split from it start there.
    let directory: String?
    /// What opened the pane, such as the link a link handler matched.
    let context: [String: Any]
    @Published private(set) var title: String
    @Published private(set) var isLoading = false
    @Published var problem: String?
    /// Set while the mod is missing or disabled; the pane keeps its place in the layout.
    @Published private(set) var unavailable: String?
    /// JSON text the page saved with `govi.setState`, restored with the layout.
    private(set) var state: String?
    private var pageSetTitle = false
    private var retries = 0
    let webView: WKWebView

    init(
        id: UUID = UUID(), modID: String, paneID: String, title: String, directory: String? = nil, state: String? = nil,
        context: [String: Any] = [:]
    ) {
        self.modID = modID
        self.paneID = paneID
        self.title = title
        self.directory = directory
        self.state = state
        self.context = GoviControl.jsonSafe(context) as? [String: Any] ?? [:]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = GoviBrowserPreferences.dataStore()
        // Mod authors debug their pages with Inspect Element in the context menu.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.setURLSchemeHandler(GoviModSchemeHandler(modID: modID), forURLScheme: Self.scheme)
        let relay = GoviModRelay()
        configuration.userContentController.addScriptMessageHandler(relay, contentWorld: .page, name: GoviModRelay.name)
        let webView = GoviModWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        relay.pane = self
        webView.pane = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        Self.registry.add(self)
        load()
    }

    convenience init(record: GoviModPaneRecord) {
        self.init(
            id: record.id, modID: record.mod, paneID: record.pane, title: record.title, directory: record.directory, state: record.state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    var record: GoviModPaneRecord {
        .init(id: id, mod: modID, pane: paneID, title: title, directory: directory, state: state)
    }

    private var declaration: GoviModManifest.Pane? {
        GoviMods.shared.active(modID)?.manifest.pane(paneID).flatMap { $0.kind == .web ? $0 : nil }
    }

    /// The name of the mod, for labels.
    var modName: String { GoviMods.shared.entry(modID)?.name ?? modID }

    // MARK: Pane

    override var paneKind: String { Self.kindName }
    override var paneTitle: String { title.isEmpty ? modName : title }
    override var paneDirectory: String? { directory }
    override var paneIcon: String {
        guard let icon = declaration?.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil else {
            return "puzzlepiece.extension"
        }
        return icon
    }
    override var paneFocusTarget: NSView { unavailable == nil ? webView : self }
    override func paneFocusDidChange(_ focused: Bool) {
        if focused { deliver("theme", Self.theme) }
        deliver("focus", ["focused": focused])
    }

    // MARK: Loading

    /// Loads the pane's page as the mod declares it now.
    func load() {
        guard let pane = declaration else {
            let entry = GoviMods.shared.entry(modID)
            unavailable =
                entry == nil
                ? "The mod “\(modID)” isn't installed."
                : entry?.enabled == false
                    ? "The mod “\(modName)” is turned off. Turn it on in Settings › Mods."
                    : "The mod “\(modName)” no longer has this pane."
            webView.isHidden = true
            return
        }
        unavailable = nil
        problem = nil
        webView.isHidden = false
        if !pageSetTitle { title = pane.title }
        installBridge()
        let address = pane.url ?? pane.page.flatMap(Self.pageAddress)
        guard let address, let url = URL(string: address) else {
            problem = "This pane's page address isn't valid."
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Called when the mod's files or manifest change, or it is turned on or off.
    func modDidChange() {
        retries = 0
        load()
        objectWillChange.send()
    }

    func reload() {
        retries = 0
        load()
    }

    static func pageAddress(_ page: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: "?=&")
        return page.addingPercentEncoding(withAllowedCharacters: allowed).map { "\(scheme)://mod/\($0)" }
    }

    /// Whether a page at `url` may use the bridge: the mod's own files, or its own local server.
    func isTrusted(scheme: String?, host: String?) -> Bool {
        if scheme?.lowercased() == Self.scheme { return true }
        guard let declared = declaration?.url.flatMap(URL.init(string:)), let host = host?.lowercased() else { return false }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
        return loopback && declared.host?.lowercased() == host && ["http", "https"].contains(scheme?.lowercased() ?? "")
    }

    // MARK: Bridge

    static var theme: [String: Any] {
        let theme = GoviTheme.current
        let hex = { (value: UInt32) in String(format: "#%06X", value & 0xFF_FFFF) }
        return [
            "dark": theme.dark, "background": hex(theme.background), "foreground": hex(theme.foreground), "muted": hex(theme.muted),
            "border": hex(theme.border), "accent": hex(theme.accent), "sidebar": hex(theme.sidebar),
        ]
    }

    /// The script that defines `window.govi`. Replaced whenever what it embeds changes, so a
    /// page that reloads itself starts from the current state and theme.
    private func installBridge() {
        let literal = { (value: Any) -> String in
            (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) }
                ?? "null"
        }
        var pane: [String: Any] = ["id": id.uuidString, "mod": modID, "pane": paneID, "context": context]
        if let directory { pane["directory"] = directory }
        if let folder = GoviMods.shared.active(modID)?.folder.path { pane["root"] = folder }
        pane["data"] = GoviMods.dataDirectory(modID).path
        let source = Self.bridgeSource
            .replacingOccurrences(of: "__PANE__", with: literal(pane))
            .replacingOccurrences(of: "__THEME__", with: literal(Self.theme))
            .replacingOccurrences(of: "__STATE__", with: state.map { literal($0) } ?? "null")
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    private static let bridgeSource = """
        (() => {
          if (window.govi || !window.webkit || !window.webkit.messageHandlers.goviMod) return;
          const post = (message) => window.webkit.messageHandlers.goviMod.postMessage(message);
          const listeners = new Map();
          let state = __STATE__;
          const govi = {
            pane: __PANE__,
            theme: __THEME__,
            call: (method, params) => post({ type: "call", method: String(method), params: params || {} }),
            exec: (command, options) => post({ type: "exec", command, options: options || {} }),
            setTitle: (title) => { post({ type: "title", title: String(title) }); },
            getState: () => (state == null ? null : JSON.parse(state)),
            setState: (value) => { state = JSON.stringify(value); return post({ type: "state", state }); },
            on(event, listener) {
              if (!listeners.has(event)) listeners.set(event, new Set());
              listeners.get(event).add(listener);
              return () => listeners.get(event).delete(listener);
            },
          };
          Object.defineProperty(govi, "_emit", { value(event, data) {
            if (event === "theme") govi.theme = data;
            for (const listener of listeners.get(event) || []) { try { listener(data); } catch (error) { console.error(error); } }
            for (const listener of listeners.get("*") || []) { try { listener(event, data); } catch (error) { console.error(error); } }
          } });
          window.govi = govi;
        })();
        """

    /// Sends an event to the page's `govi.on` listeners.
    func deliver(_ event: String, _ payload: [String: Any]) {
        guard unavailable == nil, !webView.isLoading, let url = webView.url, isTrusted(scheme: url.scheme, host: url.host) else { return }
        webView.callAsyncJavaScript(
            "window.govi && window.govi._emit(event, data)", arguments: ["event": event, "data": payload], in: nil, in: .page)
    }

    fileprivate func receive(_ body: Any, reply: @escaping (Any?, String?) -> Void) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else {
            reply(nil, "The message wasn't understood.")
            return
        }
        switch type {
        case "call":
            guard let method = message["method"] as? String else { return reply(nil, "Give a method name.") }
            let params = message["params"] as? [String: Any] ?? [:]
            let caller = id
            Task { @MainActor in
                do {
                    reply(GoviControl.jsonSafe(try await GoviControl.handle(method, params: params, caller: caller)), nil)
                } catch {
                    reply(nil, (error as? GoviControlError)?.message ?? error.localizedDescription)
                }
            }
        case "exec":
            guard let mod = GoviMods.shared.active(modID) else { return reply(nil, "This mod is turned off.") }
            guard let argv = message["command"] as? [String] else {
                return reply(nil, "Give the program and its arguments as a list of strings.")
            }
            let options = message["options"] as? [String: Any] ?? [:]
            let caller = id
            Task { @MainActor in
                do {
                    reply(try await GoviMods.shared.exec(argv, options: options, mod: mod.manifest, folder: mod.folder, pane: caller), nil)
                } catch {
                    reply(nil, (error as? GoviControlError)?.message ?? error.localizedDescription)
                }
            }
        case "title":
            let text = (message["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            pageSetTitle = !text.isEmpty
            title = text.isEmpty ? declaration?.title ?? "" : String(text.prefix(200))
            reply(nil, nil)
        case "state":
            guard let text = message["state"] as? String, text.utf8.count <= GoviModPaneRecord.maxStateSize else {
                return reply(nil, "Pane state is limited to 64 KB of JSON. Keep larger data in files under govi.pane.data.")
            }
            state = text
            installBridge()
            reply(nil, nil)
        default:
            reply(nil, "Unknown message type \(type).")
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case kind, id, mod, pane, title, directory, state }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let record = GoviModPaneRecord(
            id: try container.decode(UUID.self, forKey: .id),
            mod: try container.decode(String.self, forKey: .mod),
            pane: try container.decode(String.self, forKey: .pane),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            directory: try container.decodeIfPresent(String.self, forKey: .directory),
            state: try container.decodeIfPresent(String.self, forKey: .state))
        guard record.isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid mod pane"))
        }
        self.init(record: record)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kindName, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(modID, forKey: .mod)
        try container.encode(paneID, forKey: .pane)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(directory, forKey: .directory)
        try container.encodeIfPresent(state, forKey: .state)
    }
}

// MARK: - WebKit delegates

extension GoviModPaneView: WKNavigationDelegate, WKUIDelegate {
    /// The pane stays on the mod's page (or its declared address); other links open in a browser pane.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url else {
            return decisionHandler(.allow)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let declared = declaration?.url.flatMap(URL.init(string:))
        let sameSite = declared != nil && ["http", "https"].contains(scheme) && declared?.host?.lowercased() == url.host?.lowercased()
        if scheme == Self.scheme || scheme == "about" || sameSite { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        openElsewhere(url)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openElsewhere(url) }
        return nil
    }

    private func openElsewhere(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let controller = window?.windowController as? BaseTerminalController {
            controller.showWebPane(url, beside: self)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        retries = 0
        problem = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        isLoading = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // A mod's own server may still be starting; try a few more times before reporting it.
        if declaration?.url != nil, retries < 8 {
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.retries > 0 else { return }
                self.load()
            }
            return
        }
        problem = "The page couldn't load: \(error.localizedDescription)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
        problem = "This pane's page stopped unexpectedly and was reloaded."
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = paneTitle
        alert.informativeText = message
        Task { @MainActor in
            _ = await GoviEditorPaneView.present(alert, in: self.window)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = paneTitle
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Task { @MainActor in
            completionHandler(await GoviEditorPaneView.present(alert, in: self.window) == .alertFirstButtonReturn)
        }
    }
}

/// Serves a mod's files to its pane. Nothing outside the mod's folder is readable through it.
private final class GoviModSchemeHandler: NSObject, WKURLSchemeHandler {
    let modID: String
    init(modID: String) { self.modID = modID }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let mod = GoviMods.shared.active(modID) else {
            return task.didFailWithError(URLError(.resourceUnavailable))
        }
        var path = String(url.path.drop { $0 == "/" })
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        guard let file = GoviModPaths.file(path, in: mod.folder), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        var type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if type.hasPrefix("text/") || type.hasSuffix("javascript") || type.hasSuffix("json") { type += "; charset=utf-8" }
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.badServerResponse))
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Lets the pane tell its window controller when the page takes focus.
private final class GoviModWebView: WKWebView {
    weak var pane: GoviModPaneView?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.pane?.reportFocus() } }
        return result
    }
}

/// Receives the page's messages without the content controller retaining the pane, and
/// refuses any that don't come from the mod's own page.
private final class GoviModRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "goviMod"
    weak var pane: GoviModPaneView?

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let origin = message.frameInfo.securityOrigin
            guard let pane, message.frameInfo.isMainFrame, pane.isTrusted(scheme: origin.protocol, host: origin.host) else {
                return replyHandler(nil, "This page can't use the Govi bridge.")
            }
            pane.receive(message.body, reply: replyHandler)
        }
    }
}

// MARK: - Views

/// A mod pane in a split: the shared pane frame around a `GoviModPaneView`.
struct GoviModPane: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviModPaneView
    var isSplit: Bool

    var body: some View {
        GoviPaneFrame(pane: pane, isSplit: isSplit, label: "\(pane.modName) pane") { showButtons in
            GoviModPaneBar(pane: pane, isSplit: isSplit, showButtons: showButtons)
        } content: {
            GoviPaneHost(view: pane)
                .overlay {
                    if let unavailable = pane.unavailable {
                        VStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.extension").font(.system(size: 26)).foregroundStyle(ui.muted)
                            Text(unavailable).font(GoviInk.font(12)).foregroundStyle(ui.muted).multilineTextAlignment(.center)
                            Button("Open Mod Settings") { NotificationCenter.default.post(name: .goviShowModSettings, object: nil) }
                                .controlSize(.small)
                        }.padding(20)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let problem = pane.problem {
                        HStack(spacing: 8) {
                            Text(problem).font(GoviInk.font(11.5)).foregroundStyle(ui.ink).lineLimit(3)
                            Button {
                                pane.problem = nil
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 10))
                            }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(10)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(pane.modName) problem: \(problem)")
                    }
                }
        }
    }
}

private struct GoviModPaneBar: View {
    @Environment(\.goviFloatingDrag) private var floatingDrag
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviModPaneView
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    var isSplit: Bool
    var showButtons: Bool
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: pane.isLoading ? "hourglass" : pane.paneIcon).font(.system(size: 11)).foregroundStyle(ui.muted)
                    .frame(width: 14, height: 14)
                Text(pane.paneTitle).fontWeight(.medium).foregroundStyle(ui.ink).lineLimit(1)
                if pane.paneTitle != pane.modName {
                    Text(pane.modName).font(GoviInk.font(11)).foregroundStyle(ui.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .frame(height: GoviPaneMetrics.headerHeight)
            .overlay { GoviPaneDragHandle(surface: pane, isSplit: isSplit) }
            .help("Drag to dock beside another pane; drop in its center to swap")
            HStack(spacing: 2) {
                button("arrow.clockwise", "Reload this pane") { pane.reload() }
                if floatingDrag == nil {
                    button("rectangle.split.2x1", "Split right (\(shortcuts.chord(.splitRight).display))") { command(.splitRight) }
                    button("rectangle.split.1x2", "Split below (\(shortcuts.chord(.splitDown).display))") { command(.splitDown) }
                }
                GoviFloatingButtons(pane: pane, isSplit: isSplit)
                if isSplit && floatingDrag == nil {
                    button("arrow.up.left.and.arrow.down.right", "Maximize / restore pane (\(shortcuts.chord(.zoom).display))") {
                        command(.zoom)
                    }
                }
                button("xmark", "Close pane (\(shortcuts.chord(.closeTerminal).display))") { command(.closeTerminal) }
            }.opacity(showButtons ? 1 : 0).allowsHitTesting(showButtons)
        }
        .font(GoviInk.font(12))
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: GoviPaneMetrics.headerHeight)
        .background(GoviInk.color(GoviTheme.current.background).opacity(GoviBackdropStore.terminalOpacity), ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: showButtons)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 24).modifier(GoviHoverHighlight())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func command(_ action: GoviShortcutAction) {
        (pane.window?.windowController as? BaseTerminalController)?.performPaneCommand(action, on: pane)
    }
}

/// A mod pane in the sidebar, styled like the terminal rows above it.
struct GoviSidebarModPane: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviModPaneView
    @State private var hovering = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: pane.paneIcon).font(.system(size: 12)).foregroundStyle(ui.accent)
                        .frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pane.paneTitle).lineLimit(1).truncationMode(.tail)
                        Text(pane.modName).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if pane.isLoading { ProgressView().controlSize(.mini) }
                }.padding(.vertical, 5).padding(.trailing, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("\(pane.modName)\nDrag to move this pane")
                .onDrag { GoviPaneCoordinator.dragProvider(for: pane) }
                .padding(.trailing, hovering ? 22 : 0)
        }.overlay(alignment: .trailing) {
            Button {
                command(.closeTerminal)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close pane").accessibilityLabel("Close pane")
                .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }.modifier(GoviSidebarPaneRowStyle(active: active, hovering: hovering))
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Split right") { command(.splitRight) }
                Button("Split below") { command(.splitDown) }
                Button("Maximize / restore pane") { command(.zoom) }
                Button("Reload") { pane.reload() }
                Divider()
                Button("Close pane") { command(.closeTerminal) }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("\(pane.modName): \(pane.paneTitle)")
    }

    private func command(_ action: GoviShortcutAction) {
        (pane.window?.windowController as? BaseTerminalController)?.performPaneCommand(action, on: pane)
    }
}

extension Notification.Name {
    static let goviShowModSettings = Notification.Name("goviShowModSettings")
}
