import Foundation

public struct ClaudeStandStorageLocation: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func applicationSupport(fileManager: FileManager = .default) throws -> ClaudeStandStorageLocation {
        guard let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        return ClaudeStandStorageLocation(
            rootDirectory: applicationSupportDirectory.appendingPathComponent("ClaudeStand", isDirectory: true)
        )
    }

    var authDirectory: URL {
        rootDirectory.appendingPathComponent("auth", isDirectory: true)
    }

    var credentialsFile: URL {
        authDirectory.appendingPathComponent(".credentials.json", isDirectory: false)
    }

    var runtimeHomeDirectory: URL {
        rootDirectory.appendingPathComponent("claude-home", isDirectory: true)
    }

    var runtimeClaudeDirectory: URL {
        runtimeHomeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    var runtimeCredentialsFile: URL {
        runtimeClaudeDirectory.appendingPathComponent(".credentials.json", isDirectory: false)
    }
}
