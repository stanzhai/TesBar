import Foundation
import Testing

@testable import TesBar

/// 独立 defaults（suite 删除清理），与 06 的 isolatedDefaults 同法。
private func isolatedDefaults() -> UserDefaults {
    let suite = "SetupWizardTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// 独立 Keychain 服务名，测试结束删除条目（同 03/04 惯例）。
private func isolatedKeychain() -> KeychainStore {
    KeychainStore(service: "SetupWizardTests-\(UUID().uuidString)")
}

@available(macOS 14, *)
@MainActor
private func makeWizard(
    defaults: UserDefaults? = nil,
    keychain: KeychainStore? = nil,
    loggedIn: Bool = false,
    vehicles: [VehicleListEntry] = [VehicleListEntry(id: "v1", name: "My Tesla")],
    listError: Error? = nil
) -> SetupWizard {
    let keychain = keychain ?? isolatedKeychain()
    if loggedIn { try? keychain.saveToken("refresh-token", for: AuthService.refreshAccount) }
    // login()（ASWebAuthenticationSession）不在单测范围；authFactory 仅在 login()/verify()
    // 构造，测试不走 login()，verify() 用假 client，永不触网。
    return SetupWizard(
        defaults: defaults ?? isolatedDefaults(),
        keychain: keychain,
        keys: VCPKeyManager(),
        clientFactory: { _ in WizardFakeClient(vehicles: vehicles, listError: listError) }
    )
}

// MARK: - 步骤状态机

@available(macOS 14, *) @Test func stepFlowAdvancesSkipsAndBacks() {
    var flow = SetupStepFlow()
    #expect(flow.step == .login)
    flow.next()
    #expect(flow.step == .pair)
    flow.back()
    #expect(flow.step == .login)
    flow.next(); flow.next()
    #expect(flow.step == .done)
    flow.next()  // done 停住
    #expect(flow.step == .done)
}

@available(macOS 14, *) @Test func loginStepCannotGoBack() {
    var flow = SetupStepFlow()
    flow.back()
    #expect(flow.step == .login)
}

@available(macOS 14, *) @Test func resumingPicksStartStepFromLoginState() {
    #expect(SetupStepFlow.resuming(isLoggedIn: true).step == .pair)
    #expect(SetupStepFlow.resuming(isLoggedIn: false).step == .login)
}

@available(macOS 14, *) @MainActor @Test func loggedInWizardResumesAtPair() {
    let wizard = makeWizard(loggedIn: true)
    #expect(wizard.flow.step == .pair)
    #expect(wizard.isLoggedIn)
}

// MARK: - 配对 URL（内置域名）

@available(macOS 14, *) @Test func pairingURLConstruction() {
    #expect(SetupWizard.pairingURL(domain: "example.com")?.absoluteString == "https://tesla.cn/_ak/example.com")
    #expect(SetupWizard.pairingURL(domain: "  example.com  ")?.absoluteString == "https://tesla.cn/_ak/example.com")
    #expect(SetupWizard.pairingURL(domain: "a b.com")?.absoluteString == "https://tesla.cn/_ak/a%20b.com")
    #expect(SetupWizard.pairingURL(domain: "") == nil)
    #expect(SetupWizard.pairingURL(domain: "   ") == nil)
}

// MARK: - 完成标记

@available(macOS 14, *) @MainActor @Test func completionFlagSetOnDoneAndClearBefore() {
    let defaults = isolatedDefaults()
    let wizard = makeWizard(defaults: defaults)
    #expect(!wizard.isComplete)
    wizard.skip()  // login → pair
    #expect(wizard.flow.step == .pair)
    #expect(!wizard.isComplete)
    wizard.complete()
    #expect(wizard.flow.step == .done)
    #expect(defaults.bool(forKey: SetupWizard.completeKey))
    #expect(wizard.isComplete)
}

@available(macOS 14, *) @MainActor @Test func finishedCallbackFiresOnceOnDone() {
    let wizard = makeWizard(defaults: isolatedDefaults())
    var fires = 0
    wizard.onFinished = { fires += 1 }
    wizard.skip()  // login → pair
    #expect(fires == 0)
    wizard.complete()  // pair → done
    #expect(fires == 1)
    wizard.skip()  // done 停住，不再触发
    #expect(fires == 1)
}

@available(macOS 14, *) @MainActor @Test func skipWalksAllTheWayToDone() {
    let defaults = isolatedDefaults()
    let wizard = makeWizard(defaults: defaults)
    for _ in 0..<2 { wizard.skip() }
    #expect(wizard.flow.step == .done)
    #expect(wizard.isComplete)
}

@available(macOS 14, *) @MainActor @Test func completeOnlyWorksFromPair() {
    let defaults = isolatedDefaults()
    let wizard = makeWizard(defaults: defaults)
    wizard.complete()  // 仍在 login
    #expect(wizard.flow.step == .login)
    #expect(!wizard.isComplete)
}

// MARK: - 配对步验证

@available(macOS 14, *) @MainActor @Test func verifyListsVehicles() async {
    let wizard = makeWizard(vehicles: [
        VehicleListEntry(id: "1", name: "Alpha"), VehicleListEntry(id: "2", name: "Beta")
    ])
    wizard.skip()  // → pair
    await wizard.verify()
    #expect(wizard.vehicles.map(\.name) == ["Alpha", "Beta"])
    #expect(wizard.error == nil)
}

@available(macOS 14, *) @MainActor @Test func verifyErrorSurfacesWithoutCompleting() async {
    let wizard = makeWizard(listError: URLError(.notConnectedToInternet))
    wizard.skip()
    await wizard.verify()
    #expect(wizard.vehicles.isEmpty)
    #expect(wizard.error != nil)
    #expect(!wizard.isComplete)
}

@available(macOS 14, *) @Test func authErrorsMapToGuidance() {
    #expect(SetupWizard.guidanceMessage(AuthError.reauthRequired).contains("重新登录"))
    #expect(SetupWizard.guidanceMessage(AuthError.refreshTokenInvalid).contains("重新登录"))
    // Bad client_id/secret 指向构建注入的凭据，不是"重登"。
    let msg = SetupWizard.guidanceMessage(AuthError.clientCredentialsRejected("combo invalid"))
    #expect(msg.contains("client_id"))
    #expect(msg.contains("combo invalid"))
    #expect(!msg.contains("重新登录"))
}

/// 向导用的最小 TeslaClient 假实现（ScriptedTeslaClient 的 listVehicles 固定返回空，单独造一个）。
private struct WizardFakeClient: TeslaClient {
    let vehicles: [VehicleListEntry]
    let listError: Error?

    func listVehicles() async throws -> [VehicleListEntry] {
        if let listError { throw listError }
        return vehicles
    }

    func vehicleData(id: String) async throws -> VehicleSnapshot {
        ScriptedTeslaClient.snapshot(state: .online)
    }

    func wake(id: String) async throws {}

    func signAndSend(command: VehicleCommand, vehicleID: String) async throws {}

    func refreshAccessToken() async throws {}
}
