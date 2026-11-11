import AppKit
import Combine
import SwiftUI
import WebKit

/// Editor settings, stored in user defaults.
enum GoviEditorPreferences {
    /// Command-clicking a file path in a terminal opens it in an editor pane.
    static let openPathsKey = "GoviEditorOpensClickedPaths"
    static var opensClickedPaths: Bool { UserDefaults.standard.object(forKey: openPathsKey) as? Bool ?? true }
}

/// A code editor pane: a file tree beside Monaco, which Govi bundles.
///
/// Swift reads and writes files; the Monaco page only ever receives text, and
/// it can't navigate anywhere or reach the disk itself.
final class GoviEditorPaneView: GoviPaneView, ObservableObject, Codable {
    static let kindName = "editor"

    @Published private(set) var root: URL
    @Published private(set) var file: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var isReadOnly = false
    @Published private(set) var line = 1
    @Published private(set) var column = 1
    @Published var problem: String?
    @Published var showsTree = true
    let tree: GoviFileTreeModel
    let webView: WKWebView
    /// When the pane last had focus; reused for clicked paths.
    private(set) var lastActive = Date()
    private var ready = false
    private var whenReady: [() -> Void] = []
    /// The open file's modification date when it was read or last saved.
    private var diskDate: Date?
    private var saving = false

