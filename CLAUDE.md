# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build
xcodebuild build -scheme ClaudeStand -destination 'generic/platform=iOS'
xcodebuild build -scheme ClaudeStand -destination 'platform=macOS'

# Test (always use xcodebuild, never swift test)
xcodebuild test -scheme ClaudeStand -destination 'platform=macOS' -maximum-test-execution-time-allowance 120

# Test with filter
xcodebuild test -scheme ClaudeStand -destination 'platform=macOS' -only-testing 'ClaudeStandTests/SuiteName/testName' -maximum-test-execution-time-allowance 120
```

## Architecture

ClaudeStand runs Claude Code on iPad/iOS via `swift-bun` (BunRuntime) — a JavaScriptCore-based runtime with Node.js/Bun polyfills. No external JS runtime (Node.js, Bun binary) is needed. JSC is native to every Apple platform.

```
ClaudeSession (actor)
  → BunRuntime.load(cli.js)
    → BunContext (JSContext + Node.js/Bun polyfills)
      → cli.js (@anthropic-ai/claude-code)
        → fetch() → URLSession → Anthropic API
```

### Key components

- **ClaudeSession** (actor) — Public API. `send(prompt)` / `send(prompt, images:)` → `AsyncThrowingStream<StreamEvent, Error>`. Manages sessionID for multi-turn. Pushes SDKUserMessage to JS stdin, reads events from `BunContext.eventStream`.
- **BunRuntime / BunContext** (from `swift-bun`) — Loads cli.js into JSContext with full Node.js/Bun compatibility. `__emitEvent` bridges stdout to Swift `AsyncStream`. `fetch()` bridges to `URLSession`.
- **PackageManager** (actor) — Downloads `@anthropic-ai/claude-code` from npm registry at runtime (~17MB tarball). Zero production dependencies — no `npm install` needed. Caches in `Library/Caches/claude-code/`. Auto-updates.
- **ClaudeConfiguration** — Model, workingDirectory, allowedTools, maxTurns, systemPrompt, etc. `iPadTools` preset excludes Bash. `processArgv()` builds `process.argv` array.
- **StreamEvent / StreamEventParser** — Parses NDJSON lines into typed events (system, streamEvent, assistant, result).
- **SDKUserMessageBuilder** — Builds `SDKUserMessage` JSON with text and image content blocks.
- **AuthSession** (actor) — OAuth via `ASWebAuthenticationSession`. Tokens in Keychain `"Claude Code-credentials"`.

### IPC protocol

No IPC needed. JavaScript runs in-process via JavaScriptCore.

- **Swift → JS**: `__pushStdin(data)` injects SDKUserMessage JSON into the CLI's simulated stdin
- **JS → Swift**: `process.stdout.write` → `__emitEvent` → `BunContext.eventStream` → `StreamEventParser`

### Image support

SDKUserMessage content blocks with base64-encoded images:
```json
{"type":"user","message":{"role":"user","content":[
  {"type":"text","text":"Analyze this"},
  {"type":"image","source":{"type":"base64","media_type":"image/png","data":"<b64>"}}
]}}
```

### Design constraints

- OAuth only — no API key support
- Claude Code tools run in JSC — Bash excluded via `--tools`, file tools use polyfilled `node:fs`
- `--tools` restricts available tools, `--allowedTools` auto-approves them
- cli.js downloaded at runtime from npm registry (auto-update)

## Platforms

- iOS 26+ / iPadOS 26+ / macOS 26+
- Swift 6.2+

## Dependencies

- `swift-bun` (`BunRuntime`) — JavaScriptCore + Node.js/Bun polyfills
- `@anthropic-ai/claude-code` — downloaded at runtime from npm registry
