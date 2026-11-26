import Foundation
import Testing
@testable import HangarCore

@Suite struct TerminalLaunchTests {
    private func settings(_ kind: TerminalKind, command: String = "") -> TerminalSettings {
        TerminalSettings(kind: kind, customCommand: command)
    }

    @Test func terminalOpensTheCommandFile() throws {
        let plan = try plan(.codex)
        #expect(TerminalLaunch.command(settings(.terminal), plan: plan) == ["/usr/bin/open", "-a", "Terminal", plan.scriptURL.path])
    }

    @Test func warpOpensThePresetsOwnTabConfigInANewWindow() throws {
        let plan = try plan(.codex)
        #expect(TerminalLaunch.warpTabConfigName(plan) == "hangar_\(plan.stem)")
        #expect(TerminalLaunch.command(settings(.warp), plan: plan)
                == ["/usr/bin/open", "warp://tab_config/hangar_\(plan.stem)?new_window=true"])
        #expect(TerminalLaunch.warpTabConfigURL(plan) == plan.paths.warpTabConfigs.appending(path: "hangar_\(plan.stem).toml"))
    }

    @Test func warpTabConfigRunsThisLaunchsScript() throws {
        let plan = try plan(.claude, directory: "/w \"q\"\nx")
        let toml = TerminalLaunch.warpTabConfig(plan)
        #expect(toml.contains("\nname = \"Hangar · P\"\n"))
        #expect(toml.contains("\n[[panes]]\nid = \"main\"\ntype = \"terminal\"\n"))
        #expect(toml.contains("\ndirectory = \"/w \\\"q\\\"\\u000Ax\"\n"))
        #expect(toml.contains("\ncommands = [\(TOML.string(Shell.quote(plan.scriptURL.path)))]\n"))
        #expect(plan.scriptURL.lastPathComponent.hasSuffix("-\(plan.launchID).command"))
    }

    @Test func customTemplateGetsQuotedPlaceholdersInOnePass() throws {
        let plan = try plan(.codex, directory: "/w {script} d")
        let custom = settings(.custom, command: "/opt/homebrew/bin/tmux new-window -c {dir} {script}")
        #expect(TerminalLaunch.command(custom, plan: plan)
                == ["/bin/sh", "-c", "/opt/homebrew/bin/tmux new-window -c '/w {script} d' \(Shell.quote(plan.scriptURL.path))"])
    }

    @Test func onlyTheTabConfigsOfTheFirstNameAreRemoved() throws {
        let folder = try temporaryDirectory()
        let names = ["agent_launcher.toml", "agent_launcher_claude-old.toml", "hangar_claude-gpu.toml", "my_tab.toml",
                     "agent_launcher_notes.txt"]
        for name in names { try Data().write(to: folder.appending(path: name)) }
        TerminalLaunch.removeLegacyTabConfigs(in: folder)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
                == ["hangar_claude-gpu.toml", "my_tab.toml", "agent_launcher_notes.txt"])
        TerminalLaunch.removeLegacyTabConfigs(in: folder.appending(path: "missing"))     // no folder: nothing happens
    }

    @Test func failingOpenerReportsItsOutput() throws {
        let plan = try plan(.codex)
        let error = #expect(throws: TerminalLaunch.Failure.self) {
            try TerminalLaunch.run(plan, settings: settings(.custom, command: "echo nope >&2; exit 3"))
        }
        #expect(error?.status == 3)
        #expect(error?.output == "nope")
        #expect(FileManager.default.fileExists(atPath: plan.scriptURL.path))
    }
}

@Suite struct ConnectionStatusTests {
    @Test func statusCodesMapToClearStates() {
        let models = Data(#"{"object":"list","data":[{"id":"qwen3-coder-30b","object":"model"}]}"#.utf8)
        #expect(ConnectionCheck.status(code: 200, body: models) == .ok(models: ["qwen3-coder-30b"]))
        #expect(ConnectionCheck.status(code: 200, body: Data("oops".utf8)) == .ok(models: []))
        #expect(ConnectionCheck.status(code: 401, body: Data()) == .unauthorized)
        #expect(ConnectionCheck.status(code: 503, body: Data()) == .loading)
        #expect(ConnectionCheck.status(code: 404, body: Data()) == .unreachable("HTTP 404"))
        #expect(ConnectionCheck.status(code: 502, body: Data()) == .unreachable("HTTP 502"))
        #expect(ConnectionCheck.status(code: 500, body: Data()) == .unexpected(500))
    }

    @Test func onlyStartupFailuresKeepPolling() {
        let transient = [ConnectionStatus.loading, .timeout, .unreachable("HTTP 404")].map(\.isTransient)
        let final = [ConnectionStatus.ok(models: []), .unauthorized, .keyUnreadable, .unexpected(500)].map(\.isTransient)
        #expect(transient == [true, true, true])
        #expect(final == [false, false, false, false])
    }

    @Test func missingKeyFileIsReportedWithoutANetworkCall() async {
        #expect(await ConnectionCheck.run(Server(url: "http://192.0.2.1", keyFile: "/nonexistent/key")) == .keyUnreadable)
    }
}

@Suite struct CheckTriggerTests {
    private let url = "https://gpu-abc12345.example.com"

    @Test func serversWithoutAKeyAreCheckedAfterAPause() {
        #expect(CheckTrigger.afterEdit(from: url, to: url + "x", hasKey: false) == .debounced)
        #expect(CheckTrigger.afterEdit(from: "", to: "h", hasKey: false) == .debounced)
    }

    @Test func withAKeyTypingWaitsAndPastingChecks() {
        #expect(CheckTrigger.afterEdit(from: "https://", to: "https://a", hasKey: true) == .wait)
        #expect(CheckTrigger.afterEdit(from: url, to: String(url.dropLast()), hasKey: true) == .wait)   // deleting
        #expect(CheckTrigger.afterEdit(from: "", to: url, hasKey: true) == .now)                        // pasted
        // the whole URL replaced by another of the same length: only the pod id differs
        #expect(CheckTrigger.afterEdit(from: url, to: "https://gpu-xyz98760.example.com", hasKey: true) == .now)
        #expect(CheckTrigger.afterEdit(from: "https://", to: "https://1234567", hasKey: true) == .wait)  // 7 chars
        #expect(CheckTrigger.afterEdit(from: "https://", to: "https://12345678", hasKey: true) == .now)  // 8 chars
    }

    @Test func pollingStopsOnFinalAnswersAndAfterHalfAnHour() {
        #expect(Polling.shouldContinue(after: .unreachable("HTTP 404"), elapsed: .seconds(29 * 60)))
        #expect(!Polling.shouldContinue(after: .unreachable("HTTP 404"), elapsed: .seconds(30 * 60)))
        #expect(Polling.shouldContinue(after: .loading, elapsed: .zero))
        #expect(!Polling.shouldContinue(after: .unauthorized, elapsed: .zero))
        #expect(!Polling.shouldContinue(after: .ok(models: []), elapsed: .zero))
    }
}
