import Foundation
import Testing
@testable import HangarCore

@Suite struct InstalledToolsTests {
    private let binaries = ["claude", "codex", "gemini"]

    @Test func onlyMarkedLinesWithAbsolutePathsCount() {
        let output = """
            Welcome back! Last login: today
            HANGAR-TOOL\tclaude\t/Users/demo/.local/bin/claude
            HANGAR-TOOL\tcodex\tcodex: aliased to npx codex
            HANGAR-TOOL\tgemini\t/opt/homebrew/bin/gemini
            HANGAR-TOOL\tother\t/usr/bin/other
            claude\t/fake/claude
            HANGAR-DONE
            """
        #expect(InstalledTools.parse(output, binaries: binaries)
                == ["claude": "/Users/demo/.local/bin/claude", "gemini": "/opt/homebrew/bin/gemini"])
    }

    @Test func aRunThatNeverFinishedIsUnknownNotEmpty() {
        #expect(InstalledTools.parse("HANGAR-TOOL\tclaude\t/x/claude\n", binaries: binaries) == nil)
        #expect(InstalledTools.parse("HANGAR-DONE\n", binaries: binaries) == [:])
    }

    @Test func scriptAsksTheShellForEachBinaryAndEndsWithTheMarker() throws {
        let script = InstalledTools.script(for: ["claude", "my tool"])
        #expect(script.hasPrefix("for b in claude 'my tool'; do "))
        #expect(script.hasSuffix("printf 'HANGAR-DONE\\n'"))
        // the same script, run by a real POSIX shell with a PATH holding one of the two
        let bin = try temporaryDirectory()
        let tool = bin.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(InstalledTools.parse(text, binaries: ["claude", "my tool"]) == ["claude": tool.path])
    }

    /// A stand-in for the login shell: ignores its arguments and prints what it is told.
    private func fakeShell(_ body: String) throws -> String {
        let url = try temporaryDirectory().appending(path: "fake-shell")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func detectReadsWhatTheShellPrints() async throws {
        let shell = try fakeShell("echo noise; printf 'HANGAR-TOOL\\tcodex\\t/opt/codex\\nHANGAR-DONE\\n'")
        #expect(await InstalledTools.detect(binaries: binaries, shell: shell) == ["codex": "/opt/codex"])
    }

    @Test func aHangingOrBrokenShellIsUnknown() async throws {
        #expect(await InstalledTools.detect(binaries: binaries, shell: try fakeShell("sleep 30"),
                                            timeout: .milliseconds(300)) == nil)
        #expect(await InstalledTools.detect(binaries: binaries, shell: "/nonexistent/shell") == nil)
        #expect(await InstalledTools.detect(binaries: binaries, shell: try fakeShell("exit 1")) == nil)
    }
}
