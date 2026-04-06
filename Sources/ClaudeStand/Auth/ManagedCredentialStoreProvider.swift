import Foundation

public struct ManagedCredentialStoreProvider: ClaudeCredentialStoreProviding {
    public let store: ManagedCredentialStore

    public init(store: ManagedCredentialStore) {
        self.store = store
    }

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws {
        self.store = try ManagedCredentialStore(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    public func credentialStoreData() throws -> Data {
        try store.read()
    }
}
