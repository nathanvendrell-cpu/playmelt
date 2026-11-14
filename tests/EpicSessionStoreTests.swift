import Foundation
import Security
import LocalAuthentication

private final class MockKeychain: EpicKeychainAccess {
    var copyStatus = errSecItemNotFound, copyData: Data?
    var updateStatuses: [OSStatus] = [errSecSuccess]
    var addStatus = errSecSuccess, deleteStatus = errSecSuccess
    var queries: [[String: Any]] = [], values: [[String: Any]] = []
    var copied = 0, updated = 0, added = 0, deleted = 0
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) { copied += 1; queries.append(query); return (copyStatus, copyData) }
    func add(_ attributes: [String: Any]) -> OSStatus { added += 1; queries.append(attributes); values.append(attributes); return addStatus }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updated += 1; queries.append(query); values.append(attributes)
        return updateStatuses.count > 1 ? updateStatuses.removeFirst() : updateStatuses[0]
    }
    func delete(_ query: [String: Any]) -> OSStatus { deleted += 1; queries.append(query); return deleteStatus }
}
/// Shared fake encrypted-item boundary, never the system keychain or a file.
private final class PersistentMockKeychain: EpicKeychainAccess {
    var items: [String: Data] = [:]
    var queries: [[String: Any]] = [], values: [[String: Any]] = []
    private func key(_ query: [String: Any]) -> String {
        [query[kSecAttrService as String] as? String ?? "", query[kSecAttrAccount as String] as? String ?? "",
         String(query[kSecUseDataProtectionKeychain as String] as? Bool ?? false)].joined(separator: "|")
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        queries.append(query)
        guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        queries.append(attributes); values.append(attributes)
        guard items[key(attributes)] == nil else { return errSecDuplicateItem }
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        items[key(attributes)] = data; return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        queries.append(query); values.append(attributes)
        guard items[key(query)] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        items[key(query)] = data; return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        queries.append(query)
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}
private final class StoreSpy: EpicSessionStoring {
    let persistenceKind = "keychain" // Simulated successful persistence, never Security.
    var stored: [String: Any]?
    var loadError: Error?, saveError: Error?, clearError: Error?
    var onSave: (() -> Void)?
    private let lock = NSLock()
    private var counts = [0, 0, 0]
    var operations: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    func load() throws -> [String: Any]? { lock.lock(); counts[0] += 1; lock.unlock(); if let loadError { throw loadError }; return stored }
    func save(_ session: [String: Any]) throws { lock.lock(); counts[1] += 1; lock.unlock(); onSave?(); if let saveError { throw saveError }; stored = session }
    func clear() throws { lock.lock(); counts[2] += 1; lock.unlock(); if let clearError { throw clearError }; stored = nil }
}
private final class SessionRunner: OwnedProcessRunning {
    var response: [String: Any] = [:]
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        lock.lock(); count += 1; lock.unlock()
        if cancelled() { throw OwnedProcessError.cancelled }
        return .init(output: try JSONSerialization.data(withJSONObject: response), exitCode: 0, pid: 0, handedOff: false)
    }
}

@main enum EpicSessionStoreTests {
    static var checks = 0
    static let session: [String: Any] = ["account_id": "fixture-account", "access_token": "fixture-access", "refresh_token": "fixture-refresh"]
    static func check(_ value: Bool, _ label: String) { checks += 1; if !value { fatalError("FAIL: " + label) } }
    static func rejects(_ label: String, _ block: () throws -> Void) {
        do { try block(); check(false, label) } catch { check(true, label) }
    }
    static func wait(_ done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        check(done(), "bounded callback on main")
    }
    static func success(_ value: [String: Any] = session) -> [String: Any] {
        ["ok": true, "session": value,
         "snapshot": ["accountId": value["account_id"] as? String ?? "fixture-account", "displayName": "Fixture", "games": [], "installed": [], "source": "fixture", "updatedAt": "2026-10-25T00:00:00Z"]]
    }
    static func main() throws {
        let encoded = try EpicSessionEnvelope.encode(session)
        check(try EpicSessionEnvelope.decode(encoded)["account_id"] as? String == "fixture-account", "bounded envelope round trip")
        rejects("oversized envelope refused") { _ = try EpicSessionEnvelope.decode(Data(repeating: 32, count: EpicSessionEnvelope.maximumBytes + 1)) }
        rejects("invalid JSON refused") { _ = try EpicSessionEnvelope.decode(Data("not-json".utf8)) }
        var wrong = ["schemaVersion": 1, "account_id": "different", "session": session] as [String: Any]
        rejects("envelope identity mismatch refused") { _ = try EpicSessionEnvelope.decode(JSONSerialization.data(withJSONObject: wrong)) }
        wrong["account_id"] = "fixture-account"; wrong["schemaVersion"] = true
        rejects("boolean schema refused") { _ = try EpicSessionEnvelope.decode(JSONSerialization.data(withJSONObject: wrong)) }
        rejects("missing token refused") { _ = try EpicSessionEnvelope.encode(["account_id": "fixture-account"]) }
        rejects("non-string token refused") { _ = try EpicSessionEnvelope.encode(["account_id": "fixture-account", "access_token": 1]) }
        rejects("overlarge token refused") { _ = try EpicSessionEnvelope.encode(["account_id": "fixture-account", "access_token": String(repeating: "x", count: 20_000)]) }
        rejects("valid access token cannot mask malformed refresh token") { _ = try EpicSessionEnvelope.encode(["account_id": "fixture-account", "access_token": "fixture-access", "refresh_token": 123]) }
        rejects("valid access token cannot mask oversized refresh token") { _ = try EpicSessionEnvelope.encode(["account_id": "fixture-account", "access_token": "fixture-access", "refresh_token": String(repeating: "x", count: 20_000)]) }
        var large = session; large["extra"] = String(repeating: "x", count: 70_000)
        rejects("overlarge valid JSON refused") { _ = try EpicSessionEnvelope.encode(large) }
        check(!EpicSessionStoreError.publicMessage(NSError(domain: "fixture-secret", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "fixture-secret"])).contains("fixture-secret"), "backend error never echoes secret text")

