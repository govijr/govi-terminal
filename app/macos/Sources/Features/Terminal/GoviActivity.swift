import SwiftUI
import AppKit
import Combine
import UserNotifications

/// What a session is doing, as far as Govi can tell from signals the terminal
/// engine already reports. Nothing here reads screen text.
///
/// Signals:
/// - OSC 9;4 progress reports (Claude Code and others emit these while working).
/// - Rapid title changes (agents animate a spinner in the title while working).
/// - OSC 9 / OSC 777 desktop notifications and the bell (agents use these when
///   they stop and need an answer).
/// - Whether a program is running in the foreground (shell integration).

/// How a session was started from Govi, when it was.
struct GoviLaunch {
    var executable: String?
    var agent: GoviAgent?
    var directory: String?
    var label: String?
    var arguments: [String] = []
    var issue: GoviTaskLink?
}

enum GoviActivityPreferences {
    static let notifyKey = "GoviAgentNotifications"
    static let badgeKey = "GoviAgentDockBadge"
    static var notify: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
    static var badge: Bool { UserDefaults.standard.object(forKey: badgeKey) as? Bool ?? true }
}

@MainActor final class GoviActivityCenter: ObservableObject {
    static let shared = GoviActivityCenter()

    struct Info: Equatable {
        var state: GoviActivityState = .idle
        var agent: GoviAgent?
        var label: String?
        var project = ""
        var branch = ""
        var startedAt: Date?
        var endedAt: Date?
        var changedAt = Date.distantPast
        var reported = false
    }
    @Published private(set) var info: [UUID: Info] = [:]

