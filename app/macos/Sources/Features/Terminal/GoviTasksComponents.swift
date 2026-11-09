import SwiftUI
import AppKit

// Shared building blocks for the Tasks panel.

enum GoviTaskColor {
    static let open = Color(nsColor: .systemGreen)
    static let progress = Color(nsColor: .systemYellow)
    static let failed = Color(nsColor: .systemRed)
    static let saved = Color(nsColor: .systemYellow)
}

struct GoviRepositoryAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

struct GoviRepositoryPicker: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var store = GoviRepositoryStore.shared
    let current: String
    let folder: String?
    let choose: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private func matching(_ items: [String]) -> [String] {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(raw) }
    }
    private func excluding(_ items: [String], _ shown: [String]) -> [String] {
        items.filter { item in !shown.contains { $0.caseInsensitiveCompare(item) == .orderedSame } }
    }
    private var savedItems: [String] { matching(store.saved) }
    private var folderItems: [String] { excluding(matching(folder.map { [$0] } ?? []), store.saved) }
    private var recentItems: [String] { excluding(matching(store.recent), store.saved + folderItems) }
    private var mineItems: [String] { excluding(matching(store.mine), store.saved + folderItems + recentItems) }
    private var typed: String? {
        guard let repo = GoviGitHubRepository(text) else { return nil }
        let all = store.saved + store.recent + store.mine + (folder.map { [$0] } ?? [])
        return all.contains { $0.caseInsensitiveCompare(repo.fullName) == .orderedSame } ? nil : repo.fullName
    }
    private var first: String? { typed ?? (savedItems + folderItems + recentItems + mineItems).first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(ui.muted)
                TextField("Find a repository or type owner/name", text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let first { choose(first) } }
                if store.loading { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }.padding(.horizontal, 12).frame(height: 38)
            GoviHairline().padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let typed { row(typed, symbol: "arrow.right.circle", label: "Open " + typed) }
                    section("Starred", savedItems, symbol: "star")
                    section("This folder", folderItems, symbol: "folder")
                    section("Recent", recentItems, symbol: "clock")
                    section("Your repositories", mineItems, symbol: "book.closed")
                    if store.loading && store.mine.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Loading your repositories…")
                        }
                        .font(GoviInk.font(11.5)).foregroundStyle(ui.muted).padding(10)
                    } else if let error = store.error, store.mine.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(GoviInk.font(11)).foregroundStyle(ui.muted).fixedSize(horizontal: false, vertical: true)
                            Button("Try again") { Task { await store.load(force: true) } }.buttonStyle(GoviQuietButtonStyle())
                        }.padding(10)
                    } else if typed == nil && savedItems.isEmpty && folderItems.isEmpty && recentItems.isEmpty && mineItems.isEmpty {
                        Text(
                            text.isEmpty
                                ? "Type owner/name to open any repository." : "No repositories match. Type the full owner/name to open it."
                        )
                        .font(GoviInk.font(11.5)).foregroundStyle(ui.muted).padding(10).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(6)
            }.frame(maxHeight: 360)
            GoviHairline().padding(.horizontal, 8)
            HStack(spacing: 5) {
                Image(systemName: "star").font(.system(size: 9.5))
                Text("Star repositories to keep them on top")
                Spacer()
                GoviKeyHint("↩")
            }.font(GoviInk.font(10.5)).foregroundStyle(ui.muted).padding(.horizontal, 12).frame(height: 30)
        }
        .frame(width: 340).fixedSize(horizontal: false, vertical: true)
        .modifier(GoviGlassPanel(tint: 0.78))
        .onAppear {
            focused = true
            Task { await store.load() }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            Text(title).font(GoviInk.font(10.5).weight(.semibold)).foregroundStyle(ui.muted)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
            ForEach(items, id: \.self) { row($0, symbol: symbol) }
        }
    }

    private func row(_ value: String, symbol: String, label: String? = nil) -> some View {
        GoviRepositoryRow(
            value: value, symbol: symbol, label: label, current: value.caseInsensitiveCompare(current) == .orderedSame,
            saved: store.isSaved(value), isFirst: value == first, choose: { choose(value) },
            toggleSaved: label == nil ? { store.toggleSaved(value) } : nil)
    }
}

