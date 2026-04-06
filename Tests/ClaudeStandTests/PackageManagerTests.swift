import Foundation
import Testing
@testable import ClaudeStand

@Suite("PackageManager")
struct PackageManagerTests {
    @Test("manual policy uses cache when cli.js already exists")
    func manualUsesCache() async throws {
        let cacheDirectory = try Self.makeTempDirectory()
        try Self.installPackage(version: "1.0.0", into: cacheDirectory)

        let tracker = FetchTracker()
        let manager = PackageManager(
            cacheDirectory: cacheDirectory,
            registryFetcher: { version in
                await tracker.recordFetch(version)
                return PackageManager.RegistryInfo(version: "2.0.0", tarballURL: URL(string: "https://example.com/latest.tgz")!)
            },
            tarballDownloader: { _ in
                await tracker.recordDownload()
                return try Self.makeTarball(version: "2.0.0")
            }
        )

        let path = try await manager.resolveCLIPath(policy: .manual)

        #expect(path.lastPathComponent == "cli.js")
        #expect(await tracker.fetchRequests == [])
        #expect(await tracker.downloadCount == 0)
        #expect(await manager.installedVersion == "1.0.0")
    }

    @Test("checkOnStart installs latest when versions differ")
    func checkOnStartInstallsLatest() async throws {
        let cacheDirectory = try Self.makeTempDirectory()
        try Self.installPackage(version: "1.0.0", into: cacheDirectory)

        let tracker = FetchTracker()
        let manager = PackageManager(
            cacheDirectory: cacheDirectory,
            registryFetcher: { version in
                await tracker.recordFetch(version)
                return PackageManager.RegistryInfo(version: "2.0.0", tarballURL: URL(string: "https://example.com/latest.tgz")!)
            },
            tarballDownloader: { _ in
                await tracker.recordDownload()
                return try Self.makeTarball(version: "2.0.0")
            }
        )

        let path = try await manager.resolveCLIPath(policy: .checkOnStart)

        #expect(path.lastPathComponent == "cli.js")
        #expect(await tracker.fetchRequests == [nil])
        #expect(await tracker.downloadCount == 1)
        #expect(await manager.installedVersion == "2.0.0")
    }

    @Test("pinned policy resolves the requested version")
    func pinnedVersion() async throws {
        let cacheDirectory = try Self.makeTempDirectory()
        let tracker = FetchTracker()
        let manager = PackageManager(
            cacheDirectory: cacheDirectory,
            registryFetcher: { version in
                await tracker.recordFetch(version)
                return PackageManager.RegistryInfo(version: version ?? "unexpected", tarballURL: URL(string: "https://example.com/pinned.tgz")!)
            },
            tarballDownloader: { _ in
                await tracker.recordDownload()
                return try Self.makeTarball(version: "3.1.4")
            }
        )

        _ = try await manager.resolveCLIPath(policy: .pinned(version: "3.1.4"))

        #expect(await tracker.fetchRequests == ["3.1.4"])
        #expect(await manager.installedVersion == "3.1.4")
    }

    @Test("checkForUpdate reports version differences")
    func updateInfo() async throws {
        let cacheDirectory = try Self.makeTempDirectory()
        try Self.installPackage(version: "1.0.0", into: cacheDirectory)

        let manager = PackageManager(
            cacheDirectory: cacheDirectory,
            registryFetcher: { _ in
                PackageManager.RegistryInfo(version: "2.0.0", tarballURL: URL(string: "https://example.com/latest.tgz")!)
            },
            tarballDownloader: { _ in
                try Self.makeTarball(version: "2.0.0")
            }
        )

        let info = try await manager.checkForUpdate()
        #expect(info.currentVersion == "1.0.0")
        #expect(info.latestVersion == "2.0.0")
        #expect(info.isUpdateAvailable == true)
    }

    @Test("PackageError descriptions are meaningful")
    func errorDescriptions() {
        let errors: [PackageManager.PackageError] = [
            .registryRequestFailed,
            .invalidRegistryResponse,
            .downloadFailed,
            .extractionFailed,
            .decompressionFailed,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    private static func installPackage(version: String, into cacheDirectory: URL) throws {
        let packageDirectory = cacheDirectory.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data(#"console.log("cli")"#.utf8)
            .write(to: packageDirectory.appendingPathComponent("cli.js"), options: .atomic)
        try Data(#"{"name":"@anthropic-ai/claude-code","version":"\#(version)"}"#.utf8)
            .write(to: packageDirectory.appendingPathComponent("package.json"), options: .atomic)
    }

    private static func makeTarball(version: String) throws -> Data {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let packageDirectory = source.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data(#"console.log("cli")"#.utf8)
            .write(to: packageDirectory.appendingPathComponent("cli.js"), options: .atomic)
        try Data(#"{"name":"@anthropic-ai/claude-code","version":"\#(version)"}"#.utf8)
            .write(to: packageDirectory.appendingPathComponent("package.json"), options: .atomic)

        let tarball = root.appendingPathComponent("package.tgz", isDirectory: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["czf", tarball.path, "-C", source.path, "package"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try Data(contentsOf: tarball)
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudestand-package-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor FetchTracker {
    private(set) var fetchRequests: [String?] = []
    private(set) var downloadCount = 0

    func recordFetch(_ version: String?) {
        fetchRequests.append(version)
    }

    func recordDownload() {
        downloadCount += 1
    }
}
