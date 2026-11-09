import SwiftUI

struct GoviInlineSettingsView: View {
    @Environment(\.goviPalette) private var ui
    @AppStorage("GoviLocalSuggestions") private var enabled = true
    @AppStorage("GoviJevRanking") private var jevRanking = false
    @State private var key = ""
    @State private var hasKey = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                Text("A little ahead of your cursor.").font(GoviInk.font(15).weight(.medium))
                Toggle("Show inline suggestions", isOn: $enabled)
                Text("Start typing in the terminal to see a dimmed completion. Press Tab to accept it, keep typing to change it, or press Return to run only what you've entered.")
                    .foregroundStyle(ui.muted).lineSpacing(4)
                HStack(spacing: 0) {
                    Text("git").foregroundStyle(ui.ink)
                    Text(" status").foregroundStyle(ui.muted)
                    Spacer()
                    Text("Tab").font(GoviInk.font(10)).foregroundStyle(ui.muted).padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ui.line))
                }.font(.custom(GoviFontCatalog.selected, size: 14)).padding(14)
                    .background(ui.canvas, in: RoundedRectangle(cornerRadius: 8))
                Text("Suggestions use your saved commands, shell history and commands entered in Govi. They work locally, with no account or subscription.")
                    .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
                Divider()
                Text("Optional ranking").font(GoviInk.font(13).weight(.semibold))
                Toggle("Rank suggestions with Jev", isOn: $jevRanking).disabled(!hasKey || !enabled)
                Text("Sends your typed prefix and up to six candidate commands to TypeSafe after a typing pause. Jev chooses among these commands; it doesn't generate them. TypeSafe API usage is billed separately. This is off by default.")
                    .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
                HStack(spacing: 10) {
                    SecureField(hasKey ? "Replace Jev API key…" : "Jev API key…", text: $key).textFieldStyle(.roundedBorder)
                    Button("Save key") {
                        do { try GoviJevKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; hasKey = true; notice = "Saved in Keychain. The key has not been verified." }
                        catch { notice = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.count > 8192)
                    if hasKey {
                        Button("Remove") {
                            do { try GoviJevKey.remove(); hasKey = false; jevRanking = false; notice = "Key removed." }
                            catch { notice = error.localizedDescription }
                        }
                    }
                }
                if let notice { Text(notice).font(GoviInk.font(10.5)).foregroundStyle(ui.muted) }
                Link("Get a TypeSafe key", destination: URL(string: "https://typesafe.ai")!).font(GoviInk.font(11))
                Divider()
                Text("Available in zsh terminals. Open a new terminal after updating Govi. When no suggestion is visible, Tab keeps its usual completion behavior.")
                    .font(GoviInk.font(11)).foregroundStyle(ui.muted).lineSpacing(4)
            }.padding(.bottom, 12)
        }.onAppear { hasKey = GoviJevKey.exists; if !hasKey { jevRanking = false } }
    }
}
