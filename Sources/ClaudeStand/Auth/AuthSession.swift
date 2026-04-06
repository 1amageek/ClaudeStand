import Foundation

/// Reads Claude OAuth credentials from a platform-specific credential source.
///
/// - macOS default: shared Claude Code CLI Keychain entry
/// - iOS / iPadOS / visionOS default: app-owned managed credential store
///
/// ClaudeStand always materializes the returned JSON into a managed
/// `.claude/.credentials.json` for the embedded CLI runtime. API key based
/// authentication is intentionally unsupported.
public actor AuthSession: ClaudeAuthenticating {
    private struct CredentialStore: Sendable {
        let rawData: Data
        let credentials: ClaudeOAuthCredentials
    }

    private let provider: any ClaudeCredentialStoreProviding
    private var cachedCredentialStore: CredentialStore?

    public init(
        account: String = "default",
        location: ClaudeStandStorageLocation? = nil
    ) {
        self.provider = Self.makeDefaultProvider(account: account, location: location)
    }

    public init(provider: any ClaudeCredentialStoreProviding) {
        self.provider = provider
    }

    /// Whether stored credentials exist and have not expired.
    public var isAuthenticated: Bool {
        do {
            let creds = try loadCredentialStore().credentials
            return creds.isClaudeCodeAuthenticated
        } catch {
            return false
        }
    }

    /// Returns the current OAuth access token from the configured credential store.
    public func accessToken() async throws -> String {
        let creds = try await oauthCredentials()
        if creds.isExpired {
            throw ClaudeAuthenticationError.expiredCredentials(expiresAt: creds.expiresAt)
        }
        if creds.hasRequiredScope == false {
            throw ClaudeAuthenticationError.missingRequiredScope(scopes: creds.scopes)
        }
        return creds.accessToken
    }

    /// Returns the parsed OAuth credentials from the shared credential store.
    public func oauthCredentials() async throws -> ClaudeOAuthCredentials {
        try loadCredentialStore().credentials
    }

    /// Returns the raw credential store JSON for `.claude/.credentials.json`.
    public func credentialStoreData() async throws -> Data {
        try loadCredentialStore().rawData
    }

    /// Clear cached credentials (does not delete from Keychain).
    public func clearCache() async {
        cachedCredentialStore = nil
    }

    // MARK: - Credential Store

    private func loadCredentialStore() throws -> CredentialStore {
        if let cached = cachedCredentialStore {
            return cached
        }
        let store = try readFromProvider()
        cachedCredentialStore = store
        return store
    }

    private static func makeDefaultProvider(
        account: String,
        location: ClaudeStandStorageLocation?
    ) -> any ClaudeCredentialStoreProviding {
        #if os(macOS)
        let resolvedLocation = location
            ?? (try? ClaudeStandStorageLocation.applicationSupport())
        if let resolvedLocation {
            let store = ManagedCredentialStore(location: resolvedLocation)
            return CachedCredentialStoreProvider(
                store: store,
                runtimeCredentialsFile: resolvedLocation.runtimeCredentialsFile,
                fallback: KeychainCredentialStoreProvider(account: account)
            )
        }
        return KeychainCredentialStoreProvider(account: account)
        #else
        do {
            let store: ManagedCredentialStore
            if let location {
                store = ManagedCredentialStore(location: location)
            } else {
                store = try ManagedCredentialStore()
            }
            return ManagedCredentialStoreProvider(store: store)
        } catch {
            return UnavailableCredentialStoreProvider()
        }
        #endif
    }

    private func readFromProvider() throws -> CredentialStore {
        let data = try provider.credentialStoreData()
        do {
            let document = try JSONDecoder().decode(ClaudeCredentialStoreDocument.self, from: data)
            guard document.claudeAiOauth.accessToken.isEmpty == false else {
                throw ClaudeAuthenticationError.malformedCredentials
            }
            guard document.claudeAiOauth.hasRequiredScope else {
                throw ClaudeAuthenticationError.missingRequiredScope(scopes: document.claudeAiOauth.scopes)
            }

            return CredentialStore(
                rawData: data,
                credentials: document.claudeAiOauth
            )
        } catch let error as ClaudeAuthenticationError {
            throw error
        } catch {
            throw ClaudeAuthenticationError.malformedCredentials
        }
    }
}

private struct UnavailableCredentialStoreProvider: ClaudeCredentialStoreProviding {
    func credentialStoreData() throws -> Data {
        throw ClaudeAuthenticationError.managedCredentialStoreUnavailable
    }
}
