import AppKit
import Foundation
import HangarCore
import Observation
import SwiftUI

/// Holds the config, saves every UI edit to `config.json` and follows edits made on disk.
/// The working folder and its recents are launcher state, kept in UserDefaults.
@MainActor
@Observable
final class LauncherModel {
    struct AlertMessage: Equatable {
        var title: String
        var message: String
    }

    /// The connection state of one server (root URL and key file), shared by every preset on it.
    struct Check: Equatable {
        /// The last answer; nil until the first one arrives.
        var status: ConnectionStatus?
        var attempt = 0
        /// A request is in flight.
        var isRunning = false
        /// The last answer was a startup failure and another try is scheduled.
        var isPolling = false
        /// Polling stopped after `Polling.limit` without an answer.
        var gaveUp = false
    }

    var config: LauncherConfig {
        didSet { persist() }
    }

    /// Set while `config.json` cannot be read: the app then does not write it, so a broken
    /// hand edit is never overwritten.
    private(set) var loadError: String?
    /// False until a config was read once: a broken file at startup leaves nothing to edit.
    private(set) var hasLoaded = false
    var alert: AlertMessage?
    var checks: [Server: Check] = [:]
    var folder: String {
        didSet { defaults.set(folder, forKey: "folder") }
    }
    private(set) var recentFolders: [String] {
        didSet { defaults.set(recentFolders, forKey: "recentFolders") }
    }
    /// Whether each tool's binary is on the terminal's PATH. Missing until known: an unknown tool
    /// is never blocked.
    var installed: [Tool: Bool] = [:]
    private(set) var isLaunching = false
    private(set) var justCopied = false
    let paths: LauncherPaths
    let defaults: UserDefaults
    /// Snapshots: an in-memory config, never read from or written to disk, no automatic checks
    /// (their staged results must stay) and no check that the working folder exists.
    let isSample: Bool

    @ObservationIgnored private var saved: LauncherConfig?
    @ObservationIgnored private var watcher: ConfigWatcher?
    @ObservationIgnored private var checkTasks: [Server: Task<Void, Never>] = [:]
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var detection: Task<Void, Never>?

    init(paths: LauncherPaths = .standard, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.defaults = defaults
        isSample = false
        folder = defaults.string(forKey: "folder") ?? "~"
        recentFolders = defaults.stringArray(forKey: "recentFolders") ?? []
        do {
            try paths.adoptLegacyFolder()
        } catch {
            let legacy = paths.legacyRoot?.path ?? ""
            alert = AlertMessage(title: String(localized: "Couldn’t move the configuration"),
                                 message: String(localized: "Couldn’t move \(legacy) to \(paths.root.path): \(error.localizedDescription)"))
        }
        TerminalLaunch.removeLegacyTabConfigs(in: paths.warpTabConfigs)
        do {
            if case .reset(let backup) = try ConfigFile.migrateIfOutdated(paths.config) {
                alert = AlertMessage(title: String(localized: "config.json replaced"),
                                     message: String(localized: "It was in an older version’s format: I saved it as \(backup.lastPathComponent) and restored the default configuration."))
            }
            let config = try ConfigFile.load(paths.config)
            self.config = config
            saved = config
            hasLoaded = true
        } catch {
            config = .defaults
            loadError = ConfigFile.describe(error)
        }
        watcher = ConfigWatcher(folder: paths.root, file: paths.config) { [weak self] in self?.reload() }
        refreshInstalledTools()
    }

