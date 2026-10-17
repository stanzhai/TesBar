import Foundation
import Testing

@testable import TesBar

/// Scripted transport: records requests, replays scripted responses in order.
private final class StubTransport: HTTPExecuting, @unchecked Sendable {
    struct Call { let request: URLRequest; let body: [String: String] }

    private(set) var calls: [Call] = []
    private var script: [(status: Int, headers: [String: String], body: Data)]

    init(_ script: [(status: Int, json: String)]) {
        self.script = script.map {
            (status: $0.status, headers: ["content-type": "application/json"], body: Data($0.json.utf8))
        }
    }

    func send(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        calls.append(Call(request: request, body: Self.fields(request)))
        guard !script.isEmpty else { throw HTTPStatusError(500) }
        return script.removeFirst()
    }

    /// Decodes a form-urlencoded body into a field dictionary (values percent-decoded).
    static func fields(_ request: URLRequest) -> [String: String] {
        guard let data = request.httpBody ?? request.httpBodyStream.map({ stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }) else { return [:] }
        let query = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            // Form semantics: a literal `+` in a value must arrive percent-encoded
            // (%2B); decoding it as space would mask exactly the bug under test.
            let value = parts[1].replacingOccurrences(of: "+", with: "%2B")
            fields[parts[0]] = value.removingPercentEncoding ?? value
        }
        return fields
    }
}

