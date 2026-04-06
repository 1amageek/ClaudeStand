import Foundation

public struct CachedCredentialStoreProvider: ClaudeCredentialStoreProviding {
    public let store: ManagedCredentialStore
    public let runtimeCredentialsFile: URL
    public let fallback: any ClaudeCredentialStoreProviding

    public init(
        store: ManagedCredentialStore,
        runtimeCredentialsFile: URL,
        fallback: any ClaudeCredentialStoreProviding
    ) {
        self.store = store
        self.runtimeCredentialsFile = runtimeCredentialsFile
        self.fallback = fallback
    }

    public func credentialStoreData() throws -> Data {
        if let cached = try loadValidCredentials(at: store.credentialsFile) {
            return cached
        }

        if let runtimeCached = try loadValidCredentials(at: runtimeCredentialsFile) {
            try store.write(runtimeCached)
            return runtimeCached
        }

        let keychainData = try fallback.credentialStoreData()
        try store.write(keychainData)
        return keychainData
    }

    private func loadValidCredentials(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        do {
            let document = try JSONDecoder().decode(ClaudeCredentialStoreDocument.self, from: data)
            guard document.claudeAiOauth.accessToken.isEmpty == false else {
                return nil
            }
            guard document.claudeAiOauth.isExpired == false else {
                return nil
            }
            guard document.claudeAiOauth.hasRequiredScope else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
