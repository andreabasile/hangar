import Foundation

public enum TerminalKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal, warp, custom

    public var id: Self { self }
}

public struct TerminalSettings: Codable, Equatable, Sendable {
    public var kind: TerminalKind
    /// Run with /bin/sh and must return at once. Placeholders: `{script}`, `{dir}` (shell-quoted).
    /// (Files from the first version also hold `customApp`; decoding ignores it.)
    public var customCommand: String

    public init(kind: TerminalKind, customCommand: String) {
        self.kind = kind
        self.customCommand = customCommand
    }
}

/// Where a preset's model runs. Presets with the same root and key file are the same server:
/// its connection is checked and polled once for all of them.
public struct Server: Hashable, Sendable {
    /// What the tools get as key when the server has no auth: they refuse to start without one.
    public static let dummyKey = "local"

    /// The URL without spaces, trailing slashes or `/v1`: each tool adds what it needs.
    public let root: String
    /// Path of the file holding the key; nil means no auth.
    public let keyFile: String?

    public init(url: String, keyFile: String?) {
        var root = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1") { root.removeLast(3) }
        self.root = root
        self.keyFile = keyFile
    }

    public var keyPath: String? { keyFile.map { NSString(string: $0).expandingTildeInPath } }
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tool: Tool
    public var mode: LaunchMode
    /// Account mode: nil is the tool's default account, a name a separate one. Presets with the same
    /// tool and name share the login.
    public var account: String?
    /// Server mode: the server root, e.g. `http://localhost:1234`.
    public var url: String
    /// Path of the file holding the key; nil (absent from the file) means no auth.
    public var keyFile: String?
    public var model: String
    public var contextTokens: Int
    /// Raw shell text appended to the command, so quoting works as in a terminal.
    /// (Older files also hold `workingDirectory`; the folder is now launcher state, so it is ignored.)
    public var extraArgs: String

    /// Below this Claude Code keeps autocompacting: the UI warns, without blocking.
    public static let claudeMinimumContext = 65_536
    public var contextIsTooSmall: Bool { tool == .claude && contextTokens < Self.claudeMinimumContext }

    public var server: Server { Server(url: url, keyFile: keyFile) }

    public init(id: String, name: String, tool: Tool, url: String, keyFile: String?, model: String,
                contextTokens: Int, extraArgs: String, mode: LaunchMode = .server, account: String? = nil) {
        self.id = id
        self.name = name
        self.tool = tool
        self.mode = mode
        self.account = account
        self.url = url
        self.keyFile = keyFile
        self.model = model
        self.contextTokens = contextTokens
        self.extraArgs = extraArgs
    }
}

public struct LauncherConfig: Codable, Equatable, Sendable {
    /// Bumped when the schema changes, so an old file is recognised and converted (with a backup).
    /// 4: presets have a mode (server or account); 3: each preset holds its URL and key file;
    /// 2 had shared endpoints.
    public static let currentVersion = 4

    public var version: Int
    public var terminal: TerminalSettings
    public var presets: [Preset]

    public init(version: Int = currentVersion, terminal: TerminalSettings, presets: [Preset]) {
        self.version = version
        self.terminal = terminal
        self.presets = presets
    }

    /// First run: each tool with its own login, and both on a local LM Studio (the model is picked
    /// from its list).
    public static let defaults = LauncherConfig(
        terminal: TerminalSettings(kind: .warp, customCommand: ""),
        presets: [
            Preset(id: "claude", name: "Claude Code", tool: .claude, url: "", keyFile: nil, model: "",
                   contextTokens: 200_000, extraArgs: "", mode: .account),
            Preset(id: "codex", name: "Codex", tool: .codex, url: "", keyFile: nil, model: "",
                   contextTokens: 200_000, extraArgs: "", mode: .account),
            Preset(id: "claude-lmstudio", name: "Claude Code · LM Studio", tool: .claude, url: "http://localhost:1234",
                   keyFile: nil, model: "", contextTokens: 65_536, extraArgs: ""),
            Preset(id: "codex-lmstudio", name: "Codex · LM Studio", tool: .codex, url: "http://localhost:1234",
                   keyFile: nil, model: "", contextTokens: 32_768, extraArgs: ""),
        ])
}

