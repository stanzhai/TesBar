import AppKit
import AuthenticationServices
import Foundation
import os
/// Injectable HTTP seam: one request in, status/headers/body out.
/// Production impl is ``URLSessionTransport``; tests script a stub.
public protocol HTTPExecuting: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data)
}

/// Production transport over URLSession. Header names lowercased.
public struct URLSessionTransport: HTTPExecuting {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return (http.statusCode, headers, data)
    }
}

public enum AuthError: Error, Equatable {
    /// Token endpoint rejected the refresh token (HTTP 400/401 or body `login_required`).
    case refreshTokenInvalid
    /// Refresh failed inside ``AuthService/authorized(_:)`` — observable signal for 09/10 to guide re-login (user story 34).
    case reauthRequired
}

/// HTTP-level failure carried in thrown errors; ``AuthService/authorized(_:)`` triggers one refresh+retry on 401.
public struct HTTPStatusError: Error, Equatable, Sendable {
    public let status: Int
    public init(_ status: Int) { self.status = status }
}

/// Tesla OAuth 2 authorization-code flow + refresh (research §4).
///
/// Token endpoint is the fleet-auth host (mandatory for server-to-server since 2025-08).
/// Refresh tokens are single-use: a new one is persisted *before* the new access token,
/// because a crash after that leaves a still-usable refresh token (old access tokens are
/// invalidated server-side at refresh time; a stale refresh token would lock us out).
public actor AuthService {
    public static let tokenEndpoint = URL(string: "https://fleet-auth.prd.cn.vn.cloud.tesla.cn/oauth2/v3/token")!
    public static let authorizeEndpoint = "https://auth.tesla.com/oauth2/v3/authorize"
    public static let redirectURI = "https://auth.tesla.com/void/callback"
    static let scope = "openid offline_access user_data vehicle_device_data vehicle_cmds vehicle_charging_cmds"
    static let accessAccount = "tesbar-access-token"
    static let refreshAccount = "tesbar-refresh-token"

    private let clientID: String
    private let clientSecret: String
    /// Regional Fleet API base URL sent as the OAuth `audience` (spec: single region, out of scope to resolve).
    private let audience: String
    private let transport: any HTTPExecuting
    private let keychain: KeychainStore
    private let logger = Logger(subsystem: "com.tesbar.app", category: "auth")

    public init(
        clientID: String,
        clientSecret: String,
        audience: String = "https://fleet-api.prd.cn.vn.cloud.tesla.cn",
        transport: any HTTPExecuting = URLSessionTransport(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.audience = audience
        self.transport = transport
        self.keychain = keychain
    }

    // MARK: Web authorization (system UI — not unit-tested; exchange() below is)

    /// Runs the Tesla login sheet, exchanges the returned code, persists both tokens.
    public func authorize() async throws {
        let code = try await authorizationCode()
        try await exchange(code: code)
    }

    private func authorizationCode() async throws -> String {
        var components = URLComponents(string: Self.authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "audience", value: audience),
        ]
        let callback = try await runWebAuthentication(at: components.url!)

        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw URLError(.cancelled) }
        return code
    }

    private func runWebAuthentication(at url: URL) async throws -> URL {
        try await Self.presentWebAuthentication(url: url)
    }

    /// ASWebAuthenticationSession must start on the main thread and needs a strong
    /// reference held while the sheet is up; `box` provides both.
    @MainActor
    private static func presentWebAuthentication(url: URL) async throws -> URL {
        final class SessionBox: @unchecked Sendable {
            var session: ASWebAuthenticationSession?
            var anchor: WebAuthAnchor?
        }
        let box = SessionBox()
        let anchor = WebAuthAnchor()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "https") { callbackURL, error in
                box.session = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? URLError(.cancelled))
                }
            }
            session.presentationContextProvider = anchor
            box.anchor = anchor
            session.prefersEphemeralWebBrowserSession = false
            box.session = session
            if !session.start() {
                continuation.resume(throwing: URLError(.cannotOpenFile))
            }
        }
    }
}

/// Presents the login sheet attached to the app's current window (menu-bar app: any window will do).
private final class WebAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}

extension AuthService {
    // MARK: Token endpoint

    /// Exchanges an authorization code for tokens and persists them.
    func exchange(code: String) async throws {
        let response = try await tokenResponse(fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("audience", audience),
            ("redirect_uri", Self.redirectURI),
        ])
        guard let refreshToken = response.refreshToken else { throw AuthError.reauthRequired }
        try keychain.saveToken(refreshToken, for: Self.refreshAccount)
        try keychain.saveToken(response.accessToken!, for: Self.accessAccount)
    }

    /// Refreshes via the stored refresh token (client_id only, no secret) and replaces both tokens.
    public func refresh() async throws {
        let oldRefreshToken: String
        do {
            oldRefreshToken = try keychain.readToken(Self.refreshAccount)
        } catch KeychainError.itemNotFound {
            throw AuthError.refreshTokenInvalid
        }
        let response = try await tokenResponse(fields: [
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", oldRefreshToken),
        ])
        // Single-use semantics: persist the replacement first, then the access token.
        if let refreshToken = response.refreshToken {
            try keychain.saveToken(refreshToken, for: Self.refreshAccount)
        } else {
            // Defense: token endpoint returned no new refresh token — keep the old one usable.
            logger.warning("token endpoint returned no refresh_token; keeping previous value")
        }
        try keychain.saveToken(response.accessToken!, for: Self.accessAccount)
    }

    /// Startup check (user story 33): silently refresh if the access token is expired or near expiry.
    public func ensureFreshAccessToken() async throws {
        guard let accessToken = try? keychain.readToken(Self.accessAccount),
              let expiry = Self.jwtExpiry(accessToken),
              expiry > Date().addingTimeInterval(60).timeIntervalSince1970
        else { return try await refresh() }
    }

    /// Current access token for API calls (ticket 05).
    public func currentAccessToken() throws -> String {
        try keychain.readToken(Self.accessAccount)
    }

    /// Runs `body`; on HTTP 401 refreshes once and retries once. Refresh failure → ``AuthError/reauthRequired``.
    public func authorized<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HTTPStatusError where error.status == 401 {
            do {
                try await refresh()
            } catch {
                throw AuthError.reauthRequired
            }
            return try await body()
        }
    }

    // MARK: Internals

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case error
        }
    }

    private func tokenResponse(fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (status, _, data) = try await transport.send(request)
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        switch status {
        case 200...299:
            guard let decoded, let token = decoded.accessToken, !token.isEmpty else { throw HTTPStatusError(status) }
            return decoded
        case 400, 401:
            throw AuthError.refreshTokenInvalid
        default:
            if decoded?.error == "login_required" { throw AuthError.refreshTokenInvalid }
            throw HTTPStatusError(status)
        }
    }

    /// `exp` claim (seconds since Unix epoch) of a JWT; nil when the payload is missing or unparseable.
    public static func jwtExpiry(_ jwt: String) -> TimeInterval? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        struct Payload: Decodable { let exp: TimeInterval }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.exp
    }
}
