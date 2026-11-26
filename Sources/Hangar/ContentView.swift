import AppKit
import HangarCore
import SwiftUI

/// What the Preset menu can do in the focused window.
struct PresetCommands {
    var add: (() -> Void)?
    var duplicate: (() -> Void)?
    var focusURL: (() -> Void)?
    var check: (() -> Void)?
    var copy: (() -> Void)?
    var launch: (() -> Void)?
}

extension FocusedValues {
    @Entry var presetCommands: PresetCommands?
}

struct ContentView: View {
    @Environment(LauncherModel.self) private var model
    @AppStorage("selectedPreset") private var storedSelection = ""
    @State private var selection: Preset.ID?
    @State private var pendingDelete: Preset?
    @FocusState private var urlFocused: Bool

    init(selection: Preset.ID? = nil) {
        _selection = State(initialValue: selection)
    }

    private var selectedPreset: Preset? { model.config.presets.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.hasLoaded ? model.config.presets : []) { preset in
                    PresetRow(preset: preset)
                        .tag(preset.id)
                        .contextMenu {
                            Button("Duplicate") { selection = model.duplicatePreset(preset.id) }
                            Button("Delete…", role: .destructive) { pendingDelete = preset }
                        }
                }
            }
            .onDeleteCommand { if model.hasLoaded { pendingDelete = selectedPreset } }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            if !model.hasLoaded, let error = model.loadError {
                BrokenConfigView(error: error, file: model.paths.config)
            } else if let preset = model.preset(selection) {
                PresetDetail(preset: preset, urlFocused: $urlFocused).id(selection)
            } else {
                ContentUnavailableView("No Preset Selected", systemImage: "terminal",
                                       description: Text("Choose a preset in the sidebar, or create one with +."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("New Preset", systemImage: "plus") { selection = model.addPreset() }
                    .help("New preset (⌘N)")
                    .disabled(!model.hasLoaded)
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    if let selection { self.selection = model.duplicatePreset(selection) }
                }
                .help("Duplicate the preset (⌘D)")
                .disabled(selectedPreset == nil || !model.hasLoaded)
                Button("Delete", systemImage: "trash") { pendingDelete = selectedPreset }
                    .help("Delete the preset (⌫)")
                    .disabled(selectedPreset == nil || !model.hasLoaded)
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { preset in
            Button("Delete", role: .destructive) {
                model.deletePreset(preset.id)
                if selection == preset.id { selection = model.config.presets.first?.id }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("The preset is removed from config.json.")
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.hasLoaded, let error = model.loadError { ConfigErrorBanner(error: error, file: model.paths.config) }
        }
        .focusedSceneValue(\.presetCommands, commands)
        .onAppear {
            guard selection == nil else { return }
            let ids = model.config.presets.map(\.id)
            selection = ids.contains(storedSelection) ? storedSelection : ids.first
        }
        .onChange(of: selection) { storedSelection = selection ?? "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInstalledTools()
        }
    }

    private var commands: PresetCommands {
        guard model.hasLoaded else { return PresetCommands() }
        let preset = selectedPreset
        let ready = preset.flatMap { model.blockingReason($0) == nil && !model.isLaunching ? $0 : nil }
        return PresetCommands(
            add: { selection = model.addPreset() },
            duplicate: preset.map { preset in { selection = model.duplicatePreset(preset.id) } },
            focusURL: preset.flatMap { $0.mode == .server ? $0 : nil }.map { _ in { urlFocused = true } },
            check: preset.flatMap { $0.mode == .server ? $0 : nil }.map { preset in { model.check(preset.server) } },
            copy: preset.map(model.plan(for:)).map { plan in { model.copyCommand(plan) } },
            launch: ready.map { preset in { Task { await model.launch(preset) } } })
    }
}

private struct PresetRow: View {
    let preset: Preset

    /// The account, or the model, or else where it runs.
    private var subtitle: String {
        if preset.mode == .account {
            guard let account = preset.account?.trimmingCharacters(in: .whitespaces) else {
                return String(localized: "Default account")
            }
            return account.isEmpty ? String(localized: "Separate account") : String(localized: "Account “\(account)”")
        }
        if !preset.model.isEmpty { return preset.model }
        if preset.server.root.isEmpty { return String(localized: "No URL") }
        return URL(string: preset.server.root)?.host() ?? preset.server.root
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name.isEmpty ? String(localized: "Untitled") : preset.name)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            ToolBadge(tool: preset.tool)
        }
        .padding(.vertical, 2)
    }
}