public struct LauncherPaths: Sendable {
    public var root: URL
    public var warpTabConfigs: URL
    /// The folder of the app's first name, moved to `root` on first launch.
    public var legacyRoot: URL?

    public init(root: URL, warpTabConfigs: URL, legacyRoot: URL? = nil) {
        self.root = root
        self.warpTabConfigs = warpTabConfigs
        self.legacyRoot = legacyRoot
    }

    public var config: URL { root.appending(path: "config.json") }
    public var generated: URL { root.appending(path: "generated", directoryHint: .isDirectory) }
    /// Codex's home for server launches: no MCP servers, plugins or hooks from `~/.codex`.
    public var codexHome: URL { root.appending(path: "codex-home", directoryHint: .isDirectory) }
    public var accounts: URL { root.appending(path: "accounts", directoryHint: .isDirectory) }
    /// Server-mode state of the tools that need a home of their own, one folder per preset.
    public var presets: URL { root.appending(path: "presets", directoryHint: .isDirectory) }

    /// A preset's server-mode folder: absolute, no `~`, no trailing slash. `stem` is a plain file name.
    public func presetDirectory(_ stem: String) -> String {
        presets.appending(path: stem).standardizedFileURL.path
    }

    /// A separate account's folder: absolute, no `~`, no trailing slash. The tools hash the raw
    /// path (Claude names its Keychain item after it), so it must always be spelled the same way.
    public func accountDirectory(_ tool: Tool, name: String) -> String {
        accounts.appending(path: tool.rawValue).appending(path: Account.slug(name)).standardizedFileURL.path
    }

    public static var standard: LauncherPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LauncherPaths(root: home.appending(path: ".config/hangar", directoryHint: .isDirectory),
                             warpTabConfigs: home.appending(path: ".warp/tab_configs", directoryHint: .isDirectory),
                             legacyRoot: home.appending(path: ".config/agent-launcher", directoryHint: .isDirectory))
    }

    /// Moves the legacy folder to `root` with a single rename, so presets, backups, Codex's home and
    /// generated files come along. Does nothing when `root` already exists (both are left alone)
    /// or there is no legacy folder. Returns whether it moved.
    @discardableResult
    public func adoptLegacyFolder() throws -> Bool {
        let manager = FileManager.default
        guard let legacyRoot, !manager.fileExists(atPath: root.path), manager.fileExists(atPath: legacyRoot.path) else {
            return false
        }
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: legacyRoot, to: root)
        return true
    }
}

public enum ConfigFile {
    public struct UnsupportedVersion: Error {
        public let version: Int
    }

