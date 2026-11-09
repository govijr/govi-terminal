import SwiftUI
import AppKit

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Changes store

/// Working-tree changes for the repository containing the focused terminal's folder.
final class GoviGitChanges: ObservableObject {
    struct File: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let oldPath: String?
        /// Porcelain XY status code, e.g. " M", "A ", "??".
        let code: String
        /// nil for binary files.
        var additions: Int? = 0
        var deletions: Int? = 0
        var untracked: Bool { code == "??" }
        var kind: String {
            if untracked { return "U" }
            if code.contains("D") { return "D" }
            if code.contains("R") { return "R" }
            if code.contains("A") { return "A" }
            if code.contains("U") { return "!" }
            return "M"
        }
        var name: String { (path as NSString).lastPathComponent }
        var folder: String { (path as NSString).deletingLastPathComponent }
        var paths: [String] { [oldPath, path].compactMap { $0 } }
    }

    fileprivate struct Snapshot: Equatable {
        var root: String?
        var branch = ""
        var upstream: String?
        var ahead = 0, behind = 0
        var hasHead = true
        var files: [File] = []
        /// Git directories to watch alongside the root (outside it for linked worktrees).
        var gitDirectories: [String] = []
    }

    @Published private(set) var root: String?
    @Published private(set) var branch = ""
    @Published private(set) var upstream: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var files: [File] = []
    @Published var busy: String?
    @Published var error: String?
    @Published var notice: String?
    /// Bumped when HEAD, refs or worktree metadata change on disk, so views
    /// showing branches and worktrees can reload them without polling.
    @Published private(set) var metadataRevision = 0
    private var hasHead = true
    private var loading = false
    private var directory = ""
    private var generation = 0
    private lazy var watcher = GoviRepositoryWatcher { [weak self] change in self?.filesChanged(change) }
    /// A refresh is wanted but was skipped because nobody can see the window.
    private var stale = false
    private var scheduled = false
    /// A change arrived while a read was running; read again once it lands.
    private var pending = false
    private var lastRefresh = Date.distantPast

    /// Set by the owning window. Hidden windows skip refreshes and catch up on return.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue, isVisible, stale else { return }
            stale = false
            metadataRevision += 1
            refresh(directory)
        }
    }

    var additions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    var deletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }

    func refresh(_ path: String, force: Bool = false) {
        if path != directory {
            directory = path
            generation += 1
            apply(Snapshot())
            error = nil
            notice = nil
        }
        guard force || !loading else {
            pending = true
            return
        }
        loading = true
        lastRefresh = Date()
        pending = false
        let token = generation
        DispatchQueue.global(qos: .utility).async {
            let snapshot = Self.read(path)
            DispatchQueue.main.async {
                self.loading = false
                guard token == self.generation else { return }
                self.apply(snapshot)
                if self.pending { self.filesChanged(.init(workingTree: true)) }
            }
        }
    }

    private func apply(_ s: Snapshot) {
        // Assign only what changed so the dock doesn't redraw on every poll.
        if root != s.root { root = s.root }
        if branch != s.branch { branch = s.branch }
        if upstream != s.upstream { upstream = s.upstream }
        if ahead != s.ahead { ahead = s.ahead }
        if behind != s.behind { behind = s.behind }
        if files != s.files { files = s.files }
        hasHead = s.hasHead
        watcher.watch(root: s.root, gitDirectories: s.gitDirectories)
    }

    /// File events arrive coalesced; a busy build can still produce a steady
    /// stream, so refreshes run at most once per second.
    private func filesChanged(_ change: GoviRepositoryWatcher.Change) {
        guard !directory.isEmpty else { return }
        guard isVisible else {
            stale = true
            return
        }
        if change.metadata { metadataRevision += 1 }
        guard !scheduled else { return }
        let wait = max(0, 1 - Date().timeIntervalSince(lastRefresh))
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh(self.directory)
        }
    }

    private static func read(_ path: String) -> Snapshot {
        typealias Git = GoviGitRunner
        guard let top = (try? Git.run(path, ["rev-parse", "--show-toplevel"]))?.trimmed.nonEmpty else { return Snapshot() }
        var snapshot = Snapshot(root: top)
        snapshot.gitDirectories = ((try? Git.run(top, ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
        snapshot.hasHead = (try? Git.run(top, ["rev-parse", "--verify", "--quiet", "HEAD"])) != nil
        snapshot.branch =
            (try? Git.run(top, ["symbolic-ref", "--short", "-q", "HEAD"]))?.trimmed.nonEmpty
            ?? (try? Git.run(top, ["rev-parse", "--short", "HEAD"]))?.trimmed.nonEmpty ?? "No commits yet"
        snapshot.upstream = (try? Git.run(top, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]))?.trimmed.nonEmpty
        if snapshot.upstream != nil, let counts = try? Git.run(top, ["rev-list", "--left-right", "--count", "@{u}...HEAD"]) {
            let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if parts.count == 2 {
                snapshot.behind = parts[0]
                snapshot.ahead = parts[1]
            }
        }

        // Status: "XY path\0", with the original path as an extra entry for renames/copies.
        let status = (try? Git.run(top, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])) ?? ""
        let entries = status.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [File] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            i += 1
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            var old: String?
            if code.contains("R") || code.contains("C"), i < entries.count {
                old = entries[i]
                i += 1
            }
            files.append(File(path: String(entry.dropFirst(3)), oldPath: old, code: code))
        }

        // Line counts against HEAD (or the empty tree before the first commit).
        let base = snapshot.hasHead ? "HEAD" : Git.emptyTree
        let numstat = (try? Git.run(top, ["diff", base, "--numstat", "-z", "-M"])) ?? ""
        var stats: [String: (Int?, Int?)] = [:]
        let records = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var j = 0
        while j < records.count {
            let columns = records[j].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            j += 1
            guard columns.count == 3 else { continue }
            var name = columns[2]
            if name.isEmpty {  // rename: "a\td\t\0old\0new\0"
                guard j + 1 < records.count else { break }
                name = records[j + 1]
                j += 2
            }
            stats[name] = (Int(columns[0]), Int(columns[1]))
        }
        for k in files.indices {
            if files[k].untracked {
                let url = URL(fileURLWithPath: top).appendingPathComponent(files[k].path)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 2_000_000, let data = try? Data(contentsOf: url) else {
                    files[k].additions = nil
                    files[k].deletions = nil
                    continue
                }
                if data.prefix(8000).contains(0) {
                    files[k].additions = nil
                    files[k].deletions = nil
                    continue
                }
                let newlines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                files[k].additions = newlines + (data.isEmpty || data.last == 10 ? 0 : 1)
            } else if let stat = stats[files[k].path] {
                files[k].additions = stat.0
                files[k].deletions = stat.1
            }
        }
        snapshot.files = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return snapshot
    }

    func diff(_ file: File, completion: @escaping (String) -> Void) {
        guard let top = root else {
            completion("")
            return
        }
        let base = hasHead ? "HEAD" : GoviGitRunner.emptyTree
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            if file.untracked {
                text = (try? GoviGitRunner.run(top, ["diff", "--no-index", "--", "/dev/null", file.path], allow: [0, 1])) ?? ""
            } else {
                text = (try? GoviGitRunner.run(top, ["diff", "-M", base, "--"] + file.paths)) ?? ""
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    func commit(message: String, files selected: [File], completion: @escaping (Bool) -> Void) {
        guard let top = root, busy == nil, !selected.isEmpty else { return }
        let paths = Array(Set(selected.flatMap(\.paths))).sorted()
        let count = selected.count
        busy = "Committing…"
        error = nil
        notice = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try GoviGitRunner.run(top, ["add", "-A", "--"] + paths, mergeErrors: true)
                try GoviGitRunner.run(top, ["commit", "-m", message, "--"] + paths, mergeErrors: true)
            }
            DispatchQueue.main.async {
                self.busy = nil
                switch result {
                case .success: self.notice = "Committed \(count) file\(count == 1 ? "" : "s")."
                case .failure(let failure): self.error = failure.localizedDescription
                }
                self.refresh(self.directory, force: true)
                if case .success = result { completion(true) } else { completion(false) }
            }
        }
    }

    func push() {
        guard let top = root, busy == nil else { return }
        let upstream = upstream
        busy = "Pushing…"
        error = nil
        notice = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> String in
                if upstream != nil {
                    try GoviGitRunner.run(top, ["push"], mergeErrors: true, timeout: GoviGit.networkTimeout)
                    return "Pushed to \(upstream!)."
                }
                let remotes = (try GoviGitRunner.run(top, ["remote"])).split(whereSeparator: \.isNewline).map(String.init)
                guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
                    throw NSError(
                        domain: "GoviGit", code: 1, userInfo: [NSLocalizedDescriptionKey: "This repository has no remote to push to."])
                }
                try GoviGitRunner.run(top, ["push", "-u", remote, "HEAD"], mergeErrors: true, timeout: GoviGit.networkTimeout)
                return "Pushed and set upstream to \(remote)."
            }
            DispatchQueue.main.async {
                self.busy = nil
                switch result {
                case .success(let message): self.notice = message
                case .failure(let failure): self.error = failure.localizedDescription
                }
                self.refresh(self.directory, force: true)
            }
        }
    }
}

