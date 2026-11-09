import SwiftUI
import AppKit

// MARK: - Panel

struct GoviTasksView: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var model = GoviTasksModel.shared
    @ObservedObject private var connections = GoviIntegrations.shared
    @ObservedObject private var repos = GoviRepositoryStore.shared
    let directory: String
    var linked: GoviTaskLink?
    let launch: (GoviLaunch) -> Bool
    let close: () -> Void
    @AppStorage("GoviTasksProvider") private var provider = GoviIntegrationProvider.github
    @AppStorage("GoviTasksRepository") private var repository = ""
    @AppStorage("GoviTasksAssigned") private var assigned = true
    @AppStorage("GoviTasksReviews") private var reviews = false
    /// The GitHub repository of the terminal Tasks was opened from, offered in the picker.
    @State private var folderRepository: String?
    @State private var repoPickerOpen = false
    @State private var query = ""
    @State private var comment = ""
    @State private var connectionsOpen = false
    @State private var newPullRequest = false
    @State private var initializing = true
    @FocusState private var searchFocused: Bool
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            if connectionsOpen {
                GoviIntegrationSettingsView(signInGitHub: signInGitHub).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                toolbar.padding(.horizontal, 12).frame(height: 42)
                GoviHairline()
                HStack(spacing: 0) {
                    taskList.frame(width: 300).frame(maxHeight: .infinity)
                    GoviHairline(vertical: true)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .font(GoviInk.font(12)).foregroundStyle(ui.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Same surface as a terminal pane: the theme background at the terminal's opacity, no card.
        .background(GoviInk.color(GoviTheme.current.background).opacity(GoviBackdropStore.terminalOpacity), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { toast }
        .overlayPreferenceValue(GoviRepositoryAnchorKey.self) { anchor in repositoryPopover(anchor) }
        .animation(.easeOut(duration: 0.18), value: model.notice)
        .animation(.easeOut(duration: 0.18), value: model.error)
        .onExitCommand {
            if repoPickerOpen { repoPickerOpen = false } else if searchFocused && !query.isEmpty { query = "" }
        }
        .task { await openInitialTask() }
        .onChange(of: provider) { _ in
            if !initializing {
                model.clear()
                comment = ""
                query = ""
                Task { await refresh() }
            }
        }
        .onChange(of: reviews) { _ in
            if !initializing {
                model.clear()
                comment = ""
                Task { await refresh() }
            }
        }
        .onChange(of: assigned) { _ in if !initializing { Task { await refresh() } } }
        .onChange(of: repository) { _ in
            if !initializing {
                model.clear()
                comment = ""
                query = ""
                Task { await refresh() }
            }
        }
        .onChange(of: connections.githubEnabled) { _ in model.clear() }
        .onChange(of: connections.hasLinearKey) { _ in model.clear() }
        .onChange(of: model.notice) { value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if model.notice == value { model.notice = nil }
            }
        }
        .sheet(isPresented: $newPullRequest) { GoviPullRequestComposer(directory: directory, linked: linked) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            GoviSegmented(
                selection: $provider,
                options: GoviIntegrationProvider.allCases.map {
                    GoviSegmented<GoviIntegrationProvider>.Option(
                        value: $0, title: $0.name, symbol: $0 == .github ? "chevron.left.forwardslash.chevron.right" : "square.stack.3d.up")
                })
            if provider == .github {
                repositoryChip
                GoviSegmented(
                    selection: $reviews, options: [.init(value: false, title: "Issues"), .init(value: true, title: "Pull requests")])
            }
            if !reviews || provider == .linear {
                GoviChipToggle(title: "Mine", symbol: "person", isOn: $assigned).help("Only show issues assigned to you")
            }
            Spacer(minLength: 8)
            searchField
        }
    }

    /// The tab's title bar, matching a terminal pane's: title on the left, actions on the right.
    private var paneBar: some View {
        HStack(spacing: 6) {
            if connectionsOpen {
                barButton("chevron.left", "Back to Tasks") {
                    connectionsOpen = false
                    Task { await refresh() }
                }
            } else {
                Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(ui.muted).frame(width: 14, height: 14)
            }
            Text(connectionsOpen ? "Connections" : "Tasks").foregroundStyle(ui.ink)
            if !connectionsOpen {
                Text(provider == .linear ? "Linear" : (repository.isEmpty ? "GitHub" : repository)).foregroundStyle(ui.muted).lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if !connectionsOpen {
                    ZStack {
                        if model.busy == "Loading…" {
                            ProgressView().controlSize(.small).scaleEffect(0.55)
                        } else {
                            barButton("arrow.clockwise", "Refresh (⌘R)") { Task { await refresh() } }
                        }
                    }.frame(width: 24, height: 24)
                        .background(
                            Button("") { Task { await refresh() } }.keyboardShortcut("r", modifiers: .command).opacity(0).disabled(
                                model.busy != nil))
                    barButton("arrow.triangle.pull", "New pull request") { newPullRequest = true }.disabled(!connections.githubEnabled)
                    barButton("link", "Connections") { connectionsOpen = true }
                }
                barButton("xmark", "Close Tasks", action: close)
            }
        }
        .font(GoviInk.font(12))
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 30)
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 24).modifier(GoviHoverHighlight())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private var repositoryChip: some View {
        Button {
            repoPickerOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "book.closed").font(.system(size: 11)).foregroundStyle(ui.muted)
                if let repo = GoviGitHubRepository(repository) {
                    (Text(repo.owner + " / ").foregroundColor(ui.muted) + Text(repo.name).fontWeight(.medium).foregroundColor(ui.ink))
                        .font(GoviInk.font(12)).lineLimit(1).truncationMode(.head)
                    if repos.isSaved(repo.fullName) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(GoviTaskColor.saved)
                    }
                } else {
                    Text("Choose repository").font(GoviInk.font(12)).foregroundStyle(ui.muted)
                }
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(ui.muted)
                    .rotationEffect(.degrees(repoPickerOpen ? 180 : 0))
            }
            .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: 280)
            .modifier(GoviHoverHighlight(on: repoPickerOpen))
        }
        .buttonStyle(.plain).fixedSize()
        .anchorPreference(key: GoviRepositoryAnchorKey.self, value: .bounds) { $0 }
        .help("Choose a repository")
    }

    @ViewBuilder private func repositoryPopover(_ anchor: Anchor<CGRect>?) -> some View {
        if repoPickerOpen, let anchor {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).onTapGesture { repoPickerOpen = false }
                    GoviRepositoryPicker(current: repository, folder: folderRepository, choose: chooseRepository)
                        .offset(x: proxy[anchor].minX, y: proxy[anchor].maxY + 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func chooseRepository(_ value: String) {
        repoPickerOpen = false
        guard let repo = GoviGitHubRepository(value) else { return }
        repos.used(repo.fullName)
        if repo.fullName.caseInsensitiveCompare(repository) == .orderedSame { Task { await refresh() } } else { repository = repo.fullName }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ui.muted)
            TextField(identifierPlaceholder, text: $query)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { if let id = queryIdentifier { Task { await model.open(id, provider: provider, repository: repository) } } }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ui.muted)
                }.buttonStyle(.plain)
            } else {
                GoviKeyHint("⌘F")
            }
        }
        .padding(.horizontal, 10).frame(width: 220, height: 28)
        .background(
            ui.ink.opacity(searchFocused ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: GoviChromeMetrics.corner, style: .continuous)
        )
        .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0))
    }

    // MARK: List

    private var visibleIssues: [GoviTaskIssue] {
        model.issues.filter { matches($0.link.title + " " + $0.link.identifier + " " + $0.labels.joined(separator: " ")) }
    }
    private var visiblePullRequests: [GoviPullRequest] {
        model.pullRequests.filter { matches($0.title + " #\($0.number) " + $0.headRefName) }
    }
    private var showingReviews: Bool { provider == .github && reviews }

    private var taskList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if let id = queryIdentifier {
                            openByIdentifierRow(id)
                        }
                        if showingReviews {
                            ForEach(visiblePullRequests) { pr in
                                GoviTaskRow(
                                    symbol: prSymbol(pr), tint: prTint(pr), identifier: "#\(pr.number)", title: pr.title,
                                    meta: [pr.author?.login, age(pr.updated)].compactMap { $0 },
                                    trailing: pr.failingChecks > 0 ? "\(pr.failingChecks) failing" : (pr.isDraft ? "Draft" : nil),
                                    trailingTint: pr.failingChecks > 0 ? GoviTaskColor.failed : ui.muted,
                                    labels: [], selected: model.pullRequest?.number == pr.number
                                ) { model.selectReview(pr) }
                                .id("pr-\(pr.number)")
                            }
                        } else {
                            ForEach(visibleIssues) { issue in
                                GoviTaskRow(
                                    symbol: issueSymbol(issue), tint: issueTint(issue), identifier: issue.link.identifier,
                                    title: issue.link.title,
                                    meta: [issue.author, age(issue.updated)].compactMap { $0 },
                                    trailing: issue.link.provider == "linear" ? issue.stateName : nil, trailingTint: ui.muted,
                                    labels: issue.labels, selected: model.issue?.id == issue.id
                                ) { choose(issue) }
                                .id(issue.id)
                            }
                        }
                        if needsSetup {
                            setupList
                        } else if model.busy == "Loading…" && model.issues.isEmpty && model.pullRequests.isEmpty {
                            ForEach(0..<7, id: \.self) { _ in GoviTaskRowPlaceholder() }
                        } else if model.loaded && model.error == nil && currentCount == 0 && queryIdentifier == nil {
                            emptyList
                        } else if !model.loaded && model.busy == nil && currentCount == 0 {
                            setupList
                        }
                    }
                    .padding(8)
                }
                .background(moveShortcuts(proxy))
                if currentCount > 0 {
                    HStack {
                        Text(listFooter).font(GoviInk.font(10.5)).foregroundStyle(ui.muted)
                        Spacer()
                        GoviKeyHint("⌥↑↓")
                    }.padding(.horizontal, 16).frame(height: 32)
                        .overlay(alignment: .top) { GoviHairline().padding(.horizontal, 12) }
                }
            }
        }
    }

    /// ⌥↑ / ⌥↓ step through the list without stealing plain arrows from text fields.
    private func moveShortcuts(_ proxy: ScrollViewProxy) -> some View {
        ZStack {
            Button("") { step(-1, proxy) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("") { step(1, proxy) }.keyboardShortcut(.downArrow, modifiers: .option)
        }.opacity(0).frame(width: 0, height: 0)
    }
    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        if showingReviews {
            let items = visiblePullRequests
            guard !items.isEmpty else { return }
            let current = items.firstIndex { $0.number == model.pullRequest?.number } ?? (delta > 0 ? -1 : items.count)
            let next = items[max(0, min(items.count - 1, current + delta))]
            model.selectReview(next)
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("pr-\(next.number)") }
        } else {
            let items = visibleIssues
            guard !items.isEmpty, model.busy == nil else { return }
            let current = items.firstIndex { $0.id == model.issue?.id } ?? (delta > 0 ? -1 : items.count)
            let next = items[max(0, min(items.count - 1, current + delta))]
            choose(next)
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next.id) }
        }
    }

    private var currentCount: Int { showingReviews ? visiblePullRequests.count : visibleIssues.count }
    private var listFooter: String {
        let total = showingReviews ? model.pullRequests.count : model.issues.count
        let noun = showingReviews ? "pull request" : "issue"
        let shown = currentCount == total ? "\(total)" : "\(currentCount) of \(total)"
        return "\(shown) open \(noun)\(total == 1 ? "" : "s")"
    }

    private func openByIdentifierRow(_ id: String) -> some View {
        Button {
            Task { await model.open(id, provider: provider, repository: repository) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle").foregroundStyle(ui.accent)
                Text("Open \(provider == .github ? "#" + id.trimmingCharacters(in: CharacterSet(charactersIn: "#")) : id.uppercased())")
                    .font(GoviInk.font(12).weight(.medium))
                Spacer()
                GoviKeyHint("↩")
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                .background(ui.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }.buttonStyle(.plain).padding(.bottom, 4)
    }

    @ViewBuilder private var emptyList: some View {
        if !query.isEmpty {
            GoviEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing here matches “\(query)”.")
        } else {
            GoviEmptyState(
                symbol: "checkmark.circle",
                title: showingReviews ? "No open pull requests" : (assigned ? "Nothing assigned to you" : "No open issues"),
                message: assigned && !showingReviews ? "Turn off Mine to see everyone's issues." : "Your inbox is clear."
            ) {
                if assigned && !showingReviews { Button("Show all issues") { assigned = false }.buttonStyle(GoviQuietButtonStyle()) }
            }
        }
    }

    @ViewBuilder private var setupList: some View {
        if provider == .github && !connections.githubEnabled {
            GoviEmptyState(
                symbol: "link", title: "Connect GitHub", message: "Use your GitHub CLI sign-in to bring issues and pull requests here."
            ) {
                Button("Connect") { connectionsOpen = true }.buttonStyle(GoviPrimaryButtonStyle())
            }
        } else if provider == .linear && !connections.hasLinearKey {
            GoviEmptyState(symbol: "link", title: "Connect Linear", message: "Add a Linear API key to see your team's issues.") {
                Button("Connect") { connectionsOpen = true }.buttonStyle(GoviPrimaryButtonStyle())
            }
        } else if provider == .github && GoviGitHubRepository(repository) == nil {
            GoviEmptyState(
                symbol: "book.closed", title: "Choose a repository",
                message: "Pick one of your repositories, or star the ones you use most to keep them on top."
            ) {
                VStack(spacing: 8) {
                    if let folderRepository {
                        Button("Use \(folderRepository)") { chooseRepository(folderRepository) }.buttonStyle(GoviPrimaryButtonStyle())
                    }
                    Button("Choose repository") { repoPickerOpen = true }.buttonStyle(GoviQuietButtonStyle())
                }
            }
        } else {
            GoviEmptyState(symbol: "arrow.clockwise", title: "Load tasks", message: "Fetch the latest open items.") {
                Button("Refresh") { Task { await refresh() } }.buttonStyle(GoviQuietButtonStyle())
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let issue = model.issue {
            issueDetail(issue)
        } else if let pr = model.pullRequest {
            pullRequestDetail(pr)
        } else if model.loadingDetail {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GoviEmptyState(
                symbol: "sparkles", title: showingReviews ? "Pick a pull request" : "Pick a task",
                message: "Hand it to a coding agent in its own worktree, then come back to share the result."
            )
            .frame(maxWidth: 320).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func issueDetail(_ issue: GoviTaskIssue) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            stateBadge(issue)
                            Text(issue.link.identifier).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ui.muted)
                            if let author = issue.author { Text("by \(author)").foregroundStyle(ui.muted) }
                            if let age = age(issue.updated) { Text("· updated \(age) ago").foregroundStyle(ui.muted) }
                            if model.loadingDetail { ProgressView().controlSize(.small).scaleEffect(0.7) }
                            Spacer()
                            linkButtons(issue.link)
                        }.font(GoviInk.font(11.5))
                        Text(issue.link.title.isEmpty ? issue.link.identifier : issue.link.title)
                            .font(GoviInk.font(20).weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !issue.labels.isEmpty {
                            HStack(spacing: 5) { ForEach(issue.labels.prefix(6), id: \.self) { GoviLabelPill(name: $0) } }
                        }
                    }
                    GoviTaskLaunchView(
                        issue: issue, brief: $model.brief, requiredBranch: model.requiredBranch, directory: directory,
                        loading: model.loadingDetail, shortcutEnabled: !composerFocused, launch: launch
                    )
                    .id(issue.id)
                    GoviTaskSection(title: "Description") {
                        GoviMarkdownText(text: issue.body, empty: "No description provided.")
                    }
                    if !issue.comments.isEmpty {
                        GoviTaskSection(title: "Activity", count: issue.comments.count) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(issue.comments.enumerated()), id: \.offset) { _, value in GoviCommentCard(raw: value) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 24)
                .frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            composer(issue)
        }
    }

    private func composer(_ issue: GoviTaskIssue) -> some View {
        let expanded = composerFocused || !comment.isEmpty
        let empty = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if comment.isEmpty {
                    Text("Comment on \(issue.link.identifier)…").foregroundStyle(ui.muted).padding(.leading, 5).padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $comment).font(GoviInk.font(12.5)).scrollContentBackground(.hidden).focused($composerFocused)
                    .frame(height: expanded ? 76 : 18)
            }
            if expanded {
                HStack(spacing: 8) {
                    Text("Markdown supported").font(GoviInk.font(10.5)).foregroundStyle(ui.muted)
                    Spacer()
                    Button("Cancel") {
                        comment = ""
                        composerFocused = false
                    }.buttonStyle(GoviQuietButtonStyle())
                    Button {
                        let draft = comment
                        Task {
                            await model.postComment(draft)
                            if model.notice != nil && comment == draft {
                                comment = ""
                                composerFocused = false
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if model.busy == "Posting comment…" { ProgressView().controlSize(.small).scaleEffect(0.6) }
                            Text("Comment")
                            GoviKeyHint("⌘↩", onAccent: true)
                        }
                    }
                    .buttonStyle(GoviPrimaryButtonStyle())
                    .keyboardShortcut(composerFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(empty || model.busy != nil)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(ui.ink.opacity(composerFocused ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle()).onTapGesture { composerFocused = true }
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 16)
        .frame(maxWidth: 780).frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: expanded)
    }

    @ViewBuilder private func stateBadge(_ issue: GoviTaskIssue) -> some View {
        if issue.link.provider == "linear", !model.states.isEmpty {
            Menu {
                ForEach(model.states) { state in
                    Button {
                        model.stateID = state.id
                        Task { await model.updateState() }
                    } label: {
                        if state.name == issue.stateName { Label(state.name, systemImage: "checkmark") } else { Text(state.name) }
                    }
                }
            } label: {
                GoviStatePill(title: issue.stateName, symbol: linearSymbol(issue.stateName), tint: issueTint(issue), menu: true)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy != nil)
                .help("Change status")
        } else {
            GoviStatePill(title: issue.stateName, symbol: issueSymbol(issue), tint: issueTint(issue))
        }
    }

    private func linkButtons(_ link: GoviTaskLink) -> some View {
        HStack(spacing: 2) {
            if let url = GoviTaskText.webURL(link.url, provider: link.provider) {
                GoviIconButton(symbol: "link", help: "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    model.notice = "Link copied"
                }
                GoviIconButton(symbol: "arrow.up.right.square", help: "Open in " + (link.provider == "github" ? "GitHub" : "Linear")) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func pullRequestDetail(_ pr: GoviPullRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        GoviStatePill(title: pr.isDraft ? "Draft" : pr.state.capitalized, symbol: prSymbol(pr), tint: prTint(pr))
                        Text("#\(pr.number)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ui.muted)
                        if let author = pr.author?.login { Text("by \(author)").foregroundStyle(ui.muted) }
                        if let age = age(pr.updated) { Text("· updated \(age) ago").foregroundStyle(ui.muted) }
                        Spacer()
                        linkButtons(
                            .init(id: String(pr.number), provider: "github", identifier: "#\(pr.number)", title: pr.title, url: pr.url))
                    }.font(GoviInk.font(11.5))
                    Text(pr.title).font(GoviInk.font(20).weight(.semibold)).textSelection(.enabled).fixedSize(
                        horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        GoviBranchChip(name: pr.headRefName)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(ui.muted)
                        GoviBranchChip(name: pr.baseRefName)
                        if let decision = pr.reviewDecision, !decision.isEmpty {
                            Text(decision.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(GoviInk.font(11)).foregroundStyle(
                                    decision == "APPROVED"
                                        ? GoviTaskColor.open : decision == "CHANGES_REQUESTED" ? GoviTaskColor.failed : ui.muted
                                )
                                .padding(.leading, 6)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.prepareReview(repository: repository) }
                        } label: {
                            HStack(spacing: 7) {
                                if model.busy == "Reading review feedback…" {
                                    ProgressView().controlSize(.small).scaleEffect(0.6)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text("Address review feedback")
                            }
                        }.buttonStyle(GoviPrimaryButtonStyle(large: true)).disabled(model.busy != nil)
                        Spacer()
                    }
                    Text("Collects review comments and check results into a brief for an agent on \(pr.headRefName).")
                        .font(GoviInk.font(11.5)).foregroundStyle(ui.muted)
                }
                .padding(14).background(ui.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if !pr.checks.isEmpty {
                    GoviTaskSection(title: "Checks", detail: checksSummary(pr)) {
                        VStack(spacing: 0) {
                            ForEach(Array(pr.checks.enumerated()), id: \.offset) { index, check in
                                HStack(spacing: 8) {
                                    Image(systemName: checkSymbol(check)).foregroundStyle(checkTint(check)).font(.system(size: 12))
                                    Text(check.label).lineLimit(1)
                                    Spacer()
                                    Text(check.result.capitalized).font(GoviInk.font(11)).foregroundStyle(ui.muted)
                                }.padding(.horizontal, 12).frame(height: 32)
                                if index < pr.checks.count - 1 { GoviHairline().padding(.leading, 32) }
                            }
                        }.background(ui.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                GoviTaskSection(title: "Description") { GoviMarkdownText(text: pr.body ?? "", empty: "No description provided.") }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Toast

    @ViewBuilder private var toast: some View {
        if let error = model.error {
            GoviToast(symbol: "exclamationmark.triangle.fill", tint: GoviTaskColor.failed, text: error) { model.error = nil }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let notice = model.notice {
            GoviToast(symbol: "checkmark.circle.fill", tint: GoviTaskColor.open, text: notice, dismiss: nil)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Helpers

    private var identifierPlaceholder: String {
        provider == .github ? (reviews ? "Filter pull requests" : "Filter or jump to #123") : "Filter or jump to APP-142"
    }
    private var queryIdentifier: String? {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .github {
            guard !reviews, raw.range(of: "^#?[0-9]+$", options: .regularExpression) != nil else { return nil }
            let number = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return model.issues.contains { $0.link.id == number } ? nil : number
        }
        guard raw.range(of: "^[A-Za-z][A-Za-z0-9]*-[0-9]+$", options: .regularExpression) != nil else { return nil }
        return model.issues.contains { $0.link.identifier.caseInsensitiveCompare(raw) == .orderedSame } ? nil : raw
    }
    private func choose(_ issue: GoviTaskIssue) {
        guard model.issue?.id != issue.id || model.busy == nil else { return }
        comment = ""
        Task { await model.select(issue) }
    }
    private func matches(_ text: String) -> Bool {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || text.localizedCaseInsensitiveContains(raw)
    }
    private func age(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }
    private func issueSymbol(_ issue: GoviTaskIssue) -> String {
        issue.link.provider == "linear" ? linearSymbol(issue.stateName) : "circle.circle"
    }
    private func linearSymbol(_ state: String) -> String {
        let name = state.lowercased()
        if name.contains("progress") || name.contains("started") { return "circle.lefthalf.filled" }
        if name.contains("review") { return "circle.righthalf.filled" }
        if name.contains("backlog") { return "circle.dotted" }
        if name.contains("done") || name.contains("complete") { return "checkmark.circle.fill" }
        return "circle"
    }
    private func issueTint(_ issue: GoviTaskIssue) -> Color {
        guard issue.link.provider == "linear" else { return GoviTaskColor.open }
        let name = issue.stateName.lowercased()
        if name.contains("progress") || name.contains("started") { return GoviTaskColor.progress }
        if name.contains("review") { return GoviTaskColor.open }
        return ui.muted
    }
    private func prSymbol(_ pr: GoviPullRequest) -> String {
        pr.isDraft ? "circle.dashed" : "arrow.triangle.pull"
    }
    private func prTint(_ pr: GoviPullRequest) -> Color {
        pr.failingChecks > 0 ? GoviTaskColor.failed : pr.isDraft ? ui.muted : GoviTaskColor.open
    }
    private func checksSummary(_ pr: GoviPullRequest) -> String {
        let pending = pr.checks.count - pr.failingChecks - pr.passingChecks
        return [
            pr.failingChecks > 0 ? "\(pr.failingChecks) failing" : nil, pr.passingChecks > 0 ? "\(pr.passingChecks) passing" : nil,
            pending > 0 ? "\(pending) pending" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }
    private func checkSymbol(_ check: GoviPullRequest.Check) -> String {
        if check.failed { return "xmark.circle.fill" }
        return ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(check.result.uppercased()) ? "checkmark.circle.fill" : "clock"
    }
    private func checkTint(_ check: GoviPullRequest.Check) -> Color {
        if check.failed { return GoviTaskColor.failed }
        return check.result.uppercased() == "SUCCESS" ? GoviTaskColor.open : ui.muted
    }
    /// Missing connections or repository are shown as the list's own state, not as an error.
    private var needsSetup: Bool {
        provider == .github ? (!connections.githubEnabled || GoviGitHubRepository(repository) == nil) : !connections.hasLinearKey
    }
    private func refresh() async {
        guard !needsSetup else {
            model.clear()
            return
        }
        await model.refresh(provider: provider, repository: repository, assigned: assigned, reviews: reviews)
    }
    private func openInitialTask() async {
        defer { initializing = false }
        if let context = try? await GoviIntegrationGit.context(directory) { folderRepository = context.repository?.fullName }
        if let linked, let source = GoviIntegrationProvider(rawValue: linked.provider) {
            let previous = GoviTasksModel.key(provider: provider, repository: repository, assigned: assigned, reviews: reviews)
            provider = source
            repository = linked.repository ?? repository
            if GoviTasksModel.key(provider: provider, repository: repository, assigned: assigned, reviews: reviews) != previous {
                model.clear()
            }
            if linked.identifier.hasPrefix("PR ") {
                reviews = true
                await refresh()
                return
            }
            if model.issue?.link.id != linked.id { await model.select(.init(link: linked, body: "")) }
            if model.issues.isEmpty { await refresh() }
        } else {
            // Come back to the last repository and list; fall back to this terminal's repository.
            if repository.isEmpty, let folderRepository {
                repository = folderRepository
                repos.used(folderRepository)
            }
            if provider == .github && !connections.githubEnabled && connections.hasLinearKey { provider = .linear }
            let key = GoviTasksModel.key(provider: provider, repository: repository, assigned: assigned, reviews: reviews)
            if model.loadedKey != key { model.clear() }
            if !model.isFresh(key) { await refresh() }
        }
    }
    private func signInGitHub() {
        guard let executable = GoviGitHubClient.findExecutable() else { return }
        _ = launch(
            .init(
                executable: executable, directory: directory, label: "GitHub sign-in",
                arguments: ["auth", "login", "--hostname", "github.com", "--web"]))
    }
}

// MARK: - Launch card

private struct GoviTaskLaunchView: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var catalog = GoviAgentCatalog.shared
    let issue: GoviTaskIssue
    @Binding var brief: String
    let requiredBranch: String?
    let directory: String
    let loading: Bool
    let shortcutEnabled: Bool
    let launch: (GoviLaunch) -> Bool
    @State private var folder = ""
    @State private var agent = GoviAgent.claude
    @State private var worktree = true
    @State private var branch = ""
    @State private var busy = false
    @State private var error: String?
    @State private var customizing = false

    private var available: Bool { catalog.installed[agent] != nil }
    private var tooLong: Bool { brief.count > 30_000 }
    private var ready: Bool { !busy && !loading && !folder.isEmpty && available && !brief.isEmpty && !tooLong }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Button {
                    Task { await start() }
                } label: {
                    HStack(spacing: 7) {
                        if busy {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 10))
                        }
                        Text(busy ? "Opening workspace…" : available ? "Start with \(agent.name)" : "\(agent.name) isn't installed")
                    }
                }
                .buttonStyle(GoviPrimaryButtonStyle(large: true, joined: .leading))
                .keyboardShortcut(shortcutEnabled ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(!ready)
                Menu {
                    ForEach(GoviTaskAgent.supported) { value in
                        Button {
                            agent = value
                        } label: {
                            if value == agent {
                                Label(value.name, systemImage: "checkmark")
                            } else {
                                Text(value.name + (catalog.installed[value] == nil ? " — not installed" : ""))
                            }
                        }.disabled(catalog.installed[value] == nil)
                    }
                    Divider()
                    Button("Look for agents again") { catalog.refresh() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 9).frame(height: 32)
                .foregroundStyle(ui.paper)
                .background(ui.accent.opacity(0.88), in: GoviJoinedShape(side: .trailing))
                .overlay(alignment: .leading) { Rectangle().fill(ui.paper.opacity(0.35)).frame(width: 1, height: 18) }
                .help("Choose agent")
                Spacer(minLength: 12)
                GoviKeyHint("⌘↩")
            }
            HStack(spacing: 6) {
                GoviMetaChip(
                    symbol: "folder", text: folder.isEmpty ? "Choose repository" : URL(fileURLWithPath: folder).lastPathComponent,
                    action: chooseFolder
                )
                .help(folder.isEmpty ? "Choose a local checkout" : GoviPaneNaming.shortPath(folder) + " — click to change")
                if let requiredBranch {
                    GoviMetaChip(symbol: "arrow.triangle.branch", text: requiredBranch, mono: true, note: "existing checkout")
                } else {
                    GoviMetaChip(
                        symbol: "arrow.triangle.branch", text: worktree ? branch : "current branch", mono: worktree,
                        note: worktree ? "new worktree" : nil
                    ) { customizing = true }
                }
                GoviMetaChip(symbol: "doc.text", text: "Brief", note: briefSize, warning: tooLong) { customizing = true }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { customizing.toggle() }
                } label: {
                    Label(customizing ? "Done" : "Customize", systemImage: customizing ? "checkmark" : "slider.horizontal.3")
                }.buttonStyle(GoviQuietButtonStyle())
            }
            if customizing { options.transition(.opacity.combined(with: .move(edge: .top))) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(GoviInk.font(11.5)).foregroundStyle(GoviTaskColor.failed)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !available, catalog.installed.values.isEmpty == false {
                Text("Pick an installed agent from the menu.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
            }
        }
        .padding(14)
        .background(ui.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(busy)
        .onAppear {
            folder = GoviIntegrations.shared.repository(for: issue) ?? directory
            branch = GoviTaskText.branch(for: issue.link.identifier)
            catalog.refresh()
            chooseAvailableAgent()
        }
        .onReceive(catalog.$installed) { _ in chooseAvailableAgent() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            GoviHairline()
            GoviOptionRow(title: "Repository") {
                Text(folder.isEmpty ? "None" : GoviPaneNaming.shortPath(folder)).foregroundStyle(ui.muted).lineLimit(1).truncationMode(
                    .middle)
                Button("Choose…", action: chooseFolder).buttonStyle(GoviQuietButtonStyle())
            }
            if requiredBranch == nil {
                GoviOptionRow(title: "Worktree") {
                    Text("New branch from current HEAD").foregroundStyle(ui.muted)
                    Toggle("", isOn: $worktree).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                if worktree {
                    GoviOptionRow(title: "Branch") {
                        TextField("Branch name", text: $branch).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(ui.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            } else if let requiredBranch {
                Text("Uses your existing checkout of \(requiredBranch); Govi won't switch branches.").font(GoviInk.font(11))
                    .foregroundStyle(ui.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Brief").font(GoviInk.font(11.5).weight(.medium))
                    Text(tooLong ? "Shorten to 30,000 characters" : "Sent to the agent as its first message")
                        .font(GoviInk.font(11)).foregroundStyle(tooLong ? GoviTaskColor.failed : ui.muted)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(brief, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.buttonStyle(GoviQuietButtonStyle())
                }
                TextEditor(text: $brief).font(.system(size: 11, design: .monospaced)).frame(height: 200)
                    .scrollContentBackground(.hidden).padding(10)
                    .background(ui.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var briefSize: String {
        let count = brief.count
        return count >= 1000 ? String(format: "%.1fk chars", Double(count) / 1000) : "\(count) chars"
    }
    private func chooseAvailableAgent() {
        if catalog.installed[agent] == nil, let first = GoviTaskAgent.supported.first(where: { catalog.installed[$0] != nil }) {
            agent = first
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repository"
        panel.begin {
            if $0 == .OK, let url = panel.url {
                folder = url.path
                error = nil
            }
        }
    }
    private func start() async {
        guard ready, let executable = catalog.installed[agent] else { return }
        busy = true
        error = nil
        defer { busy = false }
        var created: String?
        do {
            let context = try await GoviIntegrationGit.context(folder)
            if let expected = issue.link.repository, context.repository?.fullName.lowercased() != expected.lowercased() {
                throw GoviIntegrationError.message("Choose the checkout whose origin is \(expected).")
            }
            if let requiredBranch, context.branch != requiredBranch {
                throw GoviIntegrationError.message(
                    "Open branch \(requiredBranch) in the selected checkout first. The current branch is \(context.branch.isEmpty ? "detached" : context.branch)."
                )
            }
            var path = context.root
            if worktree && requiredBranch == nil {
                let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw GoviIntegrationError.message("Enter a branch name.") }
                path = try await Task.detached { try GoviGit.createWorktree(repository: context.root, branch: name) }.value
                created = path
            }
            guard
                launch(
                    .init(
                        executable: executable, agent: agent, directory: path,
                        label: issue.link.identifier + " · " + issue.link.title, arguments: [brief], issue: issue.link))
            else {
                throw GoviIntegrationError.message(
                    "Govi couldn't open the workspace." + (created.map { " The worktree is available at " + $0 } ?? ""))
            }
            GoviIntegrations.shared.remember(context.root, for: issue)
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Pull request composer

private struct GoviPullRequestComposer: View {
    @Environment(\.goviPalette) private var ui
    @Environment(\.dismiss) private var dismiss
    let directory: String
    let linked: GoviTaskLink?
    @State private var context: GoviIntegrationGitContext?
    @State private var base = ""
    @State private var title = ""
    @State private var text = ""
    @State private var draft = true
    @State private var busy = false
    @State private var error: String?
    @State private var created: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(ui.accent)
                Text("New pull request").font(GoviInk.font(15).weight(.semibold))
                Spacer()
                GoviIconButton(symbol: "xmark", help: "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let context {
                HStack(spacing: 6) {
                    Text(context.repository?.fullName ?? "").font(GoviInk.font(12).weight(.medium))
                    GoviBranchChip(name: context.branch)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(ui.muted)
                    TextField("base", text: $base).textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7).frame(width: 120, height: 22)
                        .background(ui.hover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            } else if busy {
                ProgressView().controlSize(.small)
            }
            TextField("Title", text: $title).textFieldStyle(.plain).font(GoviInk.font(16).weight(.medium))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).font(GoviInk.font(12.5)).scrollContentBackground(.hidden)
            }.frame(minHeight: 180).padding(10)
                .background(ui.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ui.line.opacity(0.5), lineWidth: 1))
            Text("Commit and push this branch from Changes first.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(GoviTaskColor.failed).font(GoviInk.font(11.5))
                    .textSelection(.enabled)
            }
            HStack {
                Toggle("Draft", isOn: $draft).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                if let created {
                    Button("Open pull request") { NSWorkspace.shared.open(created) }.buttonStyle(GoviPrimaryButtonStyle(large: true))
                } else {
                    Button(busy ? "Creating…" : (draft ? "Create draft" : "Create pull request")) { Task { await create() } }
                        .buttonStyle(GoviPrimaryButtonStyle(large: true)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(
                            busy || context?.repository == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || base.isEmpty || context?.branch == base)
                }
            }
        }.padding(22).frame(width: 600).font(GoviInk.font(12)).foregroundStyle(ui.ink).background(ui.paper)
            .modifier(GoviChromeAppearance()).task { await prepare() }
    }
    private func prepare() async {
        busy = true
        defer { busy = false }
        do {
            let value = try await GoviIntegrationGit.context(directory)
            guard let repo = value.repository, !value.branch.isEmpty else {
                throw GoviIntegrationError.message("Open a named branch in a GitHub.com repository first.")
            }
            context = value
            title = linked?.title ?? value.branch
            text = linked.map { "References " + $0.url + "\n\nChanges:\n\nValidation:\n" } ?? "Changes:\n\nValidation:\n"
            base = try await GoviGitHubClient().defaultBranch(repo)
        } catch { self.error = error.localizedDescription }
    }
    private func create() async {
        guard !busy, let context, let repo = context.repository else { return }
        busy = true
        error = nil
        defer { busy = false }
        let reviewedTitle = title
        let reviewedBase = base
        let reviewedBody = text
        let reviewedDraft = draft
        do {
            guard GoviIntegrations.shared.githubEnabled else { throw GoviIntegrationError.message("Connect GitHub in Connections first.") }
            let head = try await GoviIntegrationGit.verifyPullRequest(context)
            let remote = try await GoviGitHubClient().branchSHA(context.branch, repository: repo)
            guard remote == head else {
                throw GoviIntegrationError.message(
                    "GitHub's branch differs from this checkout. Review and push the intended commits before creating the pull request.")
            }
            let current = try await GoviIntegrationGit.verifyPullRequest(context)
            guard current == head else {
                throw GoviIntegrationError.message("New commits appeared during review. Reopen New Pull Request to continue.")
            }
            let result = try await GoviGitHubClient().createPullRequest(
                repository: repo, head: context.branch, base: reviewedBase, title: reviewedTitle, body: reviewedBody, draft: reviewedDraft)
            guard let url = GoviTaskText.webURL(result, provider: "github") else {
                throw GoviIntegrationError.message("The request completed. Check GitHub for the pull request before trying again.")
            }
            created = url
        } catch { self.error = error.localizedDescription }
    }
}
