import Foundation
import Synchronization
import Testing
@testable import ClaudeStand

@Suite("AuthSession")
struct AuthSessionTests {
    @Test("AuthSession parses credentials from an injected provider and caches reads")
    func authSessionParsesInjectedProvider() async throws {
        let provider = StubCredentialStoreProvider(
            payloads: [
                Self.credentialDocumentData(
                    accessToken: "token",
                    refreshToken: "refresh"
                )
            ]
        )
        let session = AuthSession(provider: provider)

        let token = try await session.accessToken()
        let credentials = try await session.oauthCredentials()
        let rawData = try await session.credentialStoreData()

        #expect(token == "token")
        #expect(credentials.refreshToken == "refresh")
        #expect(String(decoding: rawData, as: UTF8.self).contains(#""accessToken":"token""#))
        #expect(provider.readCount == 1)
    }

    @Test("AuthSession clearCache reloads the provider")
    func authSessionClearCacheReloadsProvider() async throws {
        let provider = StubCredentialStoreProvider(
            payloads: [
                Self.credentialDocumentData(accessToken: "first"),
                Self.credentialDocumentData(accessToken: "second"),
            ]
        )
        let session = AuthSession(provider: provider)

        let first = try await session.accessToken()
        await session.clearCache()
        let second = try await session.accessToken()

        #expect(first == "first")
        #expect(second == "second")
        #expect(provider.readCount == 2)
    }

    @Test("ManagedCredentialStore round-trips app-owned credentials")
    func managedCredentialStoreRoundTrip() throws {
        let applicationSupport = try Self.makeTempDirectory()
        let store = try ManagedCredentialStore(applicationSupportDirectory: applicationSupport)
        let payload = Self.credentialDocumentData(accessToken: "app-owned")

        try store.write(payload)

        #expect(try store.read() == payload)
        #expect(store.credentialsFile.path.contains("/ClaudeStand/auth/.credentials.json"))
    }

    @Test("ManagedCredentialStore uses an explicit storage location")
    func managedCredentialStoreUsesExplicitLocation() throws {
        let rootDirectory = try Self.makeTempDirectory()
            .appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: rootDirectory)
        let store = ManagedCredentialStore(location: location)
        let payload = Self.credentialDocumentData(accessToken: "shared-root")

        try store.write(payload)