        let api = MockKeychain(), store = EpicKeychainSessionStore(access: MockKeychain())
        // The unused store above proves construction itself has no Security call;
        // every exercised Keychain method below uses the explicit mock transport.
        _ = store
        let keychain = EpicKeychainSessionStore(access: api)
        check(api.queries.isEmpty, "store construction is lazy")
        check(try keychain.load() == nil, "missing own item returns no credentials")
        api.copyStatus = errSecSuccess; api.copyData = encoded
        check(try keychain.load()?["account_id"] as? String == "fixture-account", "mock owned item loads")
        api.copyData = Data("bad fixture".utf8)
        rejects("malformed Keychain bytes refused") { _ = try keychain.load() }
        api.copyStatus = errSecInteractionNotAllowed
        rejects("locked Keychain read exposed") { _ = try keychain.load() }
        api.updateStatuses = [errSecItemNotFound, errSecSuccess]; api.addStatus = errSecDuplicateItem
        try keychain.save(session)
        check(api.updated == 2 && api.added == 1 && api.deleted == 0, "upsert retries duplicate without deleting old credential")
        api.updateStatuses = [errSecMissingEntitlement]
        rejects("ad-hoc entitlement failure is not persistence success") { try keychain.save(session) }
        check(api.added == 1, "failed update does not fall back to another storage")
        api.deleteStatus = errSecItemNotFound; try keychain.clear()
        api.deleteStatus = errSecAuthFailed
        rejects("failed deletion exposed") { try keychain.clear() }
        for query in api.queries {
            check(query[kSecAttrService as String] as? String == EpicKeychainSessionStore.service &&
                  query[kSecAttrAccount as String] as? String == EpicKeychainSessionStore.account, "exact Playmelt service/account on every operation")
            check(query[kSecUseDataProtectionKeychain as String] as? Bool == true && query[kSecAttrSynchronizable as String] as? Bool == false, "device-local DP keychain only")
            check((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true, "authentication UI disabled without biometric evaluation")
            check(query[kSecAttrAccessGroup as String] == nil, "no shared or foreign access group requested")
        }
        for attributes in api.values {
            check(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, "ThisDeviceOnly protection written")
            check((attributes[kSecValueData as String] as? Data)?.count == encoded.count, "only bounded envelope persisted")
        }

        check(EpicKeychainBackend.configured(info: [:]) == .dataProtection, "missing internal flag retains production DP backend")
        check(EpicKeychainBackend.configured(info: ["PlaymeltInternalBuild": false]) == .dataProtection, "release flag retains DP backend")
        check(EpicKeychainBackend.configured(info: ["PlaymeltInternalBuild": "true"]) == .dataProtection, "string cannot opt into internal backend")
        check(EpicKeychainBackend.configured(info: ["PlaymeltInternalBuild": true]) == .internalLogin, "explicit internal bundle chooses login keychain")
        let internalAPI = MockKeychain(), internalStore = EpicKeychainSessionStore(access: internalAPI, backend: .internalLogin)
        check(internalStore.persistenceBackend == "internal-login" && internalAPI.queries.isEmpty, "internal backend remains lazy and identifiable")
        check(try internalStore.load() == nil, "internal absent item does not inspect DP or another app's item")
        internalAPI.updateStatuses = [errSecItemNotFound]; try internalStore.save(session)
        internalAPI.copyStatus = errSecSuccess; internalAPI.copyData = encoded
        check(try internalStore.load()?["account_id"] as? String == "fixture-account", "internal login keychain envelope round trip uses mock")
        try internalStore.clear()
        for query in internalAPI.queries {
            check(query[kSecAttrService as String] as? String == "fr.playmelt.epic.session.internal.v1" && query[kSecAttrAccount as String] as? String == EpicKeychainSessionStore.account, "internal load save clear share exact isolated namespace")
            check(query[kSecUseDataProtectionKeychain as String] as? Bool == false && query[kSecAttrSynchronizable as String] as? Bool == false, "internal backend is explicit file-based and never iCloud")
            check(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String, "internal keychain never opens an unexpected system prompt")
            check(query[kSecAttrAccessGroup as String] == nil && query[kSecAttrAccess as String] == nil && query[kSecAttrAccessControl as String] == nil, "internal backend never supplies a shared group or broader access control")
        }
        for value in internalAPI.values {
            check(value[kSecAttrAccessible as String] == nil, "login keychain does not claim DP protection classes")
            check((value[kSecValueData as String] as? Data)?.count == encoded.count, "internal encrypted item receives only bounded envelope")
        }
        internalAPI.updateStatuses = [errSecAuthFailed]
        let additions = internalAPI.added
        rejects("internal keychain access denial stays a visible failure") { try internalStore.save(session) }
        check(internalAPI.added == additions && internalStore.persistenceKind == "memory" && internalStore.persistenceBackend == "internal-login", "internal failure does not switch backend or add plaintext storage")

        let clientInfo: [String: Any] = ["PlaymeltClientCredentialChannel": "adhoc-login-v1",
            "PlaymeltCommercialAccessEnabled": true, "PlaymeltDevelopmentBuild": false, "PlaymeltInternalBuild": false]
        check(EpicKeychainBackend.configured(info: clientInfo) == .clientLogin, "only explicit licensed non-owner ad-hoc client chooses client login")
        for key in clientInfo.keys {
            var missing = clientInfo; missing.removeValue(forKey: key)
            check(EpicKeychainBackend.configured(info: missing) == .dataProtection, "missing client condition retains DP: " + key)
        }
        for (key, badValues) in [
            ("PlaymeltClientCredentialChannel", ["client-login", "adhoc-login-v1 ", "ADHOC-LOGIN-V1", true, 1, NSNull(), ["adhoc-login-v1"]] as [Any]),
            ("PlaymeltCommercialAccessEnabled", [false, "true", 1, NSNumber(value: 1), NSNull()] as [Any]),
            ("PlaymeltDevelopmentBuild", [true, "false", 0, NSNumber(value: 0), NSNull()] as [Any]),
            ("PlaymeltInternalBuild", ["false", 0, NSNumber(value: 0), NSNull()] as [Any])
        ] {
            for bad in badValues {
                var invalid = clientInfo; invalid[key] = bad
                check(EpicKeychainBackend.configured(info: invalid) == .dataProtection, "wrong client condition value/type retains DP: " + key)
            }
        }
        check(EpicKeychainBackend.configured(info: ["PlaymeltInternalBuild": 1]) == .dataProtection, "numeric one cannot opt into internal storage")
        var ownerInfo = clientInfo; ownerInfo["PlaymeltInternalBuild"] = true
        check(EpicKeychainBackend.configured(info: ownerInfo) == .internalLogin, "true internal flag retains its own backend, never client storage")
        check(Set([EpicKeychainBackend.dataProtection.service, EpicKeychainBackend.internalLogin.service, EpicKeychainBackend.clientLogin.service]).count == 3,
              "production DP, internal and explicit client namespaces are distinct")
        check(EpicKeychainBackend.clientLogin.service == "fr.playmelt.epic.session.client-login.v1", "client namespace is exact and versioned")

        let persisted = PersistentMockKeychain()
        let dpInstance = EpicKeychainSessionStore(access: persisted, backend: .dataProtection)
        let internalInstance = EpicKeychainSessionStore(access: persisted, backend: .internalLogin)
        try dpInstance.save(session); try internalInstance.save(session)
        persisted.queries.removeAll(); persisted.values.removeAll()
        let firstClient = EpicKeychainSessionStore(access: persisted, backend: .clientLogin)
        check(firstClient.persistenceBackend == "client-login" && persisted.queries.isEmpty, "client construction is lazy with explicit backend")
        check(try firstClient.load() == nil, "client cannot restore another channel's mock item")
        try firstClient.save(session)
        let secondClient = EpicKeychainSessionStore(access: persisted, backend: .clientLogin)
        check(try secondClient.load()?["refresh_token"] as? String == "fixture-refresh", "new client instance restores the shared mock item's envelope")
        var rotated = session; rotated["refresh_token"] = "fixture-refresh-rotated"
        try secondClient.save(rotated)
        let thirdClient = EpicKeychainSessionStore(access: persisted, backend: .clientLogin)
        check(try thirdClient.load()?["refresh_token"] as? String == "fixture-refresh-rotated", "updated mock credential survives a new client instance")
        try secondClient.clear()
        check(try thirdClient.load() == nil, "explicit client clear affects later instances")
        for query in persisted.queries {
            check(query[kSecAttrService as String] as? String == "fr.playmelt.epic.session.client-login.v1" && query[kSecAttrAccount as String] as? String == EpicKeychainSessionStore.account, "every client CRUD query targets only its exact namespace")
            check(query[kSecUseDataProtectionKeychain as String] as? Bool == false && query[kSecAttrSynchronizable as String] as? Bool == false, "client explicitly uses local login keychain without iCloud")
            check(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String && query[kSecUseAuthenticationContext as String] == nil, "client does not open authentication UI")
            check(query[kSecAttrAccessGroup as String] == nil && query[kSecAttrAccess as String] == nil && query[kSecAttrAccessControl as String] == nil, "client never broadens access through group or custom ACL")
        }
        for value in persisted.values {
            check(value[kSecAttrAccessible as String] == nil, "client login writes no DP-only protection class")
            check(((value[kSecValueData as String] as? Data)?.count ?? 0) <= EpicSessionEnvelope.maximumBytes, "client values remain bounded envelopes")
        }
        check(try dpInstance.load()?["refresh_token"] as? String == "fixture-refresh", "client clear preserves production DP mock item")
        check(try internalInstance.load()?["refresh_token"] as? String == "fixture-refresh", "client clear preserves internal mock item")
        let deniedClientAPI = MockKeychain(), deniedClient = EpicKeychainSessionStore(access: deniedClientAPI, backend: .clientLogin)
        deniedClientAPI.updateStatuses = [errSecAuthFailed]
        rejects("client access failure stays explicit") { try deniedClient.save(session) }
        check(deniedClient.persistenceBackend == "client-login" && deniedClient.persistenceKind == "memory" && deniedClientAPI.added == 0, "client failure never changes backend or creates another storage")
        check(deniedClientAPI.queries.allSatisfy { $0[kSecAttrService as String] as? String == EpicKeychainBackend.clientLogin.service }, "client failure never queries production or internal namespaces")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-keychain-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.py")
        try Data("# mock only, never executed".utf8).write(to: worker)
        func connector(_ spy: StoreSpy, _ runner: SessionRunner) -> EpicConnector {
            EpicConnector(projectRoot: root, pythonURL: URL(fileURLWithPath: "/usr/bin/true"), workerURL: worker, runner: runner, sessionStore: spy)
        }
        func close(_ connector: EpicConnector) { var done = false; connector.shutdown { done = true }; wait { done } }
        let lazyStore = StoreSpy(), lazyRunner = SessionRunner()
        lazyStore.stored = session
        let lazy = connector(lazyStore, lazyRunner)
        _ = lazy.availability(); _ = lazy.availability()
        check(lazyStore.operations == [0,0,0] && lazyRunner.calls == 0, "init and diagnostics never read credentials or start worker")
        var done = false, restored = false
        lazy.restoreSession { result in done = true; restored = (try? result.get()) == true; check(Thread.isMainThread, "restore completion on main") }
        wait { done }
        check(restored && lazyStore.operations == [1,0,0] && lazyRunner.calls == 0, "explicit restore has no network")
        check(lazy.availability()["credentialStorage"] as? String == "keychain" && lazy.availability()["sessionVerified"] as? Bool == false, "restored credentials are not a verified library")
        lazyRunner.response = success(); done = false
        lazy.sync { result in done = true; check((try? result.get())?.accountId == "fixture-account", "restored account passes verified sync") }; wait { done }
        check(lazyStore.operations == [1,1,0] && lazy.availability()["sessionVerified"] as? Bool == true, "successful sync saves refreshed credentials")
        close(lazy)
        check(lazyStore.operations == [1,1,0] && lazyStore.stored != nil, "shutdown preserves durable credential")

        let failedStore = StoreSpy(), failedRunner = SessionRunner()
        failedStore.loadError = EpicSessionStoreError.keychain(errSecInteractionNotAllowed)
        failedStore.saveError = EpicSessionStoreError.keychain(errSecMissingEntitlement)
        let memory = connector(failedStore, failedRunner)
        done = false
        memory.restoreSession { result in done = true; check((try? result.get()) == nil, "restore error visible") }; wait { done }
        check(failedRunner.calls == 0, "failed restore never starts auth")
        failedRunner.response = success(); done = false
        memory.authenticate(code: "fixture") { result in done = true; check((try? result.get())?.credentialStorage == "memory", "authentication remains usable when save fails") }; wait { done }
        check(failedStore.operations == [1,1,0], "authenticate does not retry failed read")
        check(memory.availability()["storageStatus"] as? String == "write-error" && !(memory.availability()["storageError"] as? String ?? "").isEmpty, "write failure exposed, never labelled persisted")
        failedStore.clearError = EpicSessionStoreError.keychain(errSecInteractionNotAllowed); done = false
        memory.clearSession { result in done = true; if case .success = result { check(false, "failed delete must not succeed") } }; wait { done }
        check(memory.availability()["authenticated"] as? Bool == false && memory.availability()["storageStatus"] as? String == "delete-error", "logout clears RAM while reporting failed deletion")
        failedStore.clearError = nil; done = false
        memory.clearSession { result in done = true; check((try? result.get()) != nil, "explicit deletion retry succeeds") }; wait { done }
        check(failedStore.operations == [1,1,2], "only explicit logout removes item")
        close(memory)

        // Failed responses and authURL cannot smuggle credentials into persistence.
        var refusedResponses: [[String: Any]] = [
            ["ok": false, "session": session, "error": ["code": "authenticationFailed", "message": "Fixture failure"]],
            ["ok": false, "session": session, "error": ["code": "networkError", "message": "Fixture failure"]],
            success(["account_id": "fixture-account"]),
            success(["account_id": "fixture-account", "access_token": String(repeating: "x", count: 20_000)]),
            success(["account_id": "fixture-account", "access_token": "fixture-access", "refresh_token": 123]),
            success(["account_id": "fixture-account", "access_token": "fixture-access", "refresh_token": String(repeating: "x", count: 20_000)]),
            success(large)
        ]
        var incomplete = success()
        incomplete["snapshot"] = ["accountId": "fixture-account"]
        refusedResponses.append(incomplete)
        for field in ["games", "installed", "displayName", "source", "updatedAt"] {
            var response = success(), snapshot = success()["snapshot"] as! [String: Any]
            snapshot[field] = ["games", "installed"].contains(field) ? "not-an-array" : 123
            response["snapshot"] = snapshot; refusedResponses.append(response)
        }
        for response in refusedResponses {
            let spy = StoreSpy(), runner = SessionRunner(); runner.response = response
            let value = connector(spy, runner); done = false
            value.authenticate(code: "fixture") { _ in done = true }; wait { done }
            check(spy.operations == [0,0,0] && value.availability()["authenticated"] as? Bool == false &&
                  value.availability()["sessionVerified"] as? Bool == false, "unverified or oversized session never reaches RAM/store")
            close(value)
        }
        let urlStore = StoreSpy(), urlRunner = SessionRunner()
        urlRunner.response = ["ok": true, "url": "https://www.epicgames.com/id/login", "session": session]
        let urlConnector = connector(urlStore, urlRunner); done = false
        urlConnector.requestLoginURL { _ in done = true }; wait { done }
        check(urlStore.operations == [0,0,0] && urlConnector.availability()["authenticated"] as? Bool == false, "authURL cannot install a session")
        close(urlConnector)

        // Cancellation while a write is in flight must be followed by the exact
        // logout deletion; a late save cannot restore the forgotten credential.
        let raceStore = StoreSpy(), raceRunner = SessionRunner(); raceRunner.response = success()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        raceStore.onSave = { entered.signal(); _ = release.wait(timeout: .now() + 2) }
        let race = connector(raceStore, raceRunner)
        var authDone = false, clearDone = false, accepted = false
        race.authenticate(code: "fixture") { result in authDone = true; accepted = (try? result.get()) != nil }
        check(entered.wait(timeout: .now() + 2) == .success, "fixture write is pending")
        race.clearSession { _ in clearDone = true }; release.signal(); wait { authDone && clearDone }
        check(!accepted && raceStore.stored == nil && raceStore.operations == [0,1,1], "logout serializes after in-flight save and cancels delivery")
        close(race)
        print("Epic session persistence: \(checks) PASS; mocked Keychain/worker only, no real secrets, Security item access or network.")
    }
}
