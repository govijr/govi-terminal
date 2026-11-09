import AppKit

class HiddenTitlebarTerminalWindow: TerminalWindow {
    override func awakeFromNib() {
        super.awakeFromNib()

        // Setup our initial style
        reapplyHiddenStyle()

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fullscreenDidExit(_:)),
            name: .fullscreenDidExit,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static let hiddenStyleMask: NSWindow.StyleMask = [
        // We need `titled` in the mask to get the normal window frame
        .titled,

        // Full size content view so we can extend
        // content in to the hidden titlebar's area
        .fullSizeContentView,

        .resizable,
        .closable,
        .miniaturizable,
    ]
    
    /// Apply the hidden titlebar style.
    private func reapplyHiddenStyle() {
        // If our window is fullscreen then we don't reapply the hidden style because
        // it can result in messing up non-native fullscreen. See:
        // https://github.com/ghostty-org/ghostty/issues/8415
        if terminalController?.fullscreenStyle?.isFullscreen ?? false {
            return
        }
        
        // Apply our style mask while preserving the .fullScreen option
        let mask = styleMask.contains(.fullScreen) ? Self.hiddenStyleMask.union([.fullScreen]) : Self.hiddenStyleMask
        if styleMask != mask { styleMask = mask }

        // Hide the title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Govi owns separate native AppKit controls in its integrated header.
        // Leave these original buttons inside the titlebar rather than reparenting
        // them: AppKit can recreate that container when the shell changes its title.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Workspaces share a native tab group, presented through Govi's sidebar.
        // Disallowing tabs here previously made every + open a separate window.
        tabbingMode = .preferred

        // Nuke it from orbit -- hide the titlebar container entirely, just in case. There are
        // some operations that appear to bring back the titlebar visibility so this ensures
        // it is gone forever.
        if let themeFrame = contentView?.superview,
           let titleBarContainer = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") {
            titleBarContainer.isHidden = true
        }
    }

    override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) {
        super.addTabbedWindow(window, ordered: ordered)
        reapplyHiddenStyle()
        DispatchQueue.main.async { [weak self, weak window] in
            self?.reapplyHiddenStyle()
            (window as? HiddenTitlebarTerminalWindow)?.reapplyHiddenStyle()
        }
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        childViewController.view.isHidden = true
        reapplyHiddenStyle()
    }

    // MARK: NSWindow

    override var title: String {
        didSet {
            // Updating the title text as above automatically reveals the
            // native title view in macOS 15.0 and above. Since we're using
            // a custom view instead, we need to re-hide it.
            reapplyHiddenStyle()
        }
    }

    // We override this so that with the hidden titlebar style the titlebar
    // area is not draggable.
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = self.frame.height
        return rect
    }

    // MARK: Notifications

    @objc private func fullscreenDidExit(_ notification: Notification) {
        // Make sure they're talking about our window
        guard let fullscreen = notification.object as? FullscreenBase else { return }
        guard fullscreen.window == self else { return }

        // On exit we need to reapply the style because macOS breaks it usually.
        // This is safe to call repeatedly so if its not broken its still safe.
        reapplyHiddenStyle()
    }
}