// MARK: - Views

enum GoviGitColors {
    static let added = Color(red: 0.36, green: 0.80, blue: 0.48)
    static let removed = Color(red: 0.96, green: 0.42, blue: 0.42)
    static func kind(_ kind: String, accent: Color) -> Color {
        switch kind {
        case "A", "U": added
        case "D": removed
        case "R": Color(red: 0.45, green: 0.65, blue: 0.98)
        case "!": .orange
        default: accent
        }
    }
}

/// "+12 −3", green and red.
struct GoviDiffStat: View {
    let additions: Int?
    let deletions: Int?
    var size: CGFloat = 11.5
    var body: some View {
        HStack(spacing: 5) {
            if additions == nil && deletions == nil {
                Text("binary").foregroundStyle(.secondary)
            } else {
                Text("+\(additions ?? 0)").foregroundStyle(GoviGitColors.added)
                Text("−\(deletions ?? 0)").foregroundStyle(GoviGitColors.removed)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
    }
}

/// Colored, per-type file icons, in the spirit of an editor's file tree.
enum GoviFileIcon {
    static func icon(for name: String) -> (symbol: String, color: Color) {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        let blue = Color(red: 0.36, green: 0.62, blue: 0.98)
        let yellow = Color(red: 0.95, green: 0.78, blue: 0.30)
        let orange = Color(red: 0.98, green: 0.52, blue: 0.24)
        let green = Color(red: 0.42, green: 0.80, blue: 0.48)
        let purple = Color(red: 0.70, green: 0.52, blue: 0.95)
        let pink = Color(red: 0.95, green: 0.45, blue: 0.65)
        let teal = Color(red: 0.35, green: 0.78, blue: 0.80)
        let gray = Color(white: 0.62)
        let red = Color(red: 0.93, green: 0.38, blue: 0.36)
        switch lower {
        case "makefile", "dockerfile", "justfile": return ("hammer.fill", blue)
        case "license", "license.md", "license.txt": return ("checkmark.seal.fill", yellow)
        case ".gitignore", ".gitattributes", ".gitmodules": return ("arrow.triangle.branch", orange)
        case ".envrc", ".env": return ("key.fill", yellow)
        case "package.json", "package-lock.json": return ("shippingbox.fill", red)
        default: break
        }
        switch ext {
        case "swift": return ("swift", orange)
        case "zig", "zon": return ("bolt.fill", orange)
        case "c", "h", "m", "mm", "cpp", "hpp", "cc": return ("c.square.fill", blue)
        case "rs": return ("gearshape.2.fill", orange)
        case "go": return ("chevron.left.forwardslash.chevron.right", teal)
        case "js", "mjs", "cjs", "jsx": return ("curlybraces", yellow)
        case "ts", "tsx": return ("curlybraces", blue)
        case "json", "jsonc": return ("curlybraces.square.fill", yellow)
        case "py": return ("chevron.left.forwardslash.chevron.right", blue)
        case "rb": return ("diamond.fill", red)
        case "sh", "zsh", "bash", "fish": return ("dollarsign.square.fill", green)
        case "md", "markdown", "mdx": return ("arrow.down.doc.fill", blue)
        case "txt", "log": return ("doc.plaintext", gray)
        case "html", "htm", "xml", "plist": return ("chevron.left.forwardslash.chevron.right", orange)
        case "css", "scss", "sass": return ("paintbrush.fill", blue)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "icns", "ico", "tiff", "bmp": return ("photo.fill", purple)
        case "svg": return ("pencil.and.outline", yellow)
        case "ttf", "otf", "woff", "woff2": return ("textformat", pink)
        case "yml", "yaml", "toml", "conf", "ini", "cfg": return ("gearshape.fill", gray)
        case "lock", "sum": return ("lock.fill", gray)
        case "xib", "storyboard", "nib": return ("rectangle.on.rectangle", blue)
        case "pbxproj", "xcconfig", "entitlements", "xcscheme": return ("hammer.fill", blue)
        case "nix": return ("snowflake", teal)
        case "pdf": return ("doc.richtext.fill", red)
        case "zip", "gz", "tar", "xz", "dmg": return ("archivebox.fill", gray)
        case "profraw", "a", "o", "dylib": return ("cpu", gray)
        default: return ("doc.fill", gray)
        }
    }
}

/// One line of a parsed diff, with its old and new line numbers.
struct GoviDiffLine: Hashable {
    enum Kind { case context, added, removed, hunk, note }
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String

    static func parse(_ diff: String) -> [GoviDiffLine] {
        var rows: [GoviDiffLine] = []
        var old = 0
        var new = 0
        var started = false
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                started = true
                // @@ -a,b +c,d @@ context
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                rows.append(.init(kind: .hunk, old: nil, new: nil, text: line))
                continue
            }
            if !started {
                if line.hasPrefix("Binary files") { rows.append(.init(kind: .note, old: nil, new: nil, text: line)) }
                continue
            }
            if line.hasPrefix("+") {
                rows.append(.init(kind: .added, old: nil, new: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                rows.append(.init(kind: .removed, old: old, new: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix("\\") {
                rows.append(.init(kind: .note, old: nil, new: nil, text: line))
            } else if line.hasPrefix("diff --git") {
                started = false
            } else {
                rows.append(.init(kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        while let last = rows.last, last.kind == .context, last.text.isEmpty, last.old != nil { rows.removeLast() }
        return rows
    }

    /// Side-by-side rows: removals pair with the additions that follow them.
    static func split(_ lines: [GoviDiffLine]) -> [(left: GoviDiffLine?, right: GoviDiffLine?)] {
        var rows: [(left: GoviDiffLine?, right: GoviDiffLine?)] = []
        var removed: [GoviDiffLine] = []
        var added: [GoviDiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                rows.append((left: i < removed.count ? removed[i] : nil, right: i < added.count ? added[i] : nil))
            }
            removed = []
            added = []
        }
        for line in lines {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added: added.append(line)
            default:
                flush()
                rows.append((left: line, right: line))
            }
        }
        flush()
        return rows
    }
}

/// A folder or file row in the changes tree.
private struct GoviGitTreeRow: Identifiable {
    let id: String
    let depth: Int
    let name: String
    let file: GoviGitChanges.File?
    let descendants: [GoviGitChanges.File]
}

private enum GoviGitTree {
    final class Node {
        let name: String, path: String
        var folders: [String: Node] = [:]
        var files: [GoviGitChanges.File] = []
        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
        var allFiles: [GoviGitChanges.File] { files + folders.values.flatMap(\.allFiles) }
    }

    static func rows(_ files: [GoviGitChanges.File], collapsed: Set<String>) -> [GoviGitTreeRow] {
        let root = Node(name: "", path: "")
        for file in files {
            var node = root
            for component in file.path.split(separator: "/").dropLast().map(String.init) {
                let path = node.path.isEmpty ? component : node.path + "/" + component
                if node.folders[component] == nil { node.folders[component] = Node(name: component, path: path) }
                node = node.folders[component]!
            }
            node.files.append(file)
        }
        var rows: [GoviGitTreeRow] = []
        func walk(_ node: Node, depth: Int) {
            for folder in node.folders.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                // Compact single-child chains ("macos/Sources/Features"), like an editor does.
                var current = folder
                var name = folder.name
                while current.files.isEmpty, current.folders.count == 1, let only = current.folders.values.first {
                    name += "/" + only.name
                    current = only
                }
                rows.append(.init(id: "dir:" + current.path, depth: depth, name: name, file: nil, descendants: current.allFiles))
                if !collapsed.contains(current.path) { walk(current, depth: depth + 1) }
            }
            for file in node.files.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(.init(id: file.path, depth: depth, name: file.name, file: file, descendants: [file]))
            }
        }
        walk(root, depth: 0)
        return rows
    }
}

/// Changed files as a tree, a diff of the selected one, and commit/push.
/// Floats above the dock, or fills the terminal area as a full-size pane.
struct GoviGitPanel: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject var changes: GoviGitChanges
    let directory: String
    var expanded = false
    var toggleExpanded: () -> Void = {}
    let close: () -> Void
    @AppStorage("GoviGitDiffSplit") private var splitDiff = false
    @State private var selected: String?
    @State private var excluded: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var diffText = ""
    @State private var loadingDiff = false
    @State private var message = ""
    @FocusState private var messageFocused: Bool
    /// A slow fallback; file events drive normal refreshes.
    private let refreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var included: [GoviGitChanges.File] { changes.files.filter { !excluded.contains($0.path) } }
    private var selectedFile: GoviGitChanges.File? { changes.files.first { $0.path == selected } }
    private var canCommit: Bool {
        changes.busy == nil && !included.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).frame(height: 50)
            separator
            if changes.root == nil {
                emptyState(
                    "Not a Git repository", detail: "Open a terminal inside a repository to see its changes.",
                    icon: "folder.badge.questionmark")
            } else if changes.files.isEmpty {
                emptyState("No changes", detail: upToDateText, icon: "checkmark.circle")
            } else {
                HStack(spacing: 0) {
                    fileTree.frame(width: expanded ? 320 : 280)
                    ui.ink.opacity(0.1).frame(width: 0.5)
                    diffView
                }
            }
            separator
            footer.padding(12)
        }
        .foregroundStyle(ui.ink).font(GoviInk.font(12.5))
        .frame(width: expanded ? nil : 820, height: expanded ? nil : 560)
        .frame(maxWidth: expanded ? .infinity : nil, maxHeight: expanded ? .infinity : nil)
        .modifier(GoviGlassPanel(tint: expanded ? 0.82 : 0.6))
        .onAppear {
            changes.refresh(directory, force: true)
            syncSelection()
        }
        .onReceive(refreshTimer) { _ in if changes.isVisible { changes.refresh(directory) } }
        .onChange(of: changes.files) { _ in
            syncSelection()
            loadDiff()
        }
        .onChange(of: selected) { _ in loadDiff() }
        .onExitCommand(perform: close)
    }

    private var separator: some View { ui.ink.opacity(0.1).frame(height: 0.5) }

    private var upToDateText: String {
        guard let upstream = changes.upstream else { return "Working tree is clean. This branch has no upstream yet." }
        if changes.ahead > 0 {
            return "Working tree is clean. \(changes.ahead) commit\(changes.ahead == 1 ? "" : "s") ahead of \(upstream)."
        }
        if changes.behind > 0 { return "Working tree is clean. \(changes.behind) behind \(upstream)." }
        return "Working tree is clean and up to date with \(upstream)."
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .medium)).foregroundStyle(ui.muted)
            Text(changes.branch.isEmpty ? "Git" : changes.branch).font(GoviInk.font(13.5).weight(.semibold)).lineLimit(1)
            if changes.upstream != nil && (changes.ahead > 0 || changes.behind > 0) {
                HStack(spacing: 6) {
                    if changes.ahead > 0 { Label("\(changes.ahead)", systemImage: "arrow.up") }
                    if changes.behind > 0 { Label("\(changes.behind)", systemImage: "arrow.down") }
                }.labelStyle(.titleAndIcon).font(GoviInk.font(11)).foregroundStyle(ui.muted)
                    .help("Commits ahead of / behind \(changes.upstream ?? "upstream")")
            }
            if let root = changes.root {
                Text(GoviPaneNaming.shortPath(root)).font(GoviInk.font(11)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if !changes.files.isEmpty {
                Text("\(changes.files.count) file\(changes.files.count == 1 ? "" : "s")").font(GoviInk.font(11.5)).foregroundStyle(ui.muted)
                GoviDiffStat(additions: changes.additions, deletions: changes.deletions)
            }
            HStack(spacing: 0) {
                GoviIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    changes.refresh(directory, force: true)
                    loadDiff()
                }
                GoviIconButton(
                    symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: expanded ? "Shrink to a floating panel" : "Expand to a full-size pane", action: toggleExpanded)
                GoviIconButton(symbol: "xmark", help: "Close (Esc)", action: close)
            }
        }
    }

    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(ui.muted)
            Text(title).font(GoviInk.font(14).weight(.medium))
            Text(detail).font(GoviInk.font(12)).foregroundStyle(ui.muted).multilineTextAlignment(.center)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tree

