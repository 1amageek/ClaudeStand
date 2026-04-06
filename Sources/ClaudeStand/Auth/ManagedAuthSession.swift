import Foundation

public actor ManagedAuthSession: ClaudeCredentialManaging {
    public let store: ManagedCredentialStore

    private let authSession: AuthSession

    public init(location: ClaudeStandStorageLocation) {
        self.store = ManagedCredentialStore(location: location)
        self.authSession = AuthSession(provider: ManagedCredentialStoreProvider(store: store))
    }

    public init(store: ManagedCredentialStore) {
        self.store = store
        self.authSession = AuthSession(provider: ManagedCredentialStoreProvider(store: store))
    }

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws {
        let store = try ManagedCredentialStore(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
        self.init(store: store)
    }

    public func accessToken() async throws -> String {
        try await authSession.accessToken()
    }

    public func oauthCredentials() async throws -> ClaudeOAuthCredentials {
        try await authSession.oauthCredentials()
    }

    public func credentialStoreData() async throws -> Data {
        try await authSession.credentialStoreData()
    }

    public func credentialStoreDocument() async throws -> ClaudeCredentialStoreDocument {
        try store.readDocument()
    }

    public func clearCache() async {
        await authSession.clearCache()
    }

    public func storeCredentials(_ credentials: ClaudeOAuthCredentials) async throws {
        try store.write(oauthCredentials: credentials)
        await authSession.clearCache()
    }

    public func storeCredentialStoreDocument(_ document: ClaudeCredentialStoreDocument) async throws {
        try store.write(document: document)
        await authSession.clearCache()
    }

    @discardableResult
    public func syncRuntimeHome(at location: ClaudeStandStorageLocation) async throws -> CredentialSyncService.Result {
        let service = CredentialSyncService(location: location)
        let result = try service.sync(credentialStoreData: store.read())
        await authSession.clearCache()
        return result
    }
}
