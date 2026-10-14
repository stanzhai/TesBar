import Foundation
import os

/// Per-domain VCP handshake state for one vehicle, persisted to UserDefaults
/// (`vcpSession.{vin}.{domain}`) so a cold start skips the handshake round trip
/// (research §2; Go SDK CacheEntry equivalent).
struct VCPSessionRecord: Codable, Equatable, Sendable {
    var epoch: Data
    var counter: UInt32
    var clockTime: UInt32
    var vehiclePublicKey: Data
    /// Wall-clock seconds when the record was written; time-zero for expiresAt math.
    var savedAt: TimeInterval
}

/// Session manager for one vehicle: caches per-domain sessions in UserDefaults and
/// hands out incrementing command counters. The handshake HTTP round trip lives in
/// FleetTeslaClient (transport + endpoint are its concern); this type verifies replies.
///
/// NSLock, not actor: command sends and handshake replies can interleave, and callers
/// hold no awaits between the counter increment and the POST.
final class VCPSessionManager: @unchecked Sendable {
    private let defaults: UserDefaults
    private let vin: String
    private let logger = Logger(subsystem: "com.tesbar.app", category: "vcp-session")
    private var records: [VCPDomain: VCPSessionRecord] = [:]
    private var ks: [VCPDomain: Data] = [:]
    private let lock = NSLock()

    init(vin: String, defaults: UserDefaults) {
        self.vin = vin
        self.defaults = defaults
    }

    private func key(_ domain: VCPDomain) -> String { "vcpSession.\(vin).\(domain.rawValue)" }

    private func loadCached(_ domain: VCPDomain) -> VCPSessionRecord? {
        guard let data = defaults.data(forKey: key(domain)) else { return nil }
        return try? JSONDecoder().decode(VCPSessionRecord.self, from: data)
    }

    /// The cached record, or nil when no session exists for the domain yet.
    func record(_ domain: VCPDomain) -> VCPSessionRecord? {
        lock.lock(); defer { lock.unlock() }
        if let record = records[domain] { return record }
        guard let cached = loadCached(domain) else { return nil }
        records[domain] = cached
        return cached
    }

    /// Command counter = session.counter + 1, persisting the increment so a crash after
    /// send resumes past the used counter (protocol: counter must strictly increase).
    func nextCounter(_ domain: VCPDomain) -> UInt32? {
        guard var record = record(domain), record.counter != UInt32.max else { return nil }
        record.counter += 1
        lock.lock(); defer { lock.unlock() }
        records[domain] = record
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key(domain)) }
        return record.counter
    }

    /// Vehicle-domain seconds now (protocol: expiresAt is vehicle-clock seconds; a cached
    /// session anchors vehicle clock to `savedAt`, as Go's ImportSessionInfo timeZero does).
    func vehicleSeconds(_ domain: VCPDomain) -> UInt32? {
        guard let record = record(domain) else { return nil }
        let delta = Date().timeIntervalSince1970 - record.savedAt
        return record.clockTime &+ UInt32(max(0, delta.rounded()))
    }

    /// Drops the cached session (handshake re-runs on the next command).
    func invalidate(_ domain: VCPDomain) {
        lock.lock(); defer { lock.unlock() }
        records[domain] = nil
        ks[domain] = nil
        defaults.removeObject(forKey: key(domain))
    }

    @discardableResult
    func processHello(
        domain: VCPDomain, sessionInfoBytes: Data, tag: Data, challenge: Data,
        clientPrivateKey: SecKey
    ) throws -> VCPSessionRecord? {
        let info: SessionInfo
        let k: Data
        do {
            info = try SessionInfo.decode(sessionInfoBytes)
            k = SessionCrypto.sharedKey(fromSecret: try ECKeyPair.sharedSecret(
                privateKey: clientPrivateKey, peerPublicKey: info.publicKey))
        } catch {
            logger.warning("session info malformed for domain \(domain.rawValue): \(error)")
            return nil
        }
        guard SessionCrypto.verifySessionInfo(
            tag: tag, sessionInfoBytes: sessionInfoBytes, vin: vin, challenge: challenge, k: k
        ) else {
            logger.warning("session info HMAC invalid for domain \(domain.rawValue)")
            return nil
        }
        // protocol.md recovery rules: a same-epoch update must not roll back the clock
        // (stale info is discarded) or the anti-replay counter; a new epoch resets both.
        let old = record(domain)
        var counter = info.counter
        if let old, old.epoch == info.epoch {
            guard info.clockTime >= old.clockTime else { return nil }
            counter = max(old.counter, info.counter)
        }
        let record = VCPSessionRecord(
            epoch: info.epoch, counter: counter, clockTime: info.clockTime,
            vehiclePublicKey: info.publicKey, savedAt: Date().timeIntervalSince1970)
        lock.lock(); defer { lock.unlock() }
        records[domain] = record
        ks[domain] = k
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key(domain)) }
        return record
    }

    /// Session for command authorization, or nil when no session is cached for the domain.
    func session(_ domain: VCPDomain, clientPrivateKey: SecKey) throws -> VCPSession? {
        guard let record = record(domain) else { return nil }
        lock.lock()
        let cachedK = ks[domain]
        lock.unlock()
        let k: Data
        if let cachedK {
            k = cachedK
        } else {
            k = SessionCrypto.sharedKey(fromSecret: try ECKeyPair.sharedSecret(
                privateKey: clientPrivateKey, peerPublicKey: record.vehiclePublicKey))
            lock.lock(); ks[domain] = k; lock.unlock()
        }
        return VCPSession(
            epoch: record.epoch, counter: record.counter, clockTime: record.clockTime,
            vehiclePublicKey: record.vehiclePublicKey, k: k)
    }
}