struct GoviRepositoryRow: View {
    @Environment(\.goviPalette) private var ui
    let value: String
    let symbol: String
    let label: String?
    let current: Bool
    let saved: Bool
    let isFirst: Bool
    let choose: () -> Void
    let toggleSaved: (() -> Void)?
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(ui.muted).frame(width: 14)
            if let label {
                Text(label).font(GoviInk.font(12).weight(.medium))
            } else if let repo = GoviGitHubRepository(value) {
                (Text(repo.owner + " / ").foregroundColor(ui.muted) + Text(repo.name).fontWeight(.medium).foregroundColor(ui.ink))
                    .font(GoviInk.font(12)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if current { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ui.accent) }
            if let toggleSaved, saved || hovering {
                Button(action: toggleSaved) {
                    Image(systemName: saved ? "star.fill" : "star").font(.system(size: 11))
                        .foregroundStyle(saved ? GoviTaskColor.saved : ui.muted).frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).help(saved ? "Unstar" : "Star")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(
            hovering ? ui.ink.opacity(0.08) : isFirst ? ui.ink.opacity(0.04) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
    }
}

struct GoviHairline: View {
    @Environment(\.goviPalette) private var ui
    var vertical = false
    var body: some View {
        Rectangle().fill(ui.line.opacity(0.55))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .frame(maxWidth: vertical ? 1 : .infinity, maxHeight: vertical ? .infinity : 1)
    }
}

struct GoviKeyHint: View {
    @Environment(\.goviPalette) private var ui
    let keys: String
    var onAccent = false
    init(_ keys: String, onAccent: Bool = false) {
        self.keys = keys
        self.onAccent = onAccent
    }
    var body: some View {
        Text(keys).font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(onAccent ? ui.paper.opacity(0.8) : ui.muted)
            .padding(.horizontal, 4).frame(height: 16)
            .background((onAccent ? ui.paper : ui.ink).opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct GoviSegmented<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var symbol: String? = nil
    }
    @Environment(\.goviPalette) private var ui
    @Binding var selection: Value
    let options: [Option]
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let on = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 10.5)) }
                        Text(option.title).font(GoviInk.font(12).weight(on ? .medium : .regular))
                    }
                    .foregroundStyle(on ? ui.ink : ui.muted)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ui.ink.opacity(0.12))
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ui.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

struct GoviChipToggle: View {
    @Environment(\.goviPalette) private var ui
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    @State private var hovering = false
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? symbol + ".fill" : symbol).font(.system(size: 10.5))
                Text(title).font(GoviInk.font(12).weight(isOn ? .medium : .regular))
            }
            .foregroundStyle(isOn ? ui.accent : (hovering ? ui.ink : ui.muted))
            .padding(.horizontal, 10).frame(height: 28)
            .background(
                isOn ? ui.accent.opacity(0.13) : ui.ink.opacity(hovering ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: GoviChromeMetrics.corner, style: .continuous)
            )
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.fixedSize()
    }
}

