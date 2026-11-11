import AppKit
import SwiftUI

@MainActor final class GoviShortcuts: ObservableObject {
    static let shared = GoviShortcuts()
    @Published private(set) var values = GoviShortcutPreferences.load()
    func chord(_ action: GoviShortcutAction) -> GoviKeyChord { GoviShortcutPreferences.chord(action, values: values) }

    func set(_ chord: GoviKeyChord, for action: GoviShortcutAction, ghostty: Ghostty.App) -> String? {
        if let error = GoviShortcutPreferences.conflict(chord, for: action, values: values) { return error }
        if let surface = TerminalController.preferredParent?.focusedSurface?.surfaceModel,
            let commands = try? surface.commands()
        {
            for command in commands where command.action != action.terminalAction {
                if let existing = ghostty.config.keyboardShortcut(for: command.action), existing.keyList == chord.symbols {
                    return "Already assigned to \(command.title). Choose a different combination."
                }
            }
        }
        if chord == action.defaultChord { values[action.rawValue] = nil } else { values[action.rawValue] = chord }
        persist(ghostty)
        return nil
    }
    func reset(_ ghostty: Ghostty.App) {
        values = [:]
        persist(ghostty)
    }
    private func persist(_ ghostty: Ghostty.App) {
        if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: "GoviShortcutsV1") }
        ghostty.reloadConfig()
        syncMenus()
    }

    /// App-local shortcuts only: no global keyboard monitor or extra permission.
    func handle(_ event: NSEvent) -> Bool {
        // An open Quick Look preview takes Escape, Command-W and the arrow keys first.
        if GoviQuickLook.shared.handleKey(event) { return true }
        // Hidden demo/debug shortcut, also available in local release builds.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad]) == [
            .command, .control, .shift,
        ],
            event.charactersIgnoringModifiers?.lowercased() == "g",
            let window = NSApp.keyWindow, window.attachedSheet == nil,
            window.windowController is TerminalController
        {
            if !event.isARepeat {
                NotificationCenter.default.post(name: .goviReplayLaunchSplash, object: window)
            }
            return true
        }
        guard let chord = Self.chord(from: event),
            let action = GoviShortcutAction.allCases.first(where: { self.chord($0) == chord }),
            let window = NSApp.keyWindow, window.attachedSheet == nil,
            let controller = window.windowController as? TerminalController
        else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return false }
        if let pane = controller.focusedPane, !(pane is Ghostty.SurfaceView),
            controller.performPaneCommand(action, on: pane)
        {
            return true
        }
        if let binding = action.terminalAction {
            return controller.focusedSurface?.surfaceModel?.perform(action: binding) ?? false
        }
        switch action {
        case .find: NotificationCenter.default.post(name: .goviFindOutput, object: nil)
        case .search: NotificationCenter.default.post(name: .goviSearchSessions, object: nil)
        case .settings: NotificationCenter.default.post(name: .goviShowSettings, object: nil)
        case .focusMode: NotificationCenter.default.post(name: .goviToggleFocus, object: nil)
        case .sidebar: NotificationCenter.default.post(name: .goviToggleSidebar, object: nil)
        case .attention: NotificationCenter.default.post(name: .goviAttention, object: nil)
        case .nextAttention: GoviActivityCenter.shared.focusNext()
        case .templates: NotificationCenter.default.post(name: .goviTemplates, object: nil)
        case .remoteHosts: NotificationCenter.default.post(name: .goviRemoteHosts, object: nil)
        case .browser: controller.openWebPane()
        case .editor: controller.openEditorPane()
        case .quickLook: GoviQuickLook.shared.toggle(in: controller)
        default: return false
        }
        return true
    }

    func syncMenus() {
        let selectors: [String: GoviShortcutAction] = ["goviFindOutput:": .find, "goviSearchSessions:": .search, "openConfig:": .settings]
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let selector = item.action, let action = selectors[NSStringFromSelector(selector)] {
                    let key = chord(action)
                    item.keyEquivalent = key.character
                    item.keyEquivalentModifierMask = Self.flags(key)
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
    }

    static func flags(_ chord: GoviKeyChord) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for (mask, flag): (Int, NSEvent.ModifierFlags) in [(1, .control), (2, .option), (4, .shift), (8, .command)]
        where chord.modifiers & mask != 0 { flags.insert(flag) }
        return flags
    }
    static func chord(from event: NSEvent) -> GoviKeyChord? {
        var modifiers = 0
        for (mask, flag): (Int, NSEvent.ModifierFlags) in [(1, .control), (2, .option), (4, .shift), (8, .command)]
        where event.modifierFlags.contains(flag) { modifiers |= mask }
        let special: [UInt16: String] = [
            36: "enter", 76: "enter", 49: "space", 48: "tab", 123: "arrow_left", 124: "arrow_right", 125: "arrow_down", 126: "arrow_up",
        ]
        var key = special[event.keyCode]
        if key == nil, let text = event.charactersIgnoringModifiers?.lowercased(), text.count == 1 {
            let shifted: [String: String] = [
                "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "<": "comma",
                ">": "period", "?": "slash", ":": "semicolon", "\"": "quote", "{": "bracket_left", "}": "bracket_right", "|": "backslash",
                "_": "minus", "+": "equal", "~": "backquote",
            ]
            key = shifted[text] ?? GoviKeyChord.characters.first(where: { $0.value == text })?.key ?? text
        }
        guard let key else { return nil }
        let result = GoviKeyChord(key: key, modifiers: modifiers)
        return result.isValid ? result : nil
    }
}

struct GoviShortcutsSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject private var shortcuts = GoviShortcuts.shared
    @Environment(\.goviPalette) private var ui
    @State private var recording: GoviShortcutAction?
    @State private var monitor: Any?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click a shortcut, then press its new key combination. Escape cancels.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
            if let failure { Text(failure).font(GoviInk.font(11)).foregroundStyle(.red) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(GoviShortcutAction.allCases) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            Button {
                                recording = action
                                failure = nil
                            } label: {
                                Text(recording == action ? "Press shortcut…" : shortcuts.chord(action).display)
                                    .font(GoviInk.font(11)).frame(minWidth: 90)
                            }.accessibilityLabel("Change \(action.title) shortcut")
                            if shortcuts.values[action.rawValue] != nil {
                                Button {
                                    failure = shortcuts.set(action.defaultChord, for: action, ghostty: ghostty)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.plain).help("Reset \(action.title)")
                            } else {
                                Color.clear.frame(width: 13)
                            }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            HStack {
                Text("Changes apply to open terminals.").font(GoviInk.font(10)).foregroundStyle(ui.muted)
                Spacer()
                Button("Reset All") {
                    recording = nil
                    failure = nil
                    shortcuts.reset(ghostty)
                }
                .disabled(shortcuts.values.isEmpty)
            }
        }.onChange(of: recording) { action in
            stopRecording()
            guard let action else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    recording = nil
                    return nil
                }
                guard let key = GoviShortcuts.chord(from: event) else {
                    failure = "Include Command or Control in the new shortcut."
                    return nil
                }
                failure = shortcuts.set(key, for: action, ghostty: ghostty)
                recording = nil
                return nil
            }
        }.onDisappear { stopRecording() }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
