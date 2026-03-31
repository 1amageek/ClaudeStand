import Testing
@testable import ClaudeStand

@Suite("ClaudeConfiguration")
struct ClaudeConfigurationTests {

    @Test("Default configuration uses iPad tools")
    func defaultConfig() {
        let config = ClaudeConfiguration()
        #expect(config.allowedTools == ClaudeConfiguration.iPadTools)
        #expect(config.dangerouslySkipPermissions == true)
        #expect(config.model == nil)
        #expect(config.maxTurns == nil)
        #expect(config.workingDirectory == nil)
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

    @Test("processArgv starts with node claude -p")
    func processArgvPrefix() {
        let config = ClaudeConfiguration()
        let argv = config.processArgv()
        #expect(argv[0] == "node")
        #expect(argv[1] == "claude")
        #expect(argv[2] == "-p")
    }

    @Test("processArgv includes stream-json flags")
    func processArgvStreamJson() {
        let config = ClaudeConfiguration()
        let argv = config.processArgv()
        #expect(argv.contains("--input-format"))
        #expect(argv.contains("stream-json"))
        #expect(argv.contains("--output-format"))
        #expect(argv.contains("--verbose"))
    }

    @Test("processArgv includes model when set")
    func processArgvModel() {
        var config = ClaudeConfiguration()
        config.model = "claude-sonnet-4-6"
        let argv = config.processArgv()
        #expect(argv.contains("--model"))
        #expect(argv.contains("claude-sonnet-4-6"))
    }

    @Test("processArgv includes resume session ID")
    func processArgvResume() {
        let config = ClaudeConfiguration()
        let argv = config.processArgv(resumeSessionID: "session-abc")
        #expect(argv.contains("--resume"))
        #expect(argv.contains("session-abc"))
    }

    @Test("processArgv includes max turns")
    func processArgvMaxTurns() {
        var config = ClaudeConfiguration()
        config.maxTurns = 5
        let argv = config.processArgv()
        #expect(argv.contains("--max-turns"))
        #expect(argv.contains("5"))
    }

    @Test("processArgv includes --tools and --allowedTools")
    func processArgvTools() {
        var config = ClaudeConfiguration()
        config.allowedTools = ["Read", "Edit"]
        let argv = config.processArgv()

        let toolsIndex = argv.firstIndex(of: "--tools")!
        #expect(argv[toolsIndex + 1] == "Read,Edit")

        #expect(argv.contains("--allowedTools"))
        #expect(argv.contains("Read"))
        #expect(argv.contains("Edit"))
    }

    @Test("processArgv --tools uses comma-separated format")
    func processArgvToolsFormat() {
        let config = ClaudeConfiguration()
        let argv = config.processArgv()
        let toolsIndex = argv.firstIndex(of: "--tools")!
        let toolsValue = argv[toolsIndex + 1]
        #expect(toolsValue.contains(","))
        #expect(!toolsValue.contains("Bash"))
    }

    @Test("processArgv includes system prompt")
    func processArgvSystemPrompt() {
        var config = ClaudeConfiguration()
        config.systemPrompt = "You are a Swift expert."
        let argv = config.processArgv()
        #expect(argv.contains("--system-prompt"))
        #expect(argv.contains("You are a Swift expert."))
    }

    @Test("processArgv includes append system prompt")
    func processArgvAppendSystemPrompt() {
        var config = ClaudeConfiguration()
        config.appendSystemPrompt = "Always use TypeScript."
        let argv = config.processArgv()
        #expect(argv.contains("--append-system-prompt"))
        #expect(argv.contains("Always use TypeScript."))
    }

    @Test("processArgv skip permissions when enabled")
    func processArgvSkipPermissions() {
        var config = ClaudeConfiguration()
        config.dangerouslySkipPermissions = true
        #expect(config.processArgv().contains("--dangerously-skip-permissions"))

        config.dangerouslySkipPermissions = false
        #expect(!config.processArgv().contains("--dangerously-skip-permissions"))
    }
}