struct GoviTaskRow: View {
    @Environment(\.goviPalette) private var ui
    let symbol: String
    let tint: Color
    let identifier: String
    let title: String
    let meta: [String]
    let trailing: String?
    let trailingTint: Color
    let labels: [String]
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint).frame(width: 14).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(GoviTaskText.clean(title, limit: 300)).font(GoviInk.font(12.5).weight(.medium)).lineLimit(2)
                        .foregroundStyle(ui.ink).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(identifier).font(.system(size: 10.5, design: .monospaced))
                        ForEach(meta, id: \.self) {
                            Text("·")
                            Text($0)
                        }
                        ForEach(labels.prefix(2), id: \.self) { GoviLabelPill(name: $0, compact: true) }
                        Spacer(minLength: 0)
                        if let trailing { Text(trailing).foregroundStyle(trailingTint) }
                    }.font(GoviInk.font(10.5)).foregroundStyle(ui.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? ui.accent.opacity(0.13) : hovering ? ui.ink.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(ui.accent).frame(width: 3, height: 18).offset(x: -1) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

struct GoviTaskRowPlaceholder: View {
    @Environment(\.goviPalette) private var ui
    @State private var pulse = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(ui.ink.opacity(0.10)).frame(width: 12, height: 12).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(ui.ink.opacity(0.10)).frame(height: 10)
                RoundedRectangle(cornerRadius: 3).fill(ui.ink.opacity(0.07)).frame(width: 110, height: 8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 11)
        .opacity(pulse ? 0.5 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

struct GoviLabelPill: View {
    @Environment(\.goviPalette) private var ui
    let name: String
    var compact = false
    var body: some View {
        let tone = ui.tone(for: name)
        HStack(spacing: 4) {
            Circle().fill(tone).frame(width: 5, height: 5)
            Text(name).lineLimit(1)
        }
        .font(GoviInk.font(compact ? 10 : 11)).foregroundStyle(compact ? ui.muted : ui.ink)
        .padding(.horizontal, compact ? 5 : 7).frame(height: compact ? 15 : 20)
        .background(tone.opacity(compact ? 0.10 : 0.14), in: Capsule())
    }
}

struct GoviStatePill: View {
    @Environment(\.goviPalette) private var ui
    let title: String
    let symbol: String
    let tint: Color
    var menu = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(title).font(GoviInk.font(11.5).weight(.medium))
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).frame(height: 22)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

struct GoviBranchChip: View {
    @Environment(\.goviPalette) private var ui
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5))
            Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(ui.ink).padding(.horizontal, 7).frame(height: 22)
        .background(ui.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct GoviMetaChip: View {
    @Environment(\.goviPalette) private var ui
    let symbol: String
    let text: String
    var mono = false
    var note: String? = nil
    var warning = false
    var action: (() -> Void)? = nil
    @State private var hovering = false
    var body: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(ui.muted)
            Text(text).font(mono ? .system(size: 11, design: .monospaced) : GoviInk.font(11.5)).foregroundStyle(ui.ink)
                .lineLimit(1).truncationMode(.middle)
            if let note { Text(note).font(GoviInk.font(11)).foregroundStyle(warning ? GoviTaskColor.failed : ui.muted).lineLimit(1) }
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(ui.ink.opacity(hovering && action != nil ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        if let action {
            Button(action: action) { label.contentShape(Rectangle()) }.buttonStyle(.plain).onHover { hovering = $0 }
        } else {
            label
        }
    }
}

struct GoviOptionRow<Content: View>: View {
    @Environment(\.goviPalette) private var ui
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(GoviInk.font(11.5).weight(.medium)).frame(width: 78, alignment: .leading)
            content
            Spacer(minLength: 0)
        }.font(GoviInk.font(11.5))
    }
}

struct GoviTaskSection<Content: View>: View {
    @Environment(\.goviPalette) private var ui
    let title: String
    var count: Int? = nil
    var detail: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(GoviInk.font(12).weight(.semibold))
                if let count { Text("\(count)").font(GoviInk.font(11)).foregroundStyle(ui.muted) }
                if let detail { Text(detail).font(GoviInk.font(11)).foregroundStyle(ui.muted) }
            }
            content
        }
    }
}

/// Renders issue text with inline Markdown; strips template comments and long tails.
struct GoviMarkdownText: View {
    @Environment(\.goviPalette) private var ui
    let text: String
    let empty: String
    @State private var expanded = false
    private static let limit = 2_400
    var body: some View {
        let cleaned = GoviTaskText.clean(text)
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            Text(empty).foregroundStyle(ui.muted).italic()
        } else {
            let long = cleaned.count > Self.limit
            let shown = long && !expanded ? String(cleaned.prefix(Self.limit)) + "…" : cleaned
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Self.blocks(shown).enumerated()), id: \.offset) { _, block in blockView(block) }
                }.textSelection(.enabled).tint(ui.accent)
                if long {
                    Button(expanded ? "Show less" : "Show full description") { expanded.toggle() }
                        .buttonStyle(.plain).foregroundStyle(ui.accent).font(GoviInk.font(11.5))
                }
            }
        }
    }
    enum Block { case heading(String, Int), paragraph(String), bullet(String, Bool), code(String), quote(String), rule }

    /// A small block-level pass (headings, lists, code, quotes); inline Markdown is left to AttributedString.
    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code!.append(raw)
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flush()
                result.append(.heading(String(line[match.upperBound...]), line.prefix { $0 == "#" }.count))
            } else if line.range(of: "^([-*_])\\1{2,}$", options: .regularExpression) != nil {
                flush()
                result.append(.rule)
            } else if let match = line.range(of: "^[-*+]\\s+", options: .regularExpression) {
                flush()
                result.append(.bullet(String(line[match.upperBound...]), raw.hasPrefix("  ")))
            } else if let match = line.range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) {
                flush()
                result.append(
                    .bullet(
                        String(line[line.startIndex..<match.upperBound]).trimmingCharacters(in: .whitespaces) + " "
                            + line[match.upperBound...], raw.hasPrefix("  ")))
            } else if line.hasPrefix(">") {
                flush()
                result.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return result
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(Self.attributed(text)).font(GoviInk.font(level <= 2 ? 15 : 13.5).weight(.semibold))
                .padding(.top, 4).fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(Self.attributed(text)).font(GoviInk.font(13)).lineSpacing(3.5).foregroundStyle(ui.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let nested):
            let numbered = text.first?.isNumber == true
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !numbered { Text("•").font(GoviInk.font(13)).foregroundStyle(ui.muted) }
                Text(Self.attributed(text)).font(GoviInk.font(13)).lineSpacing(3).foregroundStyle(ui.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, nested ? 18 : 2).padding(.top, -4)
        case .code(let text):
            Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ui.ink.opacity(0.9))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(ui.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .quote(let text):
            Text(Self.attributed(text)).font(GoviInk.font(13)).foregroundStyle(ui.muted)
                .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(ui.line).frame(width: 2) }
                .fixedSize(horizontal: false, vertical: true)
        case .rule:
            GoviHairline()
        }
    }

    static func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
    }
}

