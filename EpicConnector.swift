import Foundation
import Darwin

struct EpicSnapshot {
    let accountId: String
    let displayName: String
    let games: [[String: Any]]
    let installed: [[String: Any]]
    let source: String
    let updatedAt: String
    let credentialStorage = "memory"
    let sessionLifetime = "until-app-closes"
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
/// credentials, environment secrets, command-line codes or on-disk session.
/// The session belongs to this instance and ends when Playmelt quits.
final class EpicConnector {
    private let projectRoot: URL
    private let pythonURL: URL
    private let workerURL: URL
    private let queue = DispatchQueue(label: "com.robtech.metalmax.epic", qos: .utility)
    private let lock = NSLock()
    private var session: [String: Any]?
    private var activeProcess: Process?
    private var generation = 0
    private var requestPending = false

    init(projectRoot: URL? = nil, pythonURL: URL? = nil, workerURL: URL? = nil) {
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
        lock.lock(); let authenticated = session != nil; let pending = requestPending; lock.unlock()
        return ["status": exists ? (authenticated ? "sessionAvailable" : "requiresLogin") : "missingDependency",
                "available": exists, "authenticated": authenticated, "busy": pending,
                "credentialStorage": "memory", "sessionLifetime": "until-app-closes",
                "versionVerified": false,
                "message": exists
                    ? "Connexion Epic locale. La session reste en mémoire jusqu’à la fermeture de Playmelt. La version de Legendary sera vérifiée avant connexion."
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
        request(["action": "authenticate", "code": code]) { completion($0.flatMap(Self.snapshot)) }
    }

    func sync(completion: @escaping (Result<EpicSnapshot, Error>) -> Void) {
        request(["action": "sync"]) { completion($0.flatMap(Self.snapshot)) }
    }

    /// Clears only this task-owned in-memory session. Does not sign the user out
    /// of the Epic Launcher or delete any existing account/configuration files.
    func clearSession() {
        lock.lock()
        session = nil; generation += 1
        let process = activeProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    /// Call from applicationWillTerminate to reap this connector's own worker.
    func shutdown() {
        clearSession()
        lock.lock(); let process = activeProcess; lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }

    private static func snapshot(_ payload: [String: Any]) -> Result<EpicSnapshot, Error> {
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

    private func request(_ payload: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.isReadableFile(atPath: workerURL.path) else {
            completion(.failure(EpicConnectorError.unavailable("Connecteur Epic absent. Installez d’abord la dépendance optionnelle Legendary 0.21.1 pour Playmelt.")))
            return
        }
        lock.lock()
        guard !requestPending else {
            lock.unlock()
            completion(.failure(EpicConnectorError.failed(code: "busy", message: "Une opération Epic est déjà en cours.")))
            return
        }
        requestPending = true
        let requestGeneration = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            var input = payload
            self.lock.lock()
            if payload["action"] as? String == "sync" { input["session"] = self.session }
            self.lock.unlock()
            let outcome: Result<[String: Any], Error>
            do {
                var response = try self.runWorker(input, generation: requestGeneration)
                self.lock.lock()
                let cancelled = self.generation != requestGeneration
                if !cancelled, let refreshed = response["session"] as? [String: Any] { self.session = refreshed }
                if let error = response["error"] as? [String: Any], error["code"] as? String == "authenticationFailed" { self.session = nil }
                self.lock.unlock()
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
            self.lock.lock(); self.requestPending = false; self.lock.unlock()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private func runWorker(_ input: [String: Any], generation requestGeneration: Int) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: input)
        guard body.count <= 1024 * 1024 else { throw EpicConnectorError.invalidResponse }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-I", "-B", workerURL.path]
        process.currentDirectoryURL = projectRoot
        // Do not inherit Python hooks or a Legendary configuration pointing to another account.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                               "LANG": "fr_FR.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        let incoming = Pipe(), outgoing = Pipe()
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let output = EpicBoundedOutput()
        defer {
            if process.isRunning {
                process.terminate()
                if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
            try? incoming.fileHandleForWriting.close()
            try? outgoing.fileHandleForReading.close()
            lock.lock(); activeProcess = nil; lock.unlock()
        }
        try process.run()
        lock.lock()
        activeProcess = process
        let cancelled = generation != requestGeneration
        lock.unlock()
        guard !cancelled else {
            throw EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée.")
        }
        DispatchQueue.global(qos: .utility).async {
            defer { readerFinished.signal() }
            do {
                while let data = try outgoing.fileHandleForReading.read(upToCount: 65536), !data.isEmpty {
                    if !output.append(data) {
                        if process.isRunning { process.terminate() }
                        return
                    }
                }
            } catch { /* The owner handles cancellation or malformed output. */ }
        }
        try incoming.fileHandleForWriting.write(contentsOf: body)
        try incoming.fileHandleForWriting.close()
        guard finished.wait(timeout: .now() + 180) == .success else { throw EpicConnectorError.timedOut }
        process.waitUntilExit()
        guard readerFinished.wait(timeout: .now() + 2) == .success,
              output.append(Data()), process.terminationStatus == 0,
              let response = try JSONSerialization.jsonObject(with: output.value()) as? [String: Any] else {
            throw EpicConnectorError.invalidResponse
        }
        return response
    }
}

private final class EpicBoundedOutput {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func append(_ value: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !overflow, bytes.count + value.count <= 16 * 1024 * 1024 else { overflow = true; return false }
        bytes.append(value); return true
    }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
