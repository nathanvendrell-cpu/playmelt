import Foundation
import Darwin

@_silgen_name("proc_listpids") private func steamLifecycleListPIDs(_ type: UInt32, _ info: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pidpath") private func steamLifecyclePIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32

enum SteamClientLifecycleError: LocalizedError {
    case invalidRequest, closed, busy, observationUnavailable, orphanedHelpers, multipleClients
    case startupUnconfirmed, deliveryUnconfirmed, clientDisappeared, deliveryFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "La demande Steam Windows n’est pas valide."
        case .closed: return "Playmelt se ferme."
        case .busy: return "Une demande utilise déjà ce client Steam Windows."
        case .observationUnavailable: return "Impossible de confirmer les processus de ce client Steam Windows."
        case .orphanedHelpers: return "Des composants Steam Windows sont encore actifs sans client confirmé. Aucun second client n’a été lancé."
        case .multipleClients: return "Plusieurs clients Steam Windows sont déjà actifs dans ce moteur. Aucun client supplémentaire n’a été lancé."
        case .startupUnconfirmed: return "Le démarrage de Steam Windows reste à confirmer. Aucun second démarrage n’a été tenté."
        case .deliveryUnconfirmed: return "Steam Windows n’a pas confirmé la fin de transmission. La demande reste protégée contre les doublons."
        case .clientDisappeared: return "Le client Steam Windows s’est fermé avant la transmission."
        case .deliveryFailed(let code): return "Steam Windows n’a pas accepté la transmission (code \(code))."
        }
    }
}

/// A process identity includes its birth time: a reused PID never inherits ownership.
struct SteamClientProcessIdentity: Hashable {
    let pid: pid_t
    let uid: uid_t
    let birthSeconds: Int64
    let birthMicroseconds: Int64
    let executable: String
}
enum SteamClientProcessRole { case client, helper, service }
struct SteamClientObservedProcess {
    let identity: SteamClientProcessIdentity
    let parentPID: pid_t
    let prefix: String
    let target: String
    let role: SteamClientProcessRole
}
struct SteamClientContext {
    let prefix: URL
    let wine: URL
    let steam: URL
    let loaderPaths: Set<String>
    var key: String { prefix.path }
    init(prefix: URL, wine: URL, steam: URL) throws {
        func canonical(_ url: URL) throws -> URL {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw SteamClientLifecycleError.invalidRequest }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.prefix = try canonical(prefix); self.wine = try canonical(wine); self.steam = try canonical(steam)
        guard self.steam.lastPathComponent.lowercased() == "steam.exe",
              self.steam.path.hasPrefix(self.prefix.path + "/drive_c/") else { throw SteamClientLifecycleError.invalidRequest }
        loaderPaths = WineExecutableLocations.loaderPaths(wine: self.wine)
    }
    /// Interpret only an exact executable argument, never a substring of a command line.
    func targetPath(_ argument: String) -> String? {
        let slashes = argument.replacingOccurrences(of: "\\", with: "/")
        let path: URL
        if slashes.lowercased().hasPrefix("c:/") {
            let relative = String(slashes.dropFirst(3))
            guard !relative.split(separator: "/").contains("..") else { return nil }
            path = prefix.appendingPathComponent("drive_c").appendingPathComponent(relative)
        } else if slashes.hasPrefix("/") { path = URL(fileURLWithPath: slashes) }
        else { return nil }
        return path.standardizedFileURL.resolvingSymlinksInPath().path
    }
    func role(target: String) -> SteamClientProcessRole? {
        if target.lowercased() == steam.path.lowercased() { return .client }
        let root = steam.deletingLastPathComponent().path.lowercased()
        let relative = target.lowercased().hasPrefix(root + "/") ? String(target.lowercased().dropFirst(root.count + 1)) : ""
        if ["bin/cef/cef.win7/steamwebhelper.exe", "bin/cef/cef.win7x64/steamwebhelper.exe", "bin/cef/cef.win64/steamwebhelper.exe"].contains(relative) { return .helper }
        if ["bin/steamservice.exe", "steamservice.exe"].contains(relative) { return .service }
        let common = ["Program Files (x86)", "Program Files"].map {
            prefix.appendingPathComponent("drive_c/\($0)/Common Files/Steam/steamservice.exe").standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        }
        if common.contains(target.lowercased()) { return .service }
        return nil
    }
}
protocol SteamClientProcessInspecting {
    func snapshot(_ context: SteamClientContext) throws -> [SteamClientObservedProcess]
}