    init(id: UUID = UUID(), root: URL, file: URL? = nil, line: Int? = nil, column: Int? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let relay = EditorRelay()
        configuration.userContentController.add(relay, contentWorld: .page, name: EditorRelay.name)
        let webView = EditorWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        self.root = root.standardizedFileURL
        self.tree = GoviFileTreeModel(root: root.standardizedFileURL)
        super.init(id: id, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        relay.pane = self
        webView.pane = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        applyBackground()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let page = Self.pageURL {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            problem = "This copy of Govi doesn't include the editor. Build it with ./govi/build.sh."
        }
        if let file { open(file, line: line, column: column, askingAboutChanges: false) }
    }

    convenience init(record: GoviEditorPaneRecord) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let rootOK = record.isValid && manager.fileExists(atPath: record.root, isDirectory: &isDirectory) && isDirectory.boolValue
        let root = rootOK ? URL(fileURLWithPath: record.root) : manager.homeDirectoryForCurrentUser
        let file = rootOK && !record.file.isEmpty && manager.fileExists(atPath: record.file) ? URL(fileURLWithPath: record.file) : nil
        self.init(id: record.id, root: root, file: file, line: file == nil ? nil : record.line)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    var record: GoviEditorPaneRecord { .init(id: id, root: root.path, file: file?.path ?? "", line: max(1, line)) }

    /// The bundled page, present only when Monaco was bundled with it.
    static var pageURL: URL? {
        guard let page = Bundle.main.resourceURL?.appendingPathComponent("Govi/editor/editor.html"),
            FileManager.default.fileExists(atPath: page.path),
            FileManager.default.fileExists(atPath: page.deletingLastPathComponent().appendingPathComponent("vs/loader.js").path)
        else { return nil }
        return page
    }

    // MARK: Pane

    override var paneKind: String { Self.kindName }
    override var paneTitle: String { file?.lastPathComponent ?? root.lastPathComponent }
    override var paneDirectory: String? { root.path }
    override var paneIcon: String { "chevron.left.forwardslash.chevron.right" }
    override var paneFocusTarget: NSView { webView }
    override func paneFocusDidChange(_ focused: Bool) {
        guard focused else { return }
        lastActive = Date()
        if ready { applyTheme() }
        tree.refresh()
    }

    /// The open file's path relative to the folder, for the title bar.
    var displayPath: String {
        guard let file else { return root.lastPathComponent }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : file.path
    }

    func contains(_ url: URL) -> Bool {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.standardizedFileURL.path.hasPrefix(base)
    }

    // MARK: Files

    /// Opens `url` at an optional line, asking first about unsaved changes.
    func open(_ url: URL, line: Int? = nil, column: Int? = nil, askingAboutChanges: Bool = true) {
        let url = url.standardizedFileURL
        if url == file {
            if let line { reveal(line: line, column: column) }
            return
        }
        if askingAboutChanges && isDirty {
            GoviUnsavedEdits.resolve([self], window: window) { [weak self] in
                self?.open(url, line: line, column: column, askingAboutChanges: false)
            }
            return
        }
        switch GoviTextFile.read(url) {
        case .failure(let error):
            problem = error.message
        case .success(let text):
            problem = nil
            file = url
            isDirty = false
            isReadOnly = !FileManager.default.isWritableFile(atPath: url.path)
            self.line = line ?? 1
            self.column = column ?? 1
            diskDate = Self.modificationDate(url)
            tree.reveal(url)
            let file: [String: Any] = [
                "path": url.path, "text": text, "line": line ?? 1, "column": column ?? 1, "readOnly": isReadOnly,
            ]
            whenLoaded { [weak self] in self?.call("govi.open(file)", ["file": file]) }
        }
    }

    func reveal(line: Int, column: Int?) {
        whenLoaded { [weak self] in self?.call("govi.reveal(line, column)", ["line": line, "column": column ?? 1]) }
    }

    /// Shows a different folder in the tree. The open file stays open.
    func setRoot(_ url: URL) {
        root = url.standardizedFileURL
        tree.setRoot(root)
    }

    /// Writes the open file. Returns false if it wasn't saved.
    @MainActor @discardableResult
    func save() async -> Bool {
        guard let file else { return true }
        guard !isReadOnly else {
            problem = "\(file.lastPathComponent) is read-only."
            return false
        }
        guard ready, !saving else { return false }
        saving = true
        defer { saving = false }
        guard let snapshot = await evaluate("return govi.snapshot()") as? [String: Any], let text = snapshot["text"] as? String,
            let version = snapshot["version"]
        else {
            problem = "Govi couldn't read the editor's text, so \(file.lastPathComponent) wasn't saved."
            return false
        }
        // Someone else (a formatter, an agent, git) changed it since it was read.
        if let known = diskDate, let current = Self.modificationDate(file), current > known.addingTimeInterval(0.001) {
            let alert = NSAlert()
            alert.messageText = "\(file.lastPathComponent) changed on disk"
            alert.informativeText = "Another program changed it after it was opened here. Saving replaces those changes with yours."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard await Self.present(alert, in: window) == .alertFirstButtonReturn else { return false }
        }
        // Write through symlinks, and keep the file's permissions (such as +x).
        let target = file.resolvingSymlinksInPath()
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        do {
            try Data(text.utf8).write(to: target, options: .atomic)
        } catch {
            problem = "Couldn't save \(file.lastPathComponent): \(error.localizedDescription)"
            return false
        }
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        diskDate = Self.modificationDate(file)
        problem = nil
        isDirty = (await evaluate("return govi.markSaved(version)", ["version": version]) as? Bool) ?? false
        tree.refresh()
        return true
    }

    /// Used when closing without saving.
    func forgetChanges() { isDirty = false }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Page bridge

    func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            applyTheme()
            let queued = whenReady
            whenReady = []
            queued.forEach { $0() }
        case "dirty":
            isDirty = message["dirty"] as? Bool ?? false
        case "save":
            Task { @MainActor in await self.save() }
        case "cursor":
            line = message["line"] as? Int ?? line
            column = message["column"] as? Int ?? column
        case "focus":
            reportFocus()
        case "error":
            problem = "The editor couldn't start: \(message["message"] as? String ?? "unknown error")"
        default:
            break
        }
    }

    private func whenLoaded(_ action: @escaping () -> Void) {
        if ready { action() } else { whenReady.append(action) }
    }

    private func applyTheme() {
        let theme = GoviTheme.current
        let hex = { (value: UInt32) in String(format: "#%06X", value & 0xFF_FFFF) }
        call(
            "govi.theme(theme)",
            [
                "theme": [
                    "dark": theme.dark, "background": hex(theme.background), "foreground": hex(theme.foreground),
                    "clear": GoviBackdropStore.terminalOpacity < 1,
                ]
            ])
        applyBackground()
    }

    /// Over a backdrop the editor is as clear as the terminal beside it, so the window's
    /// picture runs behind the code instead of stopping at an opaque box.
    private func applyBackground() {
        let clear = GoviBackdropStore.terminalOpacity < 1
        webView.setValue(!clear, forKey: "drawsBackground")
        webView.underPageBackgroundColor = clear ? .clear : NSColor(rgb: GoviTheme.current.background)
    }

    private func call(_ body: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                self?.problem = "Editor error: \(message)"
            }
        }
    }

    @MainActor private func evaluate(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    @MainActor static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window, window.attachedSheet == nil else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case kind, id, root, file, line }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            record: .init(
                id: try container.decode(UUID.self, forKey: .id),
                root: try container.decodeIfPresent(String.self, forKey: .root) ?? "",
                file: try container.decodeIfPresent(String.self, forKey: .file) ?? "",
                line: try container.decodeIfPresent(Int.self, forKey: .line) ?? 1))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let record = record
        try container.encode(Self.kindName, forKey: .kind)
        try container.encode(record.id, forKey: .id)
        try container.encode(record.root, forKey: .root)
        try container.encode(record.file, forKey: .file)
        try container.encode(record.line, forKey: .line)
    }
}

