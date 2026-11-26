import Foundation
import Testing
@testable import HangarCore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hangar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ConfigTests {
    @Test func firstRunHasEachToolsDefaultAccountAndTwoLocalLMStudioPresets() throws {
        let config = LauncherConfig.defaults
        #expect(config.version == 4)
        #expect(config.presets.map(\.name) == ["Claude Code", "Codex", "Claude Code · LM Studio", "Codex · LM Studio"])
        #expect(config.presets.map(\.tool) == [.claude, .codex, .claude, .codex])
        #expect(config.presets.map(\.mode) == [.account, .account, .server, .server])
        #expect(config.presets.allSatisfy { $0.account == nil && $0.keyFile == nil && $0.model.isEmpty })
        let servers = config.presets.filter { $0.mode == .server }
        #expect(servers.map(\.server) == Array(repeating: Server(url: "http://localhost:1234", keyFile: nil), count: 2))
        #expect(servers.map(\.contextTokens) == [65_536, 32_768])
        #expect(config.presets.allSatisfy { !$0.contextIsTooSmall })
    }

    @Test func missingFileIsCreatedWithDefaults() throws {
        let file = try temporaryDirectory().appending(path: "nested/config.json")
        #expect(try ConfigFile.load(file) == .defaults)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try ConfigFile.load(file) == .defaults)
    }

    @Test func roundTripKeepsEveryField() throws {
        let file = try temporaryDirectory().appending(path: "config.json")
        var config = LauncherConfig.defaults
        config.terminal = TerminalSettings(kind: .custom, customCommand: "open -a iTerm {script}")
        config.presets[0].url = "https://gpu.example.com"
        config.presets[0].keyFile = "~/.config/hangar/keys/example"
        config.presets[1].extraArgs = "--search 'two words'"
        try ConfigFile.save(config, to: file)
        #expect(try ConfigFile.load(file) == config)
    }

    @Test func fileIsReadableJSON() throws {
        let text = String(decoding: try ConfigFile.encode(.defaults), as: UTF8.self)
        #expect(text.contains("\"url\" : \"http://localhost:1234\""))
        #expect(text.contains("\"contextTokens\" : 65536"))
        #expect(text.contains("\"mode\" : \"account\""))
        #expect(text.contains("\"mode\" : \"server\""))
        #expect(text.contains("\"version\" : 4"))
        #expect(!text.contains("endpoint"))
        #expect(text.contains("\n    "))
    }

    @Test func droppedFieldsOfOlderFilesStillDecode() throws {
        var json = try JSONSerialization.jsonObject(with: ConfigFile.encode(.defaults)) as! [String: Any]
        json["terminal"] = ["kind": "custom", "customApp": "iTerm", "customCommand": "open -a iTerm {script}"]
        json["presets"] = (json["presets"] as! [[String: Any]]).map { $0.merging(["workingDirectory": "~/x"]) { $1 } }
        let config = try JSONDecoder().decode(LauncherConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(config.terminal == TerminalSettings(kind: .custom, customCommand: "open -a iTerm {script}"))
        #expect(config.presets == LauncherConfig.defaults.presets)
    }

    @Test func noAuthIsOmittedFromTheFileAndReadBackAsNil() throws {
        var config = LauncherConfig.defaults
        config.presets[0].keyFile = "~/.config/hangar/keys/example"
        let text = String(decoding: try ConfigFile.encode(config), as: UTF8.self)
        #expect(text.components(separatedBy: "\"keyFile\"").count - 1 == 1)
        #expect(try JSONDecoder().decode(LauncherConfig.self, from: Data(text.utf8)).presets[1].keyFile == nil)
    }

    @Test func brokenFileGivesAReadableReason() throws {
        let file = try temporaryDirectory().appending(path: "config.json")
        var json = try JSONSerialization.jsonObject(with: ConfigFile.encode(.defaults)) as! [String: Any]
        var presets = json["presets"] as! [[String: Any]]
        presets[1].removeValue(forKey: "model")
        json["presets"] = presets
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let error = #expect(throws: DecodingError.self) { try ConfigFile.load(file) }
        #expect(ConfigFile.describe(try #require(error)) == (try current("missing field “%@”%@", "model", try current(" in %@", "presets[1]"))))

        try Data("{\n  \"version\": 4,\n  \"presets\": [1, 2,,]\n}".utf8).write(to: file)
        let corrupt = #expect(throws: DecodingError.self) { try ConfigFile.load(file) }
        #expect(ConfigFile.describe(try #require(corrupt)) == (try current("invalid JSON at line %@, column %@", "3", "20")))
    }
}

@Suite struct MigrationTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-25T18:40:12Z")!

    private func backupName(_ folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return folder.appending(path: "config.json.bak-\(formatter.string(from: now))")
    }

    /// A file as version 2 wrote it: shared endpoints, presets pointing at them by id.
    private let version2 = """
    {"endpoints":[{"id":"gpu","keyFile":"~/.config/hangar/keys/example","name":"GPU",
    "url":"https://gpu.example.com"},{"id":"lmstudio","name":"LM Studio (locale)",
    "url":"http://localhost:1234"}],"presets":[
    {"contextTokens":131072,"endpoint":"gpu","extraArgs":"","id":"claude-gpu","model":"qwen3-coder-30b",
    "name":"Claude Code · GPU","tool":"claude"},
    {"contextTokens":131072,"endpoint":"gpu","extraArgs":"","id":"codex-gpu","model":"qwen3-coder-30b",
    "name":"Codex · GPU","tool":"codex"},
    {"contextTokens":65536,"endpoint":"lmstudio","extraArgs":"","id":"claude-lmstudio","model":"","name":"Claude Code · LM Studio",
    "tool":"claude"},
    {"contextTokens":32768,"endpoint":"lmstudio","extraArgs":"--x","id":"codex-lmstudio","model":"qwen3","name":"Codex · LM Studio",
    "tool":"codex"},
    {"contextTokens":8192,"endpoint":"gone","extraArgs":"","id":"orphan","model":"m","name":"Orfano","tool":"codex"}],
    "terminal":{"customCommand":"","kind":"terminal"},"version":2}
    """

    @Test func version2PresetsTakeTheirEndpointsURLAndKeyFileWithABackup() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        try Data(version2.utf8).write(to: file)

        #expect(try ConfigFile.migrateIfOutdated(file, now: now) == .upgraded(backup: backupName(folder)))
        #expect(try String(contentsOf: backupName(folder), encoding: .utf8) == version2)
        let config = try ConfigFile.load(file)
        let gpu = ("https://gpu.example.com", "~/.config/hangar/keys/example")
        #expect(config.presets.map(\.url) == [gpu.0, gpu.0, "http://localhost:1234", "http://localhost:1234", ""])
        #expect(config.presets.map(\.keyFile) == [gpu.1, gpu.1, nil, nil, nil])
        #expect(config.presets.map(\.id) == ["claude-gpu", "codex-gpu", "claude-lmstudio", "codex-lmstudio", "orphan"])
        #expect(config.presets[3].model == "qwen3" && config.presets[3].extraArgs == "--x" && config.presets[3].tool == .codex)
        #expect(config.terminal.kind == .terminal)
        #expect(try ConfigFile.migrateIfOutdated(file, now: now) == ConfigFile.Migration.none)   // only once
    }

    /// A file as version 3 wrote it: presets with their server, no mode.
    private let version3 = """
    {"presets":[{"contextTokens":131072,"extraArgs":"","id":"claude-gpu","keyFile":"~/.config/hangar/keys/example",
    "model":"qwen3-coder-30b","name":"Claude Code · GPU","tool":"claude","url":"https://gpu.example.com"},
    {"contextTokens":32768,"extraArgs":"--x","id":"codex-lmstudio","model":"","name":"Codex · LM Studio","tool":"codex",
    "url":"http://localhost:1234"}],"terminal":{"customCommand":"","kind":"warp"},"version":3}
    """

    @Test func version3PresetsBecomeServerPresetsWithABackup() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        try Data(version3.utf8).write(to: file)

        #expect(try ConfigFile.migrateIfOutdated(file, now: now) == .upgraded(backup: backupName(folder)))
        #expect(try String(contentsOf: backupName(folder), encoding: .utf8) == version3)
        let config = try ConfigFile.load(file)
        #expect(config.version == 4)
        #expect(config.presets == [
            Preset(id: "claude-gpu", name: "Claude Code · GPU", tool: .claude, url: "https://gpu.example.com",
                   keyFile: "~/.config/hangar/keys/example", model: "qwen3-coder-30b", contextTokens: 131_072, extraArgs: ""),
            Preset(id: "codex-lmstudio", name: "Codex · LM Studio", tool: .codex, url: "http://localhost:1234",
                   keyFile: nil, model: "", contextTokens: 32_768, extraArgs: "--x"),
        ])
        #expect(config.presets.allSatisfy { $0.mode == .server && $0.account == nil })
        #expect(try ConfigFile.migrateIfOutdated(file, now: now) == ConfigFile.Migration.none)   // only once
    }

    @Test func versionlessVersion2ShapeIsUpgradedToo() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        try Data(version2.replacingOccurrences(of: ",\"version\":2", with: "").utf8).write(to: file)
        #expect(try ConfigFile.migrateIfOutdated(file, now: now) == .upgraded(backup: backupName(folder)))
        #expect(try ConfigFile.load(file).presets.first?.keyFile == "~/.config/hangar/keys/example")
    }

    /// The first schema: a URL template filled with a pod id, no `version`.
    private let version1 = """
    {"endpoints":[{"baseURL":"https://{pod}-8080.example.com","id":"gpu","keyFile":"~/k","name":"GPU",
    "podID":"abc"}],"presets":[],"terminal":{"customApp":"","customCommand":"","kind":"warp"}}
    """

    @Test func version1IsBackedUpAndReplacedByDefaults() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        try Data(version1.utf8).write(to: file)
        #expect(try ConfigFile.migrateIfOutdated(file, now: now) == .reset(backup: backupName(folder)))
        #expect(try String(contentsOf: backupName(folder), encoding: .utf8) == version1)
        #expect(try ConfigFile.load(file) == .defaults)
    }

    @Test func versionlessFileInTodaysShapeSurvivesIntact() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        var edited = LauncherConfig.defaults
        edited.presets[0].url = "https://edited.example.com"
        edited.presets.removeLast()
        var json = try JSONSerialization.jsonObject(with: ConfigFile.encode(edited)) as! [String: Any]
        json.removeValue(forKey: "version")
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        #expect(try ConfigFile.migrateIfOutdated(file) == .adopted)
        #expect(try ConfigFile.load(file) == edited)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])   // no backup
    }

    @Test func currentMissingOrBrokenFilesAreLeftAlone() throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        #expect(try ConfigFile.migrateIfOutdated(file) == ConfigFile.Migration.none)
        try ConfigFile.save(.defaults, to: file)
        #expect(try ConfigFile.migrateIfOutdated(file) == ConfigFile.Migration.none)
        try Data("{ not json".utf8).write(to: file)
        #expect(try ConfigFile.migrateIfOutdated(file) == ConfigFile.Migration.none)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])
    }

    @Test func newerVersionIsRefusedNotOverwritten() throws {
        let file = try temporaryDirectory().appending(path: "config.json")
        var newer = LauncherConfig.defaults
        newer.version = 5
        try ConfigFile.save(newer, to: file)
        #expect(try ConfigFile.migrateIfOutdated(file) == ConfigFile.Migration.none)
        let error = #expect(throws: ConfigFile.UnsupportedVersion.self) { try ConfigFile.load(file) }
        #expect(ConfigFile.describe(try #require(error)) == (try current("version %lld is not supported (this app reads version %lld)", 5, 4)))
    }
}

