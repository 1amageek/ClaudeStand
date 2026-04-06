import Foundation
import BunRuntime
import os.log

struct ClaudeProcessExit: Sendable, Equatable {
    let exitCode: Int32?
    let message: String
}

struct ClaudeProcessStreams: Sendable {
    let stdout: AsyncStream<String>
    let diagnostics: AsyncStream<String>
    let exits: AsyncStream<ClaudeProcessExit>
}

protocol ClaudeProcessControlling: Sendable {
    var stdout: AsyncStream<String> { get }
    var diagnostics: AsyncStream<String> { get }

    func run() async throws -> Int32
    func sendInput(_ data: Data?)
    func terminate(exitCode: Int32)
    func shutdown() async throws
}

extension BunProcess: ClaudeProcessControlling {
    var diagnostics: AsyncStream<String> { output }
}

protocol ClaudePackageInstalling: Sendable {
    func resolveCLIPath(policy: ClaudePackagePolicy) async throws -> URL
}

extension PackageManager: ClaudePackageInstalling {}

protocol ClaudeProcessSessioning: Sendable {
    func start(resumeToken: String?, prompt: String?, stdinPayload: Data?) async throws -> ClaudeProcessStreams
    func terminate(exitCode: Int32) async
    func shutdown() async
}

actor ClaudeProcessSession: ClaudeProcessSessioning {
    typealias ProcessFactory = @Sendable (URL, ClaudeConfiguration, ClaudeRuntimeHome, String?, String?) -> any ClaudeProcessControlling

    private struct LaunchContext: Sendable {
        let cliPath: URL
        let runtimeHome: ClaudeRuntimeHome
        let workingDirectory: String
        let inlinePrompt: Bool
        let promptCharacters: Int
        let hasResumeToken: Bool
    }

    private let configuration: ClaudeConfiguration
    private let authenticator: any ClaudeAuthenticating
    private let packageManager: any ClaudePackageInstalling
    private let storageLocation: ClaudeStandStorageLocation
    private let processFactory: ProcessFactory
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.claudestand", category: "ProcessSession")

    private var process: (any ClaudeProcessControlling)?
    private var runTask: Task<Void, Never>?
    private var exitContinuation: AsyncStream<ClaudeProcessExit>.Continuation?
    private var diagnosticsContinuation: AsyncStream<String>.Continuation?
    private var diagnosticsForwardTask: Task<Void, Never>?
    private var diagnosticsFile: URL?
    private var launchContext: LaunchContext?

    init(
        configuration: ClaudeConfiguration,
        authenticator: any ClaudeAuthenticating,
        storageLocation: ClaudeStandStorageLocation?,
        packageManager: any ClaudePackageInstalling = PackageManager(),
        processFactory: @escaping ProcessFactory = ClaudeProcessSession.defaultProcessFactory,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.authenticator = authenticator
        self.storageLocation = storageLocation ?? (try? ClaudeStandStorageLocation.applicationSupport(fileManager: fileManager))
            ?? ClaudeStandStorageLocation(rootDirectory: fileManager.temporaryDirectory.appendingPathComponent("ClaudeStand", isDirectory: true))
        self.packageManager = packageManager
        self.processFactory = processFactory
        self.fileManager = fileManager
    }

    func start(resumeToken: String?, prompt: String?, stdinPayload: Data? = nil) async throws -> ClaudeProcessStreams {
        let cliPath = try await packageManager.resolveCLIPath(policy: configuration.packageUpdatePolicy)
        let credentialStoreData = try await authenticator.credentialStoreData()
        let syncService = CredentialSyncService(location: storageLocation, fileManager: fileManager)
        let syncResult = try syncService.sync(credentialStoreData: credentialStoreData)
        let runtimeHome = syncResult.runtimeHome
        let diagnosticsFile = runtimeHome.diagnosticsFile
        if fileManager.fileExists(atPath: diagnosticsFile.path) {
            try fileManager.removeItem(at: diagnosticsFile)
        }
        logInfo(
            "start process kind=\(Self.processKind) cli=\(cliPath.path) cwd=\(self.configuration.workingDirectory?.path ?? self.fileManager.currentDirectoryPath) inlinePrompt=\((prompt != nil).description) promptChars=\(prompt?.count ?? 0) resumeToken=\((resumeToken != nil).description) stdinPayload=\(stdinPayload?.count ?? 0)bytes"
        )
        let process = processFactory(cliPath, configuration, runtimeHome, resumeToken, prompt)

        // Queue stdin data BEFORE starting the process. BunProcess.run()
        // drains pre-queued stdin immediately after JS context setup,
        // ensuring data is buffered before the CLI's async init reads it.
        if let stdinPayload {
            logInfo("pre-queue stdin payloadBytes=\(stdinPayload.count)")
            process.sendInput(stdinPayload)
            process.sendInput(nil)
            logInfo("pre-queue stdin eof")
        }

        var exitContinuation: AsyncStream<ClaudeProcessExit>.Continuation?
        let exits = AsyncStream<ClaudeProcessExit> { continuation in
            exitContinuation = continuation
        }
        guard let exitContinuation else {
            throw ClaudeRuntimeError.streamSetupFailed
        }

        var diagnosticsContinuation: AsyncStream<String>.Continuation?
        let diagnostics = AsyncStream<String> { continuation in
            diagnosticsContinuation = continuation
        }
        guard let diagnosticsContinuation else {
            throw ClaudeRuntimeError.streamSetupFailed
        }

        self.process = process
        self.exitContinuation = exitContinuation
        self.diagnosticsContinuation = diagnosticsContinuation
        self.diagnosticsFile = diagnosticsFile
        self.launchContext = LaunchContext(
            cliPath: cliPath,
            runtimeHome: runtimeHome,
            workingDirectory: self.configuration.workingDirectory?.path ?? self.fileManager.currentDirectoryPath,
            inlinePrompt: prompt != nil,
            promptCharacters: prompt?.count ?? 0,
            hasResumeToken: resumeToken != nil
        )
        emitLaunchDiagnostics()
        self.diagnosticsForwardTask = Task { [weak self] in
            for await line in process.diagnostics {
                await self?.yieldDiagnostic(line)
            }
        }
        self.runTask = Task {
            do {
                let exitCode = try await process.run()
                self.finishRun(exitCode: exitCode, error: nil)
            } catch {
                self.finishRun(exitCode: nil, error: error)
            }
        }

        return ClaudeProcessStreams(stdout: process.stdout, diagnostics: diagnostics, exits: exits)
    }

    func terminate(exitCode: Int32) async {
        logInfo("terminate requested exitCode=\(exitCode)")
        process?.terminate(exitCode: exitCode)
    }

    func shutdown() async {
        logInfo("shutdown requested hasRunTask=\((self.runTask != nil).description) hasProcess=\((self.process != nil).description)")
        await terminate(exitCode: 0)
        if let runTask {
            await runTask.value
        } else if let process {
            do {
                try await process.shutdown()
            } catch {
            }
        }
        diagnosticsForwardTask?.cancel()
        diagnosticsForwardTask = nil
        self.runTask = nil
        self.process = nil
    }

    private func finishRun(exitCode: Int32?, error: Error?) {
        let message = Self.buildExitMessage(exitCode: exitCode, error: error)
        emitExitDiagnostics(exitCode: exitCode, error: error)
        if shouldEmitDiagnosticsFile(exitCode: exitCode, error: error) {
            emitDiagnosticsFileContentsIfAvailable()
        }
        logInfo("finishRun exitCode=\(String(describing: exitCode)) message=\(message)")
        exitContinuation?.yield(ClaudeProcessExit(exitCode: exitCode, message: message))
        exitContinuation?.finish()
        exitContinuation = nil
        diagnosticsContinuation?.finish()
        diagnosticsContinuation = nil
        diagnosticsForwardTask?.cancel()
        diagnosticsForwardTask = nil
        diagnosticsFile = nil
        launchContext = nil
        process = nil
        runTask = nil
    }

    private static func defaultProcessFactory(
        cliJSPath: URL,
        configuration: ClaudeConfiguration,
        runtimeHome: ClaudeRuntimeHome,
        resumeToken: String?,
        prompt: String?
    ) -> any ClaudeProcessControlling {
        let launch = makeLaunchEnvironment(for: runtimeHome)
        return BunProcess(
            bundle: cliJSPath,
            arguments: configuration.cliArguments(resumeToken: resumeToken, prompt: prompt),
            cwd: configuration.workingDirectory?.path ?? FileManager.default.currentDirectoryPath,
            environment: launch.environment,
            removedEnvironmentKeys: launch.removedEnvironmentKeys,
            diagnosticsEnabled: configuration.diagnosticsEnabled
        )
    }

    static func makeLaunchEnvironment(for runtimeHome: ClaudeRuntimeHome) -> (
        environment: [String: String],
        removedEnvironmentKeys: Set<String>
    ) {
        (
            environment: [
                "HOME": runtimeHome.homeDirectory.path,
                "CLAUDE_CODE_DIAGNOSTICS_FILE": runtimeHome.diagnosticsFile.path,
            ],
            removedEnvironmentKeys: ClaudeRuntimeHome.removedEnvironmentKeys
        )
    }

    private static func buildExitMessage(exitCode: Int32?, error: Error?) -> String {
        var parts: [String] = []
        if let exitCode {
            parts.append("cli.js exited with code \(exitCode)")
        }
        if let error {
            parts.append("error: \(error.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    private static let processKind = "bun"

    private func shouldEmitDiagnosticsFile(exitCode: Int32?, error: Error?) -> Bool {
        if configuration.diagnosticsEnabled {
            return true
        }
        if error != nil {
            return true
        }
        guard let exitCode else {
            return false
        }
        return exitCode != 0
    }

    private func logInfo(_ message: String) {
        guard configuration.diagnosticsEnabled else {
            return
        }
        logger.info("\(message, privacy: .public)")
    }

    private func yieldDiagnostic(_ line: String) {
        diagnosticsContinuation?.yield(line)
    }

    private func emitLaunchDiagnostics() {
        guard let launchContext else {
            return
        }

        emitForcedDiagnostic(
            "[claudestand:process] launch cli=\(launchContext.cliPath.path) cwd=\(launchContext.workingDirectory) inlinePrompt=\(launchContext.inlinePrompt) promptChars=\(launchContext.promptCharacters) resumeToken=\(launchContext.hasResumeToken)"
        )
        emitForcedDiagnostic(
            "[claudestand:process] runtimeHome=\(launchContext.runtimeHome.homeDirectory.path) claudeDir=\(launchContext.runtimeHome.claudeDirectory.path)"
        )
        emitForcedDiagnostic(
            "[claudestand:process] files diagnostics=\(launchContext.runtimeHome.diagnosticsFile.path) authCredentialsExists=\(fileManager.fileExists(atPath: storageLocation.credentialsFile.path)) runtimeCredentialsExists=\(fileManager.fileExists(atPath: storageLocation.runtimeCredentialsFile.path))"
        )
    }

    private func emitExitDiagnostics(exitCode: Int32?, error: Error?) {
        guard shouldEmitDiagnosticsFile(exitCode: exitCode, error: error) else {
            return
        }

        if let launchContext {
            let settingsFile = launchContext.runtimeHome.claudeDirectory
                .appendingPathComponent("settings.json", isDirectory: false)
            let pluginsFile = launchContext.runtimeHome.claudeDirectory
                .appendingPathComponent("installed_plugins.json", isDirectory: false)
            emitForcedDiagnostic(
                "[claudestand:process] exitSummary cli=\(launchContext.cliPath.lastPathComponent) exitCode=\(String(describing: exitCode)) error=\(error?.localizedDescription ?? "<none>")"
            )
            emitForcedDiagnostic(
                "[claudestand:process] diagnosticsExists=\(fileManager.fileExists(atPath: launchContext.runtimeHome.diagnosticsFile.path)) settingsExists=\(fileManager.fileExists(atPath: settingsFile.path)) pluginsExists=\(fileManager.fileExists(atPath: pluginsFile.path))"
            )
        } else {
            emitForcedDiagnostic(
                "[claudestand:process] exitSummary exitCode=\(String(describing: exitCode)) error=\(error?.localizedDescription ?? "<none>") launchContext=<missing>"
            )
        }
    }

    private func emitForcedDiagnostic(_ message: String) {
        if configuration.diagnosticsEnabled {
            logger.info("\(message, privacy: .public)")
        }
        diagnosticsContinuation?.yield(message)
    }

    private func emitDiagnosticsFileContentsIfAvailable() {
        guard let diagnosticsFile else {
            let message = "[claude-code:diag] diagnostics file unavailable"
            logInfo(message)
            diagnosticsContinuation?.yield(message)
            return
        }
        guard fileManager.fileExists(atPath: diagnosticsFile.path) else {
            let message = "[claude-code:diag] diagnostics file missing path=\(diagnosticsFile.path)"
            logInfo(message)
            diagnosticsContinuation?.yield(message)
            return
        }

        do {
            let contents = try String(contentsOf: diagnosticsFile, encoding: .utf8)
            if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let message = "[claude-code:diag] diagnostics file empty path=\(diagnosticsFile.path)"
                logInfo(message)
                diagnosticsContinuation?.yield(message)
                return
            }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let formatted = "[claude-code:diag] \(line)"
                logInfo(formatted)
                diagnosticsContinuation?.yield(formatted)
            }
        } catch {
            let message = "[claude-code:diag] failed to read diagnostics file error=\(error.localizedDescription)"
            if configuration.diagnosticsEnabled {
                logger.error("\(message, privacy: .public)")
            }
            diagnosticsContinuation?.yield(message)
        }
    }
}
