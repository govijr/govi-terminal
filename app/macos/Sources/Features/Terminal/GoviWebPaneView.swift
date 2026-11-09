import AppKit
import Combine
import WebKit

/// A browser pane that lives in the split tree next to terminals.
///
/// It uses the system WebKit with a non-persistent data store, so nothing it
/// loads survives a relaunch except the address. Web Inspector is available
/// from the context menu.
final class GoviWebPaneView: GoviPaneView, ObservableObject, Codable {
    static let kindName = "web"
    /// Schemes the pane navigates to itself; anything else is handed to macOS.
    static let paneSchemes: Set<String> = ["http", "https", "file", "about"]
    static let maxURLLength = GoviWebPaneRecord.maxURLLength

    @Published private(set) var pageTitle = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// Set when an address was rejected or a page failed to load.
    @Published var problem: String?

    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), url: URL? = nil, title: String = "") {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = FocusReportingWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        self.pageTitle = title
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.pane = self
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        observers.forEach { $0.invalidate() }
    }

    // MARK: Pane

    override var paneKind: String { Self.kindName }
    override var paneTitle: String {
        let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return url?.host ?? "Browser"
    }
    override var paneIcon: String { "globe" }
    override var paneFocusTarget: NSView { webView }

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
