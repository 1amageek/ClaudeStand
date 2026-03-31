import Testing
import Foundation
@testable import ClaudeStand

@Suite("PackageManager")
struct PackageManagerTests {

    @Test("Initial state has no installed version in empty directory")
    func initialState() async throws {
        let pm = makePM()
        let version = await pm.installedVersion
        #expect(version == nil)
        let path = await pm.cliJSPath
        #expect(path == nil)
    }

    @Test("installedVersion reads version from package.json")
    func installedVersionReads() async throws {
        let dir = makeTempDir()
        let packageDir = dir.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        let packageJSON: [String: Any] = ["name": "@anthropic-ai/claude-code", "version": "2.1.88"]
        let data = try JSONSerialization.data(withJSONObject: packageJSON)
        try data.write(to: packageDir.appendingPathComponent("package.json"))

        let pm = PackageManager(cacheDirectory: dir)
        let version = await pm.installedVersion
        #expect(version == "2.1.88")
    }

    @Test("cliJSPath returns path when cli.js exists")
    func cliJSPathExists() async throws {
        let dir = makeTempDir()
        let cliPath = dir.appendingPathComponent("package/cli.js")
        try FileManager.default.createDirectory(
            at: cliPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env node".utf8).write(to: cliPath)

        let pm = PackageManager(cacheDirectory: dir)
        let path = await pm.cliJSPath
        #expect(path != nil)
        #expect(path?.lastPathComponent == "cli.js")
    }

    @Test("cliJSPath returns nil when cli.js missing")
    func cliJSPathMissing() async throws {
        let dir = makeTempDir()
        let pm = PackageManager(cacheDirectory: dir)
        let path = await pm.cliJSPath
        #expect(path == nil)
    }

    @Test("checkForUpdate fetches latest version from npm registry")
    func checkForUpdate() async throws {
        let pm = makePM()
        let info = try await pm.checkForUpdate()
        #expect(!info.latestVersion.isEmpty)
        #expect(info.latestVersion.contains("."))
        #expect(info.isUpdateAvailable == true)  // empty cache → always an update
        #expect(info.currentVersion == nil)
    }

    @Test("ensureInstalled downloads and extracts package")
    func ensureInstalled() async throws {
        let dir = makeTempDir()
        let pm = PackageManager(cacheDirectory: dir)

        let cliPath = try await pm.ensureInstalled()
        #expect(FileManager.default.fileExists(atPath: cliPath.path))
        #expect(cliPath.lastPathComponent == "cli.js")

        let version = await pm.installedVersion
        #expect(version != nil)
        #expect(version!.contains("."))
    }

    @Test("ensureInstalled uses cache on second call")
    func ensureInstalledCache() async throws {
        let dir = makeTempDir()
        let pm = PackageManager(cacheDirectory: dir)

        let path1 = try await pm.ensureInstalled()
        let path2 = try await pm.ensureInstalled()
        #expect(path1 == path2)
    }

    @Test("ensureInstalled with forceUpdate redownloads")
    func ensureInstalledForceUpdate() async throws {
        let dir = makeTempDir()
        let pm = PackageManager(cacheDirectory: dir)

        let path1 = try await pm.ensureInstalled()
        #expect(FileManager.default.fileExists(atPath: path1.path))

        let path2 = try await pm.ensureInstalled(forceUpdate: true)
        #expect(FileManager.default.fileExists(atPath: path2.path))
    }

    @Test("Extraction removes sharp native binaries")
    func extractionRemovesSharp() async throws {
        let dir = makeTempDir()
        let pm = PackageManager(cacheDirectory: dir)

        _ = try await pm.ensureInstalled()

        let sharpDir = dir.appendingPathComponent("package/node_modules/@img")
        #expect(!FileManager.default.fileExists(atPath: sharpDir.path))
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
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("UpdateInfo reports correctly")
    func updateInfo() {
        let noUpdate = PackageManager.UpdateInfo(
            currentVersion: "2.1.88",
            latestVersion: "2.1.88",
            isUpdateAvailable: false
        )
        #expect(!noUpdate.isUpdateAvailable)

        let hasUpdate = PackageManager.UpdateInfo(
            currentVersion: "2.1.87",
            latestVersion: "2.1.88",
            isUpdateAvailable: true
        )
        #expect(hasUpdate.isUpdateAvailable)
    }

    // MARK: - Helpers

    private func makePM() -> PackageManager {
        PackageManager(cacheDirectory: makeTempDir())
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudestand-test-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
