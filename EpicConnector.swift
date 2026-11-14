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

struct EpicInstallation {
    let accountID: String, appName: String, platform: String, title: String, executable: String
    let directory: URL
    let prerequisitesRequired: Bool
}

/// Native-only one-use exchange authorization. Not Codable and always redacted.
/// Keep this owner alive until the exact game exits; close removes only its OVT.
final class EpicLaunchAuthorization: CustomStringConvertible, CustomDebugStringConvertible {
    struct Parameters: CustomStringConvertible, CustomDebugStringConvertible {
        let executable: URL, directory: URL, arguments: [String]
        var description: String { "Epic game launch parameters (redacted)" }
        var debugDescription: String { description }
    }
    private var parameters: Parameters?
    private let appName: String
    private var temporaryFile: URL?, temporaryDirectory: URL?
    private var temporaryInode: UInt64?
    var description: String { "Epic launch authorization (redacted)" }
    var debugDescription: String { description }
    fileprivate init(_ value: [String: Any], account: String, app: String, root: URL) throws {
        appName = app
        guard value["accountId"] as? String == account, value["appName"] as? String == app,
              let executable = value["executablePath"] as? String, let directory = value["workingDirectory"] as? String,
              var arguments = value["arguments"] as? [String], arguments.count <= 256,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 65536,
              !arguments.contains(where: { $0.contains("\0") || $0.contains("\n") || $0.contains("\r") }),
              URL(fileURLWithPath: executable).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              directory == root.path || URL(fileURLWithPath: directory).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw EpicConnectorError.invalidResponse }
        if let encoded = value["ownershipToken"] as? String {
            guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 65536,
                  arguments.filter({ $0 == "-epicovt=__PLAYMELT_PRIVATE_OWNERSHIP_TOKEN__" }).count == 1 else { throw EpicConnectorError.invalidResponse }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-epic-launch-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            temporaryDirectory = folder
            let file = folder.appendingPathComponent("ownership.ovt")
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { close(); throw EpicConnectorError.invalidResponse }
            do {
                defer { Darwin.close(fd) }
                var info = stat(); guard fstat(fd, &info) == 0 else { throw EpicConnectorError.invalidResponse }
                temporaryFile = file; temporaryInode = UInt64(info.st_ino)
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
            } catch { close(); throw error }
            arguments = arguments.map { $0 == "-epicovt=__PLAYMELT_PRIVATE_OWNERSHIP_TOKEN__" ? "-epicovt=" + file.path : $0 }
        } else if arguments.contains(where: { $0.contains("__PLAYMELT_PRIVATE_OWNERSHIP_TOKEN__") }) { throw EpicConnectorError.invalidResponse }
        parameters = Parameters(executable: URL(fileURLWithPath: executable), directory: URL(fileURLWithPath: directory), arguments: arguments)
    }
    /// Consume just before ClientLauncher dispatch; never stringify or forward to WebKit.
    func consume<T>(_ body: (Parameters) throws -> T) throws -> T {
        guard let value = parameters else { throw EpicConnectorError.invalidResponse }
        parameters = nil
        return try body(value)
    }
    static var activeLaunchCount: Int { EpicPrivateClientRegistry.count }
    /// Preserve the recognized renderer/profile script, but never execute its
    /// global Legendary auth path or its diagnostic redirection. The customized
    /// script exists only in memory and is fed to bash's private stdin.
    func launchWithScript(_ template: String, legacyAuthBlock: String, scriptExecutable: String,
                          additionalArguments: [String], environment: [String: String], directory: URL,
                          onExit: @escaping (Int32) -> Void) throws {
        guard template.contains("# Playmelt display guard v1"), !legacyAuthBlock.isEmpty,
              template.components(separatedBy: legacyAuthBlock).count == 2,
              !template.contains("set -x"), !template.contains("set -o xtrace"),
              !template.contains("BASH_XTRACEFD"), !template.contains("PS4=") else { throw EpicConnectorError.invalidResponse }
        let withoutAuth = template.replacingOccurrences(of: legacyAuthBlock, with: "")
        let allowedAssignments = ["GAME_DIR=", "RUNTIME_DIR=", "RENDERER_DIR="]
        func unsafeShellControl(_ line: String) -> Bool {
            let chars = Array(line); var quote: Character?; var index = 0
            while index < chars.count {
                let char = chars[index]
                if quote == "'" { if char == "'" { quote = nil }; index += 1; continue }
                if char == "\\" { index += 2; continue }
                if char == "\"" { quote = quote == "\"" ? nil : "\""; index += 1; continue }
                if quote == nil && char == "'" { quote = "'"; index += 1; continue }
                if char == "`" || (char == "$" && index + 1 < chars.count && chars[index + 1] == "(") { return true }
                if quote == nil && ";|&<>".contains(char) { return true }
                index += 1
            }
            return quote != nil
        }
        for raw in withoutAuth.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "set -eo pipefail" || line == "fi" || line == "exit 78" || line == "cd \"$GAME_DIR\"" || line == "mkdir -p \"$RUNTIME_DIR/logs\"" { continue }
            if line == "echo \"Écran externe ou protection des écrans non vérifié.\" >&2" || line == "if [ \"${PLAYMELT_DISPLAY_POLICY:-}\" != \"external-windowed-v1\" ] || [ ! -f \"${PLAYMELT_DISPLAY_GUARD_LIBRARY:-}\" ]; then" { continue }
            if line.hasPrefix("export ") || allowedAssignments.contains(where: { line.hasPrefix($0) }) {
                guard !unsafeShellControl(line), !["BASH_", "PS4", "EPIC_PARAMS", "${!"].contains(where: { line.contains($0) }) else { throw EpicConnectorError.invalidResponse }; continue
            }
            if line.hasPrefix("QUALITY_COORDINATES=$("), line.contains("/game_display_quality.py' --prepare '"), line.hasSuffix("')"), ![";", "`", "EPIC_PARAMS", "<", ">", "|", "&"].contains(where: { line.contains($0) }), line.components(separatedBy: "$(").count == 2 { continue }
            if line == "read -r PLAYMELT_GAME_WIDTH PLAYMELT_GAME_HEIGHT PLAYMELT_GAME_X PLAYMELT_GAME_Y <<< \"$QUALITY_COORDINATES\"" { continue }
            if line.hasPrefix("exec \"$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine\" ") || line.hasPrefix("exec \"$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/PlaymeltGame.app/Contents/MacOS/wine\" "), line.contains("\"${EPIC_PARAMS[@]}\" \"$@\""), line.hasSuffix(" 2>&1 | /usr/bin/tail -c 1048576 >\"$RUNTIME_DIR/logs/game-" + appName + ".log\"") { continue }
            throw EpicConnectorError.invalidResponse // Refuse unknown echo/trap/eval/redirection paths.
        }
        guard !additionalArguments.contains(where: { value in ["-auth_", "-epicuserid", "-epicapp", "-epicovt"].contains(where: { value.lowercased().hasPrefix($0) }) }) else { throw EpicConnectorError.invalidResponse }
        try consume { value in
            func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var script = template.replacingOccurrences(of: legacyAuthBlock, with: "EPIC_PARAMS=(" + value.arguments.map(quote).joined(separator: " ") + ")")
            var rewritten = 0
            script = try script.components(separatedBy: "\n").map { line in
                guard line.hasPrefix("exec "), let engine = line.range(of: "/engine/bin/wine\" ") ?? line.range(of: "/PlaymeltGame.app/Contents/MacOS/wine\" "), line.contains("\"${EPIC_PARAMS[@]}\" \"$@\"") else { return line }
                let suffix = String(line[engine.upperBound...]), old = quote(scriptExecutable)
                guard suffix.hasPrefix(old + " "), let logging = line.range(of: " 2>&1 | /usr/bin/tail -c 1048576 >") else { throw EpicConnectorError.invalidResponse }
                rewritten += 1
                let endArguments = String(line[line.index(engine.upperBound, offsetBy: old.count)..<logging.lowerBound])
                return String(line[..<engine.upperBound]) + quote(value.executable.path) + endArguments + " >/dev/null 2>&1"
            }.joined(separator: "\n")
            guard rewritten == 1, !script.contains("LEGENDARY_BIN"), !script.contains("AUTH_ARGS="),
                  !script.contains("user.json"), !script.contains(".config/legendary"),
                  !script.contains("eval ") else { throw EpicConnectorError.invalidResponse }
            var safeEnvironment = environment
            for key in ["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "BASH_XTRACEFD", "PS4", "LEGENDARY_CONFIG_PATH"] { safeEnvironment[key] = nil }
            try EpicPrivateClientRegistry.launch(input: Data(script.utf8), arguments: additionalArguments,
                environment: safeEnvironment, directory: directory) { [self] code in self.close(); onExit(code) }
        }
    }
    func close() {
        parameters = nil
        if let file = temporaryFile, let inode = temporaryInode {
            var info = stat()
            if lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
               UInt64(info.st_ino) == inode, info.st_uid == getuid() { _ = unlink(file.path) }
        }
        if let folder = temporaryDirectory { _ = rmdir(folder.path) }
        temporaryFile = nil; temporaryDirectory = nil; temporaryInode = nil
    }
    deinit { close() }
}