    /// Reads the config, writing the defaults first when the file does not exist yet.
    public static func load(_ url: URL) throws -> LauncherConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try save(.defaults, to: url)
            return .defaults
        }
        let config = try JSONDecoder().decode(LauncherConfig.self, from: Data(contentsOf: url))
        // a newer app wrote it: saving it here could drop fields this version does not know
        guard config.version == LauncherConfig.currentVersion else { throw UnsupportedVersion(version: config.version) }
        return config
    }

    public enum Migration: Equatable, Sendable {
        case none
        /// No `version` but already in today's shape: kept and saved again with the version.
        case adopted
        /// An older version (3, or 2 with shared endpoints): converted, the original kept as the backup.
        case upgraded(backup: URL)
        /// An older shape: renamed to the backup and replaced by the defaults.
        case reset(backup: URL)
    }

    /// Version 3: presets held their server, with no mode (all were server presets).
    private struct Version3: Decodable {
        struct Preset: Decodable {
            let id: String
            let name: String
            let tool: Tool
            let url: String
            let keyFile: String?
            let model: String
            let contextTokens: Int
            let extraArgs: String
        }
        let terminal: TerminalSettings
        let presets: [Preset]

        var converted: LauncherConfig {
            LauncherConfig(terminal: terminal, presets: presets.map { old in
                HangarCore.Preset(id: old.id, name: old.name, tool: old.tool, url: old.url, keyFile: old.keyFile,
                                  model: old.model, contextTokens: old.contextTokens, extraArgs: old.extraArgs)
            })
        }
    }

    /// Version 2: presets pointed at shared endpoints by id.
    private struct Version2: Decodable {
        struct Endpoint: Decodable {
            let id: String
            let url: String
            let keyFile: String?
        }
        struct Preset: Decodable {
            let id: String
            let name: String
            let tool: Tool
            let endpoint: String
            let model: String
            let contextTokens: Int
            let extraArgs: String
        }
        let terminal: TerminalSettings
        let endpoints: [Endpoint]
        let presets: [Preset]

        /// Each preset takes the URL and key file of the endpoint it pointed at.
        var converted: LauncherConfig {
            LauncherConfig(terminal: terminal, presets: presets.map { old in
                let endpoint = endpoints.first { $0.id == old.endpoint }
                return HangarCore.Preset(id: old.id, name: old.name, tool: old.tool, url: endpoint?.url ?? "",
                                           keyFile: endpoint?.keyFile, model: old.model, contextTokens: old.contextTokens,
                                           extraArgs: old.extraArgs)
            })
        }
    }

    /// Brings a file without the current `version` up to date, keeping the original as
    /// `config.json.bak-<timestamp>` whenever its content changes shape. A file that is not JSON
    /// is left alone: that is a hand-edit mistake, reported by `load`.
    public static func migrateIfOutdated(_ url: URL, now: Date = Date()) throws -> Migration {
        struct Header: Decodable { let version: Int? }
        struct Current: Decodable {
            let terminal: TerminalSettings
            let presets: [Preset]
        }
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: url),
              let header = try? decoder.decode(Header.self, from: data),
              (header.version ?? 1) < LauncherConfig.currentVersion else { return .none }
        // "endpoints" marks the older shapes, even when their presets happen to decode
        let hasEndpoints = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["endpoints"] != nil
        if header.version == nil, !hasEndpoints, let current = try? decoder.decode(Current.self, from: data) {
            try save(LauncherConfig(terminal: current.terminal, presets: current.presets), to: url)
            return .adopted
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).bak-\(formatter.string(from: now))")
        let converted = (hasEndpoints ? nil : (try? decoder.decode(Version3.self, from: data))?.converted)
            ?? (try? decoder.decode(Version2.self, from: data))?.converted
        try FileManager.default.moveItem(at: url, to: backup)
        try save(converted ?? .defaults, to: url)
        return converted == nil ? .reset(backup: backup) : .upgraded(backup: backup)
    }

    public static func save(_ config: LauncherConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(config).write(to: url, options: .atomic)
    }

    public static func encode(_ config: LauncherConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config) + Data("\n".utf8)
    }

    /// A one-line reason for the UI, in the app's language.
    public static func describe(_ error: any Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            let place = path.hasPrefix(".") ? String(path.dropFirst()) : path
            return path.isEmpty ? "" : String(localized: " in \(place)", bundle: .module, comment: "Where a config error is: “ in presets[1]”")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return String(localized: "missing field “\(key.stringValue)”\(path(context))", bundle: .module,
                          comment: "Config error; the second value is “ in <where>” or empty")
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return String(localized: "invalid value\(path(context))", bundle: .module,
                          comment: "Config error; the value is “ in <where>” or empty")
        case DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty:
            // JSONSerialization says "… around line 3, column 14." in the underlying error
            let detail = context.underlyingError.map { String(describing: $0) } ?? ""
            guard let match = detail.firstMatch(of: /line (\d+), column (\d+)/) else {
                return String(localized: "invalid JSON", bundle: .module)
            }
            let line = String(match.1), column = String(match.2)
            return String(localized: "invalid JSON at line \(line), column \(column)", bundle: .module)
        case DecodingError.dataCorrupted(let context):
            return String(localized: "invalid value\(path(context))", bundle: .module,
                          comment: "Config error; the value is “ in <where>” or empty")
        case let error as UnsupportedVersion:
            return String(localized: "version \(error.version) is not supported (this app reads version \(LauncherConfig.currentVersion))",
                          bundle: .module)
        default:
            return error.localizedDescription
        }
    }
}
