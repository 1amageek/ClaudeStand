import Foundation

public struct ManagedCredentialStore: Sendable {
    public let credentialsFile: URL

    public init(location: ClaudeStandStorageLocation) {
        self.credentialsFile = location.credentialsFile
    }

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws {
        let location: ClaudeStandStorageLocation
        if let applicationSupportDirectory {
            location = ClaudeStandStorageLocation(
                rootDirectory: applicationSupportDirectory.appendingPathComponent("ClaudeStand", isDirectory: true)
            )
        } else {
            location = try ClaudeStandStorageLocation.applicationSupport(fileManager: fileManager)
        }
        self.init(location: location)
    }

    public func read() throws -> Data {
        try Data(contentsOf: credentialsFile)
    }

    public func readDocument() throws -> ClaudeCredentialStoreDocument {
        let data = try read()
        do {
            return try JSONDecoder().decode(ClaudeCredentialStoreDocument.self, from: data)
        } catch {
            throw ClaudeAuthenticationError.malformedCredentials
        }
    }

    public func write(_ data: Data, using fileManager: FileManager = .default) throws {
        let directory = credentialsFile.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: credentialsFile, options: .atomic)
    }

    public func write(
        document: ClaudeCredentialStoreDocument,
        using fileManager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw ClaudeAuthenticationError.malformedCredentials
        }
        try write(data, using: fileManager)
    }

    public func write(
        oauthCredentials: ClaudeOAuthCredentials,
        using fileManager: FileManager = .default
    ) throws {
        try write(
            document: ClaudeCredentialStoreDocument(claudeAiOauth: oauthCredentials),
            using: fileManager
        )
    }
}