    private final class Entry {
        weak var surface: Ghostty.SurfaceView?
        var agent: GoviAgent?
        var label: String?
        var progressActive = false
        var progressAt = Date.distantPast
        var titleChanges: [Date] = []
        var attention = false
        var finished = false
        var failed = false
        var workingSince: Date?
        var reported: GoviReportedActivity?
        var taskStartedAt: Date?
        var taskEndedAt: Date?
        var changedAt = Date()
        var project = ""
        var branch = ""
        var contextAt = Date.distantPast
        var contextBusy = false
        var subscriptions = Set<AnyCancellable>()
        init(_ surface: Ghostty.SurfaceView) { self.surface = surface }
    }
    private var entries: [UUID: Entry] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// A working stretch shorter than this doesn't produce a "Done".
    private let minimumWork: TimeInterval = 3
    /// Title changes within this window count as activity.
    private let titleWindow: TimeInterval = 4
    /// A progress report without a running program expires after this.
    private let progressTimeout: TimeInterval = 15

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in GoviActivityCenter.shared.acknowledgeVisible() }
                })
        }
        observers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in GoviActivityCenter.shared.updateBadge() }
            })
    }

    // MARK: Inputs

    func track(_ surface: Ghostty.SurfaceView) {
        guard entries[surface.id] == nil else { return }
        let entry = Entry(surface)
        let id = surface.id
        surface.$title.dropFirst().removeDuplicates().sink { [weak self] _ in
            entry.titleChanges.append(Date())
            self?.evaluate(id)
        }.store(in: &entry.subscriptions)
        surface.$bell.removeDuplicates().sink { [weak self] ringing in
            if ringing { self?.noteAttention(id, notify: true) }
        }.store(in: &entry.subscriptions)
        surface.$focusInstant.compactMap { $0 }.sink { [weak self] _ in
            self?.acknowledge(id)
        }.store(in: &entry.subscriptions)
        entries[id] = entry
        surface.$pwd.removeDuplicates().sink { [weak self] _ in self?.refreshContext(id, force: true) }.store(in: &entry.subscriptions)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in GoviActivityCenter.shared.tick() }
            }
        }
    }

    /// Record how Govi started this session, for its icon and caption.
    func tag(_ surface: Ghostty.SurfaceView, agent: GoviAgent?, label: String?) {
        track(surface)
        if let agent { surface.goviLaunch.agent = agent.rawValue }
        if let label { surface.goviLaunch.task = label }
        entries[surface.id]?.agent = agent
        entries[surface.id]?.label = label
        evaluate(surface.id)
    }

    func noteProgress(_ surface: Ghostty.SurfaceView, _ report: Ghostty.Action.ProgressReport) {
        track(surface)
        guard let entry = entries[surface.id] else { return }
        switch report.state {
        case .set, .indeterminate, .pause:
            entry.progressActive = true
            if entry.reported == nil {
                entry.failed = false
                entry.finished = false
            }
        case .error:
            entry.progressActive = false
            if !isLooking(at: surface) { entry.failed = true }
        case .remove: entry.progressActive = false
        }
        entry.progressAt = Date()
        evaluate(surface.id)
    }

    func receive(_ signal: GoviActivitySignal) {
        guard let owner = GoviPaneCoordinator.owner(of: signal.id), let surface = owner.surfaceTree.surfaces.first(where: { $0.id == signal.id })
        else { return }
        track(surface)
        guard let entry = entries[signal.id] else { return }
        let previous = entry.reported?.visibleState
        var report = entry.reported ?? GoviReportedActivity()
        report.receive(signal.state)
        if isLooking(at: surface) { report.acknowledge() }
        entry.reported = report
        if let label = signal.label, !label.isEmpty {
            entry.label = label
            surface.goviLaunch.task = label
        }
        evaluate(signal.id)
        if report.visibleState.wantsAttention && previous != report.visibleState { post(entry, body: report.visibleState.label) }
    }

    /// OSC 9 / OSC 777. Ghostty already posts the system notification for these.
    func noteNotification(_ surface: Ghostty.SurfaceView) {
        track(surface)
        noteAttention(surface.id, notify: false)
    }

    // MARK: State

    private func noteAttention(_ id: UUID, notify: Bool) {
        guard let entry = entries[id], let surface = entry.surface, !isLooking(at: surface) else { return }
        let wasWaiting = entry.attention
        entry.attention = true
        entry.changedAt = Date()
        evaluate(id)
        if notify && !wasWaiting { post(entry, body: "Needs your input.") }
    }

    func acknowledge(_ id: UUID) {
        guard let entry = entries[id] else { return }
        entry.reported?.acknowledge()
        entry.attention = false
        entry.finished = false
        entry.failed = false
        evaluate(id)
    }

    private func acknowledgeVisible() {
        for (id, entry) in entries {
            if let surface = entry.surface, isLooking(at: surface) { acknowledge(id) }
        }
        updateBadge()
    }

    private func isLooking(at surface: Ghostty.SurfaceView) -> Bool {
        NSApp.isActive && surface.window?.isKeyWindow == true && surface.window?.firstResponder === surface
    }

    private func tick() {
        for (id, entry) in entries where entry.surface == nil || GoviPaneCoordinator.owner(of: id) == nil {
            entries[id] = nil
            info[id] = nil
        }
        for id in entries.keys {
            evaluate(id)
            if info[id]?.agent != nil || info[id]?.state.wantsAttention == true { refreshContext(id) }
        }
        if Self.badgeCount != attentionCount {
            Self.badgeCount = attentionCount
            updateBadge()
        }
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func evaluate(_ id: UUID) {
        guard let entry = entries[id], let surface = entry.surface else { return }
        let now = Date()
        entry.titleChanges.removeAll { now.timeIntervalSince($0) > titleWindow }

        let running = surface.needsConfirmQuit && !surface.processExited
        let progressWorking = entry.progressActive && (running || now.timeIntervalSince(entry.progressAt) < progressTimeout)
        let titleWorking = entry.titleChanges.count >= 3 || Self.hasSpinner(surface.title)
        let working = progressWorking || (running && titleWorking)

        if entry.reported == nil, working {
            if entry.workingSince == nil { entry.workingSince = now }
            if entry.taskStartedAt == nil || entry.taskEndedAt != nil {
                entry.taskStartedAt = now
                entry.taskEndedAt = nil
            }
            entry.finished = false
        } else if entry.reported == nil, let since = entry.workingSince {
            entry.workingSince = nil
            if now.timeIntervalSince(since) >= minimumWork && !isLooking(at: surface) && !entry.attention {
                entry.finished = true
                entry.taskEndedAt = now
                entry.changedAt = now
                post(entry, body: entry.failed ? "Stopped with an error." : "Finished.")
            }
        }

        let inferred: GoviActivityState =
            entry.failed ? .error : entry.attention ? .needsInput : working ? .working : entry.finished ? .done : .idle
        let state = entry.reported?.visibleState ?? inferred
        if info[id]?.state != state { entry.changedAt = now }
        let next = Info(
            state: state, agent: entry.agent, label: entry.label,
            project: entry.project, branch: entry.branch,
            startedAt: entry.reported?.startedAt ?? entry.taskStartedAt,
            endedAt: entry.reported?.endedAt ?? entry.taskEndedAt,
            changedAt: entry.reported?.changedAt ?? entry.changedAt, reported: entry.reported != nil)
        if info[id] != next {
            info[id] = next
            Self.badgeCount = attentionCount
            updateBadge()
        }
    }

    private func refreshContext(_ id: UUID, force: Bool = false) {
        guard let entry = entries[id], let path = entry.surface?.pwd, !entry.contextBusy,
            force || Date().timeIntervalSince(entry.contextAt) >= 15
        else { return }
        entry.contextBusy = true
        entry.contextAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let top = GoviLocalProcess.run("/usr/bin/git", ["-C", path, "rev-parse", "--show-toplevel"], timeout: 2)
            let branch = GoviLocalProcess.run("/usr/bin/git", ["-C", path, "branch", "--show-current"], timeout: 2)
            let root = top?.status == 0 ? top!.output.trimmingCharacters(in: .whitespacesAndNewlines) : path
            let name = branch?.status == 0 ? branch!.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            DispatchQueue.main.async { [weak self] in
                guard let self, let entry = self.entries[id] else { return }
                entry.contextBusy = false
                guard entry.surface?.pwd == path else {
                    entry.contextAt = .distantPast
                    return
                }
                entry.project = URL(fileURLWithPath: root).lastPathComponent
                entry.branch = name
                self.evaluate(id)
            }
        }
    }

    struct QueueItem: Identifiable {
        let id: UUID
        let title: String
        let path: String
        let info: Info
    }
    var queue: [QueueItem] {
        entries.compactMap { id, entry in
            guard let value = info[id], value.state.wantsAttention, let surface = entry.surface,
                GoviPaneCoordinator.owner(of: id) != nil
            else { return nil }
            return QueueItem(
                id: id, title: entry.label ?? entry.agent?.name ?? GoviPaneNaming.title(surface), path: surface.pwd ?? "", info: value)
        }.sorted {
            func rank(_ state: GoviActivityState) -> Int { state == .needsInput ? 0 : state == .error ? 1 : 2 }
            if rank($0.info.state) != rank($1.info.state) { return rank($0.info.state) < rank($1.info.state) }
            return $0.info.changedAt == $1.info.changedAt ? $0.id.uuidString < $1.id.uuidString : $0.info.changedAt < $1.info.changedAt
        }
    }
    func focusNext() {
        guard let item = queue.first else {
            NSSound.beep()
            return
        }
        GoviNavigation.focus(item.id)
        acknowledge(item.id)
    }

    /// Braille spinner glyphs, as used by Claude Code, Codex and many CLIs.
    private static func hasSpinner(_ title: String) -> Bool {
        guard let scalar = title.unicodeScalars.first else { return false }
        return (0x2801...0x28FF).contains(scalar.value)
    }

    var attentionCount: Int { info.values.filter { $0.state.wantsAttention }.count }
    /// Last computed count, readable from AppKit callbacks outside the main actor's checking.
    nonisolated(unsafe) static var badgeCount = 0

    func updateBadge() {
        guard !NSApp.isActive else { return }
        let count = attentionCount
        NSApp.dockTile.badgeLabel = GoviActivityPreferences.badge && count > 0 ? String(count) : nil
        NSApp.dockTile.display()
    }

    private func post(_ entry: Entry, body: String) {
        guard GoviActivityPreferences.notify, let surface = entry.surface, !isLooking(at: surface) else { return }
        let name = entry.agent?.name ?? GoviPaneNaming.title(surface)
        let place = entry.label ?? surface.pwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let title = place.map { "\(name) · \($0)" } ?? name
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    surface.showUserNotification(title: title, body: body)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        guard granted else { return }
                        Task { @MainActor in surface.showUserNotification(title: title, body: body) }
                    }
                default: break
                }
            }
        }
    }
}