/// Minimal JWT: header.payload.signature, payload carries `exp` only.
private func jwt(exp: TimeInterval) -> String {
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64(#"{"alg":"RS256"}"#)).\(b64(#"{"exp":\#(exp)}"#)).sig"
}

@Suite(.serialized)  // fixed Keychain accounts are shared — serialize the tests
struct AuthServiceTests {
    /// Scripted happy-path exchange response.
    private static func exchangeOK(refresh: String = "rt-new") -> String {
        #"{"access_token":"\#(jwt(exp: Date().addingTimeInterval(28800).timeIntervalSince1970))","refresh_token":"\#(refresh)","expires_in":28800}"#
    }
    private static let refreshOK = #"{"access_token":"at2","refresh_token":"rt2","expires_in":28800}"#

    private func makeService(_ transport: StubTransport) -> AuthService {
        AuthService(
            clientID: "cid", clientSecret: "secret",
            audience: "https://fleet-api.prd.cn.vn.cloud.tesla.cn",
            transport: transport, keychain: KeychainStore()
        )
    }

    // MARK: jwtExpiry

    @Test func jwtExpiryParsesPayloadExp() throws {
        let exp = Date().addingTimeInterval(1234).timeIntervalSince1970
        let parsed = try AuthService.jwtExpiry(jwt(exp: exp))
        #expect(parsed.map { abs($0 - exp) < 1 } == true)
    }

    @Test func jwtExpiryMalformedReturnsNil() {
        #expect(AuthService.jwtExpiry("not-a-jwt") == nil)
        #expect(AuthService.jwtExpiry(#"h.eyJpYXQiOjEyM30.s"#) == nil)  // payload decodes but has no exp
        #expect(AuthService.jwtExpiry("h.!!not-base64!!.s") == nil)
    }

    // MARK: authorize → exchange request fields

    @Test func exchangeRequestBodyFields() async throws {
        let transport = StubTransport([(status: 200, json: Self.exchangeOK())])
        let service = makeService(transport)

        try await service.exchange(code: "the-code")

        let call = try #require(transport.calls.first)
        #expect(call.request.url == AuthService.tokenEndpoint)
        #expect(call.request.httpMethod == "POST")
        #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(call.body["grant_type"] == "authorization_code")
        #expect(call.body["code"] == "the-code")
        #expect(call.body["client_id"] == "cid")
        #expect(call.body["client_secret"] == "secret")
        #expect(call.body["audience"] == "https://fleet-api.prd.cn.vn.cloud.tesla.cn")
        #expect(call.body["redirect_uri"] == AuthService.redirectURI)

        let access = try await service.currentAccessToken()
        #expect(AuthService.jwtExpiry(access) != nil)  // persisted the exchanged access token
    }

    // MARK: refresh

    @Test func refreshPersistsBothTokensAtomically() async throws {
        let transport = StubTransport([(status: 200, json: Self.refreshOK)])
        let service = makeService(transport)
        try KeychainStore().saveToken("rt1", for: AuthService.refreshAccount)
        try KeychainStore().saveToken("at1", for: AuthService.accessAccount)
        defer {
            try? KeychainStore().deleteToken(AuthService.refreshAccount)
            try? KeychainStore().deleteToken(AuthService.accessAccount)
        }

        try await service.refresh()

        #expect(try await service.currentAccessToken() == "at2")
        #expect(try KeychainStore().readToken(AuthService.refreshAccount) == "rt2")
        let call = try #require(transport.calls.first)
        #expect(call.body["grant_type"] == "refresh_token")
        #expect(call.body["client_id"] == "cid")
        #expect(call.body["refresh_token"] == "rt1")
        #expect(call.body["client_secret"] == nil)
    }

    @Test func refreshResponseWithoutNewRefreshTokenKeepsOld() async throws {
        let store = KeychainStore()
        try store.saveToken("rt-old", for: AuthService.refreshAccount)
        try store.saveToken("at-old", for: AuthService.accessAccount)
        defer {
            try? store.deleteToken(AuthService.refreshAccount)
            try? store.deleteToken(AuthService.accessAccount)
        }
        let transport = StubTransport([(status: 200, json: #"{"access_token":"at-new","expires_in":28800}"#)])
        let service = makeService(transport)

        try await service.refresh()

        #expect(try await service.currentAccessToken() == "at-new")
        #expect(try store.readToken(AuthService.refreshAccount) == "rt-old")
    }

    @Test func refreshWithoutStoredRefreshTokenThrowsInvalid() async throws {
        try? KeychainStore().deleteToken(AuthService.refreshAccount)
        let service = makeService(StubTransport([(status: 200, json: Self.refreshOK)]))

        await #expect(throws: AuthError.refreshTokenInvalid) { try await service.refresh() }
    }

    @Test func tokenEndpointInvalidGrantMapsToRefreshTokenInvalid() async throws {
        let store = KeychainStore()
        try store.saveToken("rt1", for: AuthService.refreshAccount)
        defer { try? store.deleteToken(AuthService.refreshAccount) }
        for status in [400, 401] {
            // One scripted response per call: first refresh(), then exchange().
            let transport = StubTransport([
                (status: status, json: #"{"error":"invalid_grant"}"#),
                (status: status, json: #"{"error":"invalid_grant"}"#),
            ])
            let service = makeService(transport)
            await #expect(throws: AuthError.refreshTokenInvalid) { try await service.refresh() }
            await #expect(throws: AuthError.refreshTokenInvalid) {
                try await service.exchange(code: "c")
            }
        }
    }

    @Test func unauthorizedClientMapsToClientCredentialsRejected() async throws {
        // Probed against auth.tesla.cn: real client_id + wrong secret returns this body.
        let transport = StubTransport([
            (status: 400, json: #"{"error":"unauthorized_client","error_description":"The 'client_id' and 'client_secret' combination is invalid."}"#),
        ])
        let service = makeService(transport)

        await #expect(throws: AuthError.clientCredentialsRejected(
            "The 'client_id' and 'client_secret' combination is invalid.")) {
            try await service.exchange(code: "c")
        }
    }

    @Test func loginRequiredBodyMapsToRefreshTokenInvalid() async throws {
        let store = KeychainStore()
        try store.saveToken("rt1", for: AuthService.refreshAccount)
        defer { try? store.deleteToken(AuthService.refreshAccount) }
        let transport = StubTransport([(status: 403, json: #"{"error":"login_required"}"#)])
        let service = makeService(transport)

        await #expect(throws: AuthError.refreshTokenInvalid) { try await service.refresh() }
    }

    // MARK: form encoding

    @Test func formBodyPercentEncodesSpecialCharactersInSecret() async throws {
        let transport = StubTransport([(status: 200, json: Self.exchangeOK())])
        let service = AuthService(
            clientID: "cid", clientSecret: "ab+cd&ef=gh ij%",
            audience: "aud", transport: transport, keychain: KeychainStore()
        )

        try await service.exchange(code: "the-code")

        let body = String(decoding: transport.calls[0].request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("client_secret=ab%2Bcd%26ef%3Dgh%20ij%25"))
        #expect(transport.calls[0].body["client_secret"] == "ab+cd&ef=gh ij%")
    }

    // MARK: authorized: 401 retry

    /// Sendable attempt counter for @Sendable bodies under Swift 6.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        @discardableResult func incrementAndReturn() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    @Test func authorizedRefreshesOnceOn401AndRetries() async throws {
        // First API call 401s; refresh succeeds; retry succeeds.
        let transport = StubTransport([(status: 200, json: Self.refreshOK)])
        let service = makeService(transport)
        try KeychainStore().saveToken("rt1", for: AuthService.refreshAccount)
        try KeychainStore().saveToken("at1", for: AuthService.accessAccount)
        defer {
            try? KeychainStore().deleteToken(AuthService.refreshAccount)
            try? KeychainStore().deleteToken(AuthService.accessAccount)
        }

        let attempts = Counter()
        let result = try await service.authorized { () -> String in
            let n = attempts.incrementAndReturn()
            if n == 1 { throw HTTPStatusError(401) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts.count == 2)
        #expect(try await service.currentAccessToken() == "at2")  // refresh actually persisted
    }

    @Test func authorizedRefreshFailureThrowsReauthRequiredAndDoesNotRetry() async throws {
        let transport = StubTransport([(status: 400, json: #"{"error":"invalid_grant"}"#)])
        let service = makeService(transport)
        try KeychainStore().saveToken("rt-bad", for: AuthService.refreshAccount)
        defer { try? KeychainStore().deleteToken(AuthService.refreshAccount) }

        let attempts = Counter()
        await #expect(throws: AuthError.reauthRequired) {
            _ = try await service.authorized { () -> String in
                attempts.incrementAndReturn()
                throw HTTPStatusError(401)
            }
        }
        #expect(attempts.count == 1)  // body not retried after failed refresh
    }

    @Test func authorizedPassesThroughNon401Errors() async throws {
        let service = makeService(StubTransport([]))
        await #expect(throws: HTTPStatusError.self) {
            _ = try await service.authorized { () -> String in throw HTTPStatusError(500) }
        }
    }

    // MARK: startup exp check

    @Test func ensureFreshAccessTokenRefreshesWhenExpired() async throws {
        let store = KeychainStore()
        try store.saveToken("rt1", for: AuthService.refreshAccount)
        try store.saveToken(jwt(exp: Date().timeIntervalSince1970 - 10), for: AuthService.accessAccount)
        defer {
            try? store.deleteToken(AuthService.refreshAccount)
            try? store.deleteToken(AuthService.accessAccount)
        }
        let transport = StubTransport([(status: 200, json: Self.refreshOK)])
        let service = makeService(transport)

        try await service.ensureFreshAccessToken()

        #expect(try await service.currentAccessToken() == "at2")
    }

    @Test func ensureFreshAccessTokenSkipsWhenValid() async throws {
        let store = KeychainStore()
        try store.saveToken("rt1", for: AuthService.refreshAccount)
        try store.saveToken(jwt(exp: Date().addingTimeInterval(3600).timeIntervalSince1970), for: AuthService.accessAccount)
        defer {
            try? store.deleteToken(AuthService.refreshAccount)
            try? store.deleteToken(AuthService.accessAccount)
        }
        let transport = StubTransport([])
        let service = makeService(transport)

        try await service.ensureFreshAccessToken()

        #expect(transport.calls.isEmpty)
    }
}
