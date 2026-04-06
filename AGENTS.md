# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

ClaudeStand uses a single process layer on every platform:

- iOS / iPadOS / visionOS / macOS: `BunProcess` runs `cli.js` inside JavaScriptCore via `swift-bun`

`ClaudeRuntime` is process-per-turn. Each `send(...)` creates a fresh `ClaudeProcessSession`, while Swift-owned reducers preserve logical conversation state and resume semantics across turns.

```
ClaudeRuntime (actor)
    → ClaudeConversationRuntime
  → ClaudeActivityRuntime
  → ClaudeProcessSession (per turn)
    → CredentialSyncService
    → PackageManager
    → BunProcess(bundle: cli.js)
```

### Key components

- **ClaudeRuntime** (actor) — Public API. `send(prompt:images:options:)` returns `ClaudeTurnHandle` with independent `messages` and `activity` streams.
- **ClaudeProcessSession** — Resolves package policy, syncs managed credentials into runtime `HOME`, and owns raw stdout/diagnostic/exit streams for a single turn process.
- **ClaudeConversationRuntime** — Reduces raw protocol lines into `ClaudeMessageEvent`.
- **ClaudeActivityRuntime** — Reduces tool execution, warnings, diagnostics, and protocol anomalies into `ClaudeActivityEvent`.
- **BunRuntime / BunContext** (from `swift-bun`) — runtime that loads `cli.js` into JSContext with full Node.js/Bun compatibility. `fetch()` bridges to `URLSession`.
- **PackageManager** (actor) — Resolves the Claude package using `ClaudePackagePolicy` (`manual`, `checkOnStart`, `pinned(version:)`).
- **ClaudeConfiguration** — Model, workingDirectory, allowedTools, maxTurns, systemPrompt, package policy, etc. `iPadTools` preset excludes Bash. `cliArguments()` builds `process.argv`.
- **RawClaudeEventParser** — Parses NDJSON lines into raw transport events, preserving unknown payloads for fail-fast handling.
- **SDKUserMessageBuilder** — Builds `SDKUserMessage` JSON with text and image content blocks.
- **AuthSession** (actor) — Reads OAuth credentials from platform-specific sources. On macOS it prefers managed and runtime-cached credential stores before falling back to the shared Claude Code CLI Keychain entry.
- **ManagedAuthSession** — App-owned credential manager for persisting OAuth results into `Application Support/ClaudeStand/auth/.credentials.json`.
- **CredentialSyncService** — Syncs auth store data into runtime `.claude/.credentials.json` using payload hashes, not expiry checks.

### IPC protocol

Transport is Bun-only on every platform.

- **Swift → JS**: `BunProcess.sendInput(...)` injects prompt payloads into the CLI's simulated stdin
- **JS → Swift**: `process.stdout.write` and diagnostics flow through `BunProcess` async streams into `RawClaudeEventParser` and the reducers

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
- Default tool allowlist excludes Bash via `ClaudeConfiguration.iPadTools`
- `--tools` restricts available tools, `--allowedTools` auto-approves them
- Runtime `HOME` is always isolated and env-based auth variables are stripped before launch
- Native `claude` process execution is forbidden in this repository. If Bun-backed `cli.js` execution is broken on macOS, fix the Bun path instead of adding a fallback.

## Platforms

- iOS 26+ / iPadOS 26+ / macOS 26+
- Swift 6.2+

## Dependencies

- `swift-bun` (`BunRuntime`) — JavaScriptCore + Node.js/Bun polyfills for every supported platform
- `@anthropic-ai/claude-code` — downloaded at runtime from npm registry