/// Small status mark for a session row.
struct GoviActivityBadge: View {
    let state: GoviActivityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Group {
            switch state {
            case .idle: EmptyView()
            case .working:
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .opacity(pulse ? 0.35 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                    }
            case .needsInput:
                Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.orange)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.red)
            }
        }
        .help(state.label)
        .accessibilityLabel(state.label)
    }
}

struct GoviActivitySettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage(GoviActivityPreferences.notifyKey) private var notify = true
    @AppStorage(GoviActivityPreferences.badgeKey) private var badge = true
    @AppStorage("GoviClaudeStatusHooks") private var claudeHooks = true

    var body: some View {
        ScrollView { content.padding(.bottom, 12) }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("Know when an agent needs you.").font(GoviInk.font(15).weight(.regular))
            Text("Sessions in the sidebar show whether they're working, waiting for input, done or stopped with an error.")
                .foregroundStyle(ui.muted).lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                row(.working, "A program reports progress or animates its title.")
                row(.needsInput, "A program sends a notification or rings the bell.")
                row(.done, "Work finished while you were looking elsewhere.")
                row(.error, "A program reported an error.")
            }.padding(14).background(ui.canvas, in: RoundedRectangle(cornerRadius: 8))
            Toggle("Notify me when a background session finishes or needs input", isOn: $notify)
            Toggle("Show the count on the Dock icon", isOn: $badge)
                .onChange(of: badge) { _ in GoviActivityCenter.shared.updateBadge() }
            Toggle("Use precise status hooks for Claude Code", isOn: $claudeHooks)
            Text(
                "Applies to Claude sessions opened from Govi's launcher and templates. Hooks report working, permission requests and completion without reading prompts or changing permission decisions. Existing Claude settings stay in place. Other agents use their terminal progress and notifications."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            Divider()
            GoviPersistenceSettingsView()
            Text(
                "Status comes from agent hooks and terminal signals, not from what's on screen. Opening a terminal marks its attention item as seen."
            )
            .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
        }
    }
    private func row(_ state: GoviActivityState, _ text: String) -> some View {
        HStack(spacing: 10) {
            GoviActivityBadge(state: state).frame(width: 14)
            Text(state.label).frame(width: 90, alignment: .leading)
            Text(text).foregroundStyle(ui.muted)
        }.font(GoviInk.font(12))
    }
}

