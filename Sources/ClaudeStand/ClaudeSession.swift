import Foundation
import BunRuntime
import os.log

private let logger = Logger(subsystem: "com.claudestand", category: "Session")

/// Manages a conversation with Claude Code via BunRuntime (JavaScriptCore).
///
/// Claude Code's cli.js is loaded into a `BunContext` and executed directly.
/// Events stream from JavaScript to Swift via `BunContext.eventStream`.
/// Prompts (including images) are injected via `process.stdin` in the JS context.
public actor ClaudeSession {

    public let configuration: ClaudeConfiguration

    /// Session ID obtained from the first system/init event.
    public private(set) var sessionID: String?

    /// Session metadata from the most recent system/init event.
    public private(set) var metadata: SystemEvent?

    private let runtime: BunRuntime
    private let packageManager: PackageManager
    private var context: BunContext?
    private var isStarted: Bool = false

    public init(configuration: ClaudeConfiguration = ClaudeConfiguration()) {
        self.configuration = configuration
        self.runtime = BunRuntime()
        self.packageManager = PackageManager()
    }

    /// Start the session: download cli.js if needed, load into BunRuntime.
    ///
    /// Called automatically by `send()` if not already started.
    public func start() async throws {
        guard !isStarted else { return }

        let cliJSPath = try await packageManager.ensureInstalled()
        logger.info("cli.js ready at \(cliJSPath.path, privacy: .public)")

        let ctx = try await runtime.createContext()

        // Set working directory
        let cwd = configuration.workingDirectory?.path ?? FileManager.default.currentDirectoryPath
        try await ctx.evaluate(js: "process.cwd = function() { return \(escapeJS(cwd)); };")

        // Set process.argv to simulate CLI invocation
        let argv = configuration.processArgv(resumeSessionID: sessionID)
        let argvJSON = try String(data: JSONSerialization.data(withJSONObject: argv), encoding: .utf8) ?? "[]"
        try await ctx.evaluate(js: "process.argv = \(argvJSON);")

        // Redirect stdout.write to __emitEvent for NDJSON streaming
        try await ctx.evaluate(js: """
            process.stdout.write = function(chunk) {
                var str = typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk);
                var lines = str.split('\\n');
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].trim().length > 0) {
                        __emitEvent(lines[i]);
                    }
                }
                return true;
            };
        """)

        // Create a writable stdin stream that we control
        try await ctx.evaluate(js: """
            var __stdinBuffer = [];
            var __stdinWaiting = null;
            process.stdin = {
                isTTY: false,
                on: function(event, cb) {
                    if (event === 'data') {
                        this._onData = cb;
                        // Flush buffered data
                        while (__stdinBuffer.length > 0) {
                            cb(__stdinBuffer.shift());
                        }
                    }
                    if (event === 'end') this._onEnd = cb;
                    return this;
                },
                resume: function() { return this; },
                pause: function() { return this; },
                setEncoding: function() { return this; },
                read: function() { return __stdinBuffer.shift() || null; },
                [Symbol.asyncIterator]: function() {
                    var self = this;
                    return {
                        next: function() {
                            return new Promise(function(resolve) {
                                if (__stdinBuffer.length > 0) {
                                    resolve({ value: __stdinBuffer.shift(), done: false });
                                } else {
                                    __stdinWaiting = resolve;
                                }
                            });
                        }
                    };
                }
            };
            globalThis.__pushStdin = function(data) {
                if (process.stdin._onData) {
                    process.stdin._onData(data);
                } else if (__stdinWaiting) {
                    var resolve = __stdinWaiting;
                    __stdinWaiting = null;
                    resolve({ value: data, done: false });
                } else {
                    __stdinBuffer.push(data);
                }
            };
        """)

        // Load cli.js
        let ctx2 = try await runtime.load(bundle: cliJSPath)
        self.context = ctx2
        isStarted = true
        logger.info("Session started with BunRuntime")
    }

    /// Send a text prompt and receive a stream of events.
    public func send(_ prompt: String) async -> AsyncThrowingStream<StreamEvent, Error> {
        await sendMessage(prompt: prompt, images: [])
    }

    /// Send a prompt with images and receive a stream of events.
    public func send(_ prompt: String, images: [ImageAttachment]) async -> AsyncThrowingStream<StreamEvent, Error> {
        await sendMessage(prompt: prompt, images: images)
    }

    /// Cancel and shut down the session.
    public func cancel() async {
        await context?.shutdown()
        context = nil
        isStarted = false
    }

    /// Shutdown the session.
    public func shutdown() async {
        await context?.shutdown()
        context = nil
        isStarted = false
        sessionID = nil
        metadata = nil
        logger.info("Session shutdown")
    }

    // MARK: - Private

    private func sendMessage(prompt: String, images: [ImageAttachment]) async -> AsyncThrowingStream<StreamEvent, Error> {
        let builder = SDKUserMessageBuilder()
        let messageData: Data
        do {
            messageData = try builder.build(prompt: prompt, images: images, sessionID: sessionID)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        guard let ctx = context else {
            return AsyncThrowingStream { $0.finish(throwing: SessionError.notStarted) }
        }

        // Push the SDKUserMessage into JS stdin
        let messageString = String(data: messageData, encoding: .utf8) ?? ""
        do {
            try await ctx.evaluate(js: "__pushStdin(\(escapeJS(messageString)));")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        // Return a stream that reads from BunContext.eventStream and parses events
        let eventStream = await ctx.eventStream
        let parser = StreamEventParser()

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                for await line in eventStream {
                    if Task.isCancelled { break }
                    guard !line.isEmpty else { continue }

                    let event: StreamEvent
                    do {
                        event = try parser.parse(line)
                    } catch {
                        if case StreamEventParser.ParserError.ignoredType = error {
                            continue
                        }
                        logger.warning("Unparseable line: \(line.prefix(200), privacy: .public)")
                        continue
                    }

                    switch event {
                    case .system(let sys):
                        await self?.updateMetadata(sys)
                    case .result(let res):
                        logger.info("[claude] done turns=\(res.numTurns) cost=$\(String(format: "%.4f", res.totalCostUSD)) duration=\(res.durationMS)ms")
                    default:
                        break
                    }

                    continuation.yield(event)

                    if case .result = event {
                        continuation.finish()
                        return
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func updateMetadata(_ event: SystemEvent) {
        sessionID = event.sessionID
        metadata = event
    }

    private func escapeJS(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    // MARK: - Errors

    public enum SessionError: Error, LocalizedError {
        case notStarted
        case deallocated

        public var errorDescription: String? {
            switch self {
            case .notStarted:
                "Session not started. Call start() before send()."
            case .deallocated:
                "Session was deallocated during operation."
            }
        }
    }
}
