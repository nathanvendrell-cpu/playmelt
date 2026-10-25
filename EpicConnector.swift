import Foundation
import Darwin

struct EpicSnapshot {
    let accountId: String
    let displayName: String
    let games: [[String: Any]]
    let installed: [[String: Any]]
    let source: String
    let updatedAt: String
    var credentialStorage = "memory"
    var sessionLifetime = "until-app-closes"
}

enum EpicConnectorError: LocalizedError {
    case unavailable(String)
    case failed(code: String, message: String)
    case timedOut
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .failed(_, let message): return message
        case .timedOut: return "La synchronisation Epic a dépassé le délai. Aucun résultat complet n’est annoncé."
        case .invalidResponse: return "Le connecteur Epic a retourné une réponse non exploitable."
        }
    }
}

/// Optional, explicit Epic connection. No background login, imported launcher
/// credentials, environment secrets, command-line codes or plaintext storage.
/// Only an explicit connect/sync action may load this app's Keychain entry.
final class EpicConnector {
    private let projectRoot: URL
    private let pythonURL: URL
    private let workerURL: URL
    private let queue = DispatchQueue(label: "com.robtech.metalmax.epic", qos: .utility)
    private let lock = NSLock()
    private var session: [String: Any]?
    private let runner: OwnedProcessRunning
    private let sessionStore: EpicSessionStoring
    private var storeOperation: UUID?
    private var storageStatus = "not-read"
    private var storageError = ""
    private var sessionPersisted = false
    private var sessionVerified = false
    private var restoreAllowed = true
    private var generation = 0
    private var requestPending = false
    private var closing = false

    init(projectRoot: URL? = nil, pythonURL: URL? = nil, workerURL: URL? = nil,
         runner: OwnedProcessRunning = OwnedProcessRunner(),
         sessionStore: EpicSessionStoring = EpicKeychainSessionStore()) {
        self.runner = runner
        self.sessionStore = sessionStore
        let configured = Bundle.main.object(forInfoDictionaryKey: "MetalMaxSourceDirectory") as? String
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt")
        self.projectRoot = projectRoot ?? configured.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? applicationSupport
        self.pythonURL = pythonURL ?? self.projectRoot.appendingPathComponent("Dependencies.noindex/epic-venv/bin/python3")
        self.workerURL = workerURL ?? Bundle.main.url(forResource: "epic-worker", withExtension: "py")
            ?? self.projectRoot.appendingPathComponent("scripts/epic-worker.py")
    }

    func availability() -> [String: Any] {
        let exists = FileManager.default.isExecutableFile(atPath: pythonURL.path)
            && FileManager.default.isReadableFile(atPath: workerURL.path)
        lock.lock(); let authenticated = session != nil; let pending = requestPending || storeOperation != nil
        let accountId = session?["account_id"] as? String
        let credentialStorage = authenticated ? (sessionPersisted ? "keychain" : "memory") : "none"
        let lifetime = authenticated && sessionPersisted ? "stored-on-this-mac" : "until-app-closes"
        let status = storageStatus, storageIssue = storageError, verified = sessionVerified
        lock.unlock()
        return ["status": exists ? (authenticated ? "sessionAvailable" : "requiresLogin") : "missingDependency",
                "available": exists, "authenticated": authenticated, "busy": pending,
                "accountId": accountId as Any? ?? NSNull(),
                "credentialStorage": credentialStorage, "sessionLifetime": lifetime,
                "storageStatus": status, "storageError": storageIssue, "sessionVerified": verified,
                "versionVerified": false,
                "message": exists
                    ? (!storageIssue.isEmpty ? storageIssue : authenticated
                        ? (credentialStorage == "keychain" ? "Session Epic conservée dans le Trousseau de ce Mac. Actualisez pour vérifier la bibliothèque." : "Session Epic en mémoire uniquement ; elle prendra fin à la fermeture de Playmelt.")
                        : "La connexion Epic mémorisée sera recherchée dans le Trousseau uniquement à votre demande.")
                    : "Connecteur Epic non installé. Legendary 0.21.1 est requis ; aucune installation automatique."]
    }

