import AppKit
import HangarCore
import SwiftUI

/// Renders the main window and the Settings pane to PNG, light and dark, from an in-memory sample
/// config and throwaway UserDefaults: nothing is read from or written to ~/.config. Windows are
/// drawn offscreen and never shown. `screenshot-{light,dark}.png` are the README's docs/ images.
/// ImageRenderer is not used: it leaves AppKit-backed controls (Form, TextField, List, toolbar) blank.
@MainActor
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    private let folder: URL

    init(folder: URL) { self.folder = folder }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await Snapshots.render(to: folder)
                print("snapshots in \(folder.path)")
            } catch {
                print("snapshots failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}

@MainActor
enum Snapshots {
    /// Everything shown is fictional: the snapshots go into the README. Paths are absolute under
    /// /Users/demo, since `~` would expand to the real home in the command preview.
    private static let demoHome = "/Users/demo"
    private static let keyFile = "\(demoHome)/.config/hangar/keys/example"

    /// The sample account's name, in the language the snapshots are drawn in.
    private static var work: String { String(localized: "work", comment: "A sample account name in the screenshots") }

    static var sample: LauncherConfig { LauncherConfig(terminal: TerminalSettings(kind: .warp, customCommand: ""), presets: [
        Preset(id: "claude", name: "Claude Code", tool: .claude, url: "", keyFile: nil, model: "",
               contextTokens: 200_000, extraArgs: "", mode: .account),
        Preset(id: "claude-work", name: "Claude Code · \(work)", tool: .claude, url: "", keyFile: nil, model: "",
               contextTokens: 200_000, extraArgs: "", mode: .account, account: work),
        Preset(id: "codex", name: "Codex", tool: .codex, url: "", keyFile: nil, model: "",
               contextTokens: 200_000, extraArgs: "", mode: .account),
        Preset(id: "claude-gpu", name: "Claude Code · GPU", tool: .claude, url: "https://gpu.example.com",
               keyFile: keyFile, model: "qwen3-coder-30b", contextTokens: 131_072, extraArgs: ""),
        Preset(id: "codex-gpu", name: "Codex · GPU", tool: .codex, url: "https://gpu.example.com",
               keyFile: keyFile, model: "qwen3-coder-30b", contextTokens: 131_072, extraArgs: ""),
        Preset(id: "claude-lmstudio", name: "Claude Code · LM Studio", tool: .claude, url: "http://localhost:1234",
               keyFile: nil, model: "llama-3.3-70b", contextTokens: 65_536, extraArgs: ""),
        Preset(id: "codex-lmstudio", name: "Codex · LM Studio", tool: .codex, url: "http://localhost:1234",
               keyFile: nil, model: "", contextTokens: 32_768, extraArgs: ""),
        Preset(id: "opencode-gpu", name: "OpenCode · GPU", tool: .opencode, url: "https://gpu.example.com",
               keyFile: keyFile, model: "qwen3-coder-30b", contextTokens: 131_072, extraArgs: ""),
        Preset(id: "droid-gpu", name: "Factory Droid · GPU", tool: .droid, url: "https://gpu.example.com",
               keyFile: keyFile, model: "qwen3-coder-30b", contextTokens: 131_072, extraArgs: ""),
        Preset(id: "gemini", name: "Gemini CLI", tool: .gemini, url: "", keyFile: nil, model: "",
               contextTokens: 200_000, extraArgs: "", mode: .account),
    ]) }

    /// One preset per tool, in menu order: the sidebar shows every badge.
    static let gallery = LauncherConfig(terminal: TerminalSettings(kind: .warp, customCommand: ""), presets: Tool.menuOrder.map {
        Preset(id: $0.rawValue, name: $0.spec.name, tool: $0, url: "", keyFile: nil, model: "", contextTokens: 131_072,
               extraArgs: "", mode: $0.spec.modes.contains(.account) ? .account : .server)
    })

    static func render(to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "hangar-snapshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let paths = LauncherPaths(root: URL(fileURLWithPath: "\(demoHome)/.config/hangar"),
                                  warpTabConfigs: URL(fileURLWithPath: "\(demoHome)/.warp/tab_configs"))
        let model = LauncherModel(sample: sample, folder: "\(demoHome)/code/demo", paths: paths, defaults: defaults)
        model.installed = [.claude: true, .codex: true]
        func index(_ id: Preset.ID) -> Int { model.config.presets.firstIndex { $0.id == id }! }
        let gpu = sample.presets[index("claude-gpu")].server, lmStudio = sample.presets[index("claude-lmstudio")].server
        let wide = CGSize(width: 860, height: 860), tall = CGSize(width: 860, height: 1100)
        // LM Studio with one chat model loaded, not the one the Claude preset names: a mismatch
        model.checks[lmStudio] = .init(status: .ok(models: [
            "qwen3-coder-30b-a3b-instruct-mlx", "text-embedding-nomic-embed-text-v1.5"]), attempt: 1)

        func main(_ preset: Preset.ID, _ size: CGSize, dark: Bool, _ name: String) async throws {
            try await save(ContentView(selection: preset).environment(model).defaultAppStorage(defaults),
                           title: model.config.presets[index(preset)].name,
                           size: size, dark: dark, to: folder.appending(path: name))
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            // the README screenshot: a server with a key file, reachable
            model.checks[gpu] = .init(status: .ok(models: ["qwen3-coder-30b"]), attempt: 1)
            try await main("claude-gpu", wide, dark: dark, "screenshot-\(suffix).png")
            try await main("claude", wide, dark: dark, "main-account-default-\(suffix).png")
            try await main("claude-work", wide, dark: dark, "main-account-separate-\(suffix).png")
            model.installed[.codex] = false
            try await main("codex", wide, dark: dark, "main-not-installed-\(suffix).png")
            model.installed[.codex] = true
            model.checks[gpu] = .init(status: ConnectionCheck.status(code: 404, body: Data()),
                                      attempt: 7, isRunning: false, isPolling: true)
            try await main("claude-gpu", wide, dark: dark, "main-gpu-polling-\(suffix).png")
            model.checks[gpu] = .init(status: ConnectionCheck.status(code: 404, body: Data()),
                                      attempt: 180, isRunning: false, isPolling: false, gaveUp: true)
            try await main("codex-gpu", wide, dark: dark, "main-gpu-gave-up-\(suffix).png")
            try await main("claude-lmstudio", wide, dark: dark, "main-lmstudio-mismatch-\(suffix).png")
            try await save(SettingsView().environment(model), title: String(localized: "Settings"), size: nil,
                           dark: dark, to: folder.appending(path: "settings-terminal-\(suffix).png"))
            model.checks[gpu] = .init(status: .ok(models: ["qwen3-coder-30b"]), attempt: 1)
            try await main("opencode-gpu", wide, dark: dark, "main-unverified-server-\(suffix).png")
            try await main("gemini", wide, dark: dark, "main-default-only-\(suffix).png")
            let all = LauncherModel(sample: gallery, folder: "\(demoHome)/code/demo", paths: paths, defaults: defaults)
            try await save(ContentView(selection: "claude").environment(all).defaultAppStorage(defaults), title: "Claude Code",
                           size: CGSize(width: 860, height: 1880), dark: dark, to: folder.appending(path: "badges-all-\(suffix).png"))
        }
        model.checks[gpu] = .init(status: .ok(models: ["qwen3-coder-30b"]), attempt: 1)
        try await main("droid-gpu", wide, dark: false, "main-droid-server-light.png")

        model.config.presets[index("codex-lmstudio")].model = "qwen3-coder-30b-a3b-instruct-mlx"
        try await main("codex-lmstudio", tall, dark: true, "main-codex-lmstudio-dark.png")
        model.config.presets[index("claude-lmstudio")].model = "qwen3-coder-30b-a3b-instruct-mlx"
        model.config.presets[index("claude-lmstudio")].contextTokens = 32_768
        for dark in [false, true] {
            try await main("claude-lmstudio", wide, dark: dark, "main-small-context-\(dark ? "dark" : "light").png")
        }
        model.config.terminal.kind = .custom
        try await save(SettingsView().environment(model), title: String(localized: "Settings"), size: nil, dark: false,
                       to: folder.appending(path: "settings-terminal-custom-light.png"))

        // config.json broken before anything was loaded
        // the message the app would show for this file, in the snapshots' language
        let reason: String
        do {
            _ = try JSONDecoder().decode(LauncherConfig.self, from: Data("{\n  \"version\": 4,\n  \"presets\": [1, 2,,]\n}".utf8))
            reason = ""
        } catch {
            reason = ConfigFile.describe(error)
        }
        let broken = LauncherModel(sample: sample, folder: "\(demoHome)/code/demo", paths: paths, defaults: defaults,
                                   loadError: reason)
        for dark in [false, true] {
            try await save(ContentView().environment(broken).defaultAppStorage(defaults), title: "Hangar",
                           size: CGSize(width: 860, height: 560), dark: dark,
                           to: folder.appending(path: "broken-config-\(dark ? "dark" : "light").png"))
        }
    }

    /// `size` nil lets the view pick its own size, like the Settings window does. The title is set by
    /// hand: offscreen, SwiftUI bridges the toolbar but not `navigationTitle`.
    private static func save(_ view: some View, title: String, size: CGSize?, dark: Bool, to url: URL) async throws {
        // drawn as in the key window, so the prominent button and selection show their accent color
        let controller = NSHostingController(rootView: view.environment(\.controlActiveState, .key))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        // the main window has a unified toolbar; Settings is a plain titled window
        window.styleMask = size == nil ? [.titled, .closable] : [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = title
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let size { window.setContentSize(size) }
        // let SwiftUI lay out, bridge the toolbar and settle
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let frame = window.contentView?.superview else { throw CocoaError(.fileWriteUnknown) }
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        window.close()
    }
}
