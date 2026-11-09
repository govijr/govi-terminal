import AppKit

/// Native split model regression: moving terminals must preserve the actual
/// view instances (and thus the processes they own), even through nested splits.
final class TestPane: NSView, Codable, Identifiable {
    let id: Int
    init(_ id: Int) {
        self.id = id
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    required init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(Int.self)
        super.init(frame: .zero)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

@main struct LayoutChecks {
    static func main() throws {
        typealias Tree = SplitTree<TestPane>
        let panes = (0..<8).map(TestPane.init)
        let directions: [Tree.NewDirection?] = [.left, .right, .up, .down, nil]
        var tree = Tree(view: panes[0])
        for i in 1..<panes.count { tree = try tree.insert(view: panes[i], at: panes[(i - 1) / 2], direction: i % 2 == 0 ? .down : .right) }
        var checks = 0
        func verify(_ result: Tree) {
            let leaves = Array(result)
            precondition(leaves.count == panes.count)
            precondition(Set(leaves.map(\.id)).count == panes.count)
            for pane in panes { precondition(leaves.first { $0.id == pane.id } === pane) }
            checks += 1
        }
        for source in panes {
            for target in panes {
                for direction in directions {
                    let moved = try tree.moving(view: source, to: target, direction: direction)
                    verify(moved)
                    if source !== target && direction == nil {
                        let restored = try moved.moving(view: source, to: target, direction: nil)
                        precondition(restored.structuralIdentity == tree.structuralIdentity)
                    }
                    // Exercise repeated nested rearrangements, not only a fresh tree.
                    tree = moved
                }
            }
        }
        let unknown = TestPane(99)
        do {
            _ = try tree.moving(view: unknown, to: panes[0], direction: .left)
            preconditionFailure("Missing source accepted")
        } catch Tree.SplitError.viewNotFound { checks += 1 }
        do {
            _ = try tree.moving(view: panes[0], to: unknown, direction: .right)
            preconditionFailure("Missing target accepted")
        } catch Tree.SplitError.viewNotFound { checks += 1 }
        let single = Tree(view: panes[0])
        let unchanged = try single.moving(view: panes[0], to: panes[0], direction: .down)
        precondition(unchanged.structuralIdentity == single.structuralIdentity)
        let bounds = CGSize(width: 1000, height: 800)
        func rect(_ layout: Tree, _ pane: TestPane) -> CGRect {
            layout.root!.spatial(within: bounds).slots.first {
                if case .leaf(let view) = $0.node { return view === pane }
                return false
            }!.bounds
        }
        for source in panes {
            for target in panes {
                for zone in GoviSnapZone.allCases {
                    let docked = try tree.docking(view: source, to: target, zone: zone)
                    verify(docked)
                    guard source !== target else {
                        precondition(docked.structuralIdentity == tree.structuralIdentity)
                        continue
                    }
                    precondition(docked.zoomed == nil)
                    if zone == .center {
                        precondition(rect(docked, source) == rect(tree, target))
                        precondition(rect(docked, target) == rect(tree, source))
                        for pane in panes where pane !== source && pane !== target {
                            precondition(rect(docked, pane) == rect(tree, pane))
                        }
                    } else {
                        let remainder = tree.remove(.leaf(view: source))
                        let destination = rect(remainder, target)
                        let expected = zone.rect(in: destination.size).offsetBy(dx: destination.minX, dy: destination.minY)
                        precondition(rect(docked, source) == expected, "Docking must split the selected pane, not the workspace.")
                        for pane in panes where pane !== source && pane !== target {
                            precondition(rect(docked, pane) == rect(remainder, pane), "Unrelated panes must not be rearranged.")
                        }
                    }
                }
            }
        }
        for target in panes {
            for zone in GoviSnapZone.allCases where zone != .center {
                let transferred = try tree.docking(view: unknown, to: target, zone: zone)
                precondition(Array(transferred).count == panes.count + 1)
                precondition(transferred.first { $0.id == unknown.id } === unknown)
                for pane in panes { precondition(transferred.first { $0.id == pane.id } === pane) }
                let destination = rect(tree, target)
                precondition(
                    rect(transferred, unknown) == zone.rect(in: destination.size).offsetBy(dx: destination.minX, dy: destination.minY))
                for pane in panes where pane !== target { precondition(rect(transferred, pane) == rect(tree, pane)) }
                checks += 1
            }
        }
        do {
            _ = try tree.docking(view: panes[0], to: unknown, zone: .left)
            preconditionFailure("Missing docking target accepted")
        } catch Tree.SplitError.viewNotFound { checks += 1 }
        do {
            _ = try tree.docking(view: unknown, to: panes[0], zone: .center)
            preconditionFailure("External center swap needs the source tree")
        } catch Tree.SplitError.viewNotFound { checks += 1 }

        // The recording starts with A on the left and B/C/D stacked on the
        // right. Dock C beside A: the left branch splits into A/C while the
        // right branch collapses to B/D. It must not become a workspace half.
        let example = Tree(
            root: .split(
                .init(
                    direction: .horizontal, ratio: 0.5,
                    left: .leaf(view: panes[0]),
                    right: .split(
                        .init(
                            direction: .vertical, ratio: 0.5, left: .leaf(view: panes[1]),
                            right: .split(
                                .init(direction: .vertical, ratio: 0.5, left: .leaf(view: panes[2]), right: .leaf(view: panes[3]))))))),
            zoomed: nil)
        let beside = try example.docking(view: panes[2], to: panes[0], zone: .right)
        precondition(rect(beside, panes[0]) == CGRect(x: 0, y: 0, width: 250, height: 800))
        precondition(rect(beside, panes[2]) == CGRect(x: 250, y: 0, width: 250, height: 800))
        precondition(rect(beside, panes[1]) == CGRect(x: 500, y: 0, width: 500, height: 400))
        precondition(rect(beside, panes[3]) == CGRect(x: 500, y: 400, width: 500, height: 400))
        checks += 1

        for (point, zone): (CGPoint, GoviSnapZone) in [
            (.init(x: 10, y: 80), .left), (.init(x: 990, y: 80), .right),
            (.init(x: 200, y: 10), .top), (.init(x: 200, y: 790), .bottom),
            (.init(x: 500, y: 400), .center), (.init(x: 10, y: 400), .left),
            (.init(x: 990, y: 400), .right), (.init(x: 500, y: 10), .top), (.init(x: 500, y: 790), .bottom),
            (.init(x: 250, y: 400), .center), (.init(x: 750, y: 400), .center),
        ] {
            precondition(GoviSnapZone.at(point, size: bounds) == zone)
            checks += 1
        }
        precondition(GoviSnapZone.at(.zero, size: .zero) == .center)
        let selfDock = try single.docking(view: panes[0], to: panes[0], zone: .left)
        precondition(selfDock.structuralIdentity == single.structuralIdentity)
        print("Passed \(checks + 3) pane movement/docking checks; live views and pane-local geometry preserved.")
    }
}
