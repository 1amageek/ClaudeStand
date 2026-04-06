# ClaudeStand

A Swift package that runs Claude Code on Apple platforms, including iPad, exclusively through `swift-bun`.

## Overview

ClaudeStand has a single runtime path on every supported platform:

- iOS / iPadOS / visionOS / macOS: embed Claude Code's `cli.js` in JavaScriptCore via `swift-bun`

The public Swift API is the same on every platform. `ClaudeRuntime` starts a fresh Bun-backed `cli.js` process for each `send(...)`, then keeps logical conversation state in Swift so later turns can resume with the current session ID or an explicit resume token.

Authentication uses Claude subscription OAuth (Pro / Max), not API key billing. ClaudeStand prepares an isolated managed `HOME` with `.claude/.credentials.json` and strips env-based auth variables before launching the CLI.

By default, auth sources are platform-specific:
- macOS: valid managed credentials under `Application Support/ClaudeStand/auth/.credentials.json`, then valid cached runtime credentials under `Application Support/ClaudeStand/claude-home/.claude/.credentials.json`, then the shared Claude Code CLI Keychain entry
- iOS / iPadOS / visionOS: an app-owned managed credential store under `Application Support/ClaudeStand/auth/.credentials.json`

Stored OAuth credentials must include the Claude Code scopes, including `user:inference`. Credentials without scopes are treated as incomplete and rejected.

If you need to share auth/runtime state across an app, extension, or a custom container, provide an explicit `ClaudeStandStorageLocation` and use it for both `ManagedAuthSession` and `ClaudeRuntime`.

The `@anthropic-ai/claude-code` npm package is managed at runtime according to `ClaudePackagePolicy`. No manual bundling is required.

## Requirements

- iOS 26.0+ / iPadOS 26.0+ / macOS 26.0+
- Swift 6.2+
- Xcode 26.0+
- Claude Pro / Max subscription (OAuth)
- `swift-bun` is the only supported execution path. Native `claude` process execution is intentionally unsupported.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/ClaudeStand.git", branch: "main"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "ClaudeStand", package: "ClaudeStand"),
        ]
    ),
]
```

## Usage

### Basic

```swift
import ClaudeStand

let runtime = ClaudeRuntime(configuration: .init(
    workingDirectory: projectURL,
    model: "claude-sonnet-4-6"
))

let turn = try await runtime.send(prompt: "Fix the bug in ContentView.swift")

async let messages: Void = {
    for try await event in turn.messages {
        switch event {
        case .sessionStarted(let session):
            print("Session: \(session.sessionID)")
        case .assistantTextDelta(let text):
            print(text, terminator: "")
        case .assistantMessage(let message):
            print("\nMessage ID: \(message.messageID)")
        case .result(let result):
            print("\nDone: \(result.numTurns) turns, $\(result.totalCostUSD)")
        }
    }
}()

async let activity: Void = {
    for try await event in turn.activity {
        switch event {
        case .toolStarted(let tool):
            print("Tool started: \(tool.name)")
        case .toolUpdated(let tool):
            print("Tool input: \(tool.inputJSON)")
        case .toolFinished(let result):
            print("Tool finished: \(result.invocation.name)")
        case .protocolMismatch(let warning):
            print("Protocol mismatch: \(warning)")
        case .warning(let warning):
            print("Warning: \(warning)")
        case .diagnostic(let line):
            print("Diagnostic: \(line)")
        case .system:
            break
        }
    }
}()

_ = try await (messages, activity)
```

### With images

```swift
let imageData = try Data(contentsOf: screenshotURL)
let attachment = ImageAttachment(data: imageData, mediaType: .png)

let turn = try await runtime.send(prompt: "What's wrong with this UI?", images: [attachment])
for try await event in turn.messages {
    // ...
}
```

### Configuration

```swift
let config = ClaudeConfiguration(
    workingDirectory: projectURL,
    model: "claude-sonnet-4-6",
    allowedTools: ClaudeConfiguration.iPadTools,  // Default: excludes Bash
    maxTurns: 10,
    systemPrompt: "You are a Swift expert.",
    packageUpdatePolicy: .checkOnStart,
    dangerouslySkipPermissions: true
)
```

`ClaudeConfiguration.iPadTools` includes: `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch`, `WebSearch`.

`ClaudePackagePolicy`:
- `.manual`: use the cached package if present, download only when missing
- `.checkOnStart`: resolve the latest package at runtime start
- `.pinned(version:)`: always use a specific npm version

Resume is explicit. Pass `ClaudeConversationOptions(resumeToken:)` only when starting a new runtime or sending the first turn into an idle runtime. Once a runtime has observed a session ID, subsequent turns resume from that session automatically.

### iOS OAuth handoff

When your iOS or iPadOS app completes its own OAuth flow, persist the resulting tokens through `ManagedAuthSession` before starting `ClaudeRuntime`:

```swift
let auth = try ManagedAuthSession()
try await auth.storeCredentials(
    ClaudeOAuthCredentials(
        accessToken: oauthResult.accessToken,
        refreshToken: oauthResult.refreshToken,
        expiresAt: oauthResult.expiresAt,
        scopes: oauthResult.scopes
    )
)

let runtime = ClaudeRuntime(authenticator: auth)
let turn = try await runtime.send(prompt: "Summarize the current file")
```

### Shared storage location

Use an explicit storage root when your app wants ClaudeStand to keep both the managed credential store and runtime `HOME` in a shared container:

```swift
let location = ClaudeStandStorageLocation(rootDirectory: sharedContainerURL)
let auth = ManagedAuthSession(location: location)

try await auth.storeCredentials(
    ClaudeOAuthCredentials(
        accessToken: oauthResult.accessToken,
        refreshToken: oauthResult.refreshToken,
        expiresAt: oauthResult.expiresAt,
        scopes: oauthResult.scopes
    )
)

let runtime = ClaudeRuntime(
    authenticator: auth,
    storageLocation: location
)
let turn = try await runtime.send(prompt: "Summarize the current file")
```

## Architecture

```
ClaudeRuntime (actor)
  → ClaudeConversationRuntime
  → ClaudeActivityRuntime
  → ClaudeProcessSession (per turn)
    → CredentialSyncService
    → PackageManager
    → BunProcess(bundle: cli.js)
```

ClaudeStand uses [swift-bun](https://github.com/1amageek/swift-bun) to run Claude Code's JavaScript bundle directly in JavaScriptCore on every supported platform. All Node.js built-in modules (`fs`, `path`, `crypto`, `http`, `stream`, etc.) and Bun APIs are polyfilled. Network requests go through `URLSession` via the `fetch()` bridge.

Native process execution is intentionally not supported. If a platform cannot run the Bun-backed `cli.js` path correctly, that is treated as a runtime bug to fix rather than a reason to fall back to the installed `claude` binary.

## How it works

1. **`ClaudeRuntime`** creates a fresh `ClaudeProcessSession` for each `send(...)`.

2. **`CredentialSyncService`** prepares a managed runtime `HOME` and syncs `.claude/.credentials.json` by content hash.

3. **`PackageManager`** resolves `@anthropic-ai/claude-code` according to `ClaudePackagePolicy`.

4. **`ClaudeProcessSession`** launches `BunProcess(bundle: cli.js)` on every supported platform.

5. **`ClaudeConversationRuntime`** reduces raw protocol events into `ClaudeMessageEvent`.

6. **`ClaudeActivityRuntime`** reduces tool usage, diagnostics, warnings, and protocol anomalies into `ClaudeActivityEvent`.

## License

MIT