    func requestLoginURL(completion: @escaping (Result<URL, Error>) -> Void) {
        request(["action": "authURL"]) { result in
            completion(result.flatMap { payload in
                guard let raw = payload["url"] as? String, let url = URL(string: raw),
                      url.scheme == "https", url.host == "www.epicgames.com", url.path == "/id/login",
                      url.user == nil, url.password == nil else { return .failure(EpicConnectorError.invalidResponse) }
                return .success(url)
            })
        }
    }

    /// Call only after the user submits the short-lived authorization code in
    /// a native secure input field. Never send this value through the WebKit bridge.
    func authenticate(code: String, completion: @escaping (Result<EpicSnapshot, Error>) -> Void) {
        request(["action": "authenticate", "code": code]) { completion($0.flatMap(self.snapshot)) }
    }

    func sync(completion: @escaping (Result<EpicSnapshot, Error>) -> Void) {
        request(["action": "sync"]) { completion($0.flatMap(self.snapshot)) }
    }

    /// Explicit user action only. true means credentials are available, not that
    /// the server or library has been checked. No worker/network is started here.
    func restoreSession(completion: @escaping (Result<Bool, Error>) -> Void) {
        lock.lock()
        guard !closing, !requestPending, storeOperation == nil else {
            lock.unlock(); DispatchQueue.main.async { completion(.failure(EpicConnectorError.failed(code: "busy", message: "Une opération Epic est déjà en cours."))) }; return
        }
        let id = UUID(), expected = generation; storeOperation = id
        lock.unlock()
        queue.async {
            let outcome: Result<Bool, Error>
            do { outcome = .success(try self.loadStoredSession(generation: expected)) }
            catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                self.lock.lock(); let stale = self.closing || self.generation != expected
                if self.storeOperation == id { self.storeOperation = nil }; self.lock.unlock()
                if stale { completion(.failure(EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée."))) }
                else { completion(outcome) }
            }
        }
    }

    /// Explicit logout only. Deletes this application's single entry, never Epic
    /// Launcher/Legendary credentials. Failed deletion is visible and retryable.
    func clearSession(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        lock.lock()
        guard !closing else { lock.unlock(); DispatchQueue.main.async { completion(.failure(EpicConnectorError.failed(code: "cancelled", message: "Playmelt se ferme."))) }; return }
        session = nil; sessionVerified = false; sessionPersisted = false; restoreAllowed = false; generation += 1
        let id = UUID(), expected = generation; storeOperation = id
        lock.unlock()
        queue.async {
            let outcome: Result<Void, Error>
            do {
                try self.sessionStore.clear()
                self.lock.lock()
                if self.generation == expected { self.storageStatus = "cleared"; self.storageError = "" }
                self.lock.unlock(); outcome = .success(())
            } catch {
                let message = EpicSessionStoreError.publicMessage(error) + " La suppression de la session mémorisée n’est pas confirmée."
                self.lock.lock()
                if self.generation == expected { self.storageStatus = "delete-error"; self.storageError = message }
                self.lock.unlock(); outcome = .failure(EpicConnectorError.failed(code: "sessionStorageDelete", message: message))
            }
            DispatchQueue.main.async {
                self.lock.lock(); if self.storeOperation == id { self.storeOperation = nil }; self.lock.unlock()
                completion(outcome)
            }
        }
    }

    /// Completion follows cancellation and exact worker/group reaping. The app
    /// waits asynchronously; no 180-second worker wait blocks its main thread.
    func shutdown(completion: @escaping () -> Void = {}) {
        lock.lock(); closing = true; session = nil; sessionVerified = false; sessionPersisted = false; generation += 1; lock.unlock()
        queue.async { DispatchQueue.main.async { completion() } }
    }

    /// Shared by credential admission and callback construction. An account ID
    /// alone does not make a partial/malformed library response trustworthy.
    private static func validatedSnapshot(_ payload: [String: Any]) -> Result<EpicSnapshot, Error> {
        guard let value = payload["snapshot"] as? [String: Any],
              let accountId = value["accountId"] as? String, !accountId.isEmpty,
              let displayName = value["displayName"] as? String,
              let games = value["games"] as? [[String: Any]],
              let installed = value["installed"] as? [[String: Any]],
              let source = value["source"] as? String,
              let updatedAt = value["updatedAt"] as? String else { return .failure(EpicConnectorError.invalidResponse) }
        return .success(EpicSnapshot(accountId: accountId, displayName: displayName,
                                    games: games, installed: installed, source: source, updatedAt: updatedAt))
    }
    private func snapshot(_ payload: [String: Any]) -> Result<EpicSnapshot, Error> {
        Self.validatedSnapshot(payload).map { value in
            let storage = availability()
            var result = value
            result.credentialStorage = storage["credentialStorage"] as? String ?? "memory"
            result.sessionLifetime = storage["sessionLifetime"] as? String ?? "until-app-closes"
            return result
        }
    }

    /// Queue-confined storage I/O; never hold the state lock across Keychain calls.
    private func loadStoredSession(generation expected: Int) throws -> Bool {
        lock.lock()
        let stale = closing || generation != expected, present = session != nil, allowed = restoreAllowed
        lock.unlock()
        if stale { throw EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée.") }
        if present { return true }
        if !allowed { return false }
        let loaded: [String: Any]?
        do { loaded = try sessionStore.load(); if let loaded { _ = try EpicSessionEnvelope.encode(loaded) } }
        catch {
            let message = EpicSessionStoreError.publicMessage(error)
            lock.lock(); if generation == expected { storageStatus = "read-error"; storageError = message }; lock.unlock()
            throw EpicConnectorError.failed(code: "sessionStorageRead", message: message)
        }
        lock.lock(); defer { lock.unlock() }
        guard !closing, generation == expected else { throw EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée.") }
        session = loaded; sessionVerified = false
        sessionPersisted = loaded != nil && sessionStore.persistenceKind == "keychain"
        storageStatus = loaded == nil ? "empty" : sessionPersisted ? "restored" : "memory-only"
        storageError = ""
        return loaded != nil
    }

    private func persist(_ value: [String: Any], generation expected: Int) {
        lock.lock(); let stale = closing || generation != expected; lock.unlock()
        guard !stale else { return }
        let issue: String?
        do { try sessionStore.save(value); issue = nil }
        catch { issue = EpicSessionStoreError.publicMessage(error) }
        lock.lock(); defer { lock.unlock() }
        guard !closing, generation == expected else { return }
        sessionPersisted = issue == nil && sessionStore.persistenceKind == "keychain"
        storageStatus = issue != nil ? "write-error" : sessionPersisted ? "stored" : "memory-only"
        storageError = issue ?? ""
    }

    private func request(_ payload: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.isReadableFile(atPath: workerURL.path) else {
            completion(.failure(EpicConnectorError.unavailable("Connecteur Epic absent. Installez d’abord la dépendance optionnelle Legendary 0.21.1 pour Playmelt.")))
            return
        }
        lock.lock()
        guard !requestPending && storeOperation == nil && !closing else {
            lock.unlock()
            completion(.failure(EpicConnectorError.failed(code: "busy", message: "Une opération Epic est déjà en cours ou l’application se ferme.")))
            return
        }
        requestPending = true
        if ["authenticate", "sync"].contains(payload["action"] as? String ?? "") { sessionVerified = false }
        let requestGeneration = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            var input = payload
            let outcome: Result<[String: Any], Error>
            do {
                if payload["action"] as? String == "sync" {
                    guard try self.loadStoredSession(generation: requestGeneration) else {
                        throw EpicConnectorError.failed(code: "requiresLogin", message: "Connectez votre compte Epic pour synchroniser sa bibliothèque.")
                    }
                    self.lock.lock(); input["session"] = self.session; self.lock.unlock()
                }
                var response = try self.runWorker(input, generation: requestGeneration)
                // A token refresh must not silently replace the library owner.
                // Validate identity before retaining new credentials or exposing
                // a snapshot; authURL deliberately has no session/snapshot.
                let action = payload["action"] as? String
                let verifiedResponse = response["ok"] as? Bool == true && (action == "authenticate" || action == "sync")
                if action == "authURL", response["session"] != nil { throw EpicConnectorError.invalidResponse }
                // A failed library response is not sufficient to replace the
                // stored identity/token. Reauthentication may be needed if Epic
                // rotated a token before failing the complete library request.
                let refreshed = verifiedResponse ? response["session"] as? [String: Any] : nil
                let refreshedAccount = refreshed?["account_id"] as? String
                let expectedAccount = (input["session"] as? [String: Any])?["account_id"] as? String
                if let refreshed {
                    guard (try? EpicSessionEnvelope.encode(refreshed)) != nil else { throw EpicConnectorError.invalidResponse }
                }
                if verifiedResponse {
                    guard let refreshedAccount, !refreshedAccount.isEmpty,
                          case .success(let checkedSnapshot) = Self.validatedSnapshot(response),
                          checkedSnapshot.accountId == refreshedAccount else { throw EpicConnectorError.invalidResponse }
                }
                if refreshed != nil && (refreshedAccount?.isEmpty != false ||
                    (action == "sync" && refreshedAccount != expectedAccount)) {
                    self.lock.lock()
                    if self.generation == requestGeneration {
                        self.session = nil; self.sessionVerified = false; self.sessionPersisted = false
                        self.restoreAllowed = false; self.storageStatus = "invalidated"
                    }
                    self.lock.unlock()
                    throw EpicConnectorError.failed(code: "accountChanged", message: "Le compte Epic a changé. Reconnectez le compte voulu avant de continuer.")
                }
                self.lock.lock()
                let cancelled = self.generation != requestGeneration
                if !cancelled, let refreshed { self.session = refreshed; self.restoreAllowed = true }
                if !cancelled, let error = response["error"] as? [String: Any],
                   ["authenticationFailed", "accountChanged"].contains(error["code"] as? String ?? "") {
                    self.session = nil; self.sessionVerified = false; self.sessionPersisted = false
                    self.restoreAllowed = false; self.storageStatus = "invalidated"
                }
                if !cancelled, action == "authenticate" || action == "sync" { self.sessionVerified = response["ok"] as? Bool == true }
                self.lock.unlock()
                let invalidated = ["authenticationFailed", "accountChanged"].contains((response["error"] as? [String: Any])?["code"] as? String ?? "")
                if !cancelled, !invalidated, let refreshed { self.persist(refreshed, generation: requestGeneration) }
                // Never give the callback (and therefore WebKit) tokens.
                response.removeValue(forKey: "session")
                if cancelled { throw EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée.") }
                if response["ok"] as? Bool != true {
                    let error = response["error"] as? [String: Any] ?? [:]
                    throw EpicConnectorError.failed(code: error["code"] as? String ?? "adapterError",
                                                    message: error["message"] as? String ?? "Échec du connecteur Epic.")
                }
                outcome = .success(response)
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                self.lock.lock()
                let stale = self.closing || self.generation != requestGeneration
                self.requestPending = false
                self.lock.unlock()
                // clearSession/shutdown can happen after the worker returned but
                // before this callback runs. Never revive that account in the UI.
                if stale { completion(.failure(EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée."))) }
                else { completion(outcome) }
            }
        }
    }

    private func runWorker(_ input: [String: Any], generation requestGeneration: Int) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: input)
        guard body.count <= 1024 * 1024 else { throw EpicConnectorError.invalidResponse }
        var request = OwnedProcessRequest(executable: pythonURL, arguments: ["-I", "-B", workerURL.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                          "LANG": "fr_FR.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"])
        request.directory = projectRoot; request.input = body; request.timeout = 180
        request.outputLimit = 16 * 1024 * 1024; request.mergeStandardError = false
        do {
            let result = try runner.run(request, cancelled: {
                self.lock.lock(); defer { self.lock.unlock() }
                return self.closing || self.generation != requestGeneration
            })
            guard result.exitCode == 0,
                  let response = try JSONSerialization.jsonObject(with: result.output) as? [String: Any] else { throw EpicConnectorError.invalidResponse }
            return response
        } catch OwnedProcessError.cancelled {
            throw EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée.")
        } catch OwnedProcessError.timedOut { throw EpicConnectorError.timedOut }
        catch is OwnedProcessError { throw EpicConnectorError.invalidResponse }
    }
}
