import Foundation

/// Configuration for a Claude Code session running via BunRuntime (JavaScriptCore).
public struct ClaudeConfiguration: Sendable {

    /// Working directory for the Claude session.
    public var workingDirectory: URL?

    /// Model override (e.g. "sonnet", "opus", "claude-sonnet-4-6").
    public var model: String?

    /// Tools available to Claude. Use `iPadTools` for the iPad-safe preset.
    public var allowedTools: [String]

    /// Maximum agentic turns per invocation.
    public var maxTurns: Int?

    /// System prompt override.
    public var systemPrompt: String?

    /// Additional system prompt appended to the default.
    public var appendSystemPrompt: String?

    /// Permission mode (e.g. "default", "acceptEdits", "plan").
    public var permissionMode: String?

    /// Additional directories to allow tool access to.
    public var additionalDirectories: [URL]

    /// MCP server configurations (JSON strings).
    public var mcpConfigs: [String]

    /// Skip all permission checks.
    public var dangerouslySkipPermissions: Bool

    public init(
        workingDirectory: URL? = nil,
        model: String? = nil,
        allowedTools: [String] = ClaudeConfiguration.iPadTools,
        maxTurns: Int? = nil,
        systemPrompt: String? = nil,
        appendSystemPrompt: String? = nil,
        permissionMode: String? = nil,
        dangerouslySkipPermissions: Bool = true,
        additionalDirectories: [URL] = [],
        mcpConfigs: [String] = []
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.systemPrompt = systemPrompt
        self.appendSystemPrompt = appendSystemPrompt
        self.permissionMode = permissionMode
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
        self.additionalDirectories = additionalDirectories
        self.mcpConfigs = mcpConfigs
    }

    /// iPad-safe tool preset — excludes Bash and other process-dependent tools.
    public static let iPadTools: [String] = [
        "Read", "Write", "Edit", "Glob", "Grep",
        "WebFetch", "WebSearch",
    ]

    /// Builds process.argv array for the Claude Code CLI running in BunRuntime.
    func processArgv(resumeSessionID: String? = nil) -> [String] {
        var args = [
            "node", "claude",
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
        ]

        if dangerouslySkipPermissions {
            args += ["--dangerously-skip-permissions"]
        }

        if let sessionID = resumeSessionID {
            args += ["--resume", sessionID]
        }

        if let model {
            args += ["--model", model]
        }

        if !allowedTools.isEmpty {
            args += ["--tools"] + [allowedTools.joined(separator: ",")]
            args += ["--allowedTools"] + allowedTools
        }

        if let maxTurns {
            args += ["--max-turns", String(maxTurns)]
        }

        if let systemPrompt {
            args += ["--system-prompt", systemPrompt]
        }

        if let appendSystemPrompt {
            args += ["--append-system-prompt", appendSystemPrompt]
        }

        if let permissionMode {
            args += ["--permission-mode", permissionMode]
        }

        if !additionalDirectories.isEmpty {
            args += ["--add-dir"] + additionalDirectories.map(\.path)
        }

        if !mcpConfigs.isEmpty {
            args += ["--mcp-config"] + mcpConfigs
        }

        return args
    }
}
