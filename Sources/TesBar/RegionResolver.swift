import Foundation

/// Fleet API region: default baseURL + 421/`Alt-Svc: h2=<host>` redirect handling
/// (research §0.3/§1 — the `fleet_api_metadata` endpoint does not exist).
///
/// A manual override (settings string, empty = auto) always wins: `handle421` never
/// rewrites it, and `baseURL` returns it even when a redirect was cached.
public final class RegionResolver: @unchecked Sendable {
    /// Spec single-region default (research §0.3).
    public static let defaultBaseURL = URL(string: "https://fleet-api.prd.cn.vn.cloud.tesla.cn")!
    static let cachedKey = "fleetAPIBaseURL"
    static let overrideKey = "fleetAPIBaseURLOverride"

    /// UserDefaults is documented thread-safe; its missing Sendable conformance is an overlay gap.
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current base URL: manual override if set (empty string = auto), else the last
    /// 421-resolved URL, else the spec default.
    public var baseURL: URL {
        lock.lock(); defer { lock.unlock() }
        if let override = defaults.string(forKey: Self.overrideKey), !override.isEmpty {
            return URL(string: override) ?? Self.defaultBaseURL
        }
        guard let cached = defaults.string(forKey: Self.cachedKey) else { return Self.defaultBaseURL }
        return URL(string: cached) ?? Self.defaultBaseURL
    }

    /// Manual override from settings; empty string (or nil) clears it back to auto.
    public func setOverride(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        if value.isEmpty {
            defaults.removeObject(forKey: Self.overrideKey)
        } else {
            defaults.set(value, forKey: Self.overrideKey)
        }
    }

    /// Parses `Alt-Svc: h2=<host>` from a 421 response and persists the new base URL.
    /// The override is never clobbered. Returns false when no usable entry exists.
    @discardableResult
    public func handle421(headers: [String: String]) -> Bool {
        guard let host = Self.altSvcHost(headers) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !isOverrideActive else { return true }  // manual override wins; keep it
        defaults.set("https://\(host)", forKey: Self.cachedKey)
        return true
    }

    private var isOverrideActive: Bool {
        guard let override = defaults.string(forKey: Self.overrideKey) else { return false }
        return !override.isEmpty
    }

    /// Extracts the authority host from an Alt-Svc entry naming the `h2` protocol.
    static func altSvcHost(_ headers: [String: String]) -> String? {
        // Header names are lowercased by the transport; accept either case defensively.
        guard let value = headers["alt-svc"] ?? headers["Alt-Svc"] else { return nil }
        // ponytail: no full RFC 7838 parser — first h2= token, no parameter stripping;
        // Tesla sends a single plain entry. Parse quoted/multi-value forms if they appear.
        for entry in value.split(separator: ",") {
            let parts = entry.split(separator: ";", maxSplits: 1).first?
                .split(separator: "=", maxSplits: 1) ?? []
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "h2" else { continue }
            let authority = parts[1].trimmingCharacters(in: .whitespaces)
            var host = authority
            if host.hasPrefix("\"") && host.hasSuffix("\"") && host.count >= 2 {
                host = String(host.dropFirst().dropLast())
            }
            if !host.isEmpty { return host }
        }
        return nil
    }
}

/// Transport middleware (seam for ticket 05's FleetTeslaClient): sends via the wrapped
/// transport; on 421 consults the resolver and retries **once** against the new base.
/// A 421 without a usable Alt-Svc rethrows; the retried request's error propagates as-is.
public struct RegionRedirectTransport: HTTPExecuting {
    private let base: any HTTPExecuting
    private let resolver: RegionResolver

    public init(base: any HTTPExecuting, resolver: RegionResolver) {
        self.base = base
        self.resolver = resolver
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        let response = try await base.send(request)
        guard response.status == 421 else { return response }
        guard resolver.handle421(headers: response.headers) else { throw HTTPStatusError(421) }
        // Alt-Svc is authority-form: the new base replaces scheme+host, path/query stay.
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw HTTPStatusError(421) }
        let newBase = URLComponents(url: resolver.baseURL, resolvingAgainstBaseURL: false)
        components.scheme = newBase?.scheme ?? "https"
        components.host = newBase?.host
        components.port = newBase?.port
        guard let retried = components.url else { throw HTTPStatusError(421) }
        var retry = request
        retry.url = retried
        return try await base.send(retry)
    }
}