/// User-owned game clients are observed, never killed on connector shutdown.
/// Private script input is neither argv nor an environment variable or file.
private enum EpicPrivateClientRegistry {
    static let lock = NSLock()
    static var clients: [UUID: Process] = [:]
    static var count: Int { lock.lock(); defer { lock.unlock() }; return clients.count }
    static func launch(input: Data, arguments: [String], environment: [String: String], directory: URL,
                       onExit: @escaping (Int32) -> Void) throws {
        guard input.count <= 256 * 1024 else { throw EpicConnectorError.invalidResponse }
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw EpicConnectorError.invalidResponse }
        var yes: Int32 = 1
        guard setsockopt(sockets[1], SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(sockets[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(sockets[1], F_SETFD, FD_CLOEXEC) == 0 else {
            for fd in sockets { Darwin.close(fd) }; throw EpicConnectorError.invalidResponse
        }
        let process = Process(), id = UUID()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-s", "--"] + arguments
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: false)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { child in
            DispatchQueue.main.async {
                lock.lock(); clients[id] = nil; lock.unlock()
                onExit(child.terminationStatus)
            }
        }
        lock.lock()
        do { try process.run(); clients[id] = process; lock.unlock() }
        catch { lock.unlock(); for fd in sockets { Darwin.close(fd) }; throw EpicConnectorError.failed(code: "launchFailed", message: "Impossible d’ouvrir ce jeu Epic.") }
        Darwin.close(sockets[0])
        let writer = sockets[1]
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(writer) }
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(writer, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written > 0 { offset += written }
                    else if written < 0 && errno == EINTR { continue }
                    else { break } // No payload-bearing write error reaches diagnostics/UI.
                }
            }
        }
    }
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

