import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// Google OAuth 2.0 for native apps (Authorization Code + PKCE, no client secret).
/// Each Google account you sign in with becomes its own TaskHub account.
enum GoogleAuth {
    static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/tasks",
    ]

    private static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? ""
    }

    static var isConfigured: Bool {
        !clientID.isEmpty && !clientID.contains("REPLACE_ME") && !clientID.contains("$(")
    }

    /// "123-abc.apps.googleusercontent.com" -> "com.googleusercontent.apps.123-abc"
    static var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    static var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    struct SignInResult {
        let token: OAuthToken
        let email: String
        let name: String?
    }

    @MainActor
    static func signIn(using session: WebAuthenticationSession) async throws -> SignInResult {
        guard isConfigured else {
            throw APIError.notConfigured("Google isn't configured yet. Add your OAuth client ID to Config.local.xcconfig (see README).")
        }
        let verifier = randomURLSafeString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomURLSafeString(length: 24)

        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Let the user pick which Google account, and always return a refresh token.
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]

        let callback = try await session.authenticate(using: components.url!, callbackURLScheme: callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw APIError.api("Google sign-in failed: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw APIError.api("Google sign-in was cancelled or returned an invalid response.")
        }

        let response = try await HTTP.json(TokenResponse.self, tokenURL, method: "POST", body: .form([
            "code": code,
            "client_id": clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]))
        let token = OAuthToken(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        )
        let info = try await HTTP.json(UserInfo.self, userInfoURL, headers: ["Authorization": "Bearer \(token.accessToken)"])
        return SignInResult(token: token, email: info.email ?? "Google account", name: info.name)
    }

    static func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else {
            throw APIError.api("Google session expired. Reconnect this account.")
        }
        let response = try await HTTP.json(TokenResponse.self, tokenURL, method: "POST", body: .form([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]))
        return OAuthToken(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        )
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
    }

    private struct UserInfo: Decodable {
        let email: String?
        let name: String?
    }

    private static func randomURLSafeString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(generator.next() % UInt64(chars.count))] })
    }
}

/// Hands out fresh Google access tokens, refreshing (once) when needed and saving the result.
actor GoogleTokenManager {
    static let shared = GoogleTokenManager()

    private var inFlight: [UUID: Task<OAuthToken, Error>] = [:]

    func accessToken(for accountID: UUID) async throws -> String {
        guard case .oauth(let token)? = CredentialStore.load(for: accountID) else {
            throw APIError.missingCredential
        }
        if !token.isExpiringSoon { return token.accessToken }

        if let existing = inFlight[accountID] {
            return try await existing.value.accessToken
        }
        let task = Task { try await GoogleAuth.refresh(token) }
        inFlight[accountID] = task
        defer { inFlight[accountID] = nil }
        let refreshed = try await task.value
        try CredentialStore.save(.oauth(refreshed), for: accountID)
        return refreshed.accessToken
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