@Suite struct ServerTests {
    @Test func rootDropsSpacesTrailingSlashesAndV1() {
        #expect(Server(url: "http://localhost:1234", keyFile: nil).root == "http://localhost:1234")
        #expect(Server(url: " http://localhost:1234/ ", keyFile: nil).root == "http://localhost:1234")
        #expect(Server(url: "http://localhost:1234/v1", keyFile: nil).root == "http://localhost:1234")
        #expect(Server(url: "http://localhost:1234/v1/", keyFile: nil).root == "http://localhost:1234")
        #expect(Server(url: "https://gpu.example.com", keyFile: nil).root == "https://gpu.example.com")
        #expect(Server(url: "http://host/v10", keyFile: nil).root == "http://host/v10")
    }

    @Test func keyPathExpandsTildeAndIsNilWithoutAuth() {
        #expect(Server(url: "x", keyFile: "~/.config/k").keyPath == NSString(string: "~/.config/k").expandingTildeInPath)
        #expect(Server(url: "x", keyFile: "~/.config/k").keyPath?.hasPrefix("~") == false)
        #expect(Server(url: "x", keyFile: nil).keyPath == nil)
    }

    /// Checks are keyed by server: presets that differ only in how the URL is written share one.
    @Test func sameRootAndKeyFileIsTheSameServer() {
        #expect(Server(url: "http://localhost:1234/v1/", keyFile: nil) == Server(url: "http://localhost:1234", keyFile: nil))
        #expect(Server(url: "http://localhost:1234", keyFile: "~/k") != Server(url: "http://localhost:1234", keyFile: nil))
        #expect(Set(LauncherConfig.defaults.presets.filter { $0.mode == .server }.map(\.server)).count == 1)
    }

