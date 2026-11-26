import AppKit
import HangarCore
import SwiftUI

/// Only the terminal is a setting: the server is part of each preset.
struct SettingsView: View {
    var body: some View {
        TerminalPane().frame(width: 540)
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
