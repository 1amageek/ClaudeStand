import Foundation
import Compression
import os.log

private let logger = Logger(subsystem: "com.claudestand", category: "PackageManager")

/// Downloads and manages the `@anthropic-ai/claude-code` npm package at runtime.
///
/// The package is downloaded from the npm registry as a tarball, extracted to
/// `Library/Caches/claude-code/`, and updated when a newer version is available.
/// No `npm install` is needed — the package has zero production dependencies.
public actor PackageManager {

    /// npm registry endpoint for version checks.
    private static let registryURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")!

    /// Base directory for cached packages.
    private let cacheDirectory: URL

    /// Path to the currently installed cli.js, if available.
    public var cliJSPath: URL? {
        let path = cacheDirectory.appendingPathComponent("package/cli.js")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Currently installed version, or nil if not installed.
    public var installedVersion: String? {
        let packageJSON = cacheDirectory.appendingPathComponent("package/package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return nil
        }
        return version
    }

    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("claude-code", isDirectory: true)
    }

    /// Initialize with a custom cache directory (for testing).
    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    /// Ensure the package is installed, downloading if necessary.
    ///
    /// Returns the path to `cli.js`.
    /// - Parameter forceUpdate: If true, always download the latest version.
    public func ensureInstalled(forceUpdate: Bool = false) async throws -> URL {
        if !forceUpdate, let existing = cliJSPath {
            logger.info("Using cached cli.js at \(existing.path, privacy: .public)")
            return existing
        }

        let latest = try await fetchLatestVersion()

        if !forceUpdate, let current = installedVersion, current == latest.version {
            if let path = cliJSPath {
                logger.info("Already up to date: v\(current, privacy: .public)")
                return path
            }
        }

        logger.info("Downloading @anthropic-ai/claude-code v\(latest.version, privacy: .public)")
        let tarballData = try await downloadTarball(url: latest.tarballURL)

        logger.info("Extracting package (\(tarballData.count / 1_048_576)MB)")
        try extractTarball(tarballData)

        guard let path = cliJSPath else {
            throw PackageError.extractionFailed
        }

        logger.info("Installed v\(latest.version, privacy: .public) at \(path.path, privacy: .public)")
        return path
    }

    /// Check if an update is available without downloading.
    public func checkForUpdate() async throws -> UpdateInfo {
        let latest = try await fetchLatestVersion()
        let current = installedVersion
        return UpdateInfo(
            currentVersion: current,
            latestVersion: latest.version,
            isUpdateAvailable: current != latest.version
        )
    }

    // MARK: - Private

    private struct RegistryInfo {
        var version: String
        var tarballURL: URL
    }

    private func fetchLatestVersion() async throws -> RegistryInfo {
        let (data, response) = try await URLSession.shared.data(from: Self.registryURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw PackageError.registryRequestFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let version = json["version"] as? String,
              let dist = json["dist"] as? [String: Any],
              let tarballString = dist["tarball"] as? String,
              let tarballURL = URL(string: tarballString) else {
            throw PackageError.invalidRegistryResponse
        }

        return RegistryInfo(version: version, tarballURL: tarballURL)
    }

    private func downloadTarball(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw PackageError.downloadFailed
        }

        return data
    }

    private func extractTarball(_ data: Data) throws {
        // Write tarball to temp file
        let tempTarball = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-\(UUID().uuidString.prefix(8)).tgz")
        try data.write(to: tempTarball)
        defer { try? FileManager.default.removeItem(at: tempTarball) }

        // Prepare extraction directory
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Extract using tar (available on iOS via libarchive)
        // npm tarballs are gzipped tar files with a "package/" prefix
        let process = try extractUsingFoundation(tarball: tempTarball, destination: cacheDirectory)

        guard process else {
            throw PackageError.extractionFailed
        }

        // Remove optional sharp binaries (native addon, not needed on iOS)
        let sharpDir = cacheDirectory.appendingPathComponent("package/node_modules/@img")
        if FileManager.default.fileExists(atPath: sharpDir.path) {
            try? FileManager.default.removeItem(at: sharpDir)
        }
    }

    /// Extract a .tgz file using Foundation APIs.
    ///
    /// On macOS/iOS, we use NSData's decompression + tar parsing.
    /// Falls back to spawning `tar` on macOS for simplicity.
    private func extractUsingFoundation(tarball: URL, destination: URL) throws -> Bool {
        #if os(iOS) || os(visionOS)
        // On iOS, use a lightweight tar extraction
        // The tarball is a gzip-compressed tar archive
        return try extractTarGz(at: tarball, to: destination)
        #else
        // On macOS, use the tar command for simplicity
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["xzf", tarball.path, "-C", destination.path]
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
        #endif
    }

    #if os(iOS) || os(visionOS)
    private func extractTarGz(at source: URL, to destination: URL) throws -> Bool {
        let compressedData = try Data(contentsOf: source)

        // Decompress gzip using the Process-free approach:
        // Write to temp .tgz, use Apple's built-in Archive utility via NSData
        // Apple's Compression framework doesn't handle gzip headers directly,
        // so we use a shell-free approach with NSFileManager unarchiving.
        //
        // On iOS 26+, use the built-in archive extraction.
        guard let decompressed = decompressGzip(compressedData) else {
            throw PackageError.decompressionFailed
        }

        try parseTar(data: decompressed, destination: destination)
        return true
    }

    private func decompressGzip(_ data: Data) -> Data? {
        // Use Compression framework with ZLIB algorithm (handles raw deflate)
        // Skip the gzip header to get the raw deflate stream
        guard data.count > 10 else { return nil }

        var offset = 10
        let flags = data[3]
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= data.count else { return nil }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 {  // FNAME
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC

        guard offset < data.count else { return nil }
        let deflateData = Data(data[offset...])

        // Decompress using Compression framework
        let pageSize = 65536
        var decompressed = Data()

        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { (data: Data?) in
                if let data { decompressed.append(data) }
            }

            var position = 0
            while position < deflateData.count {
                let end = min(position + pageSize, deflateData.count)
                let chunk = deflateData[position..<end]
                try filter.write(chunk)
                position = end
            }
            try filter.finalize()
        } catch {
            return nil
        }

        return decompressed.isEmpty ? nil : decompressed
    }

    private func parseTar(data: Data, destination: URL) throws {
        var offset = 0
        let blockSize = 512

        while offset + blockSize <= data.count {
            let header = data[offset..<(offset + blockSize)]

            // Check for end-of-archive (two zero blocks)
            if header.allSatisfy({ $0 == 0 }) { break }

            // Extract filename (first 100 bytes, null-terminated)
            let nameData = header[offset..<(offset + 100)]
            guard let name = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .init(charactersIn: "\0")) else {
                offset += blockSize
                continue
            }

            // Extract file size (octal, bytes 124-135)
            let sizeData = header[(offset + 124)..<(offset + 135)]
            let sizeString = String(data: sizeData, encoding: .utf8)?
                .trimmingCharacters(in: .init(charactersIn: " \0")) ?? "0"
            let fileSize = Int(sizeString, radix: 8) ?? 0

            // Extract type flag (byte 156)
            let typeFlag = header[offset + 156]

            let filePath = destination.appendingPathComponent(name)

            if typeFlag == 53 || name.hasSuffix("/") {
                // Directory
                try FileManager.default.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else if typeFlag == 48 || typeFlag == 0 {
                // Regular file
                let parentDir = filePath.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                let fileStart = offset + blockSize
                let fileEnd = fileStart + fileSize
                if fileEnd <= data.count {
                    let fileData = data[fileStart..<fileEnd]
                    try fileData.write(to: filePath)
                }
            }

            // Advance past header + file data (aligned to 512-byte blocks)
            let dataBlocks = (fileSize + blockSize - 1) / blockSize
            offset += blockSize + (dataBlocks * blockSize)
        }
    }
    #endif

    // MARK: - Types

    public struct UpdateInfo: Sendable {
        public var currentVersion: String?
        public var latestVersion: String
        public var isUpdateAvailable: Bool
    }

    // MARK: - Errors

    public enum PackageError: Error, LocalizedError {
        case registryRequestFailed
        case invalidRegistryResponse
        case downloadFailed
        case extractionFailed
        case decompressionFailed

        public var errorDescription: String? {
            switch self {
            case .registryRequestFailed:
                "Failed to fetch package info from npm registry"
            case .invalidRegistryResponse:
                "Invalid response from npm registry"
            case .downloadFailed:
                "Failed to download package tarball"
            case .extractionFailed:
                "Failed to extract package tarball"
            case .decompressionFailed:
                "Failed to decompress gzip data"
            }
        }
    }
}
