import AppKit
import Combine
import SwiftUI
import WebKit

/// Browser settings, stored in user defaults.
enum GoviBrowserPreferences {
    /// Offer local dev-server addresses a terminal prints, as a chip in its title bar.
    static let detectKey = "GoviBrowserDetectLocalServers"
    /// Keep cookies, storage and caches between launches. Off by default.
    static let keepDataKey = "GoviBrowserKeepSiteData"

    static var keepsSiteData: Bool { UserDefaults.standard.bool(forKey: keepDataKey) }

    /// Govi's own persistent store (per app, not shared with Safari), or a
    /// private one that's discarded with the pane.
    @MainActor static func dataStore() -> WKWebsiteDataStore {
        keepsSiteData ? .default() : .nonPersistent()
    }
}

/// A browser pane that lives in the split tree next to terminals.
///
/// By default it uses a non-persistent data store, so nothing it loads
/// survives a relaunch except the address; Settings › Browser can keep site
/// data instead. Web Inspector is available from the context menu.
final class GoviWebPaneView: GoviPaneView, ObservableObject, Codable {
    static let kindName = "web"
    /// Schemes the pane navigates to itself; anything else is handed to macOS.
    static let paneSchemes: Set<String> = ["http", "https", "file", "about"]
    static let maxURLLength = GoviWebPaneRecord.maxURLLength

    @Published private(set) var pageTitle = ""
    /// Nil until a page is opened; the empty web view stays hidden so the window shows through.
    @Published private(set) var url: URL? { didSet { webView.isHidden = url == nil } }
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// Set when an address was rejected or a page failed to load.
    @Published var problem: String?
    /// True while the element picker waits for a click on the page.
    @Published private(set) var isPicking = false

    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []
    /// When the pane last had focus; `govi browser` with no pane uses the newest.
    private(set) var lastActive = Date()
    /// Recent console output and uncaught errors, newest last, for agents.
    var consoleEntries: [[String: Any]] = []
    static let maxConsoleEntries = 500

    init(id: UUID = UUID(), url: URL? = nil, title: String = "") {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = GoviBrowserPreferences.dataStore()
        let console = ConsoleRelay()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        configuration.userContentController.add(console, contentWorld: .page, name: ConsoleRelay.name)
        let webView = FocusReportingWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        self.pageTitle = title
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.pane = self
        console.pane = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.pageTitle = view.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { if let url = view.url { self?.url = url } }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.isLoading = view.isLoading }
            },
        ]
        if let url, Self.isAllowedRecordURL(url) {
            self.url = url
            webView.load(URLRequest(url: url))
        }
        webView.isHidden = self.url == nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        observers.forEach { $0.invalidate() }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: Pane

    override var paneKind: String { Self.kindName }
    override var paneTitle: String {
        let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return url?.host ?? "Browser"
    }
    override var paneIcon: String { "globe" }
    /// Rounds the page's corners when it floats over a window backdrop.
    func setRounded(_ rounded: Bool) {
        webView.wantsLayer = true
        webView.layer?.cornerCurve = .continuous
        webView.layer?.cornerRadius = rounded ? 10 : 0
        webView.layer?.masksToBounds = rounded
    }
    override var paneFocusTarget: NSView { webView }
    override func paneFocusDidChange(_ focused: Bool) {
        if focused { lastActive = Date() }
    }

    // MARK: Navigation

    /// Accepts a URL or a bare host such as `localhost:3000` or `example.com`.
    /// Loopback hosts default to http, everything else to https.
    static func normalizedURL(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxURLLength, !text.contains(where: { $0.isWhitespace }) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), paneSchemes.contains(scheme) {
            return scheme == "about" || url.host != nil || scheme == "file" ? url : nil
        }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        let loopback = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"].contains(bare) || bare.hasSuffix(".localhost")
        guard loopback || bare.contains(".") else { return nil }
        guard let url = URL(string: (loopback ? "http://" : "https://") + text), url.host != nil else { return nil }
        return url
    }

    /// Addresses that may be written to recovery and templates.
    static func isAllowedRecordURL(_ url: URL) -> Bool { GoviWebPaneRecord.isAllowed(url) }

    @discardableResult
    func load(_ text: String) -> Bool {
        guard let url = Self.normalizedURL(from: text) else {
            problem = "Enter a web address such as localhost:3000 or example.com."
            return false
        }
        problem = nil
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        return true
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case kind, id, url, title }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
        let title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.init(id: id, url: url.flatMap { Self.isAllowedRecordURL($0) ? $0 : nil }, title: title)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kindName, forKey: .kind)
        try container.encode(id, forKey: .id)
        if let url, Self.isAllowedRecordURL(url) { try container.encode(url.absoluteString, forKey: .url) }
        try container.encode(pageTitle, forKey: .title)
    }
}

