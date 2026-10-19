import Foundation
import Testing

@testable import TesBar

/// Scripted transport for the 421/Alt-Svc flow: replays scripted responses in order,
/// records each request URL for asserting the retry base.
private final class ScriptedHTTPTransport: HTTPExecuting, @unchecked Sendable {
    struct Call { let url: URL }

    private(set) var calls: [Call] = []
    private var script: [(status: Int, headers: [String: String], body: Data)]

    init(_ script: [(status: Int, headers: [String: String], body: String)]) {
        self.script = script.map { (status: $0.status, headers: $0.headers, body: Data($0.body.utf8)) }
    }

    /// Script entries without a body.
    convenience init(_ script: [(status: Int, headers: [String: String])]) {
        self.init(script.map { (status: $0.status, headers: $0.headers, body: "") })
    }

    func send(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        calls.append(Call(url: request.url!))
        guard !script.isEmpty else { throw HTTPStatusError(500) }
        return script.removeFirst()
    }
}

/// Isolated UserDefaults per test.
private func isolatedDefaults() -> UserDefaults {
    let suite = "RegionResolverTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

struct RegionResolverTests {
    private let naHost = "fleet-api.prd.na.vn.cloud.tesla.com"

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://\(RegionResolver.defaultBaseURL.host!)/api/1/vehicles?offset=0")!)
    }

    // MARK: baseURL defaults + persistence

    @Test func defaultBaseURLWhenNothingCached() {
        let resolver = RegionResolver(defaults: isolatedDefaults())
        #expect(resolver.baseURL == RegionResolver.defaultBaseURL)
    }

    @Test func handle421UpdatesAndPersistsBaseURL() {
        let defaults = isolatedDefaults()
        let resolver = RegionResolver(defaults: defaults)
        #expect(resolver.handle421(headers: ["alt-svc": "h2=\(naHost)"]))
        #expect(resolver.baseURL == URL(string: "https://\(naHost)")!)
        // persisted: a fresh resolver over the same defaults sees it
        #expect(RegionResolver(defaults: defaults).baseURL == URL(string: "https://\(naHost)")!)
    }

    // MARK: Alt-Svc parsing

    @Test func altSvcVariants() {
        #expect(RegionResolver.altSvcHost(["alt-svc": "h2=\(naHost)"]) == naHost)
        #expect(RegionResolver.altSvcHost(["Alt-Svc": "h2=\(naHost)"]) == naHost)
        #expect(RegionResolver.altSvcHost(["alt-svc": "h2=\"\(naHost)\"; ma=86400"]) == naHost)
        #expect(RegionResolver.altSvcHost(["alt-svc": "h3=\"other\"; ma=60, h2=\(naHost)"]) == naHost)
        #expect(RegionResolver.altSvcHost(["alt-svc": "h3=\"\(naHost)\""]) == nil)
        #expect(RegionResolver.altSvcHost(["alt-svc": ""]) == nil)
        #expect(RegionResolver.altSvcHost([:]) == nil)
    }

    // MARK: manual override

    @Test func manualOverrideWinsAndIsNotClobberedBy421() {
        let defaults = isolatedDefaults()
        let resolver = RegionResolver(defaults: defaults)
        resolver.setOverride("https://custom.example.com")
        #expect(resolver.baseURL == URL(string: "https://custom.example.com")!)

        #expect(resolver.handle421(headers: ["alt-svc": "h2=\(naHost)"]))
        #expect(resolver.baseURL == URL(string: "https://custom.example.com")!)
        // cache untouched: clearing the override falls back to the default (nothing was written)
        resolver.setOverride("")
        #expect(resolver.baseURL == RegionResolver.defaultBaseURL)
    }

    @Test func emptyOverrideMeansAuto() {
        let resolver = RegionResolver(defaults: isolatedDefaults())
        resolver.setOverride("")
        #expect(resolver.baseURL == RegionResolver.defaultBaseURL)
    }

    // MARK: RegionRedirectTransport

    @Test func redirect421RetriesOnceAgainstNewBase() async throws {
        let defaults = isolatedDefaults()
        let transport = ScriptedHTTPTransport([
            (status: 421, headers: ["alt-svc": "h2=\(naHost)"], body: ""),
            (status: 200, headers: ["content-type": "application/json"], body: #"{"response":"[]"}"#),
        ])
        let wrapped = RegionRedirectTransport(base: transport, resolver: RegionResolver(defaults: defaults))

        let response = try await wrapped.send(makeRequest())

        #expect(response.status == 200)
        #expect(transport.calls.count == 2)
        #expect(transport.calls[0].url.host == RegionResolver.defaultBaseURL.host)
        #expect(transport.calls[1].url.host == naHost)
        // path/query preserved on the retry
        #expect(transport.calls[1].url.path == "/api/1/vehicles")
        #expect(transport.calls[1].url.query == "offset=0")
        #expect(RegionResolver(defaults: defaults).baseURL == URL(string: "https://\(naHost)")!)
    }

    @Test func redirect421WithoutAltSvcRethrows() async {
        let resolver = RegionResolver(defaults: isolatedDefaults())
        let transport = ScriptedHTTPTransport([(status: 421, headers: ["content-type": "text/plain"], body: "Misdirected Request")])
        let wrapped = RegionRedirectTransport(base: transport, resolver: resolver)

        await #expect(throws: HTTPStatusError.self) {
            _ = try await wrapped.send(makeRequest())
        }
        #expect(transport.calls.count == 1)
        #expect(resolver.baseURL == RegionResolver.defaultBaseURL)
    }

    @Test func non421PassesThroughUntouched() async throws {
        let resolver = RegionResolver(defaults: isolatedDefaults())
        let transport = ScriptedHTTPTransport([(status: 404, headers: [:], body: "")])
        let wrapped = RegionRedirectTransport(base: transport, resolver: resolver)

        let response = try await wrapped.send(makeRequest())

        #expect(response.status == 404)
        #expect(transport.calls.count == 1)
        #expect(transport.calls[0].url.host == RegionResolver.defaultBaseURL.host)
        #expect(resolver.baseURL == RegionResolver.defaultBaseURL)
    }

    @Test func manualOverrideRedirectStillServesOverrideBase() async throws {
        let defaults = isolatedDefaults()
        let resolver = RegionResolver(defaults: defaults)
        resolver.setOverride("https://custom.example.com")
        let transport = ScriptedHTTPTransport([
            (status: 421, headers: ["alt-svc": "h2=\(naHost)"], body: ""),
            (status: 200, headers: [:], body: ""),
        ])
        let wrapped = RegionRedirectTransport(base: transport, resolver: resolver)

        let response = try await wrapped.send(URLRequest(url: URL(string: "https://irrelevant.example.com/api/1/vehicles")!))

        // retry went to the override base, not the Alt-Svc host
        #expect(response.status == 200)
        #expect(transport.calls[1].url.host == "custom.example.com")
    }
}
