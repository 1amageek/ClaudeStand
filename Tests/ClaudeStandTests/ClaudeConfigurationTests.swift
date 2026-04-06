import Testing
@testable import ClaudeStand

@Suite("ClaudeConfiguration")
struct ClaudeConfigurationTests {

    @Test("Default configuration uses iPad tools")
    func defaultConfig() {
        let config = ClaudeConfiguration()
        #expect(config.allowedTools == ClaudeConfiguration.iPadTools)
        #expect(config.dangerouslySkipPermissions == true)
        #expect(config.packageUpdatePolicy == .checkOnStart)
        #expect(config.diagnosticsEnabled == false)
        #expect(config.model == nil)
        #expect(config.maxTurns == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.settingSources.isEmpty)
        #expect(config.strictMCPConfig == false)
        #expect(config.disableSlashCommands == false)
    }

    @Test("text-only prompts prefer inline transport")
    func inlineTransportPreferred() {
        let config = ClaudeConfiguration()
        #expect(config.prefersInlinePromptTransport == true)
    }

    @Test("iPad tools exclude Bash")
    func iPadToolsNoBash() {
        let tools = ClaudeConfiguration.iPadTools
        #expect(!tools.contains("Bash"))
        #expect(tools.contains("Read"))
        #expect(tools.contains("Write"))
        #expect(tools.contains("Edit"))
        #expect(tools.contains("Glob"))
        #expect(tools.contains("Grep"))
    }

    @Test("cliArguments starts with -p")
    func cliArgumentsPrefix() {
        let config = ClaudeConfiguration()
        let argv = config.cliArguments()
        #expect(argv[0] == "-p")
    }

    @Test("cliArguments includes stream-json flags")
    func cliArgumentsStreamJson() {
        let config = ClaudeConfiguration()
        let argv = config.cliArguments()
        #expect(argv.contains("--input-format"))
        #expect(argv.contains("stream-json"))
        #expect(argv.contains("--output-format"))
        // --verbose is always present for structured output parsing.
        #expect(argv.contains("--verbose"))
        // --debug is only present when diagnosticsEnabled is true.
        #expect(!argv.contains("--debug"))
    }

    @Test("cliArguments includes verbose flags only when diagnostics are enabled")
    func cliArgumentsVerboseWhenDiagnosticsEnabled() {
        let config = ClaudeConfiguration(diagnosticsEnabled: true)
        let argv = config.cliArguments()
        #expect(argv.contains("--verbose"))
        #expect(argv.contains("--debug"))
    }

    @Test("cliArguments omits input-format when prompt is inline")
    func cliArgumentsInlinePrompt() {
        let config = ClaudeConfiguration()
        let argv = config.cliArguments(prompt: "hello")
        #expect(!argv.contains("--input-format"))
        #expect(argv.starts(with: ["-p", "hello"]))
    }

    @Test("cliArguments includes model when set")
    func cliArgumentsModel() {
        var config = ClaudeConfiguration()
        config.model = "claude-sonnet-4-6"
        let argv = config.cliArguments()
        #expect(argv.contains("--model"))
        #expect(argv.contains("claude-sonnet-4-6"))
    }

    @Test("cliArguments includes resume token")
    func cliArgumentsResume() {
        let config = ClaudeConfiguration()
        let argv = config.cliArguments(resumeToken: "session-abc")
        #expect(argv.contains("--resume"))
        #expect(argv.contains("session-abc"))
    }

    @Test("cliArguments includes max turns")
    func cliArgumentsMaxTurns() {
        var config = ClaudeConfiguration()
        config.maxTurns = 5
        let argv = config.cliArguments()
        #expect(argv.contains("--max-turns"))
        #expect(argv.contains("5"))
    }

    @Test("cliArguments includes --tools and --allowedTools")
    func cliArgumentsTools() {
        var config = ClaudeConfiguration()
        config.allowedTools = ["Read", "Edit"]
        let argv = config.cliArguments()

        let toolsIndex = argv.firstIndex(of: "--tools")!
        #expect(argv[toolsIndex + 1] == "Read,Edit")

        #expect(argv.contains("--allowedTools"))
        #expect(argv.contains("Read"))
        #expect(argv.contains("Edit"))
    }

    @Test("cliArguments --tools uses comma-separated format")
    func cliArgumentsToolsFormat() {
        let config = ClaudeConfiguration()
        let argv = config.cliArguments()
        let toolsIndex = argv.firstIndex(of: "--tools")!
        let toolsValue = argv[toolsIndex + 1]
        #expect(toolsValue.contains(","))
        #expect(!toolsValue.contains("Bash"))
    }

    @Test("cliArguments includes system prompt")
    func cliArgumentsSystemPrompt() {
        var config = ClaudeConfiguration()
        config.systemPrompt = "You are a Swift expert."
        let argv = config.cliArguments()
        #expect(argv.contains("--system-prompt"))
        #expect(argv.contains("You are a Swift expert."))
    }

    @Test("cliArguments includes append system prompt")
    func cliArgumentsAppendSystemPrompt() {
        var config = ClaudeConfiguration()
        config.appendSystemPrompt = "Always use TypeScript."
        let argv = config.cliArguments()
        #expect(argv.contains("--append-system-prompt"))
        #expect(argv.contains("Always use TypeScript."))
    }

    @Test("cliArguments skip permissions when enabled")
    func cliArgumentsSkipPermissions() {
        var config = ClaudeConfiguration()
        config.dangerouslySkipPermissions = true
        #expect(config.cliArguments().contains("--dangerously-skip-permissions"))

        config.dangerouslySkipPermissions = false
        #expect(!config.cliArguments().contains("--dangerously-skip-permissions"))
    }

    @Test("cliArguments includes setting source filters")
    func cliArgumentsSettingSources() {
        let config = ClaudeConfiguration(settingSources: [.user, .local])
        let argv = config.cliArguments()
        let index = argv.firstIndex(of: "--setting-sources")
        #expect(index != nil)
        #expect(argv[index! + 1] == "user,local")
    }

    @Test("cliArguments includes strict MCP and slash command flags")
    func cliArgumentsStrictFlags() {
        let config = ClaudeConfiguration(
            strictMCPConfig: true,
            disableSlashCommands: true
        )
        let argv = config.cliArguments()
        #expect(argv.contains("--strict-mcp-config"))
        #expect(argv.contains("--disable-slash-commands"))
    }
}
