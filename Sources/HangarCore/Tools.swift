import Foundation

/// How a preset starts its tool.
public enum LaunchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Against a model server the user chooses: URL and optional key file.
    case server
    /// With the tool's own login: its default account or a separate one.
    case account

    public var id: Self { self }
}

/// What the app needs to know about a tool. The command itself is built per tool in `LaunchPlan`.
public struct ToolSpec: Sendable {
    public let name: String
    public let binary: String
    /// SF Symbol for the sidebar badge, and its point size on the 20 pt tile; vendor logos are not used.
    public let symbol: String
    public let symbolSize: Double
    /// Badge gradient, top and bottom, as sRGB hex.
    public let colors: [UInt32]
    public let modes: [LaunchMode]
    /// Whether an account can live in a folder of its own. Tools whose login is in a Keychain item
    /// shared across folders, or that only isolate through HOME, cannot.
    public let separateAccounts: Bool
    /// The tool's own variables that point it at another home: removed for the default account, so
    /// a value inherited by the terminal cannot switch accounts. Generic ones (XDG_*) are left alone.
    public let isolationVariables: [String]
    /// The flag for an optional model in account mode; nil when Hangar knows none.
    public let accountModelFlag: String?
    /// Where the default account lives, as the user would write it, when it is known.
    public let defaultHome: String?
    /// Shown, with a copy button, when the binary is not on the login shell's PATH.
    public let installCommand: String
    /// True only for the tools launched against a mock server (Claude Code and Codex); the others
    /// follow their documentation and source.
    public let verified: Bool
    /// Shown in server mode for tools that may still ask for their vendor's login.
    public let serverNote: String?

    init(name: String, binary: String, symbol: String, symbolSize: Double = 10, colors: [UInt32], modes: [LaunchMode],
         separateAccounts: Bool, isolationVariables: [String] = [], accountModelFlag: String? = nil,
         defaultHome: String? = nil, installCommand: String, verified: Bool = false, serverNote: String? = nil) {
        self.name = name
        self.binary = binary
        self.symbol = symbol
        self.symbolSize = symbolSize
        self.colors = colors
        self.modes = modes
        self.separateAccounts = separateAccounts
        self.isolationVariables = isolationVariables
        self.accountModelFlag = accountModelFlag
        self.defaultHome = defaultHome
        self.installCommand = installCommand
        self.verified = verified
        self.serverNote = serverNote
    }
}

