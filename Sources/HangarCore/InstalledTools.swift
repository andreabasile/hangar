import Foundation

/// Which tools are on the PATH the terminal will have.
public enum InstalledTools {
    static let marker = "HANGAR-TOOL"
    static let done = "HANGAR-DONE"

    /// One marked line per tool found, then an end marker: noise printed by the user's startup files
    /// is ignored, and a run that never reached the end is told apart from "nothing installed".
    public static func script(for binaries: [String]) -> String {
        "for b in \(binaries.map(Shell.quote).joined(separator: " ")); do "
            + "p=$(command -v \"$b\" 2>/dev/null) && printf '\(marker)\\t%s\\t%s\\n' \"$b\" \"$p\"; done; "
            + "printf '\(done)\\n'"
    }

    /// Binary name → absolute path. Aliases and functions (`command -v` prints no path for them) do not
    /// count: the launch script runs the binary through `env`. nil if the end marker is missing.
    public static func parse(_ output: String, binaries: [String]) -> [String: String]? {
        var found: [String: String] = [:]
        var finished = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line == done { finished = true }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[0] == marker, binaries.contains(fields[1]), fields[2].hasPrefix("/") else { continue }
            found[fields[1]] = fields[2]
        }
        return finished ? found : nil
    }

    public static var userShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Runs the user's shell as an interactive login shell (`-lic`), like a terminal does: many
    /// installers add themselves to PATH in .zshrc, which a plain login shell does not read. stdin is
    /// closed and output goes to a file, so a startup file waiting for input or leaving a process
    /// behind cannot hang the check. nil when the shell failed, timed out or never reached the end.
    public static func detect(binaries: [String], shell: String = userShell,
                              timeout: Duration = .seconds(10)) async -> [String: String]? {
        await Task.detached {
            let output = FileManager.default.temporaryDirectory.appending(path: "hangar-tools-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: output) }
            guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lic", script(for: binaries)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = ContinuousClock.now + timeout
            while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            return parse((try? String(contentsOf: output, encoding: .utf8)) ?? "", binaries: binaries)
        }.value
    }
}
