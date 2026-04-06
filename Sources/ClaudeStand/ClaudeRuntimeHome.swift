import Foundation

struct ClaudeRuntimeHome: Sendable {
    static let removedEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
    ]

    let homeDirectory: URL
    let claudeDirectory: URL

    var diagnosticsFile: URL {
        claudeDirectory.appendingPathComponent("diagnostics.ndjson", isDirectory: false)
    }

    static func prepare(
        location: ClaudeStandStorageLocation,
        fileManager: FileManager = .default
    ) throws -> ClaudeRuntimeHome {
        let homeDirectory = location.runtimeHomeDirectory
        let claudeDirectory = location.runtimeClaudeDirectory

        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        let runtimeHome = ClaudeRuntimeHome(homeDirectory: homeDirectory, claudeDirectory: claudeDirectory)
        try runtimeHome.writeManagedSettings()
        try runtimeHome.ensureInstalledPluginsFile(using: fileManager)
        return runtimeHome
    }

    static func prepare(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws -> ClaudeRuntimeHome {
        let location = try makeStorageLocation(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
        return try prepare(location: location, fileManager: fileManager)
    }

    private static func makeStorageLocation(
        fileManager: FileManager,
        applicationSupportDirectory: URL?
    ) throws -> ClaudeStandStorageLocation {
        if let applicationSupportDirectory {
            return ClaudeStandStorageLocation(
                rootDirectory: applicationSupportDirectory.appendingPathComponent("ClaudeStand", isDirectory: true)
            )
        }
        return try ClaudeStandStorageLocation.applicationSupport(fileManager: fileManager)
    }

    func readCredentialStore(using fileManager: FileManager = .default) throws -> Data? {
        let credentialsFile = claudeDirectory.appendingPathComponent(".credentials.json", isDirectory: false)
        guard fileManager.fileExists(atPath: credentialsFile.path) else {
            return nil
        }
        return try Data(contentsOf: credentialsFile)
    }

    func writeCredentialStore(_ data: Data) throws {
        let credentialsFile = claudeDirectory.appendingPathComponent(".credentials.json", isDirectory: false)
        try data.write(to: credentialsFile, options: .atomic)
    }

    private func writeManagedSettings() throws {
        let settingsFile = claudeDirectory.appendingPathComponent("settings.json", isDirectory: false)
        let data = Data(#"{"enabledPlugins":{}}"#.utf8)
        try data.write(to: settingsFile, options: .atomic)
    }

    private func ensureInstalledPluginsFile(using fileManager: FileManager) throws {
        let pluginsFile = claudeDirectory.appendingPathComponent("installed_plugins.json", isDirectory: false)
        if fileManager.fileExists(atPath: pluginsFile.path) {
            return
        }
        try Data(#"{"version":2,"plugins":{}}"#.utf8).write(to: pluginsFile)
    }
}