// MARK: - WebKit delegates

extension GoviWebPaneView: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if Self.paneSchemes.contains(scheme) {
            decisionHandler(.allow)
            return
        }
        // mailto:, app links and the like belong to other apps, and only when
        // the person clicked them.
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        problem = nil
    }

    /// Pages that open new windows (`target=_blank`) load in this pane.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    private func report(_ error: Error) {
        let error = error as NSError
        // Cancellation happens on every superseded navigation; it isn't a failure.
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        problem = error.localizedDescription
    }
}

/// Lets the pane tell its window controller when the page takes focus, since
/// the web view, not the pane, becomes first responder.
private final class FocusReportingWebView: WKWebView {
    weak var pane: GoviWebPaneView?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.pane?.reportFocus() } }
        return result
    }
}

// MARK: - Automation for `govi browser` and the MCP server

/// An element named by a ref from `snapshot()` or by a CSS selector.
enum GoviWebTarget {
    case ref(String)
    case selector(String)

    var selector: String {
        switch self {
        case .ref(let ref): "[data-govi-ref=\"\(ref.replacingOccurrences(of: "\"", with: ""))\"]"
        case .selector(let selector): selector
        }
    }
}

@MainActor
extension GoviWebPaneView {
    var summary: [String: Any] {
        var info: [String: Any] = [
            "pane": id.uuidString, "url": webView.url?.absoluteString ?? "", "title": webView.title ?? "",
            "loading": webView.isLoading,
        ]
        if let problem { info["problem"] = problem }
        return info
    }