/// Read-only, same-UID inspection. Arguments/environment are never persisted or logged.
/// -steampid is a Windows PID and is deliberately not used as a macOS parent PID.
final class DarwinSteamClientProcessInspector: SteamClientProcessInspecting {
    /// Unknown Wine locations are candidates for READ-ONLY classification, never
    /// accepted loader identities. Unrelated non-Wine apps are not inspected.
    static func candidateExecutable(_ executable: String, context: SteamClientContext) -> Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return context.loaderPaths.contains(executable) || context.role(target: executable) != nil ||
            ["wine", "wine64", "wine-preloader", "wine64-preloader"].contains(name)
    }
    static func classify(executable: String, arguments: [String], prefix: String?, uid: uid_t,
                         context: SteamClientContext) throws -> (target: String, role: SteamClientProcessRole)? {
        guard uid == geteuid(), let prefix, prefix.hasPrefix("/"),
              URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path == context.key else { return nil }
        let target = arguments.prefix(2).compactMap { context.targetPath($0) }.first { context.role(target: $0) != nil }
        guard let target, let role = context.role(target: target) else { return nil }
        guard context.loaderPaths.contains(executable) || executable.lowercased() == target.lowercased() else {
            throw SteamClientLifecycleError.observationUnavailable
        }
        return (target, role)
    }
    private func info(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var value = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &value, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              Int32(value.kp_proc.p_stat) != SZOMB else { return nil }
        return value
    }
    /// KERN_PROCARGS2: argc, executable, padding, argv, environment.
    static func parseArguments(_ data: Data) -> (arguments: [String], prefix: String?)? {
        guard data.count >= 5 else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 4096 else { return nil }
        let bytes = [UInt8](data); var offset = 4
        func string() -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(bytes: bytes[offset..<end], encoding: .utf8)
        }
        guard string() != nil else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<count { guard let value = string() else { return nil }; arguments.append(value) }
        var prefix: String?
        while offset < bytes.count {
            guard let value = string() else { return nil }
            if value.hasPrefix("WINEPREFIX=") {
                guard prefix == nil else { return nil }
                prefix = String(value.dropFirst(11))
            }
        }
        return (arguments, prefix)
    }
    func snapshot(_ context: SteamClientContext) throws -> [SteamClientObservedProcess] {
        var capacity = max(1024, Int(steamLifecycleListPIDs(4, UInt32(geteuid()), nil, 0)) / MemoryLayout<pid_t>.size + 128)
        var pids = [pid_t](), used: Int32 = 0
        repeat {
            guard capacity <= 65536 else { throw SteamClientLifecycleError.observationUnavailable }
            pids = [pid_t](repeating: 0, count: capacity)
            used = pids.withUnsafeMutableBytes { steamLifecycleListPIDs(4, UInt32(geteuid()), $0.baseAddress, Int32($0.count)) }
            guard used > 0, Int(used) % MemoryLayout<pid_t>.size == 0 else { throw SteamClientLifecycleError.observationUnavailable }
            if Int(used) < capacity * MemoryLayout<pid_t>.size { break }; capacity *= 2
        } while true
        var result: [SteamClientObservedProcess] = []
        for pid in pids.prefix(Int(used) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard let before = info(pid), before.kp_eproc.e_ucred.cr_uid == geteuid() else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard buffer.withUnsafeMutableBytes({ steamLifecyclePIDPath(pid, $0.baseAddress, UInt32($0.count)) }) > 0 else {
                if info(pid) == nil { continue }; throw SteamClientLifecycleError.observationUnavailable
            }
            let executable = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.resolvingSymlinksInPath().path
            guard Self.candidateExecutable(executable, context: context) else { continue }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size <= 2 * 1024 * 1024 else {
                if info(pid) == nil { continue }; throw SteamClientLifecycleError.observationUnavailable
            }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
            guard let after = info(pid) else { continue }
            guard after.kp_eproc.e_ucred.cr_uid == geteuid(),
                  before.kp_proc.p_starttime.tv_sec == after.kp_proc.p_starttime.tv_sec,
                  before.kp_proc.p_starttime.tv_usec == after.kp_proc.p_starttime.tv_usec else { continue }
            guard read == 0, let parsed = Self.parseArguments(data.prefix(size)) else { throw SteamClientLifecycleError.observationUnavailable }
            // Wine argv[0] can be the PE image; otherwise the first exact PE path is argv[1].
            guard let matched = try Self.classify(executable: executable, arguments: parsed.arguments, prefix: parsed.prefix,
                                                 uid: after.kp_eproc.e_ucred.cr_uid, context: context) else { continue }
            let identity = SteamClientProcessIdentity(pid: pid, uid: after.kp_eproc.e_ucred.cr_uid,
                birthSeconds: Int64(after.kp_proc.p_starttime.tv_sec), birthMicroseconds: Int64(after.kp_proc.p_starttime.tv_usec), executable: executable)
            result.append(.init(identity: identity, parentPID: after.kp_eproc.e_ppid, prefix: context.key, target: matched.target, role: matched.role))
        }
        return result
    }
}

