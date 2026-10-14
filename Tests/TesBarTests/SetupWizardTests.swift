import Foundation
import Testing

@testable import TesBar

/// ticket 10：SetupWizard 状态机 + 持久化 + 配对 URL + 完成标记。
/// UI 不测（编译即验收）；SetupWizard 依赖注入 defaults/keychain/auth/client，全在此脚本化。
/// `@Test` 与 `@available` 不能同置一函数（同 06），故测试为带标注的自由函数。

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
        keys: VCPKeyManager(store: keychain),
        clientFactory: { _ in WizardFakeClient(vehicles: vehicles, listError: listError) }
    )
}

// MARK: - 步骤状态机

@available(macOS 14, *) @Test func stepFlowAdvancesSkipsAndBacks() {
    var flow = SetupStepFlow()
    #expect(flow.step == .credentials)
    flow.next()
    #expect(flow.step == .login)
    flow.back()
    #expect(flow.step == .credentials)
    flow.next(); flow.next(); flow.next(); flow.next()
    #expect(flow.step == .done)
    flow.next()  // done 停住
    #expect(flow.step == .done)
}

@available(macOS 14, *) @Test func credentialsStepCannotGoBack() {
    var flow = SetupStepFlow()
    flow.back()
    #expect(flow.step == .credentials)
}

@available(macOS 14, *) @Test func resumingLoggedInSkipsToKeyPair() {
    #expect(SetupStepFlow.resuming(isLoggedIn: true).step == .keyPair)
    #expect(SetupStepFlow.resuming(isLoggedIn: false).step == .credentials)
}

@available(macOS 14, *) @MainActor @Test func freshWizardWithLoginResumesAtKeyPair() {
    let wizard = makeWizard(loggedIn: true)
    #expect(wizard.flow.step == .keyPair)
    #expect(wizard.isLoggedIn)
}

// MARK: - 凭据持久化 / 加载

@available(macOS 14, *) @MainActor @Test func saveCredentialsPersistsIDToDefaultsAndSecretToKeychain() {
    let defaults = isolatedDefaults()
    let keychain = isolatedKeychain()
    let wizard = makeWizard(defaults: defaults, keychain: keychain)
    wizard.clientID = "cid-1"
    wizard.clientSecret = "sekret"
    wizard.saveCredentials()
    #expect(wizard.flow.step == .login)
    #expect(defaults.string(forKey: SetupWizard.clientIDKey) == "cid-1")
    #expect((try? keychain.readToken(SetupWizard.clientSecretAccount)) == "sekret")
}

@available(macOS 14, *) @MainActor @Test func emptyCredentialsRejectedWithoutAdvancing() {
    let wizard = makeWizard()
    wizard.clientID = "  "
    wizard.clientSecret = ""
    wizard.saveCredentials()
    #expect(wizard.flow.step == .credentials)
    #expect(wizard.error != nil)
}

@available(macOS 14, *) @MainActor @Test func restoreLoadsSavedCredentialsAndDomain() {
    let defaults = isolatedDefaults()
    let keychain = isolatedKeychain()
    defaults.set("cid-2", forKey: SetupWizard.clientIDKey)
    defaults.set("example.com", forKey: SetupWizard.domainKey)
    try? keychain.saveToken("saved-secret", for: SetupWizard.clientSecretAccount)
    let wizard = makeWizard(defaults: defaults, keychain: keychain)
    #expect(wizard.clientID == "cid-2")
    #expect(wizard.clientSecret == "saved-secret")
    #expect(wizard.domain == "example.com")
}

// MARK: - 配对 URL

@available(macOS 14, *) @Test func pairingURLConstruction() {
    #expect(SetupWizard.pairingURL(domain: "example.com")?.absoluteString == "https://tesla.com/_ak/example.com")
    #expect(SetupWizard.pairingURL(domain: "  example.com  ")?.absoluteString == "https://tesla.com/_ak/example.com")
    #expect(SetupWizard.pairingURL(domain: "a b.com")?.absoluteString == "https://tesla.com/_ak/a%20b.com")
    #expect(SetupWizard.pairingURL(domain: "") == nil)
    #expect(SetupWizard.pairingURL(domain: "   ") == nil)
}

