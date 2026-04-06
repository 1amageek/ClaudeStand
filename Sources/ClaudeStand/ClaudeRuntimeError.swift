import Foundation

public enum ClaudeRuntimeError: Error, LocalizedError, Equatable {
    case notStarted
    case turnInProgress
    case stopping
    case cancelled
    case invalidResumeState
    case processExited(String)
    case protocolMismatch(String)
    case streamSetupFailed

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            "Claude runtime is not started."
        case .turnInProgress:
            "A Claude turn is already in progress."
        case .stopping:
            "Claude runtime is stopping."
        case .cancelled:
            "Claude turn was cancelled."
        case .invalidResumeState:
            "Resume tokens can only be used when starting a new runtime."
        case .processExited(let message):
            "Claude process exited unexpectedly. \(message)"
        case .protocolMismatch(let message):
            "Claude stream protocol mismatch. \(message)"
        case .streamSetupFailed:
            "Failed to create Claude turn streams."
        }
    }
}
