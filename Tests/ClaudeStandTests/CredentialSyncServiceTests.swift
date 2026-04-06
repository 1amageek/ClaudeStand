import Foundation
import Testing
@testable import ClaudeStand

@Suite("CredentialSyncService")
struct CredentialSyncServiceTests {
    @Test("runtime home materialization writes settings and plugin state")
    func runtimeHomePreparation() throws {
        let directory = try Self.makeTempDirectory()
        let runtimeHome = try ClaudeRuntimeHome.prepare(applicationSupportDirectory: directory)

        let settings = runtimeHome.claudeDirectory.appendingPathComponent("settings.json")
        let plugins = runtimeHome.claudeDirectory.appendingPathComponent("installed_plugins.json")

        #expect(String(decoding: try Data(contentsOf: settings), as: UTF8.self) == #"{"enabledPlugins":{}}"#)
        #expect(String(decoding: try Data(contentsOf: plugins), as: UTF8.self) == #"{"version":2,"plugins":{}}"#)
    }

    @Test("credential sync updates runtime credentials when source hash changes")
    func credentialSyncUsesHash() throws {
        let root = try Self.makeTempDirectory().appendingPathComponent("ClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: root)
        let service = CredentialSyncService(location: location)

        let first = Data(#"{"claudeAiOauth":{"accessToken":"first","expiresAt":4102444800000}}"#.utf8)
        let second = Data(#"{"claudeAiOauth":{"accessToken":"second","expiresAt":4102444800000}}"#.utf8)

        let firstResult = try service.sync(credentialStoreData: first)
        let secondResult = try service.sync(credentialStoreData: second)

        #expect(firstResult.didUpdateCredentials == true)
        #expect(secondResult.didUpdateCredentials == true)
        #expect(try Data(contentsOf: location.runtimeClaudeDirectory.appendingPathComponent(".credentials.json")) == second)
    }

    @Test("credential sync supports explicit storage locations")
    func explicitStorageLocation() throws {
        let root = try Self.makeTempDirectory().appendingPathComponent("SharedClaudeStand", isDirectory: true)
        let location = ClaudeStandStorageLocation(rootDirectory: root)
        let service = CredentialSyncService(location: location)
        let credentials = Data(#"{"claudeAiOauth":{"accessToken":"shared"}}"#.utf8)

        let result = try service.sync(credentialStoreData: credentials)

        #expect(result.homeDirectory == location.runtimeHomeDirectory)
        #expect(result.claudeDirectory == location.runtimeClaudeDirectory)
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudestand-runtime-home-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