public enum Tool: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    case copilot, opencode, kilo, crush, qwen, goose, kimi, pi
    case vibe, droid, aider
    case gemini, cursor, amp, kiro, cline, auggie

    public var id: Self { self }

    /// Claude Code and Codex first, then by name: the order of the tool menu.
    public static let menuOrder: [Tool] = [.claude, .codex]
        + allCases.filter { $0 != .claude && $0 != .codex }.sorted { $0.spec.name.localizedStandardCompare($1.spec.name) == .orderedAscending }

    public var spec: ToolSpec {
        let both: [LaunchMode] = [.server, .account]
        switch self {
        case .claude:
            return ToolSpec(name: "Claude Code", binary: "claude", symbol: "sparkle", symbolSize: 11, colors: [0xFF9E33, 0xED611A],
                            modes: both, separateAccounts: true, isolationVariables: ["CLAUDE_CONFIG_DIR"],
                            accountModelFlag: "--model", defaultHome: "~/.claude",
                            installCommand: "curl -fsSL https://claude.ai/install.sh | bash", verified: true)
        case .codex:
            return ToolSpec(name: "Codex", binary: "codex", symbol: "chevron.left.forwardslash.chevron.right", symbolSize: 9,
                            colors: [0x6B6BF5, 0x4A45CC], modes: both, separateAccounts: true,
                            isolationVariables: ["CODEX_HOME"], accountModelFlag: "-m", defaultHome: "~/.codex",
                            installCommand: "npm i -g @openai/codex", verified: true)
        case .copilot:
            return ToolSpec(name: "GitHub Copilot CLI", binary: "copilot", symbol: "airplane", symbolSize: 9,
                            colors: [0x4AA8F0, 0x2477C9], modes: both, separateAccounts: true,
                            isolationVariables: ["COPILOT_HOME", "COPILOT_CACHE_HOME"], installCommand: "npm i -g @github/copilot")
        case .opencode:
            return ToolSpec(name: "OpenCode", binary: "opencode", symbol: "curlybraces", symbolSize: 9,
                            colors: [0x7A8BA3, 0x52637A], modes: both, separateAccounts: true,
                            installCommand: "curl -fsSL https://opencode.ai/install | bash")
        case .kilo:
            return ToolSpec(name: "Kilo CLI", binary: "kilo", symbol: "scalemass.fill", symbolSize: 9,
                            colors: [0xE5A422, 0xB97A06], modes: both, separateAccounts: true,
                            installCommand: "npm i -g @kilocode/cli")
        case .crush:
            return ToolSpec(name: "Crush", binary: "crush", symbol: "heart.fill", colors: [0xF46EA0, 0xD13D78],
                            modes: both, separateAccounts: true, isolationVariables: ["CRUSH_GLOBAL_DATA"],
                            installCommand: "brew install charmbracelet/tap/crush")
        case .qwen:
            return ToolSpec(name: "Qwen Code", binary: "qwen", symbol: "hexagon.fill", colors: [0xA174F2, 0x7745D6],
                            modes: both, separateAccounts: true, isolationVariables: ["QWEN_HOME"],
                            installCommand: "npm i -g @qwen-code/qwen-code@latest")
        case .goose:
            return ToolSpec(name: "Goose", binary: "goose", symbol: "bird.fill", colors: [0xB08A63, 0x7F5F3F],
                            modes: both, separateAccounts: true, isolationVariables: ["GOOSE_PATH_ROOT"],
                            installCommand: "brew install block-goose-cli")
        case .kimi:
            return ToolSpec(name: "Kimi Code", binary: "kimi", symbol: "moon.stars.fill", colors: [0x4C6FE0, 0x2C46A8],
                            modes: both, separateAccounts: true, isolationVariables: ["KIMI_CODE_HOME"],
                            installCommand: "npm i -g @moonshot-ai/kimi-code")
        case .pi:
            return ToolSpec(name: "Pi", binary: "pi", symbol: "pi", symbolSize: 11, colors: [0x2BB3A8, 0x168077],
                            modes: both, separateAccounts: true, isolationVariables: ["PI_CODING_AGENT_DIR"],
                            installCommand: "npm i -g --ignore-scripts @earendil-works/pi-coding-agent")
        case .vibe:
            return ToolSpec(name: "Mistral Vibe", binary: "vibe", symbol: "wind", symbolSize: 9, colors: [0xF2555A, 0xC72E33],
                            modes: both, separateAccounts: false, isolationVariables: ["VIBE_HOME"], defaultHome: "~/.vibe",
                            installCommand: "uv tool install --python 3.14 mistral-vibe")
        case .droid:
            return ToolSpec(name: "Factory Droid", binary: "droid", symbol: "cpu.fill", colors: [0x7B8494, 0x565E6C],
                            modes: both, separateAccounts: false, installCommand: "npm i -g @factory/cli",
                            serverNote: String(localized: "It may still ask you to sign in to Factory.", bundle: .module))
        case .aider:
            return ToolSpec(name: "Aider", binary: "aider", symbol: "hammer.fill", colors: [0x4CC46A, 0x2A9446],
                            modes: [.server], separateAccounts: false,
                            installCommand: "uv tool install --python 3.12 aider-chat")
        case .gemini:
            return ToolSpec(name: "Gemini CLI", binary: "gemini", symbol: "circle.lefthalf.filled",
                            colors: [0x5C8DF6, 0x8B5CF6], modes: [.account], separateAccounts: false, defaultHome: "~/.gemini",
                            installCommand: "npm i -g @google/gemini-cli")
        case .cursor:
            return ToolSpec(name: "Cursor CLI", binary: "cursor-agent", symbol: "cursorarrow.rays", symbolSize: 9,
                            colors: [0x2CC3DA, 0x1690A8], modes: [.account], separateAccounts: false,
                            installCommand: "brew install --cask cursor-cli")
        case .amp:
            return ToolSpec(name: "Amp", binary: "amp", symbol: "bolt.fill", colors: [0x9BC02A, 0x6E8F10],
                            modes: [.account], separateAccounts: false, installCommand: "npm i -g @ampcode/cli")
        case .kiro:
            return ToolSpec(name: "Kiro CLI", binary: "kiro-cli", symbol: "wand.and.stars", symbolSize: 9,
                            colors: [0xC45CE6, 0x9333C2], modes: [.account], separateAccounts: false,
                            installCommand: "brew install --cask kiro-cli")
        case .cline:
            return ToolSpec(name: "Cline", binary: "cline", symbol: "terminal.fill", symbolSize: 9, colors: [0x4F8A99, 0x336473],
                            modes: [.account], separateAccounts: false, installCommand: "npm i -g cline")
        case .auggie:
            return ToolSpec(name: "Auggie", binary: "auggie", symbol: "brain.head.profile", symbolSize: 9,
                            colors: [0xE08A5E, 0xB65F34], modes: [.account], separateAccounts: false,
                            installCommand: "npm i -g @augmentcode/auggie")
        }
    }
}

extension Preset {
    /// The preset with its mode and account brought within what its tool supports: the first
    /// supported mode, and the default account when the tool has no separate ones.
    public func adapted() -> Preset {
        var preset = self
        let spec = tool.spec
        if !spec.modes.contains(preset.mode), let mode = spec.modes.first { preset.mode = mode }
        if preset.mode == .account, !spec.separateAccounts { preset.account = nil }
        return preset
    }
}

public enum Account {
    /// A folder name for an account name: ASCII letters and digits, dashes between words.
    /// Names that keep nothing (only non-Latin letters, say) get a stable hash instead.
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        guard slug.isEmpty else { return slug }
        var hash: UInt32 = 2_166_136_261                          // FNV-1a: Hasher is seeded per process
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return "account-" + String(hash, radix: 16)
    }
}
