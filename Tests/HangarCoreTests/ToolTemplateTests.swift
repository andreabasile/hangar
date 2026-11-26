import Foundation
import Testing
@testable import HangarCore

/// A throwaway Hangar folder with a key file whose content is a sentinel that must never show up in
/// a command or a generated file.
private struct Fixture {
    static let sentinel = "SENTINEL-KEY-must-never-appear-0123"
    let root: URL
    let key: String
    let paths: LauncherPaths

    init() throws {
        root = try temporaryDirectory()
        let keyURL = root.appending(path: "keys/example")
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.sentinel.utf8).write(to: keyURL)
        key = keyURL.path
        paths = LauncherPaths(root: root.appending(path: "hangar"), warpTabConfigs: root.appending(path: "warp"))
    }

    func plan(_ tool: Tool, _ mode: LaunchMode, account: String? = nil, keyed: Bool = true,
              url: String = "https://gpu.example.com", name: String = "Test") -> LaunchPlan {
        let preset = Preset(id: "p", name: name, tool: tool, url: url, keyFile: keyed ? key : nil, model: "qwen3-coder-30b",
                            contextTokens: 131_072, extraArgs: "", mode: mode, account: account)
        return LaunchPlan(preset: preset, directory: root.path, paths: paths)
    }

    var dir: String { paths.presetDirectory("p") }
    func account(_ tool: Tool) -> String { paths.accountDirectory(tool, name: "lavoro") }
}

/// The command the script runs (its last line).
private func line(_ plan: LaunchPlan) -> String { String(plan.script.split(separator: "\n").last ?? "") }

/// Replaces `NAME='<json>'` with `NAME=<JSON>` and returns the parsed JSON, so commands and JSON are
/// compared exactly but independently of key order.
private func extractJSON(_ name: String, from line: inout String) throws -> Any {
    let match = try #require(line.firstMatch(of: try Regex<(Substring, Substring)>("\(name)='([^']*)'")))
    let json = try JSONSerialization.jsonObject(with: Data(match.1.utf8))
    line.replaceSubrange(match.range, with: "\(name)=<JSON>")
    return json
}

private func same(_ a: Any, _ b: Any) -> Bool { NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b]) }

@Suite struct ToolTemplateTests {
    private let claudeUnset = "-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK "
        + "-u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY"

    @Test func defaultAccountRunsTheToolAsUsualWithoutItsIsolationVariables() throws {
        let fixture = try Fixture()
        let expected: [Tool: String] = [
            .claude: "exec env -u CLAUDE_CONFIG_DIR -u ANTHROPIC_BASE_URL \(claudeUnset) claude",
            .codex: "exec env -u CODEX_HOME codex",
            .copilot: "exec env -u COPILOT_HOME -u COPILOT_CACHE_HOME copilot",
            .opencode: "exec opencode",
            .kilo: "exec kilo",
            .crush: "exec env -u CRUSH_GLOBAL_DATA crush",
            .qwen: "exec env -u QWEN_HOME qwen",
            .goose: "exec env -u GOOSE_PATH_ROOT goose session",
            .kimi: "exec env -u KIMI_CODE_HOME kimi",
            .pi: "exec env -u PI_CODING_AGENT_DIR pi",
            .vibe: "exec env -u VIBE_HOME vibe",
            .droid: "exec droid",
            .gemini: "exec gemini",
            .cursor: "exec cursor-agent",
            .amp: "exec amp",
            .kiro: "exec kiro-cli chat",
            .cline: "exec cline",
            .auggie: "exec auggie",
        ]
        let accountTools = Tool.allCases.filter { $0.spec.modes.contains(.account) }
        #expect(Set(expected.keys) == Set(accountTools))
        for tool in accountTools {
            let plan = fixture.plan(tool, .account)
            // model "qwen3-coder-30b" is set: only Claude and Codex have a flag for it in account mode
            let model = tool == .claude ? " --model qwen3-coder-30b" : tool == .codex ? " -m qwen3-coder-30b" : ""
            #expect(line(plan) == (expected[tool] ?? "") + model, "\(tool)")
            #expect(!plan.script.contains("[ -r"), "\(tool)")                  // no key in account mode
        }
    }