// MARK: - WebKit delegates

extension GoviEditorPaneView: WKNavigationDelegate, WKUIDelegate {
    /// Only the bundled page loads here.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url?.standardizedFileURL
        decisionHandler(url != nil && url == Self.pageURL?.standardizedFileURL ? .allow : .cancel)
    }

    /// Links in code (Command-click in Monaco) open in a browser pane.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            if let controller = window?.windowController as? BaseTerminalController {
                controller.showWebPane(url, beside: self)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let lost = isDirty
        ready = false
        isDirty = false
        let reopen = file
        file = nil
        if let page = Self.pageURL { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        if let reopen { open(reopen, line: line, column: column, askingAboutChanges: false) }
        problem = lost ? "The editor stopped unexpectedly and unsaved changes were lost. The file was reopened from disk." : nil
    }
}

/// Lets the pane tell its window controller when the editor takes focus.
private final class EditorWebView: WKWebView {
    weak var pane: GoviEditorPaneView?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.pane?.reportFocus() } }
        return result
    }
}

/// Receives page messages without the content controller retaining the pane.
private final class EditorRelay: NSObject, WKScriptMessageHandler {
    static let name = "goviEditor"
    weak var pane: GoviEditorPaneView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { pane?.receive(message.body) }
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - Unsaved changes

/// Asks about editors with unsaved changes before something closes them.
@MainActor
enum GoviUnsavedEdits {
    private static var asking = false

    /// Every editor with unsaved changes, in every window.
    static func all() -> [GoviEditorPaneView] {
        NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }.flatMap(\.unsavedEditors)
    }

