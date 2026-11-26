import Foundation

public enum Shell {
    /// Single-quotes a word unless it is made only of characters the shell leaves alone.
    /// A leading `=` is quoted too: zsh expands `=cmd` to the path of `cmd`.
    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@%+,")
        if !word.isEmpty, !word.hasPrefix("="), word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum TOML {
    /// A basic string, with control characters escaped as `\uXXXX` (TOML rejects them raw).
    public static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{00}"..."\u{1F}", "\u{7F}": out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// Everything one launch needs: what to run, where, and the files it generates.
public struct LaunchPlan: Sendable {
    static let codexProvider = "hangar"
    /// Generated scripts kept in `generated/`; older ones are deleted at every launch.
    static let keptScripts = 10

    public let preset: Preset
    /// Absolute path.
    public let directory: String
    public let paths: LauncherPaths
    /// Makes the script name unique, so a quick second launch cannot rewrite the first one's script.
    public let launchID: String

    public init(preset: Preset, directory: String, paths: LauncherPaths,
                launchID: String = UUID().uuidString.prefix(8).lowercased()) {
        // a hand-edited file may ask for a mode the tool does not have
        self.preset = preset.adapted()
        self.directory = NSString(string: directory).expandingTildeInPath
        self.paths = paths
        self.launchID = launchID
    }

    /// The preset id may come from a hand-edited file: keep it a plain ASCII file name, and add a
    /// stable hash when cleaning changed it, so `a/b` and `a b` do not share files.
    public var stem: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let clean = String(preset.id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        if !clean.isEmpty, clean == preset.id { return clean }
        var hash: UInt32 = 2_166_136_261                          // FNV-1a: Hasher is seeded per process
        for byte in preset.id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return (clean.isEmpty ? "preset" : clean) + "-" + String(hash, radix: 16)
    }

    public var server: Server { preset.server }

    public var scriptURL: URL { paths.generated.appending(path: "\(stem)-\(launchID).command") }
    public var settingsURL: URL { paths.generated.appending(path: "\(stem).claude-settings.json") }

    /// A separate account's folder; nil for server presets and for the default account.
    public var accountDirectory: String? {
        guard preset.mode == .account, let name = preset.account else { return nil }
        return paths.accountDirectory(preset.tool, name: name)
    }

    private var model: String { preset.model.trimmingCharacters(in: .whitespaces) }

    // MARK: Claude Code (server mode)

    public func claudeSettings() throws -> Data {
        struct Settings: Encodable {
            let apiKeyHelper: String
            let env: [String: String]
        }
        let model = preset.model
        let settings = Settings(
            apiKeyHelper: server.keyPath.map { "cat \(Shell.quote($0))" } ?? "echo \(Server.dummyKey)",
            env: ["ANTHROPIC_BASE_URL": server.root,
                  "ANTHROPIC_MODEL": model,
                  "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
                  "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
                  "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
                  "CLAUDE_CODE_SUBAGENT_MODEL": model,
                  "CLAUDE_CODE_MAX_CONTEXT_TOKENS": String(preset.contextTokens),
                  "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
                  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(settings) + Data("\n".utf8)
    }

    // MARK: Codex (server mode)

    /// Feature flags turned off on every run: tools that reach beyond the shell in the working folder,
    /// and `multi_agent`, whose `namespace` tool local servers reject (it is not a "function" tool).
    static let disabledCodexFeatures = [
        "apps", "browser_annotation_api", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
        "computer_use", "daemon_auto_start", "hooks", "image_generation", "in_app_browser", "in_app_local_automation",
        "multi_agent", "plugin_sharing", "plugins", "remote_plugin", "skill_mcp_dependency_install", "tool_suggest",
    ]

    /// `-c` overrides for this run only. Everything the launcher needs is here rather than in
    /// CODEX_HOME's config.toml, so changes reach existing homes too (`-c` wins over the file).
    /// The key comes from the provider's auth command, so it never sits in an environment variable;
    /// a server without a key gets no auth at all.
    public var codexArguments: [[String]] {
        let provider = "{name=\(TOML.string(preset.name)), base_url=\(TOML.string(server.root + "/v1")), wire_api=\"responses\"}"
        let features = "features={" + Self.disabledCodexFeatures.map { "\($0)=false" }.joined(separator: ", ") + "}"
        let auth = server.keyPath.map {
            [["-c", "model_providers.\(Self.codexProvider).auth={command=\"cat\", args=[\(TOML.string($0))]}"]]
        } ?? []
        return [["-c", "model_providers.\(Self.codexProvider)=\(provider)"]] + auth
            + [["-c", "model_provider=\"\(Self.codexProvider)\""],
               ["-c", "model_context_window=\(preset.contextTokens)"],
               ["-c", features],
               ["-c", "skills.include_instructions=false"],   // global skills in ~/.agents/skills
               ["-c", "web_search=\"disabled\""],             // not a "function" tool: local servers reject it
               ["-c", "analytics.enabled=false"],
               ["-c", "feedback.enabled=false"],
               ["-c", "check_for_update_on_startup=false"],
               ["-m", preset.model]]
    }

    // MARK: Command line

    /// A variable set for the tool only, as a shell assignment: never an argument, so nothing secret
    /// shows up in `ps`. With `readsKey` the value is the key file's path, read by the shell at run time.
    struct Assignment: Equatable {
        let name: String
        let value: String
        var readsKey = false

        init(_ name: String, _ value: String, readsKey: Bool = false) {
            self.name = name
            self.value = value
            self.readsKey = readsKey
        }

        var rendered: String { "\(name)=" + (readsKey ? "\"$(cat \(Shell.quote(value)))\"" : Shell.quote(value)) }
    }

    /// Everything one tool needs for one launch.
    struct Recipe {
        var set: [Assignment] = []
        var unset: [String] = []
        var arguments: [[String]] = []
        /// Config files written to `stateDirectory` (mode 600), by name.
        var files: [String: Data] = [:]
    }

    /// Server mode: a key exported by the login shell would win over apiKeyHelper and go to the
    /// model server; the provider switches would send Claude elsewhere.
    static let serverUnset = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
                              "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
    /// Account mode for Claude: anything inherited that would send it to another server.
    static let claudeAccountUnset = ["ANTHROPIC_BASE_URL"] + serverUnset
    /// Tools whose server mode keeps state in a folder of the preset's own.
    static let serverStateTools: Set<Tool> = [.copilot, .crush, .qwen, .goose, .kimi, .pi, .vibe, .aider, .droid]

    /// Where the tool keeps its state for this launch: the preset's folder in server mode (for the
    /// tools that need one), a separate account's folder in account mode.
    public var stateDirectory: String? {
        switch preset.mode {
        case .server: Self.serverStateTools.contains(preset.tool) ? paths.presetDirectory(stem) : nil
        case .account: accountDirectory
        }
    }

    /// Argument groups (a flag with its value), so the preview can put one per line.
    public var argumentGroups: [[String]] { recipe.arguments }

    /// The config files this launch writes, by name, for checks; they go to `stateDirectory`.
    public var generatedFiles: [String: Data] { recipe.files }

    var recipe: Recipe {
        switch preset.mode {
        case .server: serverRecipe
        case .account: accountRecipe
        }
    }

    // MARK: Server mode, per tool

    /// The key as a variable read from its file by the shell, or the dummy for tools that insist on
    /// a key even when the server has none.
    private func keyVariable(_ name: String) -> Assignment {
        server.keyPath.map { Assignment(name, $0, readsKey: true) } ?? Assignment(name, Server.dummyKey)
    }

    /// Inline and file JSON: built, never concatenated, so names and paths cannot break it.
    static func json(_ object: Any) -> Data {
        // only strings, numbers, booleans, arrays and dictionaries go in: serialising cannot fail
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// OpenCode and Kilo: an OpenAI-compatible provider; the key is read by their `{file:…}` hook.
    private var openCodeConfig: String {
        var options: [String: Any] = ["baseURL": server.root + "/v1"]
        if let key = server.keyPath { options["apiKey"] = "{file:\(key)}" }
        let provider: [String: Any] = [
            "npm": "@ai-sdk/openai-compatible", "name": preset.name, "options": options,
            "models": [preset.model: ["name": preset.model, "limit": ["context": preset.contextTokens, "output": 8192]]],
        ]
        return String(decoding: Self.json(["autoupdate": false, "provider": ["hangar": provider]]), as: UTF8.self)
    }

    private var serverRecipe: Recipe {
        let dir = stateDirectory ?? ""
        let v1 = server.root + "/v1"
        let model = preset.model, ctx = preset.contextTokens
        switch preset.tool {
        case .claude:
            return Recipe(unset: ["CLAUDE_CONFIG_DIR"] + Self.serverUnset,
                          arguments: [["--bare"], ["--strict-mcp-config"], ["--settings", settingsURL.path]])
        case .codex:
            return Recipe(set: [Assignment("CODEX_HOME", paths.codexHome.path)], unset: Self.serverUnset, arguments: codexArguments)
        case .copilot:
            var set = [Assignment("COPILOT_HOME", dir), Assignment("COPILOT_CACHE_HOME", dir + "/cache"),
                       Assignment("COPILOT_OFFLINE", "true"), Assignment("COPILOT_PROVIDER_TYPE", "openai"),
                       Assignment("COPILOT_PROVIDER_BASE_URL", v1)]
            if let key = server.keyPath { set.append(Assignment("COPILOT_PROVIDER_API_KEY_COMMAND", "cat \(Shell.quote(key))")) }
            set += [Assignment("COPILOT_MODEL", model), Assignment("COPILOT_PROVIDER_MAX_PROMPT_TOKENS", String(ctx))]
            return Recipe(set: set)
        case .opencode:
            return Recipe(set: [Assignment("OPENCODE_CONFIG_CONTENT", openCodeConfig), Assignment("OPENCODE_DISABLE_AUTOUPDATE", "1"),
                                Assignment("OPENCODE_DISABLE_MODELS_FETCH", "1")],
                          arguments: [["-m", "hangar/\(model)"]])
        case .kilo:
            return Recipe(set: [Assignment("KILO_CONFIG_CONTENT", openCodeConfig), Assignment("KILO_NO_DAEMON", "1"),
                                Assignment("KILO_TELEMETRY_LEVEL", "off"), Assignment("KILO_DISABLE_AUTOUPDATE", "1"),
                                Assignment("KILO_DISABLE_SESSION_INGEST", "1")],
                          arguments: [["-m", "hangar/\(model)"]])
        case .crush:
            var provider: [String: Any] = [
                "type": "completions", "base_url": v1,
                "models": [["id": model, "name": model, "context_window": ctx, "default_max_tokens": 8192]],
            ]
            // Crush runs `$(…)` itself when it reads the file, so the key never lands in it
            if let key = server.keyPath { provider["api_key"] = "$(cat \(Shell.quote(key)))" }
            let config: [String: Any] = [
                "providers": ["hangar": provider],
                "models": ["large": ["provider": "hangar", "model": model], "small": ["provider": "hangar", "model": model]],
                "options": ["disable_metrics": true, "disable_provider_auto_update": true],
            ]
            return Recipe(set: [Assignment("CRUSH_GLOBAL_CONFIG", dir), Assignment("CRUSH_GLOBAL_DATA", dir + "/data"),
                                Assignment("CRUSH_DATA_DIR", dir + "/proj"), Assignment("CRUSH_DISABLE_METRICS", "1"),
                                Assignment("CRUSH_DISABLE_PROVIDER_AUTO_UPDATE", "1")],
                          files: ["crush.json": Self.json(config)])
        case .qwen:
            let settings: [String: Any] = ["model": ["generationConfig": ["contextWindowSize": ctx]],
                                           "general": ["enableAutoUpdate": false]]
            return Recipe(set: [Assignment("QWEN_HOME", dir), Assignment("QWEN_CODE_SYSTEM_SETTINGS_PATH", dir + "/qwen-system.json"),
                                keyVariable("OPENAI_API_KEY"), Assignment("QWEN_USAGE_STATISTICS_ENABLED", "false"),
                                Assignment("QWEN_TELEMETRY_ENABLED", "false"), Assignment("QWEN_CODE_SKIP_UPDATE_CHECK_ONCE", "true")],
                          arguments: [["--auth-type", "openai"], ["--openai-base-url", v1], ["--model", model]],
                          files: ["qwen-system.json": Self.json(settings)])
        case .goose:
            // Goose's openai provider appends v1/chat/completions itself: it gets the root
            return Recipe(set: [Assignment("GOOSE_PATH_ROOT", dir), Assignment("GOOSE_DISABLE_KEYRING", "1"),
                                Assignment("GOOSE_PROVIDER", "openai"), Assignment("GOOSE_MODEL", model),
                                Assignment("OPENAI_BASE_URL", server.root), keyVariable("OPENAI_API_KEY"),
                                Assignment("GOOSE_CONTEXT_LIMIT", String(ctx)), Assignment("GOOSE_TELEMETRY_OFF", "1")],
                          arguments: [["session"]])
        case .kimi:
            // no -m: it would override the model set here
            return Recipe(set: [Assignment("KIMI_CODE_HOME", dir), Assignment("KIMI_MODEL_NAME", model),
                                Assignment("KIMI_MODEL_PROVIDER_TYPE", "openai"), Assignment("KIMI_MODEL_BASE_URL", v1),
                                keyVariable("KIMI_MODEL_API_KEY"), Assignment("KIMI_MODEL_MAX_CONTEXT_SIZE", String(ctx)),
                                Assignment("KIMI_DISABLE_TELEMETRY", "1"), Assignment("KIMI_CODE_NO_AUTO_UPDATE", "1")])
        case .pi:
            var provider: [String: Any] = ["baseUrl": v1, "api": "openai-completions",
                                           "models": [["id": model, "contextWindow": ctx]]]
            if let key = server.keyPath { provider["apiKey"] = "!cat \(Shell.quote(key))" }
            return Recipe(set: [Assignment("PI_CODING_AGENT_DIR", dir), Assignment("PI_TELEMETRY", "0"),
                                Assignment("PI_SKIP_VERSION_CHECK", "1"), Assignment("PI_OFFLINE", "1")],
                          arguments: [["--provider", "hangar"], ["--model", model]],
                          files: ["models.json": Self.json(["providers": ["hangar": provider]])])
        case .vibe:
            let providers = Self.json([["name": "hangar", "api_base": v1, "api_key_env_var": "HANGAR_VIBE_KEY", "api_style": "openai"]])
            let models = Self.json([["name": model, "provider": "hangar", "alias": "hangar", "max_context_length": ctx]])
            return Recipe(set: [keyVariable("HANGAR_VIBE_KEY"), Assignment("VIBE_HOME", dir),
                                Assignment("VIBE_PROVIDERS", String(decoding: providers, as: UTF8.self)),
                                Assignment("VIBE_MODELS", String(decoding: models, as: UTF8.self)),
                                Assignment("VIBE_ACTIVE_MODEL", "hangar"), Assignment("VIBE_ENABLE_TELEMETRY", "false"),
                                Assignment("VIBE_ENABLE_UPDATE_CHECKS", "false"), Assignment("VIBE_ENABLE_AUTO_UPDATE", "false")])
        case .aider:
            let metadata: [String: Any] = ["openai/\(model)": [
                "max_input_tokens": ctx, "max_tokens": ctx, "input_cost_per_token": 0, "output_cost_per_token": 0,
                "litellm_provider": "openai", "mode": "chat",
            ]]
            return Recipe(set: [keyVariable("OPENAI_API_KEY")],
                          arguments: [["--openai-api-base", v1], ["--model", "openai/\(model)"],
                                      ["--model-metadata-file", dir + "/meta.json"], ["--no-show-model-warnings"],
                                      ["--no-analytics"], ["--no-check-update"], ["--no-show-release-notes"]],
                          files: ["meta.json": Self.json(metadata)])
        case .droid:
            // the settings name the variable; Droid fills it in (unverified)
            let settings: [String: Any] = ["customModels": [[
                "model": model, "baseUrl": v1, "apiKey": "${HANGAR_DROID_KEY}",
                "provider": "generic-chat-completion-api", "maxContextLimit": ctx,
            ]]]
            return Recipe(set: [keyVariable("HANGAR_DROID_KEY"), Assignment("FACTORY_DROID_AUTO_UPDATE_ENABLED", "false")],
                          arguments: [["--settings", dir + "/droid.json"], ["-m", "custom:\(model)"]],
                          files: ["droid.json": Self.json(settings)])
        case .gemini, .cursor, .amp, .kiro, .cline, .auggie:
            return Recipe()                                       // no server mode: `adapted()` never lets one through
        }
    }

    // MARK: Account mode, per tool

    private var accountRecipe: Recipe {
        let spec = preset.tool.spec
        let subcommand: [[String]] = switch preset.tool {
        case .goose: [["session"]]
        case .kiro: [["chat"]]
        default: []
        }
        let modelArguments = spec.accountModelFlag.flatMap { model.isEmpty ? nil : [[$0, model]] } ?? []
        let toolUnset = preset.tool == .claude ? Self.claudeAccountUnset : []
        guard let dir = accountDirectory else {
            // the default account: the tool's own variables must be absent, not pointed at the default
            // folder, since Claude keys its Keychain item on any value it is given
            return Recipe(unset: spec.isolationVariables + toolUnset, arguments: subcommand + modelArguments)
        }
        return Recipe(set: separateAccount(dir), unset: toolUnset, arguments: subcommand + modelArguments)
    }

    /// The variables that move a tool's login and settings into a separate account's folder.
    private func separateAccount(_ dir: String) -> [Assignment] {
        switch preset.tool {
        case .claude: [Assignment("CLAUDE_CONFIG_DIR", dir)]
        case .codex: [Assignment("CODEX_HOME", dir)]
        case .copilot: [Assignment("COPILOT_HOME", dir), Assignment("COPILOT_CACHE_HOME", dir + "/cache"),
                        Assignment("COPILOT_AUTO_UPDATE", "false"), Assignment("COPILOT_TELEMETRY_DISABLED", "true")]
        case .opencode: [Assignment("XDG_DATA_HOME", dir + "/data"), Assignment("XDG_STATE_HOME", dir + "/state"),
                         Assignment("OPENCODE_DISABLE_AUTOUPDATE", "1")]
        // without KILO_NO_DAEMON it would attach to a running daemon and mix accounts
        case .kilo: [Assignment("XDG_DATA_HOME", dir + "/data"), Assignment("XDG_STATE_HOME", dir + "/state"),
                     Assignment("KILO_NO_DAEMON", "1"), Assignment("KILO_TELEMETRY_LEVEL", "off"),
                     Assignment("KILO_DISABLE_AUTOUPDATE", "1")]
        // without CRUSH_DATA_DIR it writes ./.crush into the project
        case .crush: [Assignment("CRUSH_GLOBAL_DATA", dir), Assignment("CRUSH_DATA_DIR", dir + "/proj"),
                      Assignment("CRUSH_DISABLE_METRICS", "1")]
        case .qwen: [Assignment("QWEN_HOME", dir), Assignment("QWEN_USAGE_STATISTICS_ENABLED", "false"),
                     Assignment("QWEN_CODE_SKIP_UPDATE_CHECK_ONCE", "true")]
        // Goose's single Keychain entry is shared by every account
        case .goose: [Assignment("GOOSE_PATH_ROOT", dir), Assignment("GOOSE_DISABLE_KEYRING", "1"),
                      Assignment("GOOSE_TELEMETRY_OFF", "1")]
        case .kimi: [Assignment("KIMI_CODE_HOME", dir), Assignment("KIMI_DISABLE_TELEMETRY", "1"),
                     Assignment("KIMI_CODE_NO_AUTO_UPDATE", "1")]
        case .pi: [Assignment("PI_CODING_AGENT_DIR", dir), Assignment("PI_TELEMETRY", "0"), Assignment("PI_SKIP_VERSION_CHECK", "1")]
        case .vibe, .droid, .aider, .gemini, .cursor, .amp, .kiro, .cline, .auggie:
            []                                                    // no separate accounts: `adapted()` clears the name
        }
    }

    /// The one command both the script and the preview run.
    private func commandLine(exec: Bool, separator: String) -> String {
        let recipe = recipe
        let unset = recipe.unset.isEmpty ? [] : ["env"] + recipe.unset.flatMap { ["-u", $0] }
        let run = (exec ? ["exec"] : []) + unset + [preset.tool.spec.binary]
        let extra = preset.extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = recipe.arguments.map { $0.map(Shell.quote).joined(separator: " ") } + (extra.isEmpty ? [] : [extra])
        return (recipe.set.map(\.rendered) + [run.joined(separator: " ")] + groups).joined(separator: separator)
    }

    /// Printed, before the key file's path, when the script cannot read it. In the app's language at the
    /// time the script is generated.
    public static var keyFileMessage: String {
        String(localized: "Hangar: cannot read the key file", bundle: .module)
    }

    /// The generated script. The key never sits in it: Codex reads it with its auth command, Claude
    /// Code through `apiKeyHelper` in the settings file, both with `cat` at run time.
    public var script: String {
        var lines = ["#!/bin/bash",
                     "# Generated by Hangar at every launch: edits here are overwritten.",
                     "cd \(Shell.quote(directory)) || exit 1"]
        if preset.mode == .server, let keyPath = server.keyPath {
            // without this, the tool would start without a key and fail with a vaguer error
            let path = Shell.quote(keyPath)
            // the message is an argument, not part of printf's format: a translation can hold any character
            lines.append("[ -r \(path) ] || { printf '%s %s\\n' \(Shell.quote(Self.keyFileMessage)) \(path) >&2; exit 1; }")
        }
        lines.append(commandLine(exec: true, separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the preview shows and "Copia comando" copies: the script's command, one flag per line.
    public var preview: String {
        "cd \(Shell.quote(directory)) && \\\n" + commandLine(exec: false, separator: " \\\n  ")
    }

    /// Writes what the command needs (Claude's settings and Codex's home in server mode, the preset's
    /// folder and the tools' config files, a separate account's folder) and, with `script`, the script
    /// itself (mode 700), keeping only the newest.
    public func writeFiles(script withScript: Bool = true) throws {
        let manager = FileManager.default
        var folders = [paths.generated]
        if preset.mode == .server, preset.tool == .codex { folders.append(paths.codexHome) }
        if preset.mode == .server, let stateDirectory { folders += [paths.presets, URL(fileURLWithPath: stateDirectory)] }
        if let accountDirectory {
            folders += [paths.accounts, paths.accounts.appending(path: preset.tool.rawValue),
                        URL(fileURLWithPath: accountDirectory)]
        }
        for folder in folders {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        switch (preset.mode, preset.tool) {
        case (.server, .claude):
            try claudeSettings().write(to: settingsURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        case (.server, .codex):
            // only needs to exist, for Codex's folder-trust entries; the launcher's settings are `-c`
            let config = paths.codexHome.appending(path: "config.toml")
            if !manager.fileExists(atPath: config.path) { try Data().write(to: config) }
        case (.server, _), (.account, _):
            break
        }
        if let stateDirectory {
            for (name, content) in generatedFiles {
                let file = URL(fileURLWithPath: stateDirectory).appending(path: name)
                try content.write(to: file, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        guard withScript else { return }
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try removeOldScripts()
    }

    private func removeOldScripts() throws {
        let scripts = try FileManager.default
            .contentsOfDirectory(at: paths.generated, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "command" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (old, _) in scripts.dropFirst(Self.keptScripts) where old != scriptURL {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