/// Epic connection and isolated operations. Access/refresh credentials travel
/// only through private pipes, never argv, logs, UI or a global launcher file.
/// The one-use exchange code is reserved for the exact game child's argv.
/// Existing Playmelt legacy credentials may be validated and migrated, never rewritten.
final class EpicConnector {
    private let projectRoot: URL
    private let pythonURL: URL?
    private let portableRuntime: PortablePythonRuntime?
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
    private var operationGeneration = 0
    private var verifiedApps = Set<String>()
    private var requestPending = false
    private var closing = false

    init(projectRoot: URL? = nil, pythonURL: URL? = nil, workerURL: URL? = nil,
         runner: OwnedProcessRunning = OwnedProcessRunner(),
         sessionStore: EpicSessionStoring = EpicKeychainSessionStore()) {
        self.runner = runner
        self.sessionStore = sessionStore
        let configured = Bundle.main.object(forInfoDictionaryKey: "MetalMaxSourceDirectory") as? String
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt")
        let development = PortablePythonRuntime.developmentAllowed
        let devRoot = projectRoot ?? configured.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? applicationSupport
        let resources=PortablePythonRuntime.applicationResources()
        self.projectRoot = projectRoot ?? (development ? devRoot : resources ?? applicationSupport)
        let venvCandidates = PortablePythonRuntime.epicDevelopmentCandidates(projectRoot:devRoot,applicationSupport:applicationSupport,development:development)
        let portable = pythonURL == nil ? PortablePythonRuntime.resolve(development: development, developmentCandidates: venvCandidates, requireLegendary: true, requireCertificates: true) : nil
        self.portableRuntime = portable
        self.pythonURL = pythonURL ?? portable?.pythonURL

        let workerCandidates = [PortablePythonRuntime.resource(named:"epic-worker.py")].compactMap { $0 } +
            ((development || pythonURL != nil || workerURL != nil) ? [devRoot.appendingPathComponent("scripts/epic-worker.py"), applicationSupport.appendingPathComponent("scripts/epic-worker.py")] : [])
        self.workerURL = workerURL ?? workerCandidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) ??
            (resources ?? self.projectRoot).appendingPathComponent("epic-worker.py")
    }

    var legendaryExecutableURL: URL? {
        if let portableRuntime { return portableRuntime.legendaryExecutableURL }
        guard let pythonURL else { return nil }
        let cli = pythonURL.deletingLastPathComponent().appendingPathComponent("legendary")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    func availability() -> [String: Any] {
        let exists = (pythonURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false)
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
                "credentialStorage": credentialStorage, "credentialBackend": sessionStore.persistenceBackend, "sessionLifetime": lifetime,
                "storageStatus": status, "storageError": storageIssue, "sessionVerified": verified,
                "versionVerified": false,
                "message": exists
                    ? (!storageIssue.isEmpty ? storageIssue : authenticated
                        ? (credentialStorage == "keychain" ? "Session Epic conservée dans le Trousseau de ce Mac. Actualisez pour vérifier la bibliothèque." : "Session Epic en mémoire uniquement ; elle prendra fin à la fermeture de Playmelt.")
                        : "La connexion Epic mémorisée sera recherchée dans le Trousseau uniquement à votre demande.")
                    : "Le runtime Epic embarqué est absent ou incomplet. Réinstallez une version complète de Playmelt."]
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

    func install(appName: String, platform: String, libraryAccountID: String,
                 completion: @escaping (Result<EpicInstallation, Error>) -> Void) {
        let workers = max(8, min(ProcessInfo.processInfo.activeProcessorCount * 3, 32))
        let memoryMiB = ProcessInfo.processInfo.physicalMemory / 1_048_576
        let sharedMemory = memoryMiB >= 32_768 ? 4096 : memoryMiB >= 16_384 ? 2048 : 1024
        request(["action": "install", "appName": appName, "platform": platform, "expectedAccountId": libraryAccountID,
                 "maxWorkers": workers, "sharedMemoryMiB": sharedMemory]) { result in
            completion(result.flatMap { payload in
                guard let value = payload["installation"] as? [String: Any], value["filesVerified"] as? Bool == true,
                      value["accountId"] as? String == libraryAccountID, value["appName"] as? String == appName,
                      let install = Self.installation(value) else { return .failure(EpicConnectorError.invalidResponse) }
                return .success(install)
            })
        }
    }
    func authorizeLaunch(appName: String, platform: String, directory: URL, libraryAccountID: String,
                         completion: @escaping (Result<EpicLaunchAuthorization, Error>) -> Void) {
        request(["action": "launchAuthorization", "appName": appName, "platform": platform,
                 "installPath": directory.path, "expectedAccountId": libraryAccountID]) { result in
            completion(result.flatMap { payload in
                guard let value = payload["launch"] as? [String: Any] else { return .failure(EpicConnectorError.invalidResponse) }
                return Result { try EpicLaunchAuthorization(value, account: libraryAccountID, app: appName, root: directory) }
            })
        }
    }
    func cancelOperation() { lock.lock(); operationGeneration += 1; lock.unlock() }
    private static func installation(_ value: [String: Any]) -> EpicInstallation? {
        guard let account = value["accountId"] as? String, let app = value["appName"] as? String,
              let platform = value["platform"] as? String, ["Mac", "Windows"].contains(platform),
              let title = value["title"] as? String, let executable = value["executable"] as? String,
              let path = value["installPath"] as? String, path.hasPrefix("/"), !executable.isEmpty else { return nil }
        return EpicInstallation(accountID: account, appName: app, platform: platform, title: title,
                                executable: executable, directory: URL(fileURLWithPath: path), prerequisitesRequired: value["prerequisitesRequired"] as? Bool ?? false)
    }
    /// Non-credential receipts only. Ownership is rechecked online before operations.
    func managedInstallations() -> [EpicInstallation] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { directory in
            let file = directory.appendingPathComponent(".playmelt-epic-install.json")
            guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]), info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 65537) <= 65536,
                  let data = try? Data(contentsOf: file), let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  record["schema"] as? Int == 1, let account = record["accountId"] as? String, let value = record["installed"] as? [String: Any],
                  value["install_path"] as? String == directory.path else { return nil }
            return Self.installation(["accountId": account, "appName": value["app_name"] ?? "", "platform": value["platform"] ?? "", "title": value["title"] ?? "", "executable": value["executable"] ?? "", "installPath": directory.path, "prerequisitesRequired": value["prereq_info"] is [String: Any]])
        }
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
        session = nil; sessionVerified = false; verifiedApps.removeAll(); sessionPersisted = false; restoreAllowed = false; generation += 1
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
    static func validatedSnapshot(_ payload: [String: Any]) -> Result<EpicSnapshot, Error> {
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
        storageError = sessionStore.restorationNotice
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
        guard let pythonURL, FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.isReadableFile(atPath: workerURL.path) else {
            completion(.failure(EpicConnectorError.unavailable("Le runtime Epic embarqué est absent ou incomplet. Réinstallez une version complète de Playmelt.")))
            return
        }
        lock.lock()
        guard !requestPending && storeOperation == nil && !closing else {
            lock.unlock()
            completion(.failure(EpicConnectorError.failed(code: "busy", message: "Une opération Epic est déjà en cours ou l’application se ferme.")))
            return
        }
        let action = payload["action"] as? String ?? ""
        let operation = ["install", "launchAuthorization"].contains(action)
        if operation {
            guard sessionVerified, let current = session?["account_id"] as? String else {
                lock.unlock(); completion(.failure(EpicConnectorError.failed(code: "requiresLogin", message: "Actualisez votre bibliothèque Epic avant cette opération."))); return
            }
            guard payload["expectedAccountId"] as? String == current else {
                lock.unlock(); completion(.failure(EpicConnectorError.failed(code: "accountChanged", message: "Le compte de la bibliothèque Epic a changé."))); return
            }
            guard let app = payload["appName"] as? String, verifiedApps.contains(app) else {
                lock.unlock(); completion(.failure(EpicConnectorError.failed(code: "notOwned", message: "Ce jeu n’appartient pas à la bibliothèque Epic vérifiée."))); return
            }
        }
        requestPending = true
        if ["authenticate", "sync"].contains(payload["action"] as? String ?? "") { sessionVerified = false }
        let requestGeneration = generation
        let requestOperationGeneration = operationGeneration
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
                if operation { self.lock.lock(); input["session"] = self.session; self.lock.unlock() }
                var response = try self.runWorker(input, generation: requestGeneration, operationGeneration: operation ? requestOperationGeneration : nil, timeout: action == "install" ? 24 * 3600 : 180)
                // A token refresh must not silently replace the library owner.
                // Validate identity before retaining new credentials or exposing
                // a snapshot; authURL deliberately has no session/snapshot.
                let action = payload["action"] as? String
                let verifiedResponse = response["ok"] as? Bool == true && (action == "authenticate" || action == "sync" || operation)
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
                    guard let refreshedAccount, !refreshedAccount.isEmpty else { throw EpicConnectorError.invalidResponse }
                    if operation {
                        let key = action == "install" ? "installation" : "launch"
                        guard let value = response[key] as? [String: Any], value["accountId"] as? String == refreshedAccount,
                              refreshedAccount == expectedAccount, value["appName"] as? String == payload["appName"] as? String else { throw EpicConnectorError.invalidResponse }
                        if action == "launchAuthorization", let arguments = value["arguments"] as? [String] {
                            for name in ["access_token", "refresh_token"] {
                                if let token = refreshed?[name] as? String, arguments.contains(where: { $0.contains(token) }) { throw EpicConnectorError.invalidResponse }
                            }
                        }
                    } else {
                        guard case .success(let checkedSnapshot) = Self.validatedSnapshot(response), checkedSnapshot.accountId == refreshedAccount else { throw EpicConnectorError.invalidResponse }
                    }
                }
                if refreshed != nil && (refreshedAccount?.isEmpty != false ||
                    ((action == "sync" || operation) && refreshedAccount != expectedAccount)) {
                    self.lock.lock()
                    if self.generation == requestGeneration {
                        self.session = nil; self.sessionVerified = false; self.sessionPersisted = false
                        self.restoreAllowed = false; self.storageStatus = "invalidated"
                    }
                    self.lock.unlock()
                    throw EpicConnectorError.failed(code: "accountChanged", message: "Le compte Epic a changé. Reconnectez le compte voulu avant de continuer.")
                }
                self.lock.lock()
                let cancelled = self.generation != requestGeneration || (operation && self.operationGeneration != requestOperationGeneration)
                if !cancelled, let refreshed { self.session = refreshed; self.restoreAllowed = true }
                if !cancelled, let error = response["error"] as? [String: Any],
                   ["authenticationFailed", "accountChanged"].contains(error["code"] as? String ?? "") {
                    self.session = nil; self.sessionVerified = false; self.sessionPersisted = false
                    self.restoreAllowed = false; self.storageStatus = "invalidated"
                }
                if !cancelled, action == "authenticate" || action == "sync" { self.sessionVerified = response["ok"] as? Bool == true }
                if !cancelled, !operation, verifiedResponse, case .success(let snapshot) = Self.validatedSnapshot(response) {
                    self.verifiedApps = Set(snapshot.games.compactMap { $0["appName"] as? String })
                }
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
                let stale = self.closing || self.generation != requestGeneration || (operation && self.operationGeneration != requestOperationGeneration)
                self.requestPending = false
                self.lock.unlock()
                // clearSession/shutdown can happen after the worker returned but
                // before this callback runs. Never revive that account in the UI.
                if stale { completion(.failure(EpicConnectorError.failed(code: "cancelled", message: "Connexion Epic annulée."))) }
                else { completion(outcome) }
            }
        }
    }

    private func runWorker(_ input: [String: Any], generation requestGeneration: Int, operationGeneration expectedOperation: Int? = nil, timeout: TimeInterval = 180) throws -> [String: Any] {
        guard let pythonURL else { throw EpicConnectorError.unavailable("Le runtime Python embarqué est indisponible.") }
        let body = try JSONSerialization.data(withJSONObject: input)
        guard body.count <= 1024 * 1024 else { throw EpicConnectorError.invalidResponse }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "fr_FR.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        var request = OwnedProcessRequest(executable: pythonURL, arguments: ["-I", "-B", workerURL.path],
            environment: portableRuntime?.environment(merging: environment) ?? environment)
        request.directory = projectRoot; request.input = body; request.timeout = timeout
        request.terminationGracePeriod = 10
        request.outputLimit = 16 * 1024 * 1024; request.mergeStandardError = false
        do {
            let result = try runner.run(request, cancelled: {
                self.lock.lock(); defer { self.lock.unlock() }
                return self.closing || self.generation != requestGeneration || expectedOperation.map { self.operationGeneration != $0 } == true
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