    /// Calls `proceed` once nothing would be lost: right away when nothing is
    /// unsaved, otherwise after the person saves or discards. Cancel calls
    /// `cancelled` instead.
    static func resolve(
        _ editors: [GoviEditorPaneView], window: NSWindow?, then proceed: @escaping () -> Void, cancelled: @escaping () -> Void = {}
    ) {
        let editors = editors.filter(\.isDirty)
        guard !editors.isEmpty else { return proceed() }
        // One question at a time: a second close while it's showing is ignored.
        guard !asking, window?.attachedSheet == nil else { return cancelled() }
        asking = true
        let alert = NSAlert()
        let names = editors.compactMap { $0.file?.lastPathComponent }
        if names.count == 1 {
            alert.messageText = "Save changes to \(names[0])?"
        } else {
            alert.messageText = "Save changes to \(names.count) files?"
            alert.informativeText = names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", …" : "")
        }
        if alert.informativeText.isEmpty { alert.informativeText = "Your changes will be lost if you don't save them." }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        Task { @MainActor in
            let response = await GoviEditorPaneView.present(alert, in: window)
            asking = false
            switch response {
            case .alertFirstButtonReturn:
                for editor in editors where !(await editor.save()) {
                    Ghostty.moveFocus(to: editor)
                    return cancelled()
                }
                proceed()
            case .alertSecondButtonReturn:
                editors.forEach { $0.forgetChanges() }
                proceed()
            default:
                cancelled()
            }
        }
    }
}

extension BaseTerminalController {
    var unsavedEditors: [GoviEditorPaneView] { surfaceTree.compactMap { $0 as? GoviEditorPaneView }.filter(\.isDirty) }

    /// Opens a file in this window's editor: the most recently used one whose
    /// folder holds the file, otherwise a new editor beside `anchor`.
    @discardableResult
    func showEditor(_ location: GoviFileLocation, root: URL? = nil, beside anchor: GoviPaneView? = nil) -> GoviEditorPaneView? {
        let url = URL(fileURLWithPath: location.path)
        let editors = surfaceTree.compactMap { $0 as? GoviEditorPaneView }
        if let existing = editors.filter({ $0.contains(url) || $0.file == url }).max(by: { $0.lastActive < $1.lastActive }) {
            existing.open(url, line: location.line, column: location.column)
            if surfaceTree.zoomed != nil { surfaceTree = .init(root: surfaceTree.root, zoomed: nil) }
            DispatchQueue.main.async { Ghostty.moveFocus(to: existing) }
            return existing
        }
        let folder = root.flatMap { url.path.hasPrefix($0.standardizedFileURL.path + "/") ? $0 : nil } ?? url.deletingLastPathComponent()
        let pane = GoviEditorPaneView(root: folder, file: url, line: location.line, column: location.column)
        return insertPane(pane, beside: anchor, undoAction: "Open Editor") ? pane : nil
    }

    /// Opens an empty editor on `folder`, or the focused pane's folder.
    @discardableResult
    func openEditorPane(folder: URL? = nil, beside anchor: GoviPaneView? = nil) -> GoviEditorPaneView? {
        let directory = folder?.path ?? focusedPane?.paneDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let pane = GoviEditorPaneView(root: URL(fileURLWithPath: directory))
        return insertPane(pane, beside: anchor, undoAction: "Open Editor") ? pane : nil
    }
}

extension GoviLinkRouter {
    /// Opens a clicked file path in the editor when it's a text file.
    static func openFile(_ raw: String, from surface: Ghostty.SurfaceView) -> Bool {
        guard GoviEditorPreferences.opensClickedPaths, let controller = surface.window?.windowController as? BaseTerminalController,
            let location = fileLocation(raw, relativeTo: surface.pwd), GoviTextFile.isEditable(location.path)
        else { return false }
        return controller.showEditor(location, root: surface.pwd.map { URL(fileURLWithPath: $0) }, beside: surface) != nil
    }
}

// MARK: - File tree

