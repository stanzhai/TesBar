import Foundation
import Security

@testable import TesBar

/// 脚本化假 TeslaClient：每个方法按预设队列返回结果，队列耗尽后重复最后一个（空队列用内置默认）。
/// 记录调用名顺序与发出的指令，供测试断言"先 Wake 后发令"等编排行为。
actor ScriptedTeslaClient: TeslaClient {
    private(set) var calls: [String] = []
    private(set) var sentCommands: [VehicleCommand] = []

    private var listScript: [Result<[VehicleListEntry], Error>]
    private var dataScript: [Result<VehicleSnapshot, Error>]
    private var wakeScript: [Result<Void, Error>]
    private var sendScript: [Result<Void, Error>]

    init(
        list: [Result<[VehicleListEntry], Error>] = [],
        data: [Result<VehicleSnapshot, Error>] = [],
        wake: [Result<Void, Error>] = [],
        send: [Result<Void, Error>] = []
    ) {
        listScript = list
        dataScript = data
        wakeScript = wake
        sendScript = send
    }

    func listVehicles() async throws -> [VehicleListEntry] {
        calls.append("listVehicles")
        return try next(&listScript, fallback: .success([Self.entry(state: "online")])).get()
    }

    /// 默认单辆在线车（id "v1"）。
    static func entry(state: String = "online") -> VehicleListEntry {
        VehicleListEntry(id: "v1", name: "My Tesla", vin: "VIN", state: state)
    }

    func vehicleData(id: String) async throws -> VehicleSnapshot {
        calls.append("vehicleData")
        return try next(&dataScript, fallback: .success(Self.snapshot(state: .online))).get()
    }

    func wake(id: String) async throws {
        calls.append("wake")
        try next(&wakeScript, fallback: .success(())).get()
    }

    func signAndSend(command: VehicleCommand, vehicleID: String) async throws {
        calls.append("signAndSend")
        sentCommands.append(command)
        try next(&sendScript, fallback: .success(())).get()
    }

    func refreshAccessToken() async throws {
        calls.append("refreshAccessToken")
    }

    /// 队列多于一个时消费队头；只剩最后一个时反复返回它；空队列返回 fallback。
    private func next<T>(_ script: inout [Result<T, Error>], fallback: Result<T, Error>) -> Result<T, Error> {
        if script.count > 1 { return script.removeFirst() }
        return script.last ?? fallback
    }

    /// 最小可用快照，测试按需换 state。
    static func snapshot(state: VehicleSnapshot.State) -> VehicleSnapshot {
        VehicleSnapshot(
            charge: .init(batteryPercent: 50, rangeKm: 200, state: "Stopped", minutesToFull: nil),
            climate: .init(insideC: nil, outsideC: nil),
            doors: .init(locked: true, frontTrunkOpen: false, rearTrunkOpen: false),
            odometerKm: 1000,
            state: state,
            timestampMs: 0
        )
    }
}

/// 模拟构建注入的共享 VCP 私钥（ADR-0004）：进程级单例 PEM，
/// 所有 client 实例共用一把钥匙（与生产 BuildConfig 语义一致）。
enum EmbeddedTestKey {
    static let privateKeyPEM: String = {
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ] as CFDictionary, &err)!
        let raw = SecKeyCopyExternalRepresentation(priv, nil)! as Data
        func tlv(_ tag: UInt8, _ content: Data) -> Data {
            [tag] + [UInt8(content.count)] + content
        }
        let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let sec1 = [tlv(0x02, Data([1])),
                    tlv(0x04, raw.suffix(32)),
                    tlv(0xA0, tlv(0x06, p256OID)),
                    tlv(0xA1, tlv(0x03, Data([0x00]) + raw.prefix(65)))]
            .reduce(into: Data(), +=)
        let der = tlv(0x30, sec1)
        let b64 = der.base64EncodedString()
        var out = "-----BEGIN EC PRIVATE KEY-----\n"
        var start = b64.startIndex
        while start < b64.endIndex {
            let end = b64.index(start, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[start..<end] + "\n"
            start = end
        }
        return out + "-----END EC PRIVATE KEY-----\n"
    }()

    /// 安装为全局共享私钥；返回复原闭包。
    @discardableResult
    static func install() -> () -> Void {
        let previous = VCPKeyManager.overridePrivateKeyPEM
        VCPKeyManager.overridePrivateKeyPEM = privateKeyPEM
        return { VCPKeyManager.overridePrivateKeyPEM = previous }
    }
}
