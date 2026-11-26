import Foundation
import Testing
@testable import HangarCore

/// Runs the generated script and the preview for real, with fake `claude`/`codex` on PATH that
/// record what they receive, a hostile folder and model, and an Anthropic key in the environment.
@Suite struct ExecutionTests {
    private static let fakeTool = """
        #!/bin/bash
        { printf '%s\\0' "$PWD" "${ANTHROPIC_API_KEY-<unset>}" "${ANTHROPIC_AUTH_TOKEN-<unset>}" \\
            "${CODEX_HOME-<unset>}" "${CLAUDE_CONFIG_DIR-<unset>}" "${CLAUDE_CODE_USE_BEDROCK-<unset>}" \\
            "${ANTHROPIC_BASE_URL-<unset>}" "$@"; } > "$HANGAR_TEST_OUT"

        """

    private static func fakeTools(in root: URL) throws -> URL {
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["claude", "codex"] {
            let url = bin.appending(path: tool)
            try Data(fakeTool.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return bin
    }

    /// Runs `arguments` with `shell`, returning what the fake tool recorded.
    private static func record(_ shell: String, _ arguments: [String], bin: URL, root: URL,
                               environment: [String: String]) throws -> (status: Int32, fields: [String]) {
        let out = root.appending(path: "out")
        try? FileManager.default.removeItem(at: out)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "HANGAR_TEST_OUT": out.path]
            .merging(environment) { $1 }
        try process.run()
        process.waitUntilExit()
        var fields = String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self).components(separatedBy: "\0")
        fields.removeLast()
        return (process.terminationStatus, fields)
    }

    @Test func accountModeDropsAnInheritedConfigDirAndKeyOrSetsItsOwn() throws {
        let root = try temporaryDirectory()
        let bin = try Self.fakeTools(in: root)
        let inherited = ["CLAUDE_CONFIG_DIR": "/elsewhere/claude", "ANTHROPIC_API_KEY": "sk-ant-api03-REAL-LOOKING-KEY",
                         "ANTHROPIC_BASE_URL": "https://proxy.example.com", "CODEX_HOME": "/elsewhere/codex"]
        let paths = LauncherPaths(root: root.appending(path: "hangar"), warpTabConfigs: root)
        for tool in [Tool.claude, .codex] {
            for account in [nil, "lavoro"] as [String?] {
                let preset = Preset(id: "a", name: "A", tool: tool, url: "", keyFile: nil, model: "", contextTokens: 1,
                                    extraArgs: "", mode: .account, account: account)
                let plan = LaunchPlan(preset: preset, directory: root.path, paths: paths)
                try plan.writeFiles()
                for (shell, arguments) in [("/bin/bash", [plan.scriptURL.path]), ("/bin/zsh", ["-f", "-c", plan.preview])] {
                    let label = "\(tool) \(account ?? "default") via \(shell)"
                    let run = try Self.record(shell, arguments, bin: bin, root: root, environment: inherited)
                    #expect(run.status == 0, "\(label)")
                    guard run.fields.count >= 7 else { Issue.record("\(label): no output"); continue }
                    let ownDirectory = plan.accountDirectory ?? "<unset>"
                    if tool == .claude {
                        #expect(run.fields[1] == "<unset>", "\(label)")                       // ANTHROPIC_API_KEY
                        #expect(run.fields[6] == "<unset>", "\(label)")                       // ANTHROPIC_BASE_URL
                        #expect(run.fields[4] == ownDirectory, "\(label)")                    // CLAUDE_CONFIG_DIR
                    } else {
                        #expect(run.fields[3] == ownDirectory, "\(label)")                    // CODEX_HOME
                    }
                    #expect(run.fields.dropFirst(7).isEmpty, "\(label)")                      // no model, no extra
                }
            }
        }
    }

    @Test func hostileInputsArriveVerbatimAndTheAnthropicKeyNeverDoes() throws {
        let root = try temporaryDirectory()
        let bin = try Self.fakeTools(in: root)
        let folder = root.appending(path: "w $(touch PWN1) `touch PWN2` 'q' \"d\" é\nnl =ls").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let model = "=ls m$(touch PWN3)`touch PWN4`'é\"\nx"
        let out = root.appending(path: "out")

        for tool in [Tool.claude, .codex] {
            let plan = try plan(tool, directory: folder, model: model, root: root)
            try plan.writeFiles()
            let runs = [("/bin/bash", [plan.scriptURL.path]), ("/bin/bash", ["-c", plan.preview]),
                        ("/bin/zsh", ["-f", "-c", plan.preview])]
            for (shell, arguments) in runs {
                try? FileManager.default.removeItem(at: out)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = arguments
                process.currentDirectoryURL = root
                process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path,
                                       "ANTHROPIC_API_KEY": "sk-ant-api03-REAL-LOOKING-KEY",
                                       "ANTHROPIC_AUTH_TOKEN": "real-token", "CLAUDE_CODE_USE_BEDROCK": "1",
                                       "HANGAR_TEST_OUT": out.path]
                try process.run()
                process.waitUntilExit()
                let label = "\(tool) via \(shell) \(arguments.count == 1 ? "script" : "preview")"
                #expect(process.terminationStatus == 0, "\(label)")

                var fields = String(decoding: try Data(contentsOf: out), as: UTF8.self).components(separatedBy: "\0")
                fields.removeLast()                                       // after the final NUL
                #expect(fields.count >= 7, "\(label)")
                guard fields.count >= 7 else { continue }
                #expect(fields[0] == folder, "\(label)")
                #expect(fields[1] == "<unset>", "\(label)")
                #expect(fields[2] == "<unset>", "\(label)")
                #expect(fields[3] == (tool == .codex ? plan.paths.codexHome.path : "<unset>"), "\(label)")
                #expect(fields[4] == "<unset>", "\(label)")
                #expect(fields[5] == "<unset>", "\(label)")
                #expect(Array(fields.dropFirst(7)) == plan.argumentGroups.flatMap { $0 }, "\(label)")
            }
        }
        let markers = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("PWN") } ?? []
        #expect(markers.isEmpty)
    }

    @Test func unreadableKeyStopsTheScriptWithAMessage() throws {
        let root = try temporaryDirectory()
        for tool in Tool.allCases.filter { $0.spec.modes.contains(.server) } {
            let plan = try plan(tool, directory: root.path, root: root)
            try plan.writeFiles()
            try FileManager.default.removeItem(atPath: plan.server.keyPath ?? "")
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [plan.scriptURL.path]
            process.environment = ["PATH": "/nonexistent"]          // reaching the tool would fail differently
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(process.terminationStatus == 1)
            #expect(message == "\(LaunchPlan.keyFileMessage) \(plan.server.keyPath ?? "")\n")
        }
    }
}
