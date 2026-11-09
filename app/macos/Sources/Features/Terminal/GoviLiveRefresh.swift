import AppKit
import CoreServices
import SwiftUI

/// Coalesced FSEvents for a repository's working tree and git directories, so
/// git state refreshes when something changes instead of on a fast timer.
final class GoviRepositoryWatcher {
    struct Change {
        /// A file outside the git directories changed.
        var workingTree = false
        /// HEAD, refs, the index or worktree metadata changed.
        var metadata = false
    }

    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private var gitDirectories: [String] = []
    private let handler: (Change) -> Void

    /// `handler` runs on the main queue.
    init(handler: @escaping (Change) -> Void) { self.handler = handler }
    deinit { stop() }

    /// Watches `root` plus git directories that may live outside it (linked
    /// worktrees keep HEAD and the index under the main repository's .git).
    func watch(root: String?, gitDirectories: [String]) {
        let directories = gitDirectories.map(Self.normalized)
        let wanted = root.map { Self.minimal([Self.normalized($0)] + directories) } ?? []
        guard wanted != paths else { return }
        stop()
        paths = wanted
        self.gitDirectories = directories
        guard !wanted.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GoviRepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.received(Array(changed.prefix(count)))
        }, &context, wanted as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ changed: [String]) {
        var change = Change()
        for path in changed {
            if let category = Self.classify(path, gitDirectories: gitDirectories) {
                if category { change.metadata = true } else { change.workingTree = true }
            }
            if change.metadata && change.workingTree { break }
        }
        if change.metadata || change.workingTree { handler(change) }
    }

    /// true for git metadata, false for working-tree files, nil for noise
    /// (object writes and lock files) that never changes what Govi shows.
    static func classify(_ path: String, gitDirectories: [String]) -> Bool? {
        let inGitDirectory = gitDirectories.contains { path == $0 || path.hasPrefix($0 + "/") } || path.contains("/.git/")
        guard inGitDirectory else { return false }
        if path.contains("/objects/") || path.hasSuffix(".lock") { return nil }
        return true
    }

    /// Drops paths already covered by a parent in the list.
    static func minimal(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths)).sorted()
        return unique.filter { path in !unique.contains { $0 != path && path.hasPrefix($0 + "/") } }
    }

    private static func normalized(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Whether a window is on screen (not minimized, hidden or fully covered).
/// Views use it to skip background refreshes nobody can see.
@MainActor final class GoviWindowVisibility: ObservableObject {
    @Published private(set) var visible = true
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow?) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.window = window
        guard let window else { return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    private func update() {
        guard let window else { return }
        let value = window.occlusionState.contains(.visible) && !window.isMiniaturized
        if value != visible { visible = value }
    }
}

/// Reports the hosting NSWindow to a `GoviWindowVisibility`.
struct GoviWindowVisibilityReader: NSViewRepresentable {
    let visibility: GoviWindowVisibility

    func makeNSView(context: Context) -> NSView { Reader(visibility) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let visibility: GoviWindowVisibility
        init(_ visibility: GoviWindowVisibility) { self.visibility = visibility; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            MainActor.assumeIsolated { visibility.attach(window) }
        }
    }
}