    @Test func separateAccountsLiveInTheirFolder() throws {
        let f = try Fixture()
        func d(_ tool: Tool) -> String { f.account(tool) }
        let expected: [Tool: String] = [
            .claude: "CLAUDE_CONFIG_DIR=\(d(.claude)) exec env -u ANTHROPIC_BASE_URL \(claudeUnset) claude --model qwen3-coder-30b",
            .codex: "CODEX_HOME=\(d(.codex)) exec codex -m qwen3-coder-30b",
            .copilot: "COPILOT_HOME=\(d(.copilot)) COPILOT_CACHE_HOME=\(d(.copilot))/cache COPILOT_AUTO_UPDATE=false "
                + "COPILOT_TELEMETRY_DISABLED=true exec copilot",
            .opencode: "XDG_DATA_HOME=\(d(.opencode))/data XDG_STATE_HOME=\(d(.opencode))/state OPENCODE_DISABLE_AUTOUPDATE=1 exec opencode",
            .kilo: "XDG_DATA_HOME=\(d(.kilo))/data XDG_STATE_HOME=\(d(.kilo))/state KILO_NO_DAEMON=1 KILO_TELEMETRY_LEVEL=off "
                + "KILO_DISABLE_AUTOUPDATE=1 exec kilo",
            .crush: "CRUSH_GLOBAL_DATA=\(d(.crush)) CRUSH_DATA_DIR=\(d(.crush))/proj CRUSH_DISABLE_METRICS=1 exec crush",
            .qwen: "QWEN_HOME=\(d(.qwen)) QWEN_USAGE_STATISTICS_ENABLED=false QWEN_CODE_SKIP_UPDATE_CHECK_ONCE=true exec qwen",
            .goose: "GOOSE_PATH_ROOT=\(d(.goose)) GOOSE_DISABLE_KEYRING=1 GOOSE_TELEMETRY_OFF=1 exec goose session",
            .kimi: "KIMI_CODE_HOME=\(d(.kimi)) KIMI_DISABLE_TELEMETRY=1 KIMI_CODE_NO_AUTO_UPDATE=1 exec kimi",
            .pi: "PI_CODING_AGENT_DIR=\(d(.pi)) PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 exec pi",
        ]
        #expect(Set(expected.keys) == Set(Tool.allCases.filter(\.spec.separateAccounts)))
        for (tool, command) in expected {
            let plan = f.plan(tool, .account, account: "lavoro")
            #expect(line(plan) == command, "\(tool)")
            #expect(d(tool).hasPrefix("/") && !d(tool).contains("~") && !d(tool).hasSuffix("/"), "\(tool)")
            try plan.writeFiles()
            #expect(try (FileManager.default.attributesOfItem(atPath: d(tool))[.posixPermissions] as? Int) == 0o700)
        }
    }

