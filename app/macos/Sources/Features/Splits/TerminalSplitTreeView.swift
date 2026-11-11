import SwiftUI

struct TerminalSplitTreeView: View {
    @Environment(\.goviPalette) private var ui
    let tree: SplitTree<GoviPaneView>
    @ObservedObject var floating: GoviFloatingPanes
    let onResize: (SplitTree<GoviPaneView>.Node, Double) -> Void

    var body: some View {
        let floatingIDs = floating.ids.intersection(tree.map(\.id))
        let shown = Self.docked(tree, without: floatingIDs)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let node = shown.zoomed ?? shown.root {
                    TerminalSplitSubtreeView(
                        node: node,
                        isRoot: node == shown.root,
                        onResize: { node, ratio in
                            // Floating panes are left out of what's drawn; resize the matching split in the real tree.
                            guard let real = Self.realNode(for: node, in: tree, without: floatingIDs) else { return }
                            onResize(real, ratio)
                        })
                    // This is necessary because we can't rely on SwiftUI's implicit
                    // structural identity to detect changes to this view. Due to
                    // the tree structure of splits it could result in bad beaviors.
                    // See: https://github.com/ghostty-org/ghostty/issues/7546
                    .id(node.structuralIdentity)
                } else if !floatingIDs.isEmpty {
                    Text("Every pane is floating. Press a panel's detach button to dock it.")
                        .font(GoviInk.font(12)).foregroundStyle(ui.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(tree.filter { floatingIDs.contains($0.id) && !floating.isMinimized($0.id) }, id: \.id) { pane in
                    GoviFloatingPaneWindow(floating: floating, pane: pane, area: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(GoviFloatingAreaProbe(floating: floating))
        }
    }

    /// The tree as laid out: floating panes removed, and no zoom on a branch that holds one.
    static func docked(_ tree: SplitTree<GoviPaneView>, without ids: Set<UUID>) -> SplitTree<GoviPaneView> {
        guard !ids.isEmpty else { return tree }
        var result = tree
        if let zoomed = tree.zoomed, zoomed.leaves().contains(where: { ids.contains($0.id) }) {
            result = .init(root: tree.root, zoomed: nil)
        }
        for pane in tree where ids.contains(pane.id) { result = result.remove(.leaf(view: pane)) }
        return result
    }

    /// The split in `tree` that a split of the docked tree stands for: removing a
    /// leaf only collapses its parent, so the surviving splits keep their sides.
    static func realNode(
        for node: SplitTree<GoviPaneView>.Node, in tree: SplitTree<GoviPaneView>, without ids: Set<UUID>
    ) -> SplitTree<GoviPaneView>.Node? {
        guard !ids.isEmpty else { return node }
        guard case .split(let shown) = node, let root = tree.root else { return nil }
        let left = shown.left.leaves().map(\.id), right = shown.right.leaves().map(\.id)
        func search(_ candidate: SplitTree<GoviPaneView>.Node) -> SplitTree<GoviPaneView>.Node? {
            guard case .split(let split) = candidate else { return nil }
            if split.left.leaves().map(\.id).filter({ !ids.contains($0) }) == left,
                split.right.leaves().map(\.id).filter({ !ids.contains($0) }) == right
            {
                return candidate
            }
            return search(split.left) ?? search(split.right)
        }
        return search(root)
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
            GoviPaneLeaf(pane: leafView, isSplit: !isRoot)

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
