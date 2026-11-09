import SwiftUI

struct TerminalSplitTreeView: View {
    let tree: SplitTree<GoviPaneView>
    let onResize: (SplitTree<GoviPaneView>.Node, Double) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                onResize: onResize)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad beaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
        }
    }
}

struct TerminalSplitSubtreeView: View {
    @Environment(\.goviPalette) private var ui

    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<GoviPaneView>.Node
    var isRoot: Bool = false
    let onResize: (SplitTree<GoviPaneView>.Node, Double) -> Void

    var body: some View {
        switch (node) {
        case .leaf(let leafView):
            if let surface = leafView as? Ghostty.SurfaceView {
                GoviTerminalPane(
                    surface: surface,
                    isSplit: !isRoot)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Terminal pane")
            } else if let web = leafView as? GoviWebPaneView {
                GoviWebPane(pane: web, isSplit: !isRoot)
            }

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch (split.direction) {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    onResize(node, $0)
                }),
                dividerColor: ui.canvas,
                gutter: 3,
                minimumPaneSize: 120,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, onResize: onResize)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, onResize: onResize)
                }
            )
        }
    }
}
