import SwiftUI
import AppKit

private final class GoviSettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One reusable, non-modal settings window. It stays separate from terminal
/// windows and never enters their workspace/tab restoration or close logic.
@MainActor final class GoviSettingsWindowController: NSWindowController {
    static let shared = GoviSettingsWindowController()
    private var hostingApp: Ghostty.App?

    private init() {
        let window = GoviSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Govi Settings"
        window.identifier = NSUserInterfaceItemIdentifier("GoviSettings")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 820, height: 600)
        super.init(window: window)
        if !window.setFrameUsingName("GoviSettingsWindow") { window.center() }
        window.setFrameAutosaveName("GoviSettingsWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ ghostty: Ghostty.App) {
        if hostingApp !== ghostty {
            hostingApp = ghostty
            window?.contentView = NSHostingView(rootView: GoviSettingsView(ghostty: ghostty) { [weak self] in self?.close() })
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @IBAction func closeWindow(_ sender: Any?) { window?.performClose(sender) }
}

struct SettingsView: View {
    // We need access to our app delegate to know if we're quitting or not.
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        GoviSettingsView(ghostty: appDelegate.ghostty)
            .modifier(GoviChromeAppearance())
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
