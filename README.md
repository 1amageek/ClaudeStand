# ClaudeStand

A Swift package that runs Claude Code standalone on Apple platforms, including iPad.

## Overview

ClaudeStand embeds Claude Code's JavaScript bundle and executes it directly via JavaScriptCore — which ships natively on every Apple platform. No Node.js, no Bun binary, no remote host required.

Authentication uses Claude subscription OAuth (Pro / Max), not API key billing.

The `@anthropic-ai/claude-code` npm package is downloaded automatically at runtime and kept up to date — no manual bundling or app rebuilds needed when Claude Code releases a new version.

## Requirements

- iOS 26.0+ / iPadOS 26.0+ / macOS 26.0+
- Swift 6.2+
- Xcode 26.0+
- Claude Pro / Max subscription (OAuth)

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

let session = ClaudeSession(configuration: .init(
    workingDirectory: projectURL,
    model: "claude-sonnet-4-6"
))

try await session.start()

for try await event in await session.send("Fix the bug in ContentView.swift") {
    switch event {
    case .system(let sys):
        print("Session: \(sys.sessionID)")
    case .streamEvent(let delta):
        if case .textDelta(_, let text) = delta.event {
            print(text, terminator: "")
        }
    case .assistant(let msg):
        for block in msg.content {
            if case .text(let text) = block {
                print(text)
            }
        }
    case .result(let result):
        print("\nDone: \(result.numTurns) turns, $\(result.totalCostUSD)")
    }
}
```

### With images

```swift
let imageData = try Data(contentsOf: screenshotURL)
let attachment = ImageAttachment(data: imageData, mediaType: .png)

for try await event in await session.send("What's wrong with this UI?", images: [attachment]) {
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
    dangerouslySkipPermissions: true
)
```

`ClaudeConfiguration.iPadTools` includes: `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch`, `WebSearch`.

## Architecture

```
ClaudeSession (actor)
  → BunRuntime.load(cli.js)
    → BunContext (JSContext + Node.js/Bun polyfills)
      → cli.js (@anthropic-ai/claude-code)
        → fetch() → URLSession → Anthropic API
```

ClaudeStand uses [swift-bun](https://github.com/1amageek/swift-bun) to run Claude Code's JavaScript bundle directly in JavaScriptCore. All Node.js built-in modules (`fs`, `path`, `crypto`, `http`, `stream`, etc.) and Bun APIs are polyfilled. Network requests go through `URLSession` via the `fetch()` bridge.

No external JavaScript runtime is embedded — JavaScriptCore is already part of every Apple OS.

## How it works

1. **`PackageManager`** downloads `@anthropic-ai/claude-code` from the npm registry (~17MB) and caches it in `Library/Caches/`. Auto-updates when a new version is available.

2. **`BunRuntime`** (from swift-bun) loads `cli.js` into a `JSContext` with full Node.js/Bun compatibility polyfills.

3. **`ClaudeSession`** sets up `process.argv` to simulate `claude -p --input-format stream-json --output-format stream-json --verbose`, then injects prompts via a simulated `process.stdin`.

4. CLI output flows through `process.stdout.write` → `__emitEvent` → `BunContext.eventStream` → `StreamEventParser` → typed `StreamEvent` values yielded to the caller.

## License

MIT
