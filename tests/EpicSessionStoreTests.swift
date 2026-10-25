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
