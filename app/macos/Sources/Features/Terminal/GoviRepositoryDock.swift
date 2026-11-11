import SwiftUI
import AppKit
import GhosttyKit

/// Repository operations run off the UI thread, with argument arrays (no shell evaluation).
final class GoviRepository: ObservableObject {
    struct Worktree: Identifiable {
        var id: String { path }
        let path: String
        let branch: String
    }
    @Published var branch = ""
    @Published var branches: [String] = []
    @Published var worktrees: [Worktree] = []
    @Published var busy = false
    @Published var error: String?
    private var directory = ""
    private var generation = UUID()

    private static func git(_ directory: String, _ arguments: [String]) throws -> String {
        try GoviGit.run(directory, arguments)
    }

    func refresh(_ path: String) {
        if directory != path {
            directory = path
            generation = UUID()
            branch = ""
            branches = []
            worktrees = []
            error = nil
        }
        guard !busy else { return }
        directory = path
        let token = UUID()
        generation = token
        DispatchQueue.global(qos: .utility).async {
            let isRepository = (try? Self.git(path, ["rev-parse", "--show-toplevel"])) != nil
            let branch =
                isRepository
                ? ((try? Self.git(path, ["symbolic-ref", "--short", "HEAD"]))
                    ?? ((try? Self.git(path, ["rev-parse", "--short", "HEAD"])).map { "Detached · \($0)" } ?? "")) : ""
            let branches = (try? Self.git(path, ["for-each-ref", "--format=%(refname:short)", "refs/heads"])) ?? ""
            let list = (try? Self.git(path, ["worktree", "list", "--porcelain", "-z"])) ?? ""
            var trees: [Worktree] = []
            var currentPath = ""
            var currentBranch = "Detached HEAD"
            for field in list.components(separatedBy: "\0") {
                if field.hasPrefix("worktree ") {
                    currentPath = String(field.dropFirst(9))
                    currentBranch = "Detached HEAD"
                } else if field.hasPrefix("branch refs/heads/") {
                    currentBranch = String(field.dropFirst(18))
                } else if field.isEmpty && !currentPath.isEmpty {
                    trees.append(.init(path: currentPath, branch: currentBranch))
                    currentPath = ""
                }
            }
            let result = trees
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.branch = branch
                self.branches = branches.split(separator: "\n").map(String.init)
                self.worktrees = result
            }
        }
    }

    func run(_ arguments: [String], completion: @escaping () -> Void = {}) {
        guard !busy else { return }
        busy = true
        error = nil
        generation = UUID()
        let path = directory
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String?
            do {
                _ = try Self.git(path, arguments)
                failure = nil
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = false
                self.error = failure
                self.refresh(self.directory)
                if failure == nil { completion() }
            }
        }
    }
}

struct GoviRepositoryDock: View {
    @ObservedObject private var usage = GoviUsageStore.shared
    @Environment(\.goviPalette) private var ui
    @Environment(\.goviFloatingPanes) private var floatingPanes

    let directory: String
    let openFolder: (String) -> Void
    @ObservedObject var changes: GoviGitChanges
    let visible: Bool
    let showChanges: () -> Void
    @StateObject private var repository = GoviRepository()
    @State private var popover: String?
    @State private var worktreeName = ""
    /// A slow fallback; file events (via `changes`) drive normal refreshes.
    private let refresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 9) {
            if let floatingPanes { GoviMinimizedPaneChips(floating: floatingPanes) }
            if changes.root != nil {
                Button(action: showChanges) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5, weight: .medium))
                        if changes.files.isEmpty {
                            Text(changes.ahead > 0 ? "↑\(changes.ahead)" : "Clean").font(GoviInk.font(11.5))
                        } else {
                            GoviDiffStat(additions: changes.additions, deletions: changes.deletions)
                        }
                    }.padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
                }
                .help(
                    changes.files.isEmpty
                        ? "\(changes.branch) · no changes"
                        : "\(changes.branch) · \(changes.files.count) changed file\(changes.files.count == 1 ? "" : "s") · diff, commit and push"
                )
                .accessibilityLabel("Git changes")
                separator
            }
            Button {
                popover = "worktrees"
                repository.refresh(directory)
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .help("Git worktrees").accessibilityLabel("Git worktrees")
            .popover(isPresented: showing("worktrees")) { worktreePopover }
            if !usage.visibleAgents.isEmpty {
                separator
                GoviUsageRings()
            }

            if repository.busy { ProgressView().controlSize(.mini) }
        }.buttonStyle(.plain).font(GoviInk.font(11)).foregroundStyle(ui.muted)
            .padding(.horizontal, 10).frame(height: 40)
            .modifier(GoviGlassControl())
            .onAppear {
                changes.refresh(directory)
                repository.refresh(directory)
                for agent in GoviAgent.allCases { usage.refresh(agent) }
            }
            .onChange(of: directory) {
                repository.refresh($0)
                changes.refresh($0)
            }
            .onChange(of: changes.metadataRevision) { _ in repository.refresh(directory) }
            .onReceive(refresh) { _ in
                guard visible else { return }
                changes.refresh(directory)
                repository.refresh(directory)
                for agent in GoviAgent.allCases { usage.refresh(agent) }
            }
    }
    private var separator: some View { Rectangle().fill(ui.line).frame(width: 0.5, height: 12) }
    private func showing(_ name: String) -> Binding<Bool> {
        Binding(get: { popover == name }, set: { if !$0 { popover = nil } })
    }
    private var worktreePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worktrees").font(.headline)
            if repository.branch.isEmpty {
                Text("Open a Git project to manage its worktrees.").foregroundStyle(ui.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(repository.worktrees) { tree in
                            Button {
                                openFolder(tree.path)
                                popover = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tree.branch)
                                    Text(GoviPaneNaming.shortPath(tree.path)).font(GoviInk.font(10)).foregroundStyle(ui.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 190)
                Divider()
                TextField("New worktree branch", text: $worktreeName).textFieldStyle(.roundedBorder)
                Button("Choose location and create…", action: createWorktree)
                    .disabled(repository.busy || !validName(worktreeName))
            }
            errorMessage
        }.padding(18).frame(width: 320).foregroundStyle(ui.ink).background(ui.paper)
    }
    @ViewBuilder private var errorMessage: some View {
        if let error = repository.error {
            Text(error).font(GoviInk.font(11)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func validName(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix("-") && !name.contains(where: { $0.isWhitespace }) }
    private func createWorktree() {
        let panel = NSSavePanel()
        panel.title = "Create Git worktree"
        panel.prompt = "Create"
        panel.nameFieldStringValue = worktreeName.replacingOccurrences(of: "/", with: "-")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repository.run(["worktree", "add", "-b", worktreeName, "--", url.path]) {
            worktreeName = ""
            openFolder(url.path)
            popover = nil
        }
    }
}