    private var fileTree: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GoviCheck(state: checkState(changes.files)) { setIncluded(changes.files, checkState(changes.files) != .all) }
                Text("CHANGES").font(GoviInk.font(10.5).weight(.semibold)).tracking(0.5).foregroundStyle(ui.muted)
                Text("\(changes.files.count)").font(GoviInk.font(10).weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1).background(ui.accent.opacity(0.25), in: Capsule())
                Spacer()
                Button {
                    let folders = GoviGitTree.rows(changes.files, collapsed: []).filter { $0.file == nil }.map {
                        String($0.id.dropFirst(4))
                    }
                    collapsed = collapsed.isEmpty ? Set(folders) : []
                } label: {
                    Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical").font(
                        .system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(ui.muted).help(collapsed.isEmpty ? "Collapse all folders" : "Expand all folders")
            }.padding(.horizontal, 12).frame(height: 32)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(GoviGitTree.rows(changes.files, collapsed: collapsed)) { row in
                        treeRow(row)
                    }
                }.padding(.horizontal, 6).padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private func treeRow(_ row: GoviGitTreeRow) -> some View {
        if let file = row.file {
            GoviGitFileRow(file: file, depth: row.depth, selected: selected == file.path, included: !excluded.contains(file.path)) {
                selected = file.path
            } toggle: {
                setIncluded([file], excluded.contains(file.path))
            }
        } else {
            let path = String(row.id.dropFirst(4))
            GoviGitFolderRow(
                name: row.name, depth: row.depth, open: !collapsed.contains(path),
                count: row.descendants.count, check: checkState(row.descendants)
            ) {
                if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
            } toggle: {
                setIncluded(row.descendants, checkState(row.descendants) != .all)
            }
        }
    }

    private func checkState(_ files: [GoviGitChanges.File]) -> GoviCheck.Mark {
        let count = files.filter { !excluded.contains($0.path) }.count
        return count == 0 ? .none : count == files.count ? .all : .some
    }
    private func setIncluded(_ files: [GoviGitChanges.File], _ include: Bool) {
        for file in files { if include { excluded.remove(file.path) } else { excluded.insert(file.path) } }
    }

    // MARK: Diff

    private var diffView: some View {
        let lines = GoviDiffLine.parse(diffText)
        let shown = Array(lines.prefix(4000))
        let width = max(3, String(shown.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0).count)
        return VStack(alignment: .leading, spacing: 0) {
            if let file = selectedFile {
                let icon = GoviFileIcon.icon(for: file.name)
                HStack(spacing: 8) {
                    Image(systemName: icon.symbol).font(.system(size: 11.5)).foregroundStyle(icon.color)
                    Text(file.path).font(GoviInk.font(11.5).weight(.medium)).lineLimit(1).truncationMode(.head)
                    if let old = file.oldPath { Text("from \(old)").font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1) }
                    Spacer(minLength: 6)
                    if loadingDiff { ProgressView().controlSize(.mini) }
                    GoviDiffStat(additions: file.additions, deletions: file.deletions, size: 11)
                    HStack(spacing: 0) {
                        GoviIconButton(symbol: "rectangle", help: "Unified diff", on: !splitDiff) { splitDiff = false }
                        GoviIconButton(symbol: "rectangle.split.2x1", help: "Side-by-side diff", on: splitDiff) { splitDiff = true }
                    }.scaleEffect(0.9)
                }.padding(.leading, 14).padding(.trailing, 8).frame(height: 34)
                ui.ink.opacity(0.08).frame(height: 0.5)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty && !loadingDiff {
                        Text(selectedFile == nil ? "Select a file to see its diff." : "No textual changes.")
                            .font(GoviInk.font(12)).foregroundStyle(ui.muted).padding(14)
                    }
                    if splitDiff {
                        ForEach(Array(GoviDiffLine.split(shown).enumerated()), id: \.offset) { _, pair in
                            if let left = pair.left, left.kind == .hunk || left.kind == .note {
                                fullRow(left)
                            } else {
                                HStack(alignment: .top, spacing: 0) {
                                    half(pair.left, number: pair.left?.old, width: width, side: .removed)
                                    ui.ink.opacity(0.1).frame(width: 0.5)
                                    half(pair.right, number: pair.right?.new, width: width, side: .added)
                                }
                            }
                        }
                    } else {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in unifiedRow(line, width: width) }
                    }
                    if lines.count > shown.count {
                        Text("Diff truncated · \(lines.count - shown.count) more lines").font(GoviInk.font(11)).foregroundStyle(ui.muted)
                            .padding(14)
                    }
                }.padding(.bottom, 8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var codeFont: Font { .custom(GoviFontCatalog.selected, size: 12) }

    private func tint(_ kind: GoviDiffLine.Kind) -> Color {
        switch kind {
        case .added: GoviGitColors.added.opacity(0.15)
        case .removed: GoviGitColors.removed.opacity(0.15)
        case .hunk: ui.accent.opacity(0.08)
        default: .clear
        }
    }

    private func gutter(_ number: Int?, width: Int) -> some View {
        Text(number.map(String.init) ?? "").font(codeFont).foregroundStyle(ui.muted.opacity(0.7)).monospacedDigit()
            .frame(width: CGFloat(width) * 7.6 + 10, alignment: .trailing)
    }

    private func code(_ text: String, kind: GoviDiffLine.Kind) -> some View {
        Text(text.isEmpty ? " " : text).font(codeFont)
            .foregroundStyle(kind == .added ? GoviGitColors.added : kind == .removed ? GoviGitColors.removed : ui.ink.opacity(0.88))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fullRow(_ line: GoviDiffLine) -> some View {
        Text(line.text).font(codeFont).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 14).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading).background(tint(line.kind))
    }

    @ViewBuilder private func unifiedRow(_ line: GoviDiffLine, width: Int) -> some View {
        if line.kind == .hunk || line.kind == .note {
            fullRow(line)
        } else {
            HStack(alignment: .top, spacing: 0) {
                gutter(line.old, width: width)
                gutter(line.new, width: width)
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").font(codeFont)
                    .foregroundStyle(line.kind == .added ? GoviGitColors.added : GoviGitColors.removed)
                    .frame(width: 22)
                code(line.text, kind: line.kind)
            }.padding(.trailing, 12).padding(.vertical, 1).background(tint(line.kind))
        }
    }

    private func half(_ line: GoviDiffLine?, number: Int?, width: Int, side: GoviDiffLine.Kind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            gutter(number, width: width)
            if let line { code(line.text, kind: line.kind) } else { Spacer(minLength: 0) }
        }
        .padding(.trailing, 10).padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(line.map { tint($0.kind) } ?? ui.ink.opacity(0.03))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let busy = changes.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(busy)
                }.font(GoviInk.font(11.5)).foregroundStyle(ui.muted)
            } else if let error = changes.error {
                Text(error).font(GoviInk.font(11.5)).foregroundStyle(GoviGitColors.removed).textSelection(.enabled)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            } else if let notice = changes.notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(GoviInk.font(11.5)).foregroundStyle(GoviGitColors.added)
            }
            HStack(spacing: 8) {
                if !changes.files.isEmpty {
                    TextField("Commit message", text: $message).textFieldStyle(.plain).font(GoviInk.font(13))
                        .focused($messageFocused)
                        .onSubmit(commit)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(ui.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                                ui.ink.opacity(messageFocused ? 0.25 : 0.08), lineWidth: 1))
                    Button(action: commit) {
                        Label(included.count == changes.files.count ? "Commit all" : "Commit \(included.count)", systemImage: "checkmark")
                    }.buttonStyle(GoviPillButtonStyle(prominent: true)).disabled(!canCommit)
                        .help("Stage the selected files and commit them (Return)")
                } else {
                    Spacer()
                }
                Button(action: changes.push) {
                    Label(changes.ahead > 0 ? "Push \(changes.ahead)" : "Push", systemImage: "arrow.up")
                }.buttonStyle(GoviPillButtonStyle(prominent: changes.files.isEmpty && changes.ahead > 0))
                    .disabled(changes.root == nil || changes.busy != nil)
                    .help(changes.upstream.map { "Push to \($0)" } ?? "Push and set the upstream branch")
            }
        }
    }

    private func syncSelection() {
        let paths = Set(changes.files.map(\.path))
        excluded = excluded.intersection(paths)
        if selected == nil || !paths.contains(selected!) { selected = changes.files.first?.path }
    }

    private func loadDiff() {
        guard let file = selectedFile else {
            diffText = ""
            return
        }
        loadingDiff = true
        changes.diff(file) { text in
            guard selected == file.path else { return }
            loadingDiff = false
            if diffText != text { diffText = text }
        }
    }

    private func commit() {
        guard canCommit else { return }
        changes.commit(message: message.trimmingCharacters(in: .whitespacesAndNewlines), files: included) { ok in
            if ok {
                message = ""
                excluded = []
            }
        }
    }
}