/// The folder shown beside the editor, read lazily as folders are expanded.
final class GoviFileTreeModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let depth: Int
        var id: URL { url }
    }

    static let hiddenNames: Set<String> = [".git", ".hg", ".svn", ".DS_Store"]
    static let maxEntriesPerFolder = 2000
    static let maxRows = 20_000

    @Published private(set) var rows: [Row] = []
    @Published private(set) var expanded: Set<URL> = []
    private(set) var root: URL
    private var cache: [URL: [Row]] = [:]

    init(root: URL) {
        self.root = root
        rebuild()
    }

    func toggle(_ folder: URL) {
        if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) }
        rebuild()
    }

    /// Expands the folders above `file` so it shows in the tree.
    func reveal(_ file: URL) {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        let base = root.path
        var added = false
        while folder.path.hasPrefix(base + "/") {
            if expanded.insert(folder).inserted { added = true }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        if added { rebuild() }
    }

    func refresh() {
        cache = [:]
        rebuild()
    }

    func setRoot(_ url: URL) {
        root = url
        expanded = []
        refresh()
    }

    private func children(of folder: URL, depth: Int) -> [Row] {
        if let cached = cache[folder] { return cached }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let rows = urls.filter { !Self.hiddenNames.contains($0.lastPathComponent) }
            .map { url in
                Row(
                    url: url.standardizedFileURL, name: url.lastPathComponent,
                    isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, depth: depth)
            }
            .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(Self.maxEntriesPerFolder)
        cache[folder] = Array(rows)
        return Array(rows)
    }

    private func rebuild() {
        var result: [Row] = []
        func walk(_ folder: URL, depth: Int) {
            for row in children(of: folder, depth: depth) {
                guard result.count < Self.maxRows else { return }
                result.append(row)
                if row.isDirectory && expanded.contains(row.url) && depth < 40 { walk(row.url, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        if result != rows { rows = result }
    }
}

// MARK: - Views

/// An editor in a split: title bar, file tree and Monaco.
struct GoviEditorPane: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviEditorPaneView
    var isSplit: Bool

    var body: some View {
        GoviPaneFrame(pane: pane, isSplit: isSplit, label: "Editor pane") { showButtons in
            GoviEditorPaneBar(pane: pane, isSplit: isSplit, showButtons: showButtons)
        } content: {
            HStack(spacing: 0) {
                if pane.showsTree {
                    GoviFileTree(pane: pane, tree: pane.tree).frame(width: 220)
                    Rectangle().fill(ui.ink.opacity(0.08)).frame(width: 1)
                }
                GoviPaneHost(view: pane)
                    .overlay {
                        if pane.file == nil && pane.problem == nil {
                            Text("Choose a file, or Command-click a path in a terminal.")
                                .font(GoviInk.font(12)).foregroundStyle(ui.muted).allowsHitTesting(false)
                        }
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
                    .accessibilityLabel("Editor problem: \(problem)")
                }
            }
        }
    }
}

private struct GoviEditorPaneBar: View {
    @Environment(\.goviFloatingDrag) private var floatingDrag
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviEditorPaneView
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    var isSplit: Bool
    var showButtons: Bool
    @AppStorage(GoviBackdropStore.styleKey) private var backdropStyle = "none"

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let file = pane.file {
                    GoviFileIcon(name: file.lastPathComponent)
                    Text(file.lastPathComponent).fontWeight(.medium).foregroundStyle(ui.ink).lineLimit(1).layoutPriority(1)
                    let folder = (pane.displayPath as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder).font(GoviInk.font(11)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.head)
                    }
                } else {
                    GoviGlyph(kind: .folder).foregroundStyle(ui.accent)
                    Text(pane.displayPath).fontWeight(.medium).foregroundStyle(ui.ink).lineLimit(1)
                }
                if pane.isDirty {
                    Circle().fill(ui.accent).frame(width: 7, height: 7).accessibilityLabel("Unsaved changes")
                }
                if pane.isReadOnly {
                    Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(ui.muted).accessibilityLabel("Read-only")
                }
                Spacer(minLength: 8)
                if pane.file != nil {
                    Text("Ln \(pane.line), Col \(pane.column)").font(GoviInk.font(11)).monospacedDigit().foregroundStyle(ui.muted)
                        .lineLimit(1).fixedSize()
                }
            }
            .frame(height: GoviPaneMetrics.headerHeight)
            .overlay { GoviPaneDragHandle(surface: pane, isSplit: isSplit) }
            .help("Drag to dock beside another pane; drop in its center to swap")
            HStack(spacing: 2) {
                button("sidebar.left", pane.showsTree ? "Hide files" : "Show files") { pane.showsTree.toggle() }
                button("folder", "Open folder…") { chooseFolder() }
                button("square.and.arrow.down", "Save (⌘S)") { Task { await pane.save() } }.disabled(!pane.isDirty)
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = pane.root
        panel.prompt = "Open"
        guard let window = pane.window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { pane.setRoot(url) }
        }
    }
}

