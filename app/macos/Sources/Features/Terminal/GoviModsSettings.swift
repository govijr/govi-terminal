import AppKit
import SwiftUI

/// Settings › Mods: what's installed, what each mod can run, and whether it's on.
struct GoviModsSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @ObservedObject private var mods = GoviMods.shared
    @State private var newName = ""
    @State private var creating = false
    @State private var message: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Mods add panes, commands, shortcuts and automations to Govi. A mod is a folder with a mod.json file; its programs run as you, with the same access as anything you start in a terminal, so only turn on mods you trust."
            )
            .foregroundStyle(ui.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("New Mod…") {
                    creating.toggle()
                    message = nil
                }
                Button("Open Mods Folder") {
                    try? FileManager.default.createDirectory(at: GoviMods.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(GoviMods.directory)
                }
                Button("Reload") {
                    mods.reload()
                    message = "Reloaded \(mods.entries.count) mod\(mods.entries.count == 1 ? "" : "s")."
                }
                if let message { Text(message).font(GoviInk.font(11)).foregroundStyle(ui.muted).lineLimit(2) }
            }.controlSize(.small)
            if creating {
                HStack(spacing: 8) {
                    TextField("Name, such as Android Emulator", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        .onSubmit(create)
                    Button("Create", action: create).disabled(GoviModPaths.slug(newName).isEmpty)
                }.controlSize(.small)
            }
            if mods.entries.isEmpty {
                Text("No mods yet. Create one to get a working example to edit, or install one with `govi mod install owner/repo`.")
                    .font(GoviInk.font(11.5)).foregroundStyle(ui.muted).padding(.top, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(mods.entries) { entry in row(entry) }
                    }.padding(.trailing, 8)
                }
            }
        }
    }

    private func create() {
        do {
            let folder = try mods.create(named: newName, enable: true)
            message = "Created and turned on. Edit the files in \(folder.lastPathComponent); Govi reloads them as you save."
            newName = ""
            creating = false
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(GoviModManifest.fileName)])
        } catch {
            message = (error as? GoviControlError)?.message ?? error.localizedDescription
        }
    }

    @ViewBuilder private func row(_ entry: GoviMods.Entry) -> some View {
        let manifest = entry.manifest
        let open = expanded.contains(entry.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(entry.enabled ? ui.accent : ui.muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).fontWeight(.medium)
                        if let manifest { Text(manifest.version).font(GoviInk.font(10.5)).foregroundStyle(ui.muted) }
                        if let manifest, manifest.service != nil, entry.enabled {
                            let running = mods.runningServices.contains(manifest.id)
                            Text(running ? "service running" : "service stopped").font(GoviInk.font(10.5))
                                .foregroundStyle(running ? ui.accent : ui.muted)
                        }
                    }
                    if let description = manifest?.description, !description.isEmpty {
                        Text(description).font(GoviInk.font(11)).foregroundStyle(ui.muted).lineLimit(2)
                    }
                    if let manifest { Text(summary(manifest)).font(GoviInk.font(10.5)).foregroundStyle(ui.muted) }
                }
                Spacer(minLength: 8)
                Button(open ? "Hide Details" : "Details") {
                    if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                }.controlSize(.small)
                if let manifest {
                    Toggle(
                        "", isOn: Binding(get: { entry.enabled }, set: { mods.setEnabled(manifest.id, $0) })
                    )
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("Turn \(entry.name) \(entry.enabled ? "off" : "on")")
                }
            }
            if let problem = entry.problem {
                Text((manifest == nil ? "" : "Using the last version that worked. ") + problem)
                    .font(GoviInk.font(11)).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if open { details(entry) }
        }
        .padding(10)
        .background(ui.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summary(_ manifest: GoviModManifest) -> String {
        var parts: [String] = []
        let count = { (number: Int, word: String) in "\(number) \(word)\(number == 1 ? "" : "s")" }
        if !manifest.panes.isEmpty { parts.append(count(manifest.panes.count, "pane")) }
        if !manifest.commands.isEmpty { parts.append(count(manifest.commands.count, "command")) }
        if !manifest.events.isEmpty { parts.append(count(manifest.events.count, "event hook")) }
        if !manifest.links.isEmpty { parts.append(count(manifest.links.count, "link handler")) }
        if manifest.service != nil { parts.append("a background service") }
        return parts.isEmpty ? "Adds nothing yet" : "Adds " + parts.joined(separator: ", ")
    }

    @ViewBuilder private func details(_ entry: GoviMods.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.folder.path).font(GoviInk.font(10.5)).foregroundStyle(ui.muted).textSelection(.enabled).lineLimit(1)
                .truncationMode(.middle)
            if let manifest = entry.manifest {
                let programs = manifest.programs
                if !programs.isEmpty {
                    Text("Programs it runs").font(GoviInk.font(11).weight(.medium))
                    ForEach(Array(programs.enumerated()), id: \.offset) { _, argv in
                        Text(argv.joined(separator: " ")).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ui.muted)
                            .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    }
                }
                if manifest.panes.contains(where: { $0.kind == .web }) {
                    Text("Its web panes can control Govi and run any program on this Mac.").font(GoviInk.font(11)).foregroundStyle(ui.muted)
                }
                let lines = mods.logs[manifest.id] ?? []
                if !lines.isEmpty {
                    Text("Recent activity").font(GoviInk.font(11).weight(.medium))
                    ScrollView {
                        Text(lines.suffix(40).joined(separator: "\n")).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(ui.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }
            }
            HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                if let manifest = entry.manifest, entry.enabled {
                    Button("Restart") { mods.restart(manifest.id) }.help("Restart its service and reload its panes")
                }
            }.controlSize(.small)
        }.padding(.leading, 24)
    }
}