    @Test func serverCommandsFollowTheTemplates() throws {
        let f = try Fixture()
        let dir = f.dir, key = f.key, v1 = "https://gpu.example.com/v1"
        let expected: [Tool: String] = [
            .copilot: "COPILOT_HOME=\(dir) COPILOT_CACHE_HOME=\(dir)/cache COPILOT_OFFLINE=true COPILOT_PROVIDER_TYPE=openai "
                + "COPILOT_PROVIDER_BASE_URL=\(v1) COPILOT_PROVIDER_API_KEY_COMMAND='cat \(key)' COPILOT_MODEL=qwen3-coder-30b "
                + "COPILOT_PROVIDER_MAX_PROMPT_TOKENS=131072 exec copilot",
            .opencode: "OPENCODE_CONFIG_CONTENT=<JSON> OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 "
                + "exec opencode -m hangar/qwen3-coder-30b",
            .kilo: "KILO_CONFIG_CONTENT=<JSON> KILO_NO_DAEMON=1 KILO_TELEMETRY_LEVEL=off KILO_DISABLE_AUTOUPDATE=1 "
                + "KILO_DISABLE_SESSION_INGEST=1 exec kilo -m hangar/qwen3-coder-30b",
            .crush: "CRUSH_GLOBAL_CONFIG=\(dir) CRUSH_GLOBAL_DATA=\(dir)/data CRUSH_DATA_DIR=\(dir)/proj CRUSH_DISABLE_METRICS=1 "
                + "CRUSH_DISABLE_PROVIDER_AUTO_UPDATE=1 exec crush",
            .qwen: "QWEN_HOME=\(dir) QWEN_CODE_SYSTEM_SETTINGS_PATH=\(dir)/qwen-system.json OPENAI_API_KEY=\"$(cat \(key))\" "
                + "QWEN_USAGE_STATISTICS_ENABLED=false QWEN_TELEMETRY_ENABLED=false QWEN_CODE_SKIP_UPDATE_CHECK_ONCE=true "
                + "exec qwen --auth-type openai --openai-base-url \(v1) --model qwen3-coder-30b",
            .goose: "GOOSE_PATH_ROOT=\(dir) GOOSE_DISABLE_KEYRING=1 GOOSE_PROVIDER=openai GOOSE_MODEL=qwen3-coder-30b "
                + "OPENAI_BASE_URL=https://gpu.example.com OPENAI_API_KEY=\"$(cat \(key))\" GOOSE_CONTEXT_LIMIT=131072 "
                + "GOOSE_TELEMETRY_OFF=1 exec goose session",
            .kimi: "KIMI_CODE_HOME=\(dir) KIMI_MODEL_NAME=qwen3-coder-30b KIMI_MODEL_PROVIDER_TYPE=openai KIMI_MODEL_BASE_URL=\(v1) "
                + "KIMI_MODEL_API_KEY=\"$(cat \(key))\" KIMI_MODEL_MAX_CONTEXT_SIZE=131072 KIMI_DISABLE_TELEMETRY=1 "
                + "KIMI_CODE_NO_AUTO_UPDATE=1 exec kimi",
            .pi: "PI_CODING_AGENT_DIR=\(dir) PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 PI_OFFLINE=1 "
                + "exec pi --provider hangar --model qwen3-coder-30b",
            .vibe: "HANGAR_VIBE_KEY=\"$(cat \(key))\" VIBE_HOME=\(dir) VIBE_PROVIDERS=<JSON> VIBE_MODELS=<JSON> VIBE_ACTIVE_MODEL=hangar "
                + "VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false exec vibe",
            .aider: "OPENAI_API_KEY=\"$(cat \(key))\" exec aider --openai-api-base \(v1) --model openai/qwen3-coder-30b "
                + "--model-metadata-file \(dir)/meta.json --no-show-model-warnings --no-analytics --no-check-update "
                + "--no-show-release-notes",
            .droid: "HANGAR_DROID_KEY=\"$(cat \(key))\" FACTORY_DROID_AUTO_UPDATE_ENABLED=false "
                + "exec droid --settings \(dir)/droid.json -m custom:qwen3-coder-30b",
        ]
        let openCode: [String: Any] = ["autoupdate": false, "provider": ["hangar": [
            "npm": "@ai-sdk/openai-compatible", "name": "Test",
            "options": ["baseURL": v1, "apiKey": "{file:\(key)}"],
            "models": ["qwen3-coder-30b": ["name": "qwen3-coder-30b", "limit": ["context": 131_072, "output": 8192]]],
        ]]]
        let inline: [Tool: [(String, Any)]] = [
            .opencode: [("OPENCODE_CONFIG_CONTENT", openCode)],
            .kilo: [("KILO_CONFIG_CONTENT", openCode)],
            .vibe: [("VIBE_PROVIDERS", [["name": "hangar", "api_base": v1, "api_key_env_var": "HANGAR_VIBE_KEY", "api_style": "openai"]]),
                    ("VIBE_MODELS", [["name": "qwen3-coder-30b", "provider": "hangar", "alias": "hangar", "max_context_length": 131_072]])],
        ]
        for (tool, command) in expected {
            var text = line(f.plan(tool, .server))
            for (name, json) in inline[tool] ?? [] {
                #expect(same(try extractJSON(name, from: &text), json), "\(tool) \(name)")
            }
            #expect(text == command, "\(tool)")
        }
        // the two verified tools keep their tested commands; Claude now also drops CLAUDE_CONFIG_DIR
        #expect(line(f.plan(.claude, .server)).hasPrefix("exec env -u CLAUDE_CONFIG_DIR \(claudeUnset) claude --bare "))
        #expect(line(f.plan(.codex, .server)).hasPrefix("CODEX_HOME=\(f.paths.codexHome.path) exec env \(claudeUnset) codex -c "))
        #expect(Set(expected.keys).union([.claude, .codex]) == Set(Tool.allCases.filter { $0.spec.modes.contains(.server) }))
    }