    /// Asks the user's shell where each tool is. Runs at startup and whenever the app becomes active,
    /// so a tool installed meanwhile is picked up.
    func refreshInstalledTools() {
        guard !isSample, detection == nil else { return }
        detection = Task { [weak self] in
            let found = await InstalledTools.detect(binaries: Tool.allCases.map(\.spec.binary))
            guard let self else { return }
            if let found {
                installed = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, found[$0.spec.binary] != nil) })
            }
            detection = nil
        }
    }

    /// For snapshots: `config` as given, or the broken-file screen when `loadError` is set.
    init(sample config: LauncherConfig, folder: String, paths: LauncherPaths, defaults: UserDefaults, loadError: String? = nil) {
        self.paths = paths
        self.defaults = defaults
        isSample = true
        self.folder = folder
        recentFolders = []
        self.config = config
        self.loadError = loadError
        hasLoaded = loadError == nil
    }

    private func persist() {
        guard !isSample, loadError == nil, config != saved else { return }
        save()
    }

    private func save() {
        do {
            try ConfigFile.save(config, to: paths.config)
            saved = config
        } catch {
            alert = AlertMessage(title: String(localized: "Couldn’t save config.json"), message: error.localizedDescription)
        }
    }

    func reload() {
        // moved away in Finder, or deleted and recreated by a sync tool: write back what is on
        // screen rather than the defaults
        guard FileManager.default.fileExists(atPath: paths.config.path) else {
            loadError = nil
            hasLoaded = true
            save()
            return
        }
        do {
            let fresh = try ConfigFile.load(paths.config)
            loadError = nil
            hasLoaded = true
            saved = fresh
            if fresh != config { config = fresh }
        } catch {
            loadError = ConfigFile.describe(error)
        }
    }

    // MARK: Presets

    private static func newID(_ prefix: String) -> String {
        "\(prefix)-" + UUID().uuidString.prefix(6).lowercased()
    }

    /// Falls back to the value it was created with, so a preset deleted while on screen
    /// neither crashes the view nor shows another preset.
    func preset(_ id: Preset.ID?) -> Binding<Preset>? {
        guard let id, let initial = config.presets.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { [unowned self] in config.presets.first { $0.id == id } ?? initial },
                       set: { [unowned self] new in
                           if let index = config.presets.firstIndex(where: { $0.id == id }) { config.presets[index] = new }
                       })
    }

    func addPreset() -> Preset.ID {
        let preset = Preset(id: Self.newID("preset"), name: String(localized: "New preset"), tool: .claude, url: "http://localhost:1234",
                            keyFile: nil, model: "", contextTokens: 131_072, extraArgs: "")
        config.presets.append(preset)
        return preset.id
    }

    /// The copy keeps the URL and key file, so it shares the server's connection state.
    func duplicatePreset(_ id: Preset.ID) -> Preset.ID? {
        guard let index = config.presets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = config.presets[index]
        copy.id = Self.newID("preset")
        copy.name += " (copia)"
        config.presets.insert(copy, at: index + 1)
        return copy.id
    }

    func deletePreset(_ id: Preset.ID) {
        config.presets.removeAll { $0.id == id }
    }

    // MARK: Connection check

    /// Checks the server after `delay` (so typing a URL does not fire a request per key), then
    /// keeps polling every 10 s while it is still starting. Replaces any check of that server.
    func check(_ server: Server, after delay: Duration = .zero) {
        guard !isSample || delay == .zero else { return }
        checkTasks[server]?.cancel()
        checkTasks[server] = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.poll(server)
        }
    }

    func stopChecking(_ server: Server) {
        checkTasks[server]?.cancel()
        checkTasks[server] = nil
        checks[server]?.isRunning = false
        checks[server]?.isPolling = false
    }

    /// A preset was selected: check its server, unless that server is already being polled.
    func checkOnAppear(_ server: Server) {
        if let check = checks[server], check.isRunning || check.isPolling { return }
        check(server, after: .milliseconds(800))
    }

    /// A preset's URL changed. With a key file nothing is sent to a half-typed URL: only a paste
    /// checks at once, otherwise the check waits for Enter or for the field to lose focus.
    func urlEdited(_ preset: Preset, from old: String) {
        switch CheckTrigger.afterEdit(from: old, to: preset.url, hasKey: preset.keyFile != nil) {
        case .debounced: check(preset.server, after: .milliseconds(800))
        case .now: check(preset.server)
        case .wait: break
        }
    }

    /// Enter (`force`) or leaving the URL field: the URL is complete. Leaving the field checks only
    /// a server without a result yet.
    func urlCommitted(_ preset: Preset, force: Bool) {
        if force || checks[preset.server] == nil { check(preset.server) }
    }

    private func isInUse(_ server: Server) -> Bool {
        config.presets.contains { $0.mode == .server && $0.server == server }
    }

    private func poll(_ server: Server) async {
        let started = ContinuousClock.now
        var attempt = 0
        // a server no preset points at any more (a URL typed over, a preset deleted) is dropped
        while !Task.isCancelled, isInUse(server) {
            attempt += 1
            checks[server] = Check(status: checks[server]?.status, attempt: attempt, isRunning: true, isPolling: attempt > 1)
            let status = await ConnectionCheck.run(server)
            guard !Task.isCancelled, isInUse(server) else { return }
            let keepGoing = Polling.shouldContinue(after: status, elapsed: ContinuousClock.now - started)
            checks[server] = Check(status: status, attempt: attempt, isRunning: false, isPolling: keepGoing,
                                   gaveUp: status.isTransient && !keepGoing)
            if case .ok(let models) = status {
                fillEmptyModels(of: server, from: models)
                if attempt >= 2 { announceReady() }
            }
            guard keepGoing else { return }
            do { try await Task.sleep(for: Polling.interval) } catch { return }
        }
    }

    /// The server came up after a wait: the user is probably in another app.
    private func announceReady() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        AccessibilityNotification.Announcement(String(localized: "Server ready")).post()
    }

    /// A preset without a model gets the server's only chat model.
    private func fillEmptyModels(of server: Server, from models: [String]) {
        for index in config.presets.indices where config.presets[index].mode == .server && config.presets[index].server == server {
            if let model = ModelChoice.automatic(current: config.presets[index].model, ids: models) {
                config.presets[index].model = model
            }
        }
    }

    /// Model ids from the last successful check of this server.
    func models(_ server: Server) -> [String]? {
        if case .ok(let models) = checks[server]?.status { return models }
        return nil
    }

    // MARK: Folder, copy, launch

    func plan(for preset: Preset) -> LaunchPlan {
        LaunchPlan(preset: preset, directory: folder, paths: paths)
    }

    var folderExists: Bool {
        if isSample { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: NSString(string: folder).expandingTildeInPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Why Avvia is disabled, if it is.
    func blockingReason(_ preset: Preset) -> String? {
        if installed[preset.tool] == false { return String(localized: "\(preset.tool.spec.name) is not installed") }
        switch preset.mode {
        case .server:
            if preset.server.root.isEmpty { return String(localized: "Missing URL") }
            if preset.model.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Missing model") }
            if preset.keyFile?.trimmingCharacters(in: .whitespaces).isEmpty == true { return String(localized: "Missing key file") }
        case .account:
            if preset.account?.trimmingCharacters(in: .whitespaces).isEmpty == true { return String(localized: "Missing account name") }
        }
        if config.terminal.kind == .custom, config.terminal.customCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Missing terminal command")
        }
        return folderExists ? nil : String(localized: "The folder doesn’t exist")
    }

    struct StatusBadge: Equatable {
        var text: String
        var symbol: String
        var color: Color
    }

    /// The connection state next to Avvia, in the words and symbol of the form. Avvia stays
    /// enabled: the server may come up.
    func launchBarStatus(_ preset: Preset) -> StatusBadge? {
        guard preset.mode == .server, let check = checks[preset.server], let status = check.status, !status.isOK else {
            return nil
        }
        if check.isPolling { return StatusBadge(text: String(localized: "Waiting for the server"), symbol: "clock.circle.fill", color: .orange) }
        return StatusBadge(text: check.gaveUp ? ConnectionStatus.gaveUpTitle : status.title(authenticated: preset.keyFile != nil),
                           symbol: status.symbol(polling: false), color: status.color(polling: false))
    }

    func launch(_ preset: Preset) async {
        guard !isLaunching else { return }
        let plan = plan(for: preset)
        isLaunching = true
        defer { isLaunching = false }
        let terminal = config.terminal
        do {
            try await Task.detached { try TerminalLaunch.run(plan, settings: terminal) }.value
            recentFolders = RecentFolders.adding(folder, to: recentFolders)
        } catch {
            alert = AlertMessage(title: String(localized: "Couldn’t open the terminal"), message: error.localizedDescription)
        }
    }

    /// Copies the preview, after writing what it needs (Claude's settings, Codex's home), so the
    /// copied command works on its own.
    func copyCommand(_ plan: LaunchPlan) {
        do {
            try plan.writeFiles(script: false)
        } catch {
            alert = AlertMessage(title: String(localized: "Couldn’t prepare the command"), message: error.localizedDescription)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plan.preview, forType: .string)
        justCopied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }
}
