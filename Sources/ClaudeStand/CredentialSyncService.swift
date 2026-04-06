import CryptoKit
import Foundation

public struct CredentialSyncService {
    public struct Result: Sendable {
        public let homeDirectory: URL
        public let claudeDirectory: URL
        public let didUpdateCredentials: Bool

        var runtimeHome: ClaudeRuntimeHome {
            ClaudeRuntimeHome(homeDirectory: homeDirectory, claudeDirectory: claudeDirectory)
        }
    }

    public let location: ClaudeStandStorageLocation
    private let fileManager: FileManager

    public init(location: ClaudeStandStorageLocation, fileManager: FileManager = .default) {
        self.location = location
        self.fileManager = fileManager
    }

    public static func applicationSupport(fileManager: FileManager = .default) throws -> CredentialSyncService {
        try CredentialSyncService(
            location: ClaudeStandStorageLocation.applicationSupport(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public func sync(using authenticator: any ClaudeAuthenticating) async throws -> Result {
        let data = try await authenticator.credentialStoreData()
        return try sync(credentialStoreData: data)
    }

    public func sync(credentialStoreData: Data) throws -> Result {
        let runtimeHome = try ClaudeRuntimeHome.prepare(location: location, fileManager: fileManager)
        let existing = try runtimeHome.readCredentialStore(using: fileManager)
        let didUpdateCredentials = existing.map(hash(for:)) != hash(for: credentialStoreData)
        if didUpdateCredentials {
            try runtimeHome.writeCredentialStore(credentialStoreData)
        }
        return Result(
            homeDirectory: runtimeHome.homeDirectory,
            claudeDirectory: runtimeHome.claudeDirectory,
            didUpdateCredentials: didUpdateCredentials
        )
    }

    private func hash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
