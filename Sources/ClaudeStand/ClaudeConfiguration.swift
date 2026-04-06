import Foundation

public enum ClaudeSettingSource: String, Sendable {
    case user
    case project
    case local
}

/// Configuration for a Claude Code session running via the embedded
/// BunProcess `cli.js` runtime on every supported Apple platform.
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

    /// Restrict Claude CLI settings loading to specific sources.
    public var settingSources: [ClaudeSettingSource]

    /// Ignore implicit MCP sources unless explicitly supplied via `mcpConfigs`.
    public var strictMCPConfig: Bool

    /// Disable slash commands and skill loading.
    public var disableSlashCommands: Bool

    /// Skip all permission checks.
    public var dangerouslySkipPermissions: Bool

    /// Policy used to install or update the Claude Code package.
    public var packageUpdatePolicy: ClaudePackagePolicy

    /// Enables verbose Claude CLI and runtime diagnostics.
    public var diagnosticsEnabled: Bool

    public init(
        workingDirectory: URL? = nil,
        model: String? = nil,
        allowedTools: [String] = ClaudeConfiguration.iPadTools,
        maxTurns: Int? = nil,
        systemPrompt: String? = nil,
        appendSystemPrompt: String? = nil,
        permissionMode: String? = nil,
        dangerouslySkipPermissions: Bool = true,
        packageUpdatePolicy: ClaudePackagePolicy = .checkOnStart,
        diagnosticsEnabled: Bool = false,
        additionalDirectories: [URL] = [],
        mcpConfigs: [String] = [],
        settingSources: [ClaudeSettingSource] = [],
        strictMCPConfig: Bool = false,
        disableSlashCommands: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.systemPrompt = systemPrompt
        self.appendSystemPrompt = appendSystemPrompt
        self.permissionMode = permissionMode
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
        self.packageUpdatePolicy = packageUpdatePolicy
        self.diagnosticsEnabled = diagnosticsEnabled
        self.additionalDirectories = additionalDirectories
        self.mcpConfigs = mcpConfigs
        self.settingSources = settingSources
        self.strictMCPConfig = strictMCPConfig
        self.disableSlashCommands = disableSlashCommands
    }

    /// iPad-safe tool preset — excludes Bash and other process-dependent tools.
    public static let iPadTools: [String] = [
        "Read", "Write", "Edit", "Glob", "Grep",
        "WebFetch", "WebSearch",
    ]

    var prefersInlinePromptTransport: Bool {
        true
    }

    /// Builds CLI arguments for the Claude Code CLI.
    ///
    /// BunProcess prepends `["node", bundlePath]` to form `process.argv`.
    /// This method returns the remaining arguments after the script path.
    func cliArguments(
        resumeToken: String? = nil,
        prompt: String? = nil
    ) -> [String] {
        // --print (-p) is a boolean flag that enables one-shot/print mode.
        // --input-format and --output-format only work with --print.
        // When a prompt is provided, it is passed as a positional argument.
        var args = ["-p"]

        if let prompt {
            args.append(prompt)
        }

        args += [
            "--output-format", "stream-json",
            "--verbose",
        ]

        if prompt == nil {
            args += ["--input-format", "stream-json"]
        }

        // --debug must come AFTER --input-format because Commander.js
        // defines --debug with an optional [filter] argument. If --debug
        // appears immediately before --input-format, Commander may
        // consume "--input-format" as the debug filter value, causing
        // the input format to be lost and the CLI to exit with
        // "Input must be provided" error.
        if diagnosticsEnabled {
            args.append("--debug")
        }

        if dangerouslySkipPermissions {
            args += ["--dangerously-skip-permissions"]
        }

        if let resumeToken {
            args += ["--resume", resumeToken]
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

        if !settingSources.isEmpty {
            args += ["--setting-sources", settingSources.map(\.rawValue).joined(separator: ",")]
        }

        if strictMCPConfig {
            args.append("--strict-mcp-config")
        }

        if disableSlashCommands {
            args.append("--disable-slash-commands")
        }

        return args
    }
}
