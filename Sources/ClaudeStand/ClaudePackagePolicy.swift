import Foundation

public enum ClaudePackagePolicy: Sendable, Equatable {
    case manual
    case checkOnStart
    case pinned(version: String)
}
