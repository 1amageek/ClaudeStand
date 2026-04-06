import Foundation

public protocol ClaudeAuthenticating: Sendable {
    func accessToken() async throws -> String
    func oauthCredentials() async throws -> ClaudeOAuthCredentials
    func credentialStoreData() async throws -> Data
    func clearCache() async
}

public protocol ClaudeCredentialManaging: ClaudeAuthenticating {
    func storeCredentials(_ credentials: ClaudeOAuthCredentials) async throws
    func storeCredentialStoreDocument(_ document: ClaudeCredentialStoreDocument) async throws
}

public struct ClaudeOAuthCredentials: Codable, Sendable {
    public static let requiredScope = "user:inference"

    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case scopes
        case subscriptionType
        case rateLimitTier
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String]? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    public var hasRequiredScope: Bool {
        guard let scopes else { return false }
        return scopes.contains(Self.requiredScope)
    }

    public var isClaudeCodeAuthenticated: Bool {
        accessToken.isEmpty == false && isExpired == false && hasRequiredScope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)

        if let expiresAtMilliseconds = try container.decodeIfPresent(Double.self, forKey: .expiresAt) {
            self.expiresAt = Date(timeIntervalSince1970: expiresAtMilliseconds / 1000.0)
        } else if let expiresAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) {
            self.expiresAt = Date(timeIntervalSince1970: Double(expiresAtMilliseconds) / 1000.0)
        } else {
            self.expiresAt = nil
        }

        if let scopes = try container.decodeIfPresent([String].self, forKey: .scopes) {
            self.scopes = scopes
        } else if let scopeString = try container.decodeIfPresent(String.self, forKey: .scopes) {
            self.scopes = scopeString
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        } else {
            self.scopes = nil
        }

        self.subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
        self.rateLimitTier = try container.decodeIfPresent(String.self, forKey: .rateLimitTier)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        if let expiresAt {
            let milliseconds = Int64((expiresAt.timeIntervalSince1970 * 1000.0).rounded())
            try container.encode(milliseconds, forKey: .expiresAt)
        }
        try container.encodeIfPresent(scopes, forKey: .scopes)
        try container.encodeIfPresent(subscriptionType, forKey: .subscriptionType)
        try container.encodeIfPresent(rateLimitTier, forKey: .rateLimitTier)
    }
}

public enum ClaudeAuthenticationError: Error, LocalizedError {
    case keychainLoadFailed(status: OSStatus)
    case managedCredentialStoreUnavailable
    case malformedCredentials
    case missingRequiredScope(scopes: [String]?)
    case expiredCredentials(expiresAt: Date?)

    public var errorDescription: String? {
        switch self {
        case .keychainLoadFailed(let status):
            return "Failed to load from Keychain (OSStatus: \(status))"
        case .managedCredentialStoreUnavailable:
            return "Managed credential store is unavailable"
        case .malformedCredentials:
            return "Credential store does not contain valid Claude OAuth credentials"
        case .missingRequiredScope(let scopes):
            let scopeList = scopes?.joined(separator: ", ") ?? "none"
            return "Claude OAuth credentials are missing the required scope (\(ClaudeOAuthCredentials.requiredScope)). Stored scopes: \(scopeList)"
        case .expiredCredentials(let expiresAt):
            if let expiresAt {
                return "Claude OAuth credentials expired at \(expiresAt)"
            }
            return "Claude OAuth credentials are expired"
        }
    }
}
