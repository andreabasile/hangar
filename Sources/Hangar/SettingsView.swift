import AppKit
import HangarCore
import SwiftUI

/// App-wide settings; the server is part of each preset.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane().frame(width: 540) }
            Tab("Terminal", systemImage: "terminal") { TerminalPane().frame(width: 540) }
        }
    }
}

struct GeneralPane: View {
    @Environment(LauncherModel.self) private var model
    @State private var language = Language.saved

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System Language").tag(String?.none)
                    ForEach(Language.available, id: \.self) { code in
                        // each language in its own name, so it can be found whatever the current one is
                        Text(verbatim: Language.name(code)).tag(String?.some(code))
                    }
                }
                .onChange(of: language) { Language.saved = language }
            } footer: {
                if language != Language.atLaunch {
                    HStack {
                        FooterText(String(localized: "Restart Hangar to use the new language."))
                        Button("Restart Now", action: relaunch)
                    }
                } else {
                    FooterText(String(localized: "The same choice as System Settings › General › Language & Region › Applications."))
                }
            }

            Section {
                LabeledContent("Folder") {
                    Text(verbatim: (model.paths.root.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.config]) }
                    Button("Open config.json") { openConfig(model.paths.config) }
                }
            } header: {
                Text("Configuration")
            } footer: {
                FooterText(String(localized: "Every change is saved to config.json at once, and edits made to the file in another editor show up here as soon as you save them."))
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }
}

/// The app's own language: the `AppleLanguages` key in its defaults domain, which macOS reads at launch.
@MainActor
enum Language {
    // a Set: `localizations` lists each language twice, once from Info.plist and once from its .lproj
    static let available = Set(Bundle.main.localizations).subtracting(["Base"]).sorted()
    static let atLaunch = saved

    /// Read from the app's own domain only: the merged value would return the system's languages.
    static var saved: String? {
        get {
            guard let domain = Bundle.main.bundleIdentifier else { return nil }
            return (UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first
        }
        set {
            if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }

    static func name(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

struct TerminalPane: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Open in", selection: $model.config.terminal.kind) {
                Text("Terminal").tag(TerminalKind.terminal)
                Text(verbatim: "Warp").tag(TerminalKind.warp)
                Text("Custom command").tag(TerminalKind.custom)
            }

            if model.config.terminal.kind == .custom {
                LabeledContent("Command") {
                    TextField("Command", text: $model.config.terminal.customCommand,
                              prompt: Text(verbatim: "/opt/homebrew/bin/tmux new-window -c {dir} {script}"))
                        .labelsHidden()
                        .font(.callout.monospaced())
                }
            }

            Section {
                EmptyView()
            } footer: {
                FooterText(note(model.config.terminal.kind))
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.loadError != nil)
    }

    private func note(_ kind: TerminalKind) -> String {
        switch kind {
        case .terminal:
            String(localized: "Opens the generated script (.command) with open -a Terminal, without automation permissions.")
        case .warp:
            String(localized: "Writes one Tab Config per preset to ~/.warp/tab_configs and opens it in a new window with warp://tab_config. The configs also appear in Warp’s + menu.")
        case .custom:
            String(localized: "Run with /bin/sh, which has no Homebrew PATH: use absolute paths. It must return at once: open -a …, or end with &. Placeholders: {script} is the generated script, {dir} the working folder.")
        }
    }
}