private struct GoviFileTree: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviEditorPaneView
    @ObservedObject var tree: GoviFileTreeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tree.root.lastPathComponent).font(GoviInk.font(11).weight(.semibold)).foregroundStyle(ui.muted.opacity(0.7))
                    .lineLimit(1).help(tree.root.path)
                Spacer()
                Button {
                    tree.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(ui.muted).help("Refresh").accessibilityLabel("Refresh files")
            }.padding(.horizontal, 12).frame(height: 26)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(tree.rows) { row in
                        GoviFileTreeRow(row: row, open: tree.expanded.contains(row.url), selected: row.url == pane.file) {
                            if row.isDirectory { tree.toggle(row.url) } else { pane.open(row.url) }
                        }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 6)
            }
        }
        .background(GoviInk.color(GoviTheme.current.background).opacity(GoviBackdropStore.terminalOpacity))
    }
}

/// One file or folder, on the sidebar's grid: 26pt rows, a 16pt icon, a rounded accent
/// fill for the open file.
private struct GoviFileTreeRow: View {
    @Environment(\.goviPalette) private var ui
    let row: GoviFileTreeModel.Row
    let open: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold)).foregroundStyle(ui.muted)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 8).opacity(row.isDirectory ? 1 : 0)
                if row.isDirectory {
                    GoviGlyph(kind: .folder).foregroundStyle(ui.accent)
                } else {
                    GoviFileIcon(name: row.name)
                }
                Text(row.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected || hovering ? ui.ink : ui.ink.opacity(0.82))
                Spacer(minLength: 0)
            }
            .font(GoviInk.font(12.5))
            .padding(.leading, CGFloat(6 + row.depth * 14)).padding(.trailing, 6).frame(height: 26)
            .background(
                selected ? ui.accent.opacity(0.20) : ui.ink.opacity(hovering ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel(row.isDirectory ? "Folder \(row.name)" : row.name)
    }
}

/// A file's icon in the tree, the editor header, the sidebar and the git panel. Known
/// types use the bundled Material Icon Theme artwork (see Govi/Brand/SOURCES.md); if that
/// file is missing, a tinted lettermark stands in, and unknown types get a plain glyph.
struct GoviFileIcon: View {
    @Environment(\.goviPalette) private var ui
    let name: String