    @Test func claudeUnder64kIsFlaggedButCodexIsNot() {
        var preset = LauncherConfig.defaults.presets[0]
        preset.contextTokens = 65_535
        #expect(preset.contextIsTooSmall)
        preset.contextTokens = 65_536
        #expect(!preset.contextIsTooSmall)
        preset.contextTokens = 8_192
        preset.tool = .codex
        #expect(!preset.contextIsTooSmall)
    }
}

@Suite struct SuggestionTests {
    private let lmStudio = ["qwen3-coder-30b-mlx", "qwen3-coder-30b-gguf",
                            "text-embedding-nomic-embed-text-v1.5"]

    @Test func embeddingModelsAreNotChatModels() {
        #expect(ModelChoice.chatModels(lmStudio) == Array(lmStudio.prefix(2)))
    }

    @Test func emptyModelIsFilledOnlyWhenThereIsNoChoice() {
        #expect(ModelChoice.automatic(current: "", ids: ["only-one", "nomic-EMBED"]) == "only-one")
        #expect(ModelChoice.automatic(current: "", ids: lmStudio) == nil)
        #expect(ModelChoice.automatic(current: "set", ids: ["only-one"]) == nil)
    }

    @Test func mismatchSuggestsTheOnlyChatModel() {
        #expect(ModelChoice.mismatch(current: "qwen3-coder-30b", ids: ["qwen3-coder-30b"]) == nil)
        #expect(ModelChoice.mismatch(current: "", ids: ["a"]) == nil)
        #expect(ModelChoice.mismatch(current: "old", ids: ["new", "nomic-embed"]) == .init(suggestion: "new"))
        #expect(ModelChoice.mismatch(current: "old", ids: lmStudio) == .init(suggestion: nil))
        #expect(ModelChoice.mismatch(current: "nomic-embed", ids: ["nomic-embed", "chat"]) == .init(suggestion: "chat"))
    }