struct GoviCommentCard: View {
    @Environment(\.goviPalette) private var ui
    let raw: String
    var body: some View {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = parts.first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ":")) } ?? "Comment"
        let name = header.components(separatedBy: " · ").first ?? header
        let location = header.components(separatedBy: " · ").dropFirst().first
        let body = parts.count > 1 ? String(parts[1]) : ""
        HStack(alignment: .top, spacing: 10) {
            Text(String(name.prefix(1)).uppercased())
                .font(GoviInk.font(11).weight(.semibold)).foregroundStyle(ui.tone(for: name))
                .frame(width: 24, height: 24).background(ui.tone(for: name).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(GoviInk.font(12).weight(.medium))
                    if let location { Text(location).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ui.muted) }
                }
                GoviMarkdownText(text: body, empty: "No text.")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(ui.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GoviEmptyState<Actions: View>: View {
    @Environment(\.goviPalette) private var ui
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(ui.accent)
                .frame(width: 44, height: 44).background(ui.accent.opacity(0.10), in: Circle())
            Text(title).font(GoviInk.font(13).weight(.semibold))
            Text(message).font(GoviInk.font(11.5)).foregroundStyle(ui.muted).multilineTextAlignment(.center).fixedSize(
                horizontal: false, vertical: true)
            actions.padding(.top, 2)
        }.padding(.horizontal, 18).padding(.vertical, 28).frame(maxWidth: .infinity)
    }
}
extension GoviEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct GoviToast: View {
    @Environment(\.goviPalette) private var ui
    let symbol: String
    let tint: Color
    let text: String
    let dismiss: (() -> Void)?
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(GoviInk.font(12)).lineLimit(3).textSelection(.enabled)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(ui.muted) }
                    .buttonStyle(.plain).padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .modifier(GoviGlassPanel(tint: 0.7))
        .frame(maxWidth: 520).padding(.bottom, 22)
    }
}

struct GoviJoinedShape: Shape {
    enum Side { case leading, trailing, none }
    var side: Side
    /// Rounds only the outer corners when two controls sit flush as one split button.
    func path(in rect: CGRect) -> Path {
        let r = min(8, rect.height / 2)
        let left: CGFloat = side == .trailing ? 0 : r
        let right: CGFloat = side == .leading ? 0 : r
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - right, y: rect.minY))
        if right > 0 {
            p.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0),
                clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        if right > 0 {
            p.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90),
                clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        if left > 0 {
            p.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180),
                clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + left))
        if left > 0 {
            p.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270),
                clockwise: false)
        }
        p.closeSubpath()
        return p
    }
}

struct GoviPrimaryButtonStyle: ButtonStyle {
    var large = false
    var joined: GoviJoinedShape.Side = .none
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, large: large, joined: joined) }
    private struct Styled: View {
        @Environment(\.goviPalette) private var ui
        @Environment(\.isEnabled) private var enabled
        let configuration: ButtonStyleConfiguration
        let large: Bool
        let joined: GoviJoinedShape.Side
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(GoviInk.font(large ? 12.5 : 12).weight(.semibold))
                .foregroundStyle(ui.paper)
                .padding(.horizontal, large ? 14 : 11).frame(height: large ? 32 : 26)
                .background(ui.accent.opacity(configuration.isPressed ? 0.78 : hovering ? 0.92 : 1), in: GoviJoinedShape(side: joined))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

struct GoviQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        @Environment(\.goviPalette) private var ui
        @Environment(\.isEnabled) private var enabled
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(GoviInk.font(11.5).weight(.medium)).foregroundStyle(ui.ink)
                .padding(.horizontal, 9).frame(height: 24)
                .background(
                    ui.ink.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.06),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}