    /// Extension → bundled artwork in Govi/FileIcons.
    private static let artByExtension: [String: String] = {
        var table: [String: String] = [:]
        func add(_ extensions: [String], _ art: String) { extensions.forEach { table[$0] = art } }
        add(["swift"], "swift")
        add(["ts", "mts", "cts"], "typescript")
        add(["tsx"], "react_ts")
        add(["js", "mjs", "cjs"], "javascript")
        add(["jsx"], "react")
        add(["json", "jsonc", "json5"], "json")
        add(["md", "mdx", "markdown"], "markdown")
        add(["py", "pyi"], "python")
        add(["rb"], "ruby")
        add(["rs"], "rust")
        add(["go"], "go")
        add(["zig"], "zig")
        add(["c"], "c")
        add(["h"], "h")
        add(["cpp", "cc", "cxx"], "cpp")
        add(["hpp", "hh", "hxx"], "hpp")
        add(["m", "mm"], "objective-c")
        add(["java"], "java")
        add(["kt", "kts"], "kotlin")
        add(["cs"], "csharp")
        add(["php"], "php")
        add(["html", "htm"], "html")
        add(["xml", "plist", "xib", "storyboard", "entitlements"], "xml")
        add(["svg"], "svg")
        add(["css"], "css")
        add(["scss", "sass"], "sass")
        add(["less"], "less")
        add(["vue"], "vue")
        add(["svelte"], "svelte")
        add(["sh", "bash", "zsh", "fish"], "console")
        add(["yml", "yaml"], "yaml")
        add(["toml"], "toml")
        add(["sql", "sqlite", "db"], "database")
        add(["lua"], "lua")
        add(["dart"], "dart")
        add(["ex", "exs"], "elixir")
        add(["png", "jpg", "jpeg", "gif", "webp", "heic", "icns", "ico", "tiff", "bmp"], "image")
        add(["mp4", "mov", "webm", "mkv"], "video")
        add(["lock"], "lock")
        add(["ini", "conf", "cfg", "env", "xcconfig", "editorconfig"], "settings")
        add(["pem", "crt", "cer", "key"], "certificate")
        add(["txt", "rtf", "log"], "document")
        add(["pdf"], "pdf")
        add(["zip", "tar", "gz", "tgz", "xz", "7z", "dmg"], "zip")
        return table
    }()
    private static let artByName: [String: String] = [
        "dockerfile": "docker", "makefile": "makefile", ".gitignore": "git", ".gitattributes": "git", ".gitmodules": "git",
        "license": "certificate", "license.md": "certificate", "license.txt": "certificate", ".env": "settings",
        "package-lock.json": "lock", "package.resolved": "lock",
    ]
    private static var artCache: [String: NSImage?] = [:]
    /// Loads each SVG once; nil when this copy of Govi has no FileIcons folder.
    private static func art(_ name: String) -> NSImage? {
        if let cached = artCache[name] { return cached }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Govi/FileIcons/\(name).svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        artCache[name] = image
        return image
    }

