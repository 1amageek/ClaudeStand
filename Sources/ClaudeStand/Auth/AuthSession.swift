import Foundation
import AuthenticationServices
import Security
import os.log

private let logger = Logger(subsystem: "com.claudestand", category: "Auth")

/// Manages OAuth authentication for Claude Code.
///
/// Performs the OAuth flow via `ASWebAuthenticationSession`, stores tokens
/// in the Keychain under the same service name Claude Code CLI uses
/// (`"Claude Code-credentials"`), so the CLI picks them up automatically.
///
/// API key authentication is intentionally unsupported.
public actor AuthSession {

    /// Keychain service name matching what Claude Code CLI uses.
    private static let keychainService = "Claude Code-credentials"

    /// The account name for the Keychain entry.
    private let keychainAccount: String

    private var cachedCredentials: Credentials?

    public init(account: String = "default") {
        self.keychainAccount = account
    }

    /// Whether stored credentials exist.
    public var isAuthenticated: Bool {
        get async {
            if cachedCredentials != nil { return true }
            do {
                cachedCredentials = try loadFromKeychain()
                return cachedCredentials != nil
            } catch {
                return false
            }
        }
    }

    /// Perform OAuth login via the system browser.
    ///
    /// Opens `ASWebAuthenticationSession` to authenticate with Claude's
    /// OAuth provider. On success, stores the credentials in the Keychain.
    public func login(anchor: ASPresentationAnchor) async throws {
        let authURL = try buildAuthorizationURL()
        let callbackScheme = "claude-code"

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error {
                    continuation.resume(throwing: AuthError.authenticationFailed(underlying: error))
                    return
                }
                guard let url else {
                    continuation.resume(throwing: AuthError.missingCallbackURL)
                    return
                }
                continuation.resume(returning: url)
            }

            let delegate = PresentationDelegate(anchor: anchor)
            session.presentationContextProvider = delegate
            session.prefersEphemeralWebBrowserSession = false

            if !session.start() {
                continuation.resume(throwing: AuthError.sessionStartFailed)
            }
        }

        let credentials = try await exchangeCodeForToken(callbackURL: callbackURL)
        try saveToKeychain(credentials)
        cachedCredentials = credentials
        logger.info("OAuth login successful")
    }

    /// Clear stored tokens and log out.
    public func logout() throws {
        cachedCredentials = nil
        try deleteFromKeychain()
        logger.info("Logged out")
    }

    /// Returns the current access token, refreshing if needed.
    func accessToken() throws -> String {
        if let creds = cachedCredentials {
            return creds.accessToken
        }
        let creds = try loadFromKeychain()
        cachedCredentials = creds
        return creds.accessToken
    }

    // MARK: - Private

    private func buildAuthorizationURL() throws -> URL {
        // Claude OAuth authorization endpoint
        // The exact URL/parameters will need to match Claude's OAuth implementation
        var components = URLComponents()
        components.scheme = "https"
        components.host = "claude.ai"
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "claude-code"),
            URLQueryItem(name: "redirect_uri", value: "claude-code://oauth/callback"),
            URLQueryItem(name: "scope", value: "claude-code"),
        ]

        guard let url = components.url else {
            throw AuthError.invalidAuthURL
        }
        return url
    }

    private func exchangeCodeForToken(callbackURL: URL) async throws -> Credentials {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingAuthorizationCode
        }

        // Exchange authorization code for access token
        var request = URLRequest(url: URL(string: "https://claude.ai/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": "claude-code",
            "redirect_uri": "claude-code://oauth/callback",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.tokenExchangeFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.tokenExchangeFailed
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Int

        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    // MARK: - Keychain

    private func saveToKeychain(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)

        // Delete existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainSaveFailed(status: status)
        }
    }

    private func loadFromKeychain() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthError.keychainLoadFailed(status: status)
        }

        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    private func deleteFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychainDeleteFailed(status: status)
        }
    }

    // MARK: - Types

    struct Credentials: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    // MARK: - Errors

    public enum AuthError: Error, LocalizedError {
        case invalidAuthURL
        case authenticationFailed(underlying: Error)
        case missingCallbackURL
        case sessionStartFailed
        case missingAuthorizationCode
        case tokenExchangeFailed
        case keychainSaveFailed(status: OSStatus)
        case keychainLoadFailed(status: OSStatus)
        case keychainDeleteFailed(status: OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidAuthURL:
                "Failed to construct OAuth authorization URL"
            case .authenticationFailed(let error):
                "Authentication failed: \(error.localizedDescription)"
            case .missingCallbackURL:
                "No callback URL received from OAuth provider"
            case .sessionStartFailed:
                "Failed to start authentication session"
            case .missingAuthorizationCode:
                "Authorization code missing from callback URL"
            case .tokenExchangeFailed:
                "Failed to exchange authorization code for token"
            case .keychainSaveFailed(let status):
                "Failed to save to Keychain (OSStatus: \(status))"
            case .keychainLoadFailed(let status):
                "Failed to load from Keychain (OSStatus: \(status))"
            case .keychainDeleteFailed(let status):
                "Failed to delete from Keychain (OSStatus: \(status))"
            }
        }
    }
}

// MARK: - ASWebAuthenticationSession Presentation

private final class PresentationDelegate: NSObject, ASWebAuthenticationPresentationContextProviding, Sendable {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
