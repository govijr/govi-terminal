import SwiftUI
import GhosttyKit

struct TerminalCommandPaletteView: View {
    @Environment(\.goviPalette) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config
    @ObservedObject private var notebook = GoviNotebook.shared
    @ObservedObject private var shortcuts = GoviShortcuts.shared

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    // The commands available to the command palette.
    private var commandOptions: [CommandOption] {
        guard let surface = surfaceView.surfaceModel else { return [] }
        do {
            let builtins = try surface.commands().filter { !["check_for_updates", "reload_config", "open_config", "toggle_quick_terminal", "toggle_tab_overview", "show_gtk_inspector", "inspector", "crash"].contains(String($0.action.split(separator: ":").first ?? "")) }.map { c in
                return CommandOption(
                    title: c.title.replacingOccurrences(of: "Ghostty", with: "Govi").replacingOccurrences(of: "Tab", with: "Workspace"),
                    description: c.description.replacingOccurrences(of: "Ghostty", with: "Govi"),
                    symbols: ghosttyConfig.keyboardShortcut(for: c.action)?.keyList
                ) {
                    onAction(c.action)
                }
            }
            let find = CommandOption(title: "Find in Terminal Output", description: "Search a snapshot of this pane's scrollback.", symbols: shortcuts.chord(.find).symbols) {
                NotificationCenter.default.post(name: .goviFindOutput, object: nil)
            }
            let settings = CommandOption(title: "Settings", description: "Themes, fonts, spacing, and cursor appearance.", symbols: shortcuts.chord(.settings).symbols) {
                NotificationCenter.default.post(name: .goviShowSettings, object: nil)
            }
            let saved = notebook.commands.map { item in
                CommandOption(title: "Saved: \(item.name)", description: item.command, symbols: nil) {
                    surface.sendText(item.command)
                }
            }
            let navigation = TerminalController.all.flatMap { controller in
                controller.surfaceTree.map { pane in
                    CommandOption(title: "Terminal: \(GoviPaneNaming.title(pane))", description: pane.pwd ?? "", symbols: nil) {
                        controller.window?.tabGroup?.selectedWindow = controller.window
                        controller.window?.makeKeyAndOrderFront(nil)
                        controller.focusedSurface = pane
                        DispatchQueue.main.async { controller.window?.makeFirstResponder(pane) }
                    }
                }
            }
            let projects = notebook.spaces.map { project in
                CommandOption(title: "Project: \(project.name)", description: project.path, symbols: nil) {
                    guard let controller = GoviPaneCoordinator.owner(of: surfaceView.id) else { return }
                    var config = Ghostty.SurfaceConfiguration(); config.workingDirectory = project.path
                    _ = TerminalController.newTab(controller.ghostty, from: surfaceView.window, withBaseConfig: config)
                }
            }
            let focus = CommandOption(title: "Toggle Focus Mode", description: "Hide or restore the sidebar and dock.", symbols: nil) {
                NotificationCenter.default.post(name: .goviToggleFocus, object: nil)
            }
            let sidebar = CommandOption(title: "Toggle Sidebar", description: "Show or hide projects and sessions.", symbols: nil) {
                NotificationCenter.default.post(name: .goviToggleSidebar, object: nil)
            }
            let tools = GoviTool.allCases.map { tool in
                CommandOption(title: "Open \(tool.name) in Split", description: tool.summary, symbols: nil) {
                    tool.open(beside: surfaceView)
                }
            }
            let templates = CommandOption(title: "Project Templates…", description: "Review and open saved workspace layouts, commands and agents.", symbols: shortcuts.chord(.templates).symbols) {
                NotificationCenter.default.post(name: .goviTemplates, object: nil)
            }
            let saveTemplate = CommandOption(title: "Save Workspace as Template…", description: "Keep this workspace's pane arrangement and launch choices.", symbols: nil) {
                NotificationCenter.default.post(name: .goviSaveTemplate, object: nil)
            }
            let attention = CommandOption(title: "Needs Attention", description: "Review waiting, failed and completed agent work.", symbols: shortcuts.chord(.attention).symbols) {
                NotificationCenter.default.post(name: .goviAttention, object: nil)
            }
            let nextAttention = CommandOption(title: "Next Terminal Needing Attention", description: "Jump to the next waiting session across workspaces.", symbols: shortcuts.chord(.nextAttention).symbols) {
                GoviActivityCenter.shared.focusNext()
            }
            let tasks = CommandOption(title: "Tasks — GitHub and Linear", description: "Start from an issue, review pull requests, and share results.", symbols: nil) {
                NotificationCenter.default.post(name: .goviTasks, object: nil)
            }
            return [find, tasks, attention, nextAttention, focus, sidebar, settings, templates, saveTemplate] + tools + navigation + projects + saved + builtins
        } catch {
            return []
        }
    }

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ui.paper,
                            options: commandOptions
                        )
                        .transition(
                            .move(edge: .top)
                            .combined(with: .opacity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16))
                        ) // Spring animation
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    guard surfaceView.window == NSApp.keyWindow,
                          GoviPaneCoordinator.owner(of: surfaceView.id)?.focusedSurface === surfaceView else { return }
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }
}

/// This is done to ensure that the given view is in the responder chain.
fileprivate struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
