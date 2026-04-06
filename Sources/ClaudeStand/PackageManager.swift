import Compression
import Foundation
import os.log

private let packageLogger = Logger(subsystem: "com.claudestand", category: "PackageManager")

public actor PackageManager {
    private static let latestRegistryURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest")!
    private static let packageRegistryPrefix = "https://registry.npmjs.org/@anthropic-ai/claude-code/"

    private let cacheDirectory: URL
    private let registryFetcher: @Sendable (String?) async throws -> RegistryInfo
    private let tarballDownloader: @Sendable (URL) async throws -> Data
    private let fileManager: FileManager

    public var cliJSPath: URL? {
        let path = cacheDirectory.appendingPathComponent("package/cli.js", isDirectory: false)
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    public var installedVersion: String? {
        let packageJSON = cacheDirectory.appendingPathComponent("package/package.json", isDirectory: false)
        guard fileManager.fileExists(atPath: packageJSON.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: packageJSON)
            let object = try JSONSerialization.jsonObject(with: data)
            return (object as? [String: Any])?["version"] as? String
        } catch {
            return nil
        }
    }

    public init() {
        let fileManager = FileManager.default
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("claude-code", isDirectory: true)
        self.init(cacheDirectory: cacheDirectory, fileManager: fileManager)
    }

    init(
        cacheDirectory: URL,
        fileManager: FileManager = .default,
        registryFetcher: @escaping @Sendable (String?) async throws -> RegistryInfo = PackageManager.defaultRegistryFetcher,
        tarballDownloader: @escaping @Sendable (URL) async throws -> Data = PackageManager.defaultTarballDownloader
    ) {
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        self.registryFetcher = registryFetcher
        self.tarballDownloader = tarballDownloader
    }

    public func resolveCLIPath(policy: ClaudePackagePolicy) async throws -> URL {
        switch policy {
        case .manual:
            if let existing = cliJSPath {
                return existing
            }
            let latest = try await registryFetcher(nil)
            return try await install(registryInfo: latest)

        case .checkOnStart:
            let latest = try await registryFetcher(nil)
            if installedVersion == latest.version, let existing = cliJSPath {
                return existing
            }
            return try await install(registryInfo: latest)

        case .pinned(let version):
            if installedVersion == version, let existing = cliJSPath {
                return existing
            }
            let pinned = try await registryFetcher(version)
            return try await install(registryInfo: pinned)
        }
    }

    public func checkForUpdate() async throws -> UpdateInfo {
        let latest = try await registryFetcher(nil)
        let current = installedVersion
        return UpdateInfo(
            currentVersion: current,
            latestVersion: latest.version,
            isUpdateAvailable: current != latest.version
        )
    }

    private func install(registryInfo: RegistryInfo) async throws -> URL {
        packageLogger.info("installing claude-code v\(registryInfo.version, privacy: .public)")
        let tarball = try await tarballDownloader(registryInfo.tarballURL)
        try extractTarball(tarball)
        guard let cliJSPath else {
            throw PackageError.extractionFailed
        }
        return cliJSPath
    }

    private static func defaultRegistryFetcher(version: String?) async throws -> RegistryInfo {
        let url: URL
        if let version {
            guard let specificURL = URL(string: version, relativeTo: URL(string: packageRegistryPrefix))?.absoluteURL else {
                throw PackageError.invalidRegistryResponse
            }
            url = specificURL
        } else {
            url = latestRegistryURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PackageError.registryRequestFailed
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard
            let json = object as? [String: Any],
            let version = json["version"] as? String,
            let dist = json["dist"] as? [String: Any],
            let tarballString = dist["tarball"] as? String,
            let tarballURL = URL(string: tarballString)
        else {
            throw PackageError.invalidRegistryResponse
        }
        return RegistryInfo(version: version, tarballURL: tarballURL)
    }

    private static func defaultTarballDownloader(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PackageError.downloadFailed
        }
        return data
    }

    private func extractTarball(_ data: Data) throws {
        let tempTarball = fileManager.temporaryDirectory
            .appendingPathComponent("claude-code-\(UUID().uuidString.prefix(8)).tgz", isDirectory: false)
        try data.write(to: tempTarball, options: .atomic)
        do {
            try resetCacheDirectory()
            let extracted = try extractArchive(at: tempTarball, destination: cacheDirectory)
            guard extracted else {
                throw PackageError.extractionFailed
            }
            let sharpDirectory = cacheDirectory.appendingPathComponent("package/node_modules/@img", isDirectory: true)
            if fileManager.fileExists(atPath: sharpDirectory.path) {
                try fileManager.removeItem(at: sharpDirectory)
            }
        } catch {
            try? fileManager.removeItem(at: tempTarball)
            throw error
        }
        try? fileManager.removeItem(at: tempTarball)
    }

    private func resetCacheDirectory() throws {
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func extractArchive(at tarball: URL, destination: URL) throws -> Bool {
        #if os(iOS) || os(visionOS)
        return try extractTarGz(at: tarball, destination: destination)
        #else
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["xzf", tarball.path, "-C", destination.path]
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
        #endif
    }

    #if os(iOS) || os(visionOS)
    private func extractTarGz(at tarball: URL, destination: URL) throws -> Bool {
        let compressedData = try Data(contentsOf: tarball)
        guard let decompressed = decompressGzip(compressedData) else {
            throw PackageError.decompressionFailed
        }
        try parseTar(data: decompressed, destination: destination)
        return true
    }

    private func decompressGzip(_ data: Data) -> Data? {
        guard data.count > 10 else { return nil }
        var offset = 10
        let flags = data[3]
        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count else { return nil }
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }
        guard offset < data.count else { return nil }
        let deflateData = Data(data[offset...])

        var decompressed = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                if let chunk {
                    decompressed.append(chunk)
                }
            }
            var position = 0
            while position < deflateData.count {
                let end = min(position + 65_536, deflateData.count)
                try filter.write(deflateData[position..<end])
                position = end
            }
            try filter.finalize()
        } catch {
            return nil
        }
        return decompressed.isEmpty ? nil : decompressed
    }

    private func parseTar(data: Data, destination: URL) throws {
        let blockSize = 512
        var offset = 0

        while offset + blockSize <= data.count {
            let header = data[offset..<(offset + blockSize)]
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            let nameBytes = Data(header.prefix(100))
            let name = String(decoding: nameBytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            let sizeBytes = Data(header.dropFirst(124).prefix(11))
            let sizeString = String(decoding: sizeBytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let fileSize = Int(sizeString, radix: 8) ?? 0
            let typeFlag = header[header.index(header.startIndex, offsetBy: 156)]

            let filePath = destination.appendingPathComponent(name, isDirectory: false)
            if typeFlag == 53 || name.hasSuffix("/") {
                try fileManager.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else if typeFlag == 48 || typeFlag == 0 {
                try fileManager.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fileStart = offset + blockSize
                let fileEnd = fileStart + fileSize
                if fileEnd <= data.count {
                    try Data(data[fileStart..<fileEnd]).write(to: filePath, options: .atomic)
                }
            }

            let dataBlocks = (fileSize + blockSize - 1) / blockSize
            offset += blockSize + (dataBlocks * blockSize)
        }
    }
    #endif

    struct RegistryInfo: Sendable, Equatable {
        let version: String
        let tarballURL: URL
    }

    public struct UpdateInfo: Sendable, Equatable {
        public let currentVersion: String?
        public let latestVersion: String
        public let isUpdateAvailable: Bool

        public init(currentVersion: String?, latestVersion: String, isUpdateAvailable: Bool) {
            self.currentVersion = currentVersion
            self.latestVersion = latestVersion
            self.isUpdateAvailable = isUpdateAvailable
        }
    }

    public enum PackageError: Error, LocalizedError, Equatable {
        case registryRequestFailed
        case invalidRegistryResponse
        case downloadFailed
        case extractionFailed
        case decompressionFailed

        public var errorDescription: String? {
            switch self {
            case .registryRequestFailed:
                "Failed to fetch package info from npm registry."
            case .invalidRegistryResponse:
                "Invalid response from npm registry."
            case .downloadFailed:
                "Failed to download package tarball."
            case .extractionFailed:
                "Failed to extract package tarball."
            case .decompressionFailed:
                "Failed to decompress package tarball."
            }
        }
    }
}