/// Tri-state inclusion checkbox.
struct GoviCheck: View {
    enum Mark { case none, some, all }
    @Environment(\.goviPalette) private var ui
    let state: Mark
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.circle.fill" : state == .some ? "minus.circle.fill" : "circle")
                .font(.system(size: 12.5)).foregroundStyle(state == .none ? ui.muted : ui.accent)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).help(state == .all ? "Exclude from commit" : "Include in commit")
    }
}

private enum GoviTreeMetrics {
    static let row: CGFloat = 26
    static let indent: CGFloat = 14
}

private struct GoviGitFolderRow: View {
    @Environment(\.goviPalette) private var ui
    let name: String
    let depth: Int
    let open: Bool
    let count: Int
    let check: GoviCheck.Mark
    let select: () -> Void
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 6) {
            GoviCheck(state: check, action: toggle)
            Color.clear.frame(width: CGFloat(depth) * GoviTreeMetrics.indent, height: 1)
            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(ui.muted)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
            Image(systemName: open ? "folder.fill" : "folder").font(.system(size: 11.5))
                .foregroundStyle(Color(red: 0.45, green: 0.66, blue: 0.95))
            Text(name).font(GoviInk.font(12.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(count)").font(GoviInk.font(10)).monospacedDigit().foregroundStyle(ui.muted).opacity(hovering ? 1 : 0.7)
        }
        .padding(.horizontal, 6).frame(height: GoviTreeMetrics.row)
        .background(ui.ink.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

private struct GoviGitFileRow: View {
    @Environment(\.goviPalette) private var ui
    let file: GoviGitChanges.File
    let depth: Int
    let selected: Bool
    let included: Bool
    let select: () -> Void
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        let icon = GoviFileIcon.icon(for: file.name)
        let kindColor = GoviGitColors.kind(file.kind, accent: Color(red: 0.90, green: 0.72, blue: 0.35))
        HStack(spacing: 6) {
            GoviCheck(state: included ? .all : .none, action: toggle)
            Color.clear.frame(width: CGFloat(depth) * GoviTreeMetrics.indent + 10, height: 1)
            Image(systemName: icon.symbol).font(.system(size: 11)).foregroundStyle(icon.color).frame(width: 14)
            Text(file.name).font(GoviInk.font(12.5)).lineLimit(1).truncationMode(.middle)
                .strikethrough(file.kind == "D", color: ui.muted)
                .foregroundStyle(file.kind == "D" ? ui.muted : kindColor.opacity(0.95))
            Spacer(minLength: 4)
            if hovering || selected {
                GoviDiffStat(additions: file.additions, deletions: file.deletions, size: 10)
            }
            Text(file.kind).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(kindColor).frame(width: 12)
        }
        .padding(.horizontal, 6).frame(height: GoviTreeMetrics.row)
        .background(
            selected ? ui.accent.opacity(0.22) : ui.ink.opacity(hovering ? 0.05 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

struct GoviPillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { Pill(configuration: configuration, prominent: prominent) }
    private struct Pill: View {
        @Environment(\.goviPalette) private var ui
        @Environment(\.isEnabled) private var enabled
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(GoviInk.font(12.5).weight(.medium))
                .padding(.horizontal, 14).frame(height: 34)
                .foregroundStyle(prominent ? ui.canvas : ui.ink)
                .background(prominent ? ui.ink.opacity(hovering ? 0.9 : 1) : ui.ink.opacity(hovering ? 0.13 : 0.08), in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}