// MARK: - 完成标记

@available(macOS 14, *) @MainActor @Test func completionFlagSetOnDoneAndClearBefore() {
    let defaults = isolatedDefaults()
    let wizard = makeWizard(defaults: defaults)
    #expect(!wizard.isComplete)
    wizard.skip(); wizard.skip(); wizard.skip()  // credentials → login → keyPair → verify
    #expect(wizard.flow.step == .verify)
    #expect(!wizard.isComplete)
    wizard.complete()
    #expect(wizard.flow.step == .done)
    #expect(defaults.bool(forKey: SetupWizard.completeKey))
    #expect(wizard.isComplete)
}

@available(macOS 14, *) @MainActor @Test func skipWalksAllTheWayToDone() {
    let defaults = isolatedDefaults()
    let wizard = makeWizard(defaults: defaults)
    for _ in 0..<4 { wizard.skip() }
    #expect(wizard.flow.step == .done)
    #expect(wizard.isComplete)
}

@available(macOS 14, *) @MainActor @Test func completeOnlyWorksFromVerify() {
    let defaults = isolatedDefaults()
    let wizard = makeWizard(defaults: defaults)
    wizard.complete()  // 仍在 credentials
    #expect(wizard.flow.step == .credentials)
    #expect(!wizard.isComplete)
}

// MARK: - 验证步

@available(macOS 14, *) @MainActor @Test func verifyListsVehicles() async {
    let wizard = makeWizard(vehicles: [
        VehicleListEntry(id: "1", name: "Alpha"), VehicleListEntry(id: "2", name: "Beta")
    ])
    for _ in 0..<2 { wizard.skip() }  // → keyPair → verify
    await wizard.verify()
    #expect(wizard.vehicles.map(\.name) == ["Alpha", "Beta"])
    #expect(wizard.error == nil)
}

@available(macOS 14, *) @MainActor @Test func verifyErrorSurfacesWithoutCompleting() async {
    let wizard = makeWizard(listError: URLError(.notConnectedToInternet))
    for _ in 0..<2 { wizard.skip() }
    await wizard.verify()
    #expect(wizard.vehicles.isEmpty)
    #expect(wizard.error != nil)
    #expect(!wizard.isComplete)
}

// MARK: - 登录态与重看公钥

@available(macOS 14, *) @MainActor @Test func keyPairStepExposesPublicKeyAndDomainPersists() throws {
    let defaults = isolatedDefaults()
    let keychain = isolatedKeychain()
    let wizard = makeWizard(defaults: defaults, keychain: keychain)
    for _ in 0..<2 { wizard.skip() }
    #expect(wizard.flow.step == .keyPair)
    wizard.prepareKeyPair()
    let pem = try #require(wizard.publicKeyPEM)
    #expect(pem.hasPrefix("-----BEGIN PUBLIC KEY-----"))
    wizard.domain = "example.com"
    wizard.saveDomain()
    #expect(defaults.string(forKey: SetupWizard.domainKey) == "example.com")
}

@available(macOS 14, *) @Test func reauthRequiredMapsToReloginGuidance() {
    #expect(SetupWizard.guidanceMessage(AuthError.reauthRequired).contains("重新登录"))
    #expect(SetupWizard.guidanceMessage(AuthError.refreshTokenInvalid).contains("重新登录"))
}

/// 向导用的最小 TeslaClient 假实现（ScriptedTeslaClient 的 listVehicles 固定返回空，单独造一个）。
private struct WizardFakeClient: TeslaClient {
    let vehicles: [VehicleListEntry]
    let listError: Error?

    func listVehicles() async throws -> [VehicleListEntry] {
        if let listError { throw listError }
        return vehicles
    }

    func vehicleData(id: String) async throws -> VehicleSnapshot { ScriptedTeslaClient.snapshot(state: .online) }
    func wake(id: String) async throws {}
    func signAndSend(command: VehicleCommand) async throws {}
    func refreshAccessToken() async throws {}
}