/// A compact menu using the same native glass surface as the agent launcher.
struct GoviAttentionMenu: View {
    let dismiss: () -> Void
    @ObservedObject private var activity = GoviActivityCenter.shared
    @Environment(\.goviPalette) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Notifications").font(GoviInk.font(13).weight(.medium))
                if !activity.queue.isEmpty {
                    Text("\(activity.queue.count)").font(GoviInk.font(10)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(ui.ink.opacity(0.08), in: Capsule())
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(ui.muted).help("Close notifications")
            }.padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            GoviMenuDivider()
            if activity.queue.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(ui.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("All caught up").font(GoviInk.font(12.5))
                        Text("Terminals that need you appear here.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(activity.queue) { item in queueRow(item) }
                    }
                }.frame(height: min(CGFloat(activity.queue.count) * 72, 360))
                GoviMenuDivider()
                GoviMenuRow(title: "Open next", icon: { Image(systemName: "arrow.turn.down.right") }) {
                    if let item = activity.queue.first { open(item.id) }
                }
            }
        }.padding(6).frame(width: 380).font(GoviInk.font(12)).foregroundStyle(ui.ink)
            .modifier(GoviGlassPanel())
            .accessibilityElement(children: .contain).accessibilityLabel("Notifications menu")
    }

    private func queueRow(_ item: GoviActivityCenter.QueueItem) -> some View {
        HStack(alignment: .center, spacing: 2) {
            Button {
                open(item.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    GoviActivityBadge(state: item.info.state).frame(width: 16).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(GoviInk.font(12.5).weight(.medium)).lineLimit(1)
                        Text(context(item)).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 7) {
                            Text(item.info.state.label)
                            if let start = item.info.startedAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(Self.elapsed(start, end: item.info.endedAt ?? context.date)).monospacedDigit()
                                }
                            }
                        }.font(GoviInk.font(10)).foregroundStyle(ui.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 10).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open \(item.title), \(item.info.state.label)")
            Button {
                activity.acknowledge(item.id)
            } label: {
                Image(systemName: "checkmark").font(.system(size: 11)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundStyle(ui.muted).help("Mark as seen").padding(.trailing, 4)
        }.modifier(GoviHoverHighlight())
    }
    private func context(_ item: GoviActivityCenter.QueueItem) -> String {
        [
            item.info.agent?.name, item.info.project.isEmpty ? GoviPaneNaming.shortPath(item.path) : item.info.project,
            item.info.branch.isEmpty ? nil : item.info.branch,
        ].compactMap { $0 }.joined(separator: " · ")
    }
    private static func elapsed(_ start: Date, end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }
    private func open(_ id: UUID) {
        dismiss()
        DispatchQueue.main.async {
            GoviNavigation.focus(id)
            activity.acknowledge(id)
        }
    }
}