    @Test func generatedFilesFollowTheTemplatesAndHoldOnlyTheKeysPath() throws {
        let f = try Fixture()
        let v1 = "https://gpu.example.com/v1", key = f.key
        let expected: [Tool: (String, Any)] = [
            .crush: ("crush.json", ["providers": ["hangar": [
                "type": "completions", "base_url": v1, "api_key": "$(cat \(key))",
                "models": [["id": "qwen3-coder-30b", "name": "qwen3-coder-30b", "context_window": 131_072, "default_max_tokens": 8192]],
            ]], "models": ["large": ["provider": "hangar", "model": "qwen3-coder-30b"],
                           "small": ["provider": "hangar", "model": "qwen3-coder-30b"]],
                "options": ["disable_metrics": true, "disable_provider_auto_update": true]] as [String: Any]),
            .qwen: ("qwen-system.json", ["model": ["generationConfig": ["contextWindowSize": 131_072]],
                                         "general": ["enableAutoUpdate": false]] as [String: Any]),
            .pi: ("models.json", ["providers": ["hangar": ["baseUrl": v1, "api": "openai-completions", "apiKey": "!cat \(key)",
                                                          "models": [["id": "qwen3-coder-30b", "contextWindow": 131_072]]]]]
                  as [String: Any]),
            .aider: ("meta.json", ["openai/qwen3-coder-30b": [
                "max_input_tokens": 131_072, "max_tokens": 131_072, "input_cost_per_token": 0, "output_cost_per_token": 0,
                "litellm_provider": "openai", "mode": "chat"]] as [String: Any]),
            .droid: ("droid.json", ["customModels": [[
                "model": "qwen3-coder-30b", "baseUrl": v1, "apiKey": "${HANGAR_DROID_KEY}",
                "provider": "generic-chat-completion-api", "maxContextLimit": 131_072]]] as [String: Any]),
        ]
        for tool in Tool.allCases where tool.spec.modes.contains(.server) && tool != .claude && tool != .codex {
            let plan = f.plan(tool, .server)
            try plan.writeFiles()
            let names = Set(plan.generatedFiles.keys)
            #expect(names == (expected[tool].map { [$0.0] } ?? []), "\(tool)")
            for name in names {
                let file = URL(fileURLWithPath: try #require(plan.stateDirectory)).appending(path: name)
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(same(try JSONSerialization.jsonObject(with: Data(text.utf8)), try #require(expected[tool]).1), "\(tool)")
                #expect(!text.contains(Fixture.sentinel), "\(tool)")
                #expect(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
                if [.crush, .pi].contains(tool) { #expect(text.contains(key), "\(tool)") }
            }
            if let dir = plan.stateDirectory {
                #expect(dir == f.dir)
                #expect(try (FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int) == 0o700)
            }
        }
    }

    @Test func keylessServersDropTheKeyOrGetTheDummy() throws {
        let f = try Fixture()
        for tool in Tool.allCases where tool.spec.modes.contains(.server) {
            let plan = f.plan(tool, .server, keyed: false)
            #expect(!plan.script.contains("cat "), "\(tool)")
            #expect(!plan.generatedFiles.values.contains { String(decoding: $0, as: UTF8.self).contains("cat ") }, "\(tool)")
        }
        #expect(line(f.plan(.qwen, .server, keyed: false)).contains(" OPENAI_API_KEY=local "))
        #expect(line(f.plan(.goose, .server, keyed: false)).contains(" OPENAI_API_KEY=local "))
        #expect(line(f.plan(.kimi, .server, keyed: false)).contains(" KIMI_MODEL_API_KEY=local "))
        #expect(line(f.plan(.aider, .server, keyed: false)).hasPrefix("OPENAI_API_KEY=local exec aider "))
        #expect(!line(f.plan(.copilot, .server, keyed: false)).contains("API_KEY_COMMAND"))
        var openCode = line(f.plan(.opencode, .server, keyed: false))
        let config = try extractJSON("OPENCODE_CONFIG_CONTENT", from: &openCode) as? [String: Any]
        let options = ((config?["provider"] as? [String: Any])?["hangar"] as? [String: Any])?["options"] as? [String: Any]
        #expect(options?["apiKey"] == nil && options?["baseURL"] as? String == "https://gpu.example.com/v1")
        let crush = try JSONSerialization.jsonObject(with: try #require(f.plan(.crush, .server, keyed: false).generatedFiles["crush.json"]))
        #expect(((crush as? [String: Any])?["providers"] as? [String: Any]).map { ($0["hangar"] as? [String: Any])?["api_key"] == nil } == true)
    }

    @Test func v1IsAppendedExactlyOnce() throws {
        let f = try Fixture()
        for url in ["https://gpu.example.com", "https://gpu.example.com/", "https://gpu.example.com/v1", "https://gpu.example.com/v1/"] {
            for tool in Tool.allCases where tool.spec.modes.contains(.server) {
                let plan = f.plan(tool, .server, url: url)
                let everything = plan.script + plan.generatedFiles.values.map { String(decoding: $0, as: UTF8.self) }.joined()
                    + ((try? plan.claudeSettings()).map { String(decoding: $0, as: UTF8.self) } ?? "")
                #expect(!everything.contains("/v1/v1") && !everything.contains("com//"), "\(tool) \(url)")
                let wantsV1 = ![Tool.claude, .goose].contains(tool)          // Claude and Goose take the root
                #expect(everything.contains("https://gpu.example.com/v1") == wantsV1, "\(tool) \(url)")
            }
        }
    }

    @Test func unsupportedModesAndAccountsAreCoerced() throws {
        func preset(_ tool: Tool, _ mode: LaunchMode, account: String? = nil) -> Preset {
            Preset(id: "p", name: "P", tool: tool, url: "http://localhost:1234", keyFile: nil, model: "m", contextTokens: 1,
                   extraArgs: "", mode: mode, account: account)
        }
        #expect(preset(.gemini, .server).adapted().mode == .account)
        #expect(preset(.aider, .account).adapted().mode == .server)
        #expect(preset(.vibe, .account, account: "lavoro").adapted().account == nil)
        #expect(preset(.droid, .account, account: "lavoro").adapted().account == nil)
        #expect(preset(.vibe, .server).adapted().mode == .server)
        #expect(preset(.claude, .account, account: "lavoro").adapted() == preset(.claude, .account, account: "lavoro"))
        // a hand-edited file asking for the impossible still builds a sound command
        let f = try Fixture()
        #expect(line(LaunchPlan(preset: preset(.gemini, .server), directory: "/tmp", paths: f.paths)) == "exec gemini")
        #expect(line(LaunchPlan(preset: preset(.cursor, .account, account: "x"), directory: "/tmp", paths: f.paths))
                == "exec cursor-agent")
        for tool in Tool.allCases {
            #expect(!tool.spec.modes.isEmpty, "\(tool)")
            #expect(tool.spec.separateAccounts == false || tool.spec.modes.contains(.account), "\(tool)")
            #expect(tool.spec.verified == [.claude, .codex].contains(tool), "\(tool)")
        }
    }

    @Test func theMenuStartsWithClaudeAndCodexThenGoesByName() {
        let names = Tool.menuOrder.map(\.spec.name)
        #expect(Array(names.prefix(2)) == ["Claude Code", "Codex"])
        #expect(Array(names.dropFirst(2)) == names.dropFirst(2).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(Set(Tool.menuOrder) == Set(Tool.allCases) && Tool.menuOrder.count == Tool.allCases.count)
        #expect(Set(Tool.allCases.map(\.spec.binary)).count == Tool.allCases.count)
        #expect(Set(Tool.allCases.map(\.spec.symbol)).count == Tool.allCases.count)
    }
}

/// Runs every tool's server-mode script with fake binaries that record their arguments and
/// environment, with a key file holding a sentinel.
@Suite struct KeyNeverInArgumentsTests {
    private static let fake = """
        #!/bin/bash
        : > "$HANGAR_TEST_OUT.args"
        for a in "$@"; do printf '%s\\0' "$a" >> "$HANGAR_TEST_OUT.args"; done
        env -0 > "$HANGAR_TEST_OUT.env"

        """

    @Test func theSentinelIsInNoArgumentAndNoGeneratedFile() throws {
        let f = try Fixture()
        let bin = f.root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in Tool.allCases {
            let url = bin.appending(path: tool.spec.binary)
            try Data(Self.fake.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let out = f.root.appending(path: "out")
        for tool in Tool.allCases where tool.spec.modes.contains(.server) {
            let plan = f.plan(tool, .server)
            try plan.writeFiles()
            #expect(!plan.script.contains(Fixture.sentinel) && !plan.preview.contains(Fixture.sentinel), "\(tool)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [plan.scriptURL.path]
            process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": f.root.path, "HANGAR_TEST_OUT": out.path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(tool)")
            let arguments = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out.path + ".args")), as: UTF8.self)
            #expect(!arguments.contains(Fixture.sentinel), "\(tool)")
            #expect(arguments.components(separatedBy: "\0").dropLast() == plan.argumentGroups.flatMap { $0 }, "\(tool)")
            // tools that take the key from a variable get it there, read at run time
            let environment = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out.path + ".env")), as: UTF8.self)
            let viaVariable: Set<Tool> = [.qwen, .goose, .kimi, .vibe, .aider, .droid]
            #expect(environment.contains(Fixture.sentinel) == viaVariable.contains(tool), "\(tool)")
        }
        // nothing Hangar wrote holds the key: only the key file itself does
        let written = FileManager.default.enumerator(at: f.paths.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(!written.isEmpty)
        for file in written {
            #expect(!(String(data: (try? Data(contentsOf: file)) ?? Data(), encoding: .utf8) ?? "").contains(Fixture.sentinel),
                    "\(file.lastPathComponent)")
        }
    }
}