    @Test func recentFoldersAreNewestFirstUniqueAndCapped() {
        var recents: [String] = []
        for folder in (1...10).map({ "~/p\($0)" }) { recents = RecentFolders.adding(folder, to: recents) }
        #expect(recents == (3...10).reversed().map { "~/p\($0)" })
        #expect(RecentFolders.adding("~/p5", to: recents).prefix(3) == ["~/p5", "~/p10", "~/p9"])
        #expect(RecentFolders.adding("~/p5", to: recents).count == RecentFolders.limit)
    }
}

@Suite struct ConfigWatcherTests {
    @MainActor @Test func notifiesOnAtomicReplaceAndInPlaceWrite() async throws {
        let folder = try temporaryDirectory()
        let file = folder.appending(path: "config.json")
        try ConfigFile.save(.defaults, to: file)
        var events = 0
        let watcher = ConfigWatcher(folder: folder, file: file) { events += 1 }

        var edited = LauncherConfig.defaults
        edited.presets[0].url = "http://other:8080"
        try ConfigFile.save(edited, to: file)            // atomic: new file renamed over the old one
        try await waitFor { events == 1 }
        #expect(try ConfigFile.load(file).presets[0].url == "http://other:8080")

        let handle = try FileHandle(forWritingTo: file)  // in place, as some editors do
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        try await waitFor { events == 2 }
        _ = watcher
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }
}

@Suite struct LegacyFolderTests {
    private func paths(in home: URL) -> LauncherPaths {
        LauncherPaths(root: home.appending(path: ".config/hangar"), warpTabConfigs: home.appending(path: ".warp/tab_configs"),
                      legacyRoot: home.appending(path: ".config/agent-launcher"))
    }

    @Test func legacyFolderMovesWholeWithItsContents() throws {
        let home = try temporaryDirectory()
        let paths = paths(in: home)
        let legacy = try #require(paths.legacyRoot)
        for file in ["config.json", "config.json.bak-20261125-194357", "codex-home/config.toml", "generated/x.command"] {
            let url = legacy.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        #expect(try paths.adoptLegacyFolder())
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: paths.config, encoding: .utf8) == "config.json")
        #expect(try String(contentsOf: paths.codexHome.appending(path: "config.toml"), encoding: .utf8) == "codex-home/config.toml")
        #expect(FileManager.default.fileExists(atPath: paths.generated.appending(path: "x.command").path))
        #expect(FileManager.default.fileExists(atPath: paths.root.appending(path: "config.json.bak-20261125-194357").path))
    }

    @Test func bothFoldersPresentAreLeftAloneAndTheNewOneIsUsed() throws {
        let home = try temporaryDirectory()
        let paths = paths(in: home)
        let legacy = try #require(paths.legacyRoot)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appending(path: "config.json"))
        try ConfigFile.save(.defaults, to: paths.config)

        #expect(try !paths.adoptLegacyFolder())
        #expect(try String(contentsOf: legacy.appending(path: "config.json"), encoding: .utf8) == "old")
        #expect(try ConfigFile.load(paths.config) == .defaults)
    }

    @Test func nothingToMoveIsANoOp() throws {
        let home = try temporaryDirectory()
        #expect(try !paths(in: home).adoptLegacyFolder())
        #expect(!FileManager.default.fileExists(atPath: paths(in: home).root.path))
        #expect(try !LauncherPaths(root: home.appending(path: "a"), warpTabConfigs: home).adoptLegacyFolder())
    }
}