    /// Waits until the page stops loading. A quiet wait never throws; it's used
    /// after clicks, which may or may not navigate.
    func waitForLoad(timeout: TimeInterval, quietly: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 150_000_000)
        while webView.isLoading {
            if Date() > deadline {
                if quietly { return }
                throw GoviControlError("The page is still loading after \(Int(timeout)) seconds.")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !quietly, let problem { throw GoviControlError(problem) }
    }

    /// The page's text and its interactive elements, each tagged with a ref
    /// that `click` and `type` accept.
    func snapshot(maxText: Int) async throws -> Any {
        var result = try await run(Self.snapshotScript, arguments: ["maxText": max(0, min(maxText, 500_000))])
        if var info = result as? [String: Any] {
            info["pane"] = id.uuidString
            result = info
        }
        return result
    }

    func click(target: GoviWebTarget) async throws -> Any {
        try await run(Self.clickScript, arguments: ["selector": target.selector])
    }

    func type(_ text: String, into target: GoviWebTarget, submit: Bool) async throws -> Any {
        try await run(Self.typeScript, arguments: ["selector": target.selector, "text": text, "submit": submit])
    }

    /// Runs JavaScript in the page. An expression's value is returned; for
    /// statements, `return` a value. Promises are awaited.
    func evaluate(_ source: String) async throws -> Any {
        do {
            return try await run("const __value = await (\n\(source)\n);\nreturn __goviValue(__value);", arguments: [:], prelude: true)
        } catch let error as GoviControlError where error.message.contains("SyntaxError") {
            return try await run(
                "const __value = await (async () => {\n\(source)\n})();\nreturn __goviValue(__value);", arguments: [:], prelude: true)
        }
    }

    func screenshotPNG() async throws -> Data {
        guard webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw GoviControlError("The browser pane isn't on screen, so it can't be captured.")
        }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: GoviControlError(error?.localizedDescription ?? "WebKit didn't return a picture."))
                }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { throw GoviControlError("Govi couldn't encode the screenshot.") }
        return png
    }

    func recordConsole(_ body: Any) {
        guard var entry = body as? [String: Any] else { return }
        if let text = entry["text"] as? String, text.count > 4000 { entry["text"] = String(text.prefix(4000)) + "…" }
        entry["url"] = webView.url?.absoluteString ?? ""
        consoleEntries.append(entry)
        if consoleEntries.count > Self.maxConsoleEntries { consoleEntries.removeFirst(consoleEntries.count - Self.maxConsoleEntries) }
    }

    /// Scripts return JSON text, which avoids WebKit's value bridging and its
    /// trouble with `undefined`; `{"__goviError": ...}` becomes a Govi error.
    private func run(_ body: String, arguments: [String: Any], prelude: Bool = false) async throws -> Any {
        let source = (prelude ? Self.valuePrelude : "") + body
        let text: Any? = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error):
                    let info = (error as NSError).userInfo
                    let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    continuation.resume(throwing: GoviControlError("JavaScript error: \(message)"))
                }
            }
        }
        guard let text = text as? String else { return NSNull() }
        let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
        if let failure = (value as? [String: Any])?["__goviError"] as? String { throw GoviControlError(failure) }
        return value
    }

    private static let valuePrelude = #"""
        const __goviValue = (value) => {
          if (value === undefined) return JSON.stringify(null);
          if (value instanceof Element) return JSON.stringify(value.outerHTML.slice(0, 20000));
          if (typeof value === "function" || typeof value === "symbol" || typeof value === "bigint") return JSON.stringify(String(value));
          const seen = new WeakSet();
          try {
            return JSON.stringify(value, (key, item) => {
              if (typeof item === "object" && item !== null) { if (seen.has(item)) return "[Circular]"; seen.add(item); }
              if (item instanceof Node) return "[" + item.nodeName + "]";
              if (typeof item === "bigint" || typeof item === "function") return String(item);
              return item;
            });
          } catch (error) { return JSON.stringify(String(value)); }
        };

        """#

    static let snapshotScript = #"""
        const query = 'a[href], button, input, select, textarea, summary, [contenteditable=""], [contenteditable="true"],'
          + ' [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=switch],'
          + ' [role=option], [role=combobox], [role=textbox], [onclick], [tabindex]:not([tabindex="-1"])';
        document.querySelectorAll('[data-govi-ref]').forEach(el => el.removeAttribute('data-govi-ref'));
        const visible = el => {
          const box = el.getBoundingClientRect();
          if (box.width < 1 || box.height < 1) return false;
          const style = getComputedStyle(el);
          return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
        };
        const clip = (text, size) => (text || '').replace(/\s+/g, ' ').trim().slice(0, size);
        const elements = [];
        let count = 0;
        for (const el of document.querySelectorAll(query)) {
          if (elements.length >= 400) break;
          if (!visible(el)) continue;
          const ref = 'e' + (++count);
          el.setAttribute('data-govi-ref', ref);
          const tag = el.tagName.toLowerCase();
          const label = el.labels && el.labels[0] ? el.labels[0].innerText : '';
          const item = { ref, tag, name: clip(el.getAttribute('aria-label') || label || el.innerText || el.value
            || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name'), 100) };
          const role = el.getAttribute('role'); if (role) item.role = role;
          if (el.type && tag === 'input') item.type = el.type;
          if (['input', 'textarea', 'select'].includes(tag) && el.type !== 'password') item.value = clip(String(el.value ?? ''), 200);
          if (el.checked) item.checked = true;
          if (el.disabled) item.disabled = true;
          if (tag === 'a') item.href = el.href;
          elements.push(item);
        }
        const text = document.body ? document.body.innerText : '';
        return JSON.stringify({ url: location.href, title: document.title, text: text.slice(0, maxText),
          truncated: text.length > maxText, elements });
        """#

    static let clickScript = #"""
        let el;
        try { el = document.querySelector(selector); } catch (error) { return JSON.stringify({ __goviError: 'That selector is not valid CSS.' }); }
        if (!el) return JSON.stringify({ __goviError: 'No element matches ' + selector + '. Take a new snapshot; refs change when the page does.' });
        el.scrollIntoView({ block: 'center', inline: 'center' });
        if (el.focus) el.focus();
        el.click();
        return JSON.stringify({ clicked: el.tagName.toLowerCase(), text: (el.innerText || el.value || '').trim().slice(0, 100) });
        """#

    static let typeScript = #"""
        let el;
        try { el = document.querySelector(selector); } catch (error) { return JSON.stringify({ __goviError: 'That selector is not valid CSS.' }); }
        if (!el) return JSON.stringify({ __goviError: 'No element matches ' + selector + '. Take a new snapshot; refs change when the page does.' });
        el.scrollIntoView({ block: 'center', inline: 'center' });
        if (el.focus) el.focus();
        const tag = el.tagName.toLowerCase();
        if (tag === 'input' || tag === 'textarea' || tag === 'select') {
          const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype : tag === 'select' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, text);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (el.isContentEditable) {
          document.execCommand('selectAll', false);
          document.execCommand('insertText', false, text);
        } else {
          return JSON.stringify({ __goviError: 'That element is a ' + tag + ', which does not take text.' });
        }
        if (submit) {
          const options = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          const proceed = el.dispatchEvent(new KeyboardEvent('keydown', options));
          el.dispatchEvent(new KeyboardEvent('keyup', options));
          if (proceed && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
        }
        return JSON.stringify({ typed: text.length, into: tag, submitted: !!submit });
        """#

    static let consoleScript = #"""
        (() => {
          const relay = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.goviConsole;
          if (!relay || window.__goviConsole) return;
          window.__goviConsole = true;
          const show = value => {
            if (typeof value === 'string') return value;
            if (value instanceof Error) return value.stack || String(value);
            try { return JSON.stringify(value); } catch (error) { return String(value); }
          };
          const send = (level, text) => { try { relay.postMessage({ level, text, time: Date.now() }); } catch (error) {} };
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[level];
            console[level] = function (...args) { send(level, args.map(show).join(' ')); return original.apply(this, args); };
          }
          window.addEventListener('error', event => !event.filename && event.message === 'Script error.' ? null : send('error', (event.message || 'Error') + (event.filename ? ' at ' + event.filename + ':' + event.lineno : '')));
          window.addEventListener('unhandledrejection', event => send('error', 'Unhandled rejection: ' + show(event.reason)));
        })();
        """#
}

/// Receives console messages without the content controller retaining the pane.
private final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    static let name = "goviConsole"
    weak var pane: GoviWebPaneView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { pane?.recordConsole(message.body) }
    }
}

// MARK: - Element picker

/// Lets the person click an element on the page and hands a description of
/// it to the terminal they used last, where an agent can act on it.
@MainActor
extension GoviWebPaneView {
    /// The picker runs in its own JavaScript world, so page scripts can't see
    /// or interfere with it; the DOM is shared.
    private static let pickerWorld = WKContentWorld.world(name: "govi-picker")

    func togglePicker() {
        if isPicking {
            webView.evaluateJavaScript("window.__goviPickCancel && window.__goviPickCancel()", in: nil, in: Self.pickerWorld)
            return
        }
        isPicking = true
        problem = nil
        window?.makeFirstResponder(webView)
        webView.callAsyncJavaScript(Self.pickerScript, arguments: [:], in: nil, in: Self.pickerWorld) { [weak self] result in
            guard let self else { return }
            self.isPicking = false
            switch result {
            case .success(let value):
                guard let text = value as? String, let data = text.data(using: .utf8),
                    let pick = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }  // Cancelled.
                self.deliver(pick)
            case .failure(let error):
                self.problem = "The element picker couldn't run on this page: \(error.localizedDescription)"
            }
        }
    }

    /// Text describing a picked element, ready to paste into an agent's prompt.
    static func describe(_ pick: [String: Any]) -> String {
        let url = pick["url"] as? String ?? ""
        let selector = pick["selector"] as? String ?? ""
        var lines = ["Element in the browser at \(url)", "Selector: \(selector)"]
        if let size = pick["size"] as? String, !size.isEmpty { lines.append("Size: \(size)") }
        if let text = pick["text"] as? String, !text.isEmpty { lines.append("Text: \(text)") }
        if let html = pick["html"] as? String, !html.isEmpty { lines += ["HTML:", html] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Types the description into the window's most recently used terminal,
    /// as a paste, and focuses it so the person can add their request. The
    /// text is also put on the clipboard.
    private func deliver(_ pick: [String: Any]) {
        let text = Self.describe(pick)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let terminals = (window?.windowController as? BaseTerminalController)?.surfaceTree.surfaces ?? []
        let recent = terminals.compactMap { terminal in terminal.focusInstant.map { (terminal, $0) } }.max { $0.1 < $1.1 }?.0
        guard let terminal = recent ?? terminals.first, let model = terminal.surfaceModel
        else {
            problem = "Copied the element to the clipboard. Open a terminal pane to send it to an agent."
            return
        }
        model.sendText(text)
        Ghostty.moveFocus(to: terminal, from: self)
    }

    static let pickerScript = #"""
        return await new Promise(resolve => {
          const box = document.createElement('div');
          const tag = document.createElement('div');
          box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #4f8cff;'
            + 'background:rgba(79,140,255,.12);border-radius:3px;transition:all 40ms linear;display:none';
          tag.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;font:11px -apple-system,sans-serif;'
            + 'background:#4f8cff;color:#fff;padding:2px 6px;border-radius:3px;display:none;white-space:nowrap';
          document.documentElement.append(box, tag);
          let current = null;
          const css = window.CSS && CSS.escape ? CSS.escape : (s => s.replace(/[^\w-]/g, '\\$&'));
          const step = el => {
            let part = el.tagName.toLowerCase();
            const classes = [...el.classList].filter(c => !/^(hover|focus|active)/.test(c)).slice(0, 2);
            if (classes.length) part += '.' + classes.map(css).join('.');
            const parent = el.parentElement;
            if (parent) {
              const same = [...parent.children].filter(c => c.tagName === el.tagName);
              if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
            }
            return part;
          };
          const selectorFor = el => {
            const parts = [];
            for (let node = el; node && node.nodeType === 1 && parts.length < 5; node = node.parentElement) {
              if (node.id && document.querySelectorAll('#' + css(node.id)).length === 1) { parts.unshift('#' + css(node.id)); break; }
              parts.unshift(step(node));
              if (node === document.body) break;
            }
            return parts.join(' > ');
          };
          const show = el => {
            const r = el.getBoundingClientRect();
            Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
            tag.textContent = step(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
            tag.style.display = 'block';
            tag.style.left = Math.max(0, r.left) + 'px';
            tag.style.top = (r.top > 22 ? r.top - 20 : r.bottom + 2) + 'px';
          };
          const finish = value => {
            removeEventListener('mousemove', move, true);
            removeEventListener('click', click, true);
            removeEventListener('mousedown', swallow, true);
            removeEventListener('mouseup', swallow, true);
            removeEventListener('keydown', key, true);
            box.remove(); tag.remove();
            delete window.__goviPickCancel;
            resolve(value);
          };
          const move = event => {
            const el = document.elementFromPoint(event.clientX, event.clientY);
            if (el && el !== current && el !== box && el !== tag) { current = el; show(el); }
          };
          const swallow = event => { event.preventDefault(); event.stopPropagation(); };
          const click = event => {
            swallow(event);
            const el = current || document.elementFromPoint(event.clientX, event.clientY);
            if (!el) return finish(null);
            const r = el.getBoundingClientRect();
            let html = el.outerHTML.replace(/\s+data-govi-ref="[^"]*"/g, '');
            if (html.length > 2000) html = html.slice(0, 2000) + '…';
            finish(JSON.stringify({ url: location.href, selector: selectorFor(el),
              text: (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 300),
              size: Math.round(r.width) + '×' + Math.round(r.height), html }));
          };
          const key = event => { if (event.key === 'Escape') { swallow(event); finish(null); } };
          window.__goviPickCancel = () => finish(null);
          addEventListener('mousemove', move, true);
          addEventListener('mousedown', swallow, true);
          addEventListener('mouseup', swallow, true);
          addEventListener('click', click, true);
          addEventListener('keydown', key, true);
        });
        """#
}

// MARK: - Settings

struct GoviBrowserSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviBrowserPreferences.detectKey) private var detect = true
    @AppStorage(GoviBrowserPreferences.keepDataKey) private var keepData = false
    @State private var cleared: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(
                "Browser panes sit next to your terminals. Open one with \(GoviShortcuts.shared.chord(.browser).display), from the + menu, or by Command-clicking a localhost link."
            )
            .foregroundStyle(ui.muted).lineSpacing(4)
            Toggle("Offer local servers that terminals print", isOn: $detect)
            Text(
                "When a terminal shows an address such as http://localhost:3000, its title bar offers to open it. Govi checks the visible text on this Mac every couple of seconds; nothing is sent anywhere."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            Toggle("Keep cookies and site data between launches", isOn: $keepData)
            Text(
                "Off: every browser pane starts signed out and forgets everything when it closes. On: browser panes share one store that only Govi uses, so sign-ins persist. Applies to browser panes opened after the change."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            HStack {
                Button("Clear Saved Site Data") {
                    let store = WKWebsiteDataStore.default()
                    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                        cleared = "Cleared cookies, storage and caches."
                    }
                }
                if let cleared { Text(cleared).font(GoviInk.font(11)).foregroundStyle(ui.muted) }
            }.controlSize(.small)
        }
    }
}