/// The tool's glyph on a rounded tile, like the icons in System Settings.
struct ToolBadge: View {
    let tool: Tool

    var body: some View {
        let spec = tool.spec
        let colors = spec.colors.map { hex in
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        Image(systemName: spec.symbol)
            .font(.system(size: spec.symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            .accessibilityHidden(true)
    }
}

private struct ConfigErrorBanner: View {
    let error: String
    let file: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("config.json is not valid: \(error)").fontWeight(.medium)
                Text("Fix the file: until it is valid, the fields are locked. Launching still works.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open config.json") { openConfig(file) }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }
}

/// Shown when config.json was broken from the start: there is nothing of the user's to edit.
private struct BrokenConfigView: View {
    let error: String
    let file: URL

    var body: some View {
        ContentUnavailableView {
            Label("Invalid config.json", systemImage: "exclamationmark.triangle")
        } description: {
            let reason = error.prefix(1).uppercased() + error.dropFirst()
            Text("\(reason).\nFix it: the app reads it again as soon as you save it.")
        } actions: {
            Button("Open config.json") { openConfig(file) }
                .buttonStyle(.borderedProminent)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }
}

struct PresetDetail: View {
    @Environment(LauncherModel.self) private var model
    @Binding var preset: Preset
    var urlFocused: FocusState<Bool>.Binding

    var body: some View {
        let plan = model.plan(for: preset)
        Form {
            switch preset.mode {
            case .server: ServerSection(preset: $preset, urlFocused: urlFocused)
            case .account: AccountSection(preset: $preset)
            }

            Section {
                TextField("Name", text: $preset.name)
                ToolPicker(tool: $preset.tool)
                    .onChange(of: preset.tool) { preset = preset.adapted() }
                if preset.tool.spec.modes.count > 1 {
                    LabeledContent("Mode") {
                        Picker("Mode", selection: $preset.mode) {
                            ForEach(preset.tool.spec.modes) { mode in
                                (mode == .server ? Text("Server") : Text("Account")).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                if preset.mode == .server || preset.tool.spec.accountModelFlag != nil {
                    LabeledContent("Model") {
                        HStack(spacing: 4) {
                            TextField("Model", text: $preset.model,
                                      prompt: preset.mode == .server ? Text("model alias") : Text("tool default"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                            if preset.mode == .server { ModelMenu(preset: $preset) }
                        }
                    }
                }
                if preset.mode == .server {
                    ModelMismatchRow(preset: $preset)
                    LabeledContent {
                        TextField("Context", value: $preset.contextTokens, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Context (tokens)")
                        if preset.tool == .claude, preset.contextIsTooSmall {
                            Label {
                                let minimum = Preset.claudeMinimumContext.formatted(.number.grouping(.never))
                                Text("Below \(minimum), Claude Code runs into “Autocompact is thrashing”")
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                TextField("Extra arguments", text: $preset.extraArgs, prompt: Text("optional, e.g. --resume"))
            } header: {
                Text("Preset")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if model.installed[preset.tool] == false { InstallHint(tool: preset.tool) }
                    if let note = toolNote { FooterText(note) }
                }
            }

            Section {
                ScrollView(.horizontal) {
                    Text(plan.preview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Command")
                    Spacer()
                    Button {
                        model.copyCommand(plan)
                    } label: {
                        Label(model.justCopied ? String(localized: "Copied") : String(localized: "Copy Command"),
                              systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .help("Copy the command (⇧⌘C)")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.loadError != nil)
        .navigationTitle(preset.name.isEmpty ? String(localized: "Untitled") : preset.name)
        .safeAreaInset(edge: .bottom, spacing: 0) { LaunchBar(preset: preset) }
    }
}

extension PresetDetail {
    /// For tools whose command follows their documentation but was never launched by us.
    var toolNote: String? {
        let spec = preset.tool.spec
        guard !spec.verified else { return nil }
        let note = String(localized: "Experimental support: this command has not been tried with \(spec.name) yet.")
        guard preset.mode == .server, let serverNote = spec.serverNote else { return note }
        return note + " " + serverNote
    }
}

/// The tool menu: installed tools first, then the others, each in menu order (Claude Code and
/// Codex first, then by name). Without a detection result yet it is one plain list.
private struct ToolPicker: View {
    @Environment(LauncherModel.self) private var model
    @Binding var tool: Tool

    var body: some View {
        Picker("Tool", selection: $tool) {
            if model.installed.isEmpty {
                ForEach(Tool.menuOrder) { Text($0.spec.name).tag($0) }
            } else {
                let installed = Tool.menuOrder.filter { model.installed[$0] != false }
                let missing = Tool.menuOrder.filter { model.installed[$0] == false }
                if !installed.isEmpty {
                    Section("Installed") { ForEach(installed) { Text($0.spec.name).tag($0) } }
                }
                if !missing.isEmpty {
                    Section("Not Installed") { ForEach(missing) { Text($0.spec.name).tag($0) } }
                }
            }
        }
        .pickerStyle(.menu)
    }
}

/// Where the preset's model runs: URL, authentication and the connection state. Presets on the
/// same URL and key file share that state.
private struct ServerSection: View {
    @Binding var preset: Preset
    var urlFocused: FocusState<Bool>.Binding

    var body: some View {
        Section {
            URLField(preset: $preset, focused: urlFocused)
            KeyFileRows(preset: $preset)
            ConnectionRow(preset: preset)
        } header: {
            Text("Model Server")
        } footer: {
            FooterText(String(localized: "The server root, without /v1.") + " " + authNote)
        }
    }
}

private extension ServerSection {
    var authNote: String {
        if preset.keyFile != nil {
            return String(localized: "The key never appears: the app passes only the file’s path, read at launch.")
        }
        return preset.tool == .claude
            ? String(localized: "Without authentication, Claude Code gets the dummy key “\(Server.dummyKey)”, since it wants one.")
            : String(localized: "Without authentication, no key is sent.")
    }
}

/// Authentication: none, or a key file. A new key file is checked after a pause, since the URL is
/// already complete.
private struct KeyFileRows: View {
    @Environment(LauncherModel.self) private var model
    @Binding var preset: Preset

    var body: some View {
        Picker("Authentication", selection: Binding(get: { preset.keyFile != nil },
                                                   set: { preset.keyFile = $0 ? (preset.keyFile ?? "") : nil })) {
            Text("None").tag(false)
            Text("Key File").tag(true)
        }
        .onChange(of: [preset.id, preset.keyFile ?? "\u{0}"]) { old, new in
            if old[0] == new[0] { model.check(preset.server, after: .milliseconds(800)) }
        }
        if let keyFile = preset.keyFile {
            LabeledContent("Key file") {
                HStack(spacing: 8) {
                    TextField("Key file", text: Binding(get: { keyFile }, set: { preset.keyFile = $0 }),
                              prompt: Text(verbatim: "~/.config/…/api-key"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    Button("Choose…") {
                        if let file = chooseKeyFile(from: keyFile) { preset.keyFile = file }
                    }
                }
            }
        }
    }
}

/// The tool's own login: its default account, or a separate one in Hangar's accounts folder.
private struct AccountSection: View {
    @Environment(LauncherModel.self) private var model
    @Binding var preset: Preset

    var body: some View {
        let spec = preset.tool.spec
        Section {
            if spec.separateAccounts {
                LabeledContent("Account") {
                    Picker("Account", selection: Binding(get: { preset.account != nil },
                                                         set: { preset.account = $0 ? (preset.account ?? "") : nil })) {
                        Text("Default").tag(false)
                        Text("Separate").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if let name = preset.account {
                    TextField("Name", text: Binding(get: { name }, set: { preset.account = $0 }), prompt: Text("e.g. work"))
                }
            } else {
                LabeledContent("Account") { Text("Default") }
            }
        } header: {
            Text("Account")
        } footer: {
            FooterText(footer(spec))
        }
    }

    private func footer(_ spec: ToolSpec) -> String {
        guard let name = preset.account else {
            let home = spec.defaultHome.map { " (\($0))" } ?? ""
            let usual = String(localized: "Uses the login and settings \(spec.name) is already set up with\(home).",
                               comment: "The second value is “ (~/.claude)” or empty")
            return spec.separateAccounts ? usual : usual + " " + String(localized: "\(spec.name) does not allow separate accounts.")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return String(localized: "Give the account a name: presets with the same name share the login.")
        }
        let folder = abbreviated(model.paths.accountDirectory(preset.tool, name: name))
        return String(localized: "Account folder: \(folder). On first launch \(spec.name) asks you to sign in. A separate account starts without your settings, MCP servers and plugins.")
    }
}

/// How to install a tool that is not on the terminal's PATH, with a copy button.
private struct InstallHint: View {
    let tool: Tool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(tool.spec.name) is not installed. To install it, in the terminal:")
            HStack(spacing: 8) {
                Text(tool.spec.installCommand)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                Button(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.spec.installCommand, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

/// Picks the model alias from the chat models the server listed in its last check.
private struct ModelMenu: View {
    @Environment(LauncherModel.self) private var model
    @Binding var preset: Preset

    var body: some View {
        let models = ModelChoice.chatModels(model.models(preset.server) ?? [])
        Menu {
            if !models.isEmpty {
                Picker("Server Models", selection: $preset.model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button(models.isEmpty ? String(localized: "Load Models from the Server") : String(localized: "Refresh the List")) {
                model.check(preset.server)
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the model from the server’s list")
        .accessibilityLabel("Choose the model")
    }
}

/// A soft warning when the preset's model is not one the server offers.
private struct ModelMismatchRow: View {
    @Environment(LauncherModel.self) private var model
    @Binding var preset: Preset

    var body: some View {
        if let ids = model.models(preset.server), let mismatch = ModelChoice.mismatch(current: preset.model, ids: ids) {
            // the button goes under the text: model names are long and would be truncated beside it
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("“\(preset.model)” is not among the server’s models").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                .font(.subheadline)
                if let suggestion = mismatch.suggestion {
                    Button("Use “\(suggestion)”") { preset.model = suggestion }
                        .controlSize(.small)
                        .padding(.leading, 22)
                }
            }
        }
    }
}

private struct LaunchBar: View {
    @Environment(LauncherModel.self) private var model
    let preset: Preset

    var body: some View {
        let blocking = model.blockingReason(preset)
        let status = blocking == nil ? model.launchBarStatus(preset) : nil
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Working folder").font(.subheadline).foregroundStyle(.secondary)
                FolderMenu()
            }
            Spacer(minLength: 12)
            if let blocking {
                Text(blocking).foregroundStyle(.secondary)
            } else if let status {
                Label {
                    Text(status.text)
                } icon: {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                }
            }
            if model.isLaunching { ProgressView().controlSize(.small) }
            Button {
                Task { await model.launch(preset) }
            } label: {
                Label("Launch", systemImage: "play.fill").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(blocking != nil || model.isLaunching)
            .help(blocking ?? String(localized: "Launch \(preset.tool.spec.name) in the terminal (⌘↩)"))
            .accessibilityHint(blocking ?? "")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .dropDestination(for: URL.self) { urls, _ in
            var isDirectory: ObjCBool = false
            guard let url = urls.first, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            model.folder = abbreviated(url.path)
            return true
        }
    }
}

/// Xcode-style pop-up: the working folder, the recently launched ones, and a picker.
private struct FolderMenu: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Recent Folders", selection: $model.folder) {
                ForEach(RecentFolders.adding(model.folder, to: model.recentFolders), id: \.self) {
                    Text(abbreviated($0)).tag($0)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Choose Another Folder…") {
                if let folder = chooseFolder(from: model.folder) { model.folder = folder }
            }
        } label: {
            Label(abbreviated(model.folder), systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Working folder. You can also drag a folder onto it from the Finder.")
    }
}

/// The server URL. With a key file, typing never sends the key to a half-typed URL: the check runs
/// on Enter, on leaving the field, or on a paste.
struct URLField: View {
    @Environment(LauncherModel.self) private var model
    @Binding var preset: Preset
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField("URL", text: $preset.url, prompt: Text(verbatim: "http://localhost:1234"))
            .focused(focused)
            .onSubmit { model.urlCommitted(preset, force: true) }
            .onChange(of: focused.wrappedValue) { _, isFocused in
                if !isFocused { model.urlCommitted(preset, force: false) }
            }
            // keyed by id too: selecting another preset changes the URL without anyone typing
            .onChange(of: [preset.id, preset.url]) { old, new in
                if old[0] == new[0] { model.urlEdited(preset, from: old[1]) }
            }
    }
}

/// Connection status plus the button that checks or stops checking. Checks when it appears (a
/// preset was selected), unless that server is already being polled.
struct ConnectionRow: View {
    @Environment(LauncherModel.self) private var model
    let preset: Preset

    var body: some View {
        let server = preset.server
        let check = model.checks[server]
        LabeledContent {
            if check?.isRunning == true || check?.isPolling == true {
                Button("Stop") { model.stopChecking(server) }
            } else {
                Button("Test Connection") { model.check(server) }
            }
        } label: {
            ConnectionStatusLabel(check: check, authenticated: preset.keyFile != nil)
        }
        .task(id: preset.id) { model.checkOnAppear(server) }
    }
}

private struct ConnectionStatusLabel: View {
    let check: LauncherModel.Check?
    let authenticated: Bool

    var body: some View {
        if let check, let status = check.status {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.gaveUp ? ConnectionStatus.gaveUpTitle : status.title(authenticated: authenticated))
                    Text(status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .help(status.help ?? status.detail)
                    if check.isPolling {
                        HStack(spacing: 6) {
                            if check.isRunning { ProgressView().controlSize(.mini) }
                            Text("Waiting for the server… (attempt \(check.attempt))")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: status.symbol(polling: check.isPolling)).foregroundStyle(status.color(polling: check.isPolling))
            }
        } else if check?.isRunning == true {
            Label { Text("Checking…") } icon: { ProgressView().controlSize(.small) }
        } else {
            Label("Connection not checked", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

/// Section footers sit flush with the row labels, as in System Settings.
struct FooterText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
    }
}

/// With the app the user picked for JSON; without one, in the Finder.
@MainActor
func openConfig(_ file: URL) {
    if !NSWorkspace.shared.open(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
}

@MainActor
func chooseFolder(from path: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "Choose")
    panel.directoryURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return abbreviated(url.path)
}

/// The key usually sits in a hidden folder such as ~/.config, so hidden files are shown.
@MainActor
func chooseKeyFile(from path: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = String(localized: "Choose")
    let current = NSString(string: path).expandingTildeInPath
    panel.directoryURL = URL(fileURLWithPath: current.isEmpty ? NSHomeDirectory() : (current as NSString).deletingLastPathComponent)
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return abbreviated(url.path)
}

/// `/Users/x/project` → `~/project`.
func abbreviated(_ path: String) -> String {
    NSString(string: NSString(string: path).expandingTildeInPath).abbreviatingWithTildeInPath
}
