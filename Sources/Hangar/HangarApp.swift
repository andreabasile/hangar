import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        // hidden: `Hangar --snapshot <folder>` renders the main views to PNG and quits
        if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
            let app = NSApplication.shared
            let delegate = SnapshotDelegate(folder: URL(fileURLWithPath: arguments[flag + 1]))
            app.delegate = delegate
            app.setActivationPolicy(.prohibited)
            app.run()
            _ = delegate
            return
        }
        HangarApp.main()
    }
}

struct HangarApp: App {
    @State private var model = LauncherModel()

    var body: some Scene {
        Window("Hangar", id: "main") {
            ContentView()
                .environment(model)
                .defaultAppStorage(model.defaults)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}       // one window: no "New Window"
            PresetMenu()
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// The Preset menu, acting on the focused main window.
struct PresetMenu: Commands {
    @FocusedValue(\.presetCommands) private var actions

    var body: some Commands {
        CommandMenu("Preset") {
            Button("New Preset") { actions?.add?() }
                .keyboardShortcut("n")
                .disabled(actions?.add == nil)
            Button("Duplicate") { actions?.duplicate?() }
                .keyboardShortcut("d")
                .disabled(actions?.duplicate == nil)
            Divider()
            Button("Edit Server URL") { actions?.focusURL?() }
                .keyboardShortcut("l")
                .disabled(actions?.focusURL == nil)
            Button("Test Connection") { actions?.check?() }
                .keyboardShortcut("r")
                .disabled(actions?.check == nil)
            Button("Copy Command") { actions?.copy?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.copy == nil)
            Divider()
            Button("Launch") { actions?.launch?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.launch == nil)
        }
    }
}