struct SteamClientLaunchRequest {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
}
protocol SteamClientProcessLaunching {
    func launch(_ request: SteamClientLaunchRequest, onExit: @escaping (Int32) -> Void) throws
    func shutdown()
}
final class SteamClientUserProcessLauncher: SteamClientProcessLaunching {
    private let launcher = UserProcessLauncher()
    var activeCount: Int { launcher.activeCount }
    func launch(_ request: SteamClientLaunchRequest, onExit: @escaping (Int32) -> Void) throws {
        try launcher.launch(executable: request.executable, arguments: request.arguments, environment: request.environment, directory: request.directory, onExit: onExit)
    }
    func shutdown() { launcher.shutdown() } // observation only; never kill a client/game/download
}
enum SteamClientLifecycleDisposition { case started, reused, forwarded }

/// One broker per application. Prefix leases additionally prevent two application
/// instances from racing during startup/delivery. Neither shutdown nor a timeout
/// signals any client, helper, game, wineserver or other store's process.
final class SteamClientLifecycle {
    typealias Completion = (Result<SteamClientLifecycleDisposition, Error>) -> Void
    private final class Pending {
        let id = UUID(), arguments: [String], environment: [String: String]
        var completions: [Completion]
        var reported = false
        init(_ arguments: [String], _ environment: [String: String], _ completion: @escaping Completion) { self.arguments = arguments; self.environment = environment; completions = [completion] }
    }
    private final class Session {
        let context: SteamClientContext
        var pending: [Pending] = [], current: Pending?, lease: Int32 = -1
        var booting = false, uncertainStartup = false, startingDeadline: TimeInterval = 0
        var bootID: UUID?, bootExit: Int32?
        init(_ context: SteamClientContext) { self.context = context }
        deinit { if lease >= 0 { close(lease) } }
    }
    private let queue = DispatchQueue(label: "fr.playmelt.steam-client-lifecycle")
    private let callbacks: DispatchQueue, inspector: SteamClientProcessInspecting, launcher: SteamClientProcessLaunching
    private let startupTimeout: TimeInterval, deliveryTimeout: TimeInterval, pollInterval: TimeInterval
    private let callbackLock = NSLock()
    private var callbacksClosed = false
    private var sessions: [String: Session] = [:], closed = false
    init(inspector: SteamClientProcessInspecting = DarwinSteamClientProcessInspector(), launcher: SteamClientProcessLaunching = SteamClientUserProcessLauncher(),
         callbackQueue: DispatchQueue = .main, startupTimeout: TimeInterval = 20, deliveryTimeout: TimeInterval = 15, pollInterval: TimeInterval = 0.1) {
        self.inspector = inspector; self.launcher = launcher; callbacks = callbackQueue
        self.startupTimeout = max(0.05, min(60, startupTimeout)); self.deliveryTimeout = max(0.05, min(60, deliveryTimeout))
        self.pollInterval = max(0.01, min(1, pollInterval))
    }
    func request(prefix: URL, wine: URL, steam: URL, arguments: [String], environment: [String: String], directory: URL?, completion: @escaping Completion) {
        queue.async {
            do {
                guard !self.closed else { throw SteamClientLifecycleError.closed }
                let context = try SteamClientContext(prefix: prefix, wine: wine, steam: steam)
                guard let envPrefix = environment["WINEPREFIX"], envPrefix.hasPrefix("/"), URL(fileURLWithPath: envPrefix).standardizedFileURL.resolvingSymlinksInPath().path == context.key,
                      directory == nil || directory!.standardizedFileURL.resolvingSymlinksInPath().path == context.key,
                      Self.validArguments(arguments) else { throw SteamClientLifecycleError.invalidRequest }
                let session = self.sessions[context.key] ?? Session(context)
                guard session.context.wine == context.wine, session.context.steam == context.steam else { throw SteamClientLifecycleError.invalidRequest }
                self.sessions[context.key] = session
                if session.current?.reported == true, session.uncertainStartup {
                    let observed = try self.inventory(session), clients = observed.filter { $0.role == .client }
                    guard clients.count <= 1 else { throw SteamClientLifecycleError.multipleClients }
                    if clients.count == 1 {
                        // A late startup can be adopted by a NEW explicit action;
                        // a background timer never restarts or replays anything.
                        self.finish(session, .failure(SteamClientLifecycleError.startupUnconfirmed))
                    } else if observed.contains(where: { $0.role == .helper }) { throw SteamClientLifecycleError.orphanedHelpers }
                }
                if let identical = ([session.current].compactMap { $0 } + session.pending).first(where: { $0.arguments == arguments && $0.environment == environment }) {
                    guard !identical.reported else { throw SteamClientLifecycleError.deliveryUnconfirmed }
                    guard identical.completions.count < 128 else { throw SteamClientLifecycleError.busy }
                    identical.completions.append(completion); return
                }
                guard session.current?.reported != true else { throw SteamClientLifecycleError.busy }
                guard session.pending.count < 32 else { throw SteamClientLifecycleError.busy }
                session.pending.append(Pending(arguments, environment, completion)); self.advance(session)
            } catch { self.emit([completion], .failure(error)) }
        }
    }
    static func validArguments(_ arguments: [String]) -> Bool {
        guard arguments.count <= 64, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else { return false }
        if arguments.isEmpty || arguments == ["steam://open/games"] { return true }
        func appID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 10 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && UInt64(value).map { $0 > 0 && $0 <= UInt32.max } == true }
        if arguments.count == 1, arguments[0].hasPrefix("steam://install/") { return appID(String(arguments[0].dropFirst(16))) }
        return arguments.count >= 2 && arguments[0] == "-applaunch" && appID(arguments[1])
    }
    private func acquire(_ session: Session) throws {
        let path = session.context.prefix.appendingPathComponent(".playmelt-steam-client.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SteamClientLifecycleError.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600, flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw SteamClientLifecycleError.busy }
        session.lease = fd
    }
    private func inventory(_ session: Session) throws -> [SteamClientObservedProcess] {
        let values = try inspector.snapshot(session.context)
        // Injectable inspectors must obey the same boundary as the Darwin adapter.
        let relevant = values.filter { $0.identity.uid == geteuid() && $0.identity.pid > 0 && $0.identity.birthSeconds > 0 &&
            $0.prefix == session.context.key && session.context.role(target: $0.target) == $0.role }
        guard relevant.allSatisfy({ session.context.loaderPaths.contains($0.identity.executable) || $0.identity.executable.lowercased() == $0.target.lowercased() }) else {
            throw SteamClientLifecycleError.observationUnavailable
        }
        return relevant
    }
    private func advance(_ session: Session) {
        guard !closed, session.current == nil, !session.pending.isEmpty else { return }
        session.current = session.pending.removeFirst()
        do {
            try acquire(session)
            let values = try inventory(session), clients = values.filter { $0.role == .client }
            guard clients.count <= 1 else { throw SteamClientLifecycleError.multipleClients }
            if clients.isEmpty {
                // Steam's persistent service is not a client or an orphaned CEF.
                // Preserve it while starting exactly one client under this lease.
                guard !values.contains(where: { $0.role == .helper }) else { throw SteamClientLifecycleError.orphanedHelpers }
                // Boot once, without a game command. All game/install requests go
                // through Steam's same-prefix IPC after a client is observed.
                let id = UUID(); session.bootID = id; session.bootExit = nil; session.booting = true
                session.startingDeadline = ProcessInfo.processInfo.systemUptime + startupTimeout
                let silent = session.current!.arguments.isEmpty || session.current!.arguments == ["steam://open/games"] ? [] : ["-silent"]
                try launcher.launch(launchRequest(session, silent)) { [weak self, weak session] code in
                    self?.queue.async { [weak self, weak session] in
                        guard let self, let session, session.bootID == id, !self.closed else { return }
                        session.bootExit = code
                        if session.current?.reported == true, !session.booting {
                            self.finish(session, .failure(SteamClientLifecycleError.startupUnconfirmed))
                        }
                    }
                }
                pollStartup(session, id: id)
            } else { try deliver(session, booted: false, expectedClient: clients[0].identity) }
        } catch { finish(session, .failure(error)) }
    }
    private func launchRequest(_ session: Session, _ arguments: [String]) -> SteamClientLaunchRequest {
        var environment = session.current!.environment; environment["WINEPREFIX"] = session.context.key
        return .init(executable: session.context.wine, arguments: [session.context.steam.path] + arguments, environment: environment, directory: session.context.prefix)
    }
    private func pollStartup(_ session: Session, id: UUID) {
        guard !closed, session.bootID == id, session.booting else { return }
        do {
            let values = try inventory(session), clients = values.filter { $0.role == .client }
            guard clients.count <= 1 else { throw SteamClientLifecycleError.multipleClients }
            if clients.count == 1 { session.booting = false; try deliver(session, booted: true, expectedClient: clients[0].identity); return }
            if let exit = session.bootExit, exit != 0 { throw SteamClientLifecycleError.deliveryFailed(exit) }
            guard ProcessInfo.processInfo.systemUptime < session.startingDeadline else { throw SteamClientLifecycleError.startupUnconfirmed }
            queue.asyncAfter(deadline: .now() + pollInterval) { [weak self, weak session] in
                guard let self, let session else { return }; self.pollStartup(session, id: id)
            }
        } catch {
            // A timed-out startup may still be alive. Keep the lease/current
            // protected until its exact launch callback has observed exit.
            session.booting = false
            if session.bootExit == nil { session.uncertainStartup = true; report(session, .failure(error)) }
            else { finish(session, .failure(error)) }
        }
    }
    private func deliver(_ session: Session, booted: Bool, expectedClient: SteamClientProcessIdentity) throws {
        guard let current = session.current else { return }
        if current.arguments.isEmpty { finish(session, .success(booted ? .started : .reused)); return }
        let values = try inventory(session), clients = values.filter { $0.role == .client }
        guard clients.count == 1 else { throw clients.isEmpty ? SteamClientLifecycleError.clientDisappeared : .multipleClients }
        guard clients[0].identity == expectedClient else { throw SteamClientLifecycleError.clientDisappeared }
        // -ifrunning addresses Steam's existing IPC endpoint. It must never be
        // used as evidence of a running game or an authenticated Steam account.
        try launcher.launch(launchRequest(session, ["-ifrunning"] + current.arguments)) { [weak self, weak session, weak current] code in
            self?.queue.async { [weak self, weak session, weak current] in
                guard let self, let session, let current, session.current === current, !self.closed else { return }
                do {
                    guard code == 0 else { throw SteamClientLifecycleError.deliveryFailed(code) }
                    let live = try self.inventory(session).filter { $0.role == .client }
                    guard live.count == 1, live[0].identity == expectedClient else { throw SteamClientLifecycleError.clientDisappeared }
                    self.finish(session, .success(.forwarded))
                } catch { self.finish(session, .failure(error)) }
            }
        }
        queue.asyncAfter(deadline: .now() + deliveryTimeout) { [weak self, weak session, weak current] in
            guard let self, let session, let current, session.current === current, !self.closed else { return }
            self.report(session, .failure(SteamClientLifecycleError.deliveryUnconfirmed))
        }
    }
    private func report(_ session: Session, _ result: Result<SteamClientLifecycleDisposition, Error>) {
        guard let current = session.current, !current.reported else { return }
        current.reported = true; let completions = current.completions; current.completions = []
        emit(completions, result)
        // Queued distinct requests cannot remain unresolved after an uncertain
        // transmission. A new user action can inspect again after exact exit.
        let pending = session.pending; session.pending = []
        emit(pending.flatMap(\.completions), .failure(SteamClientLifecycleError.busy))
    }
    private func finish(_ session: Session, _ result: Result<SteamClientLifecycleDisposition, Error>) {
        guard let current = session.current else { return }
        let completions = current.reported ? [] : current.completions
        session.current = nil; session.booting = false; session.uncertainStartup = false; session.bootID = nil
        if session.lease >= 0 { close(session.lease); session.lease = -1 }
        emit(completions, result)
        advance(session)
    }
    private func emit(_ completions: [Completion], _ result: Result<SteamClientLifecycleDisposition, Error>) {
        callbacks.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock(); let allowed = !self.callbacksClosed; self.callbackLock.unlock()
            if allowed { completions.forEach { $0(result) } }
        }
    }
    func shutdown() {
        callbackLock.lock(); callbacksClosed = true; callbackLock.unlock()
        queue.async {
            guard !self.closed else { return }; self.closed = true
            // No process signal and no callback after shutdown. Kernel leases
            // close on process death as well; no age/PID heuristic is involved.
            self.sessions.removeAll(); self.launcher.shutdown()
        }
    }
}