    private static let byExtension: [String: (String, UInt32)] = {
        var table: [String: (String, UInt32)] = [:]
        func add(_ extensions: [String], _ mark: String, _ color: UInt32) { extensions.forEach { table[$0] = (mark, color) } }
        add(["swift"], "S", 0xF05138)
        add(["ts", "mts", "cts"], "TS", 0x3178C6)
        add(["tsx"], "TX", 0x3FA9D8)
        add(["js", "mjs", "cjs"], "JS", 0xE8D44D)
        add(["jsx"], "JX", 0xE8B84D)
        add(["json", "jsonc", "json5"], "{}", 0xCBA53C)
        add(["md", "mdx", "markdown"], "M", 0x519ABA)
        add(["py", "pyi"], "PY", 0x4B8BBE)
        add(["rb"], "RB", 0xCC342D)
        add(["rs"], "RS", 0xDEA584)
        add(["go"], "GO", 0x00ADD8)
        add(["zig"], "Z", 0xF7A41D)
        add(["c"], "C", 0x5C8DD6)
        add(["h"], "H", 0x9B7FD1)
        add(["cpp", "cc", "cxx"], "C+", 0x5C8DD6)
        add(["hpp", "hh", "hxx"], "H+", 0x9B7FD1)
        add(["m", "mm"], "OC", 0x438EFF)
        add(["java"], "J", 0xB07219)
        add(["kt", "kts"], "K", 0xA97BFF)
        add(["cs"], "C#", 0x9B4F96)
        add(["php"], "PH", 0x777BB4)
        add(["html", "htm", "xml", "svg"], "<>", 0xE34C26)
        add(["css"], "#", 0x8A63D2)
        add(["scss", "sass", "less"], "#", 0xCF649A)
        add(["vue"], "V", 0x41B883)
        add(["svelte"], "SV", 0xFF3E00)
        add(["sh", "bash", "zsh", "fish"], "$", 0x89E051)
        add(["yml", "yaml"], "Y", 0xCB4B4B)
        add(["toml"], "T", 0xB5651D)
        add(["sql"], "DB", 0xE38C00)
        add(["lua"], "L", 0x51A0CF)
        add(["dart"], "D", 0x00B4AB)
        add(["ex", "exs"], "EX", 0x9B6FB5)
        return table
    }()
    private static let byName: [String: (String, UInt32)] = [
        "dockerfile": ("DK", 0x2496ED), "makefile": ("MK", 0x6D8086), ".gitignore": ("G", 0xF1502F),
        ".gitattributes": ("G", 0xF1502F), ".gitmodules": ("G", 0xF1502F),
    ]
    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "icns", "ico", "tiff", "bmp", "mp4", "mov"]

    var body: some View {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        Group {
            if let art = (Self.artByName[lower] ?? Self.artByExtension[ext]).flatMap(Self.art) {
                Image(nsImage: art).resizable().interpolation(.high)
                    .frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
            } else if let mark = Self.byName[lower] ?? Self.byExtension[ext] {
                let tint = ui.tint(mark.1)
                Text(mark.0).font(.system(size: mark.0.count > 1 ? 7 : 9.5, weight: .heavy, design: .rounded)).foregroundStyle(tint)
                    .frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    .background(tint.opacity(0.20), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else if Self.images.contains(ext) {
                GoviGlyph(kind: .image).foregroundStyle(ui.tint(0xA074C4))
            } else {
                GoviGlyph(kind: .file).foregroundStyle(ui.muted)
            }
        }.accessibilityHidden(true)
    }
}

/// An editor pane in the sidebar, styled like the terminal rows above it.
struct GoviSidebarEditor: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var pane: GoviEditorPaneView
    @State private var hovering = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Group {
                        if let file = pane.file {
                            GoviFileIcon(name: file.lastPathComponent)
                        } else {
                            GoviGlyph(kind: .code).foregroundStyle(ui.color(for: .code))
                        }
                    }.frame(width: GoviSidebarMetrics.icon, height: GoviSidebarMetrics.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pane.paneTitle + (pane.isDirty ? " •" : "")).lineLimit(1).truncationMode(.tail)
                        Text(pane.root.lastPathComponent).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5).padding(.trailing, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help("\(pane.file?.path ?? pane.root.path)\nDrag to move this pane")
                .onDrag { GoviPaneCoordinator.dragProvider(for: pane) }
                .padding(.trailing, hovering ? 22 : 0)
        }.overlay(alignment: .trailing) {
            Button {
                command(.closeTerminal)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Close editor").accessibilityLabel("Close editor")
                .opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }.modifier(GoviSidebarPaneRowStyle(active: active, hovering: hovering))
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Split right") { command(.splitRight) }
                Button("Split below") { command(.splitDown) }
                Button("Maximize / restore pane") { command(.zoom) }
                if let file = pane.file { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
                Divider()
                Button("Close editor") { command(.closeTerminal) }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("Editor: \(pane.paneTitle)\(pane.isDirty ? ", unsaved" : "")")
    }

    private func command(_ action: GoviShortcutAction) {
        (pane.window?.windowController as? BaseTerminalController)?.performPaneCommand(action, on: pane)
    }
}

// MARK: - Settings

struct GoviEditorSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviEditorPreferences.openPathsKey) private var openPaths = true

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(
                "Editor panes show a folder beside a code editor. Open one with \(GoviShortcuts.shared.chord(.editor).display) or from the + menu."
            )
            .foregroundStyle(ui.muted).lineSpacing(4)
            Toggle("Open file paths I Command-click in a terminal", isOn: $openPaths)
            Text("Paths such as ./src/app.ts:42 open at that line. Folders and files that aren't text still open with macOS.")
                .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            Text("Govi asks before closing an editor with unsaved changes, and before saving over a file another program changed.")
                .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            Divider()
            Text("Quick Look").font(GoviInk.font(12).weight(.semibold))
            GoviQuickLookSettingsView()
        }
    }
}