        #expect(store.credentialsFile == rootDirectory.appendingPathComponent("auth/.credentials.json"))
        #expect(try store.read() == payload)
    }

    @Test("ManagedCredentialStoreProvider loads app-owned credentials")
    func managedCredentialStoreProviderLoadsData() throws {
        let applicationSupport = try Self.makeTempDirectory()
        let store = try ManagedCredentialStore(applicationSupportDirectory: applicationSupport)
        let payload = Self.credentialDocumentData(accessToken: "provider")
        try store.write(payload)

        let provider = ManagedCredentialStoreProvider(store: store)

        #expect(try provider.credentialStoreData() == payload)
    }

    @Test("CachedCredentialStoreProvider prefers valid managed credentials without keychain fallback")
    func cachedCredentialProviderPrefersManagedStore() throws {
        let rootDirectory = try Self.makeTempDirectory()
            .appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: rootDirectory)
        let store = ManagedCredentialStore(location: location)
        let payload = Self.credentialDocumentData(accessToken: "managed-token")
        try store.write(payload)

        let fallback = StubCredentialStoreProvider(
            payloads: [Self.credentialDocumentData(accessToken: "keychain-token")]
        )
        let provider = CachedCredentialStoreProvider(
            store: store,
            runtimeCredentialsFile: location.runtimeCredentialsFile,
            fallback: fallback
        )

        let data = try provider.credentialStoreData()

        #expect(data == payload)
        #expect(fallback.readCount == 0)
    }

    @Test("CachedCredentialStoreProvider bootstraps from runtime credentials before keychain")
    func cachedCredentialProviderBootstrapsFromRuntimeHome() throws {
        let rootDirectory = try Self.makeTempDirectory()
            .appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: rootDirectory)
        let runtimeDirectory = location.runtimeCredentialsFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let runtimePayload = Self.credentialDocumentData(accessToken: "runtime-token")
        try runtimePayload.write(to: location.runtimeCredentialsFile, options: .atomic)

        let fallback = StubCredentialStoreProvider(
            payloads: [Self.credentialDocumentData(accessToken: "keychain-token")]
        )
        let provider = CachedCredentialStoreProvider(
            store: ManagedCredentialStore(location: location),
            runtimeCredentialsFile: location.runtimeCredentialsFile,
            fallback: fallback
        )

        let data = try provider.credentialStoreData()

        #expect(data == runtimePayload)
        #expect(fallback.readCount == 0)
        #expect(try Data(contentsOf: location.credentialsFile) == runtimePayload)
    }

    @Test("CachedCredentialStoreProvider persists keychain fallback into managed store")
    func cachedCredentialProviderPersistsFallback() throws {
        let rootDirectory = try Self.makeTempDirectory()
            .appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: rootDirectory)
        let keychainPayload = Self.credentialDocumentData(accessToken: "keychain-token")
        let fallback = StubCredentialStoreProvider(payloads: [keychainPayload])
        let provider = CachedCredentialStoreProvider(
            store: ManagedCredentialStore(location: location),
            runtimeCredentialsFile: location.runtimeCredentialsFile,
            fallback: fallback
        )

        let data = try provider.credentialStoreData()

        #expect(data == keychainPayload)
        #expect(fallback.readCount == 1)
        #expect(try Data(contentsOf: location.credentialsFile) == keychainPayload)
    }

    @Test("ManagedCredentialStore writes OAuth login results in CLI-compatible format")
    func managedCredentialStoreWritesOAuthCredentials() throws {
        let applicationSupport = try Self.makeTempDirectory()
        let store = try ManagedCredentialStore(applicationSupportDirectory: applicationSupport)
        let credentials = ClaudeOAuthCredentials(
            accessToken: "ios-access",
            refreshToken: "ios-refresh",
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            scopes: [ClaudeOAuthCredentials.requiredScope],
            subscriptionType: "pro",
            rateLimitTier: "standard"
        )

        try store.write(oauthCredentials: credentials)

        let document = try store.readDocument()
        #expect(document.claudeAiOauth.accessToken == "ios-access")
        #expect(document.claudeAiOauth.refreshToken == "ios-refresh")
        #expect(document.claudeAiOauth.expiresAt == credentials.expiresAt)
        #expect(document.claudeAiOauth.scopes == [ClaudeOAuthCredentials.requiredScope])
        #expect(document.claudeAiOauth.subscriptionType == "pro")
        #expect(document.claudeAiOauth.rateLimitTier == "standard")
    }

    @Test("AuthSession reads credentials written by managed store OAuth API")
    func authSessionReadsManagedStoreOAuthWrite() async throws {
        let applicationSupport = try Self.makeTempDirectory()
        let store = try ManagedCredentialStore(applicationSupportDirectory: applicationSupport)
        try store.write(
            oauthCredentials: ClaudeOAuthCredentials(
                accessToken: "stored-access",
                refreshToken: "stored-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
                scopes: [ClaudeOAuthCredentials.requiredScope]
            )
        )

        let session = AuthSession(provider: ManagedCredentialStoreProvider(store: store))

        let credentials = try await session.oauthCredentials()
        #expect(credentials.accessToken == "stored-access")
        #expect(credentials.refreshToken == "stored-refresh")
        #expect(credentials.scopes == [ClaudeOAuthCredentials.requiredScope])
    }

    @Test("AuthSession rejects stored credentials without the Claude Code scope")
    func authSessionRejectsMissingScope() async {
        let provider = StubCredentialStoreProvider(
            payloads: [
                Data(#"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":4102444800000}}"#.utf8)
            ]
        )
        let session = AuthSession(provider: provider)

        await #expect(throws: ClaudeAuthenticationError.self) {
            _ = try await session.accessToken()
        }
    }

    @Test("AuthSession preserves provider availability errors")
    func authSessionPreservesProviderErrors() async {
        let provider = FailingCredentialStoreProvider(
            error: ClaudeAuthenticationError.managedCredentialStoreUnavailable
        )
        let session = AuthSession(provider: provider)

        await #expect(throws: ClaudeAuthenticationError.self) {
            _ = try await session.oauthCredentials()
        }
    }

    @Test("ManagedAuthSession stores new OAuth results and invalidates cached reads")
    func managedAuthSessionStoresAndRefreshesCredentials() async throws {
        let applicationSupport = try Self.makeTempDirectory()
        let session = try ManagedAuthSession(applicationSupportDirectory: applicationSupport)

        try await session.storeCredentials(
            ClaudeOAuthCredentials(
                accessToken: "first-access",
                refreshToken: "first-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
                scopes: [ClaudeOAuthCredentials.requiredScope]
            )
        )
        let first = try await session.accessToken()

        try await session.storeCredentials(
            ClaudeOAuthCredentials(
                accessToken: "second-access",
                refreshToken: "second-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_102_444_900),
                scopes: [ClaudeOAuthCredentials.requiredScope]
            )
        )
        let second = try await session.accessToken()
        let storedDocument = try await session.credentialStoreDocument()

        #expect(first == "first-access")
        #expect(second == "second-access")
        #expect(storedDocument.claudeAiOauth.refreshToken == "second-refresh")
    }

    @Test("ManagedAuthSession stores credentials in an explicit storage location")
    func managedAuthSessionUsesExplicitLocation() async throws {
        let rootDirectory = try Self.makeTempDirectory()
            .appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: rootDirectory)
        let session = ManagedAuthSession(location: location)

        try await session.storeCredentials(
            ClaudeOAuthCredentials(
                accessToken: "shared-access",
                refreshToken: "shared-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
                scopes: [ClaudeOAuthCredentials.requiredScope]
            )
        )

        let storedData = try Data(contentsOf: location.credentialsFile)
        #expect(String(decoding: storedData, as: UTF8.self).contains(#""accessToken":"shared-access""#))
    }

    @Test("ManagedAuthSession can sync runtime home after credential updates")
    func managedAuthSessionSyncsRuntimeHome() async throws {
        let rootDirectory = try Self.makeTempDirectory()
            .appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: rootDirectory)
        let session = ManagedAuthSession(location: location)

        try await session.storeCredentials(
            ClaudeOAuthCredentials(
                accessToken: "runtime-access",
                refreshToken: "runtime-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
                scopes: [ClaudeOAuthCredentials.requiredScope]
            )
        )

        let result = try await session.syncRuntimeHome(at: location)

        #expect(result.didUpdateCredentials == true)
        let runtimeCredentials = try Data(contentsOf: location.runtimeClaudeDirectory.appendingPathComponent(".credentials.json"))
        #expect(String(decoding: runtimeCredentials, as: UTF8.self).contains(#""accessToken":"runtime-access""#))
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudestand-auth-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func credentialDocumentData(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAtMilliseconds: Int64 = 4_102_444_800_000,
        scopes: [String] = [ClaudeOAuthCredentials.requiredScope]
    ) -> Data {
        let document = ClaudeCredentialStoreDocument(
            claudeAiOauth: ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1000.0),
                scopes: scopes
            )
        )
        let encoder = JSONEncoder()
        do {
            return try encoder.encode(document)
        } catch {
            Issue.record("Failed to encode test credential document: \(error)")
            return Data()
        }
    }
}

private final class StubCredentialStoreProvider: ClaudeCredentialStoreProviding, Sendable {
    private struct State: Sendable {
        var payloads: [Data]
        var readCount: Int = 0
    }

    private let state: Mutex<State>

    init(payloads: [Data]) {
        self.state = Mutex(State(payloads: payloads))
    }

    var readCount: Int {
        state.withLock { $0.readCount }
    }

    func credentialStoreData() throws -> Data {
        try state.withLock { state in
            guard state.payloads.isEmpty == false else {
                throw ClaudeAuthenticationError.managedCredentialStoreUnavailable
            }
            state.readCount += 1
            return state.payloads.removeFirst()
        }
    }
}

private struct FailingCredentialStoreProvider: ClaudeCredentialStoreProviding {
    let error: ClaudeAuthenticationError

    func credentialStoreData() throws -> Data {
        throw error
    }
}
