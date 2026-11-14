// swiftc OwnedProcess.swift SteamClientLifecycle.swift tests/SteamClientLifecycleTests.swift -o <temporary test binary>
import Foundation
import Darwin

private final class LifecycleInspector: SteamClientProcessInspecting {
    let lock = NSLock()
    var values: [String: [SteamClientObservedProcess]] = [:]
    var failure = false
    var snapshots: [[SteamClientObservedProcess]] = []
    func set(_ context: SteamClientContext, _ processes: [SteamClientObservedProcess]) { lock.lock(); values[context.key] = processes; lock.unlock() }
    func snapshot(_ context: SteamClientContext) throws -> [SteamClientObservedProcess] {
        lock.lock(); defer { lock.unlock() }
        if failure { throw SteamClientLifecycleError.observationUnavailable }
        if !snapshots.isEmpty { return snapshots.removeFirst() }
        return values[context.key] ?? []
    }
}
private final class LifecycleLauncher: SteamClientProcessLaunching {
    struct Call { let request: SteamClientLaunchRequest; let exit: (Int32) -> Void }
    let lock = NSLock()
    var values: [Call] = []
    var closed = false, failNext = false
    func launch(_ request: SteamClientLaunchRequest, onExit: @escaping (Int32) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; throw OwnedProcessError.spawn(13) }
        values.append(.init(request: request, exit: onExit))
    }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return values }
    func shutdown() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}
@main struct SteamClientLifecycleTests {
    static var checks = 0
    static func expect(_ ok: @autoclosure () -> Bool, _ message: String) {
        guard ok() else { fatalError("FAIL: \(message)") }; checks += 1
    }
    static func until(_ message: String, _ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        expect(predicate(), message)
    }
    static func failed(_ result: Result<SteamClientLifecycleDisposition, Error>?, _ kind: SteamClientLifecycleError) -> Bool {
        guard case .failure(let error)? = result, let value = error as? SteamClientLifecycleError else { return false }
        return String(describing: value) == String(describing: kind)
    }
    static func succeeded(_ result: Result<SteamClientLifecycleDisposition, Error>?, _ expected: SteamClientLifecycleDisposition) -> Bool {
        guard case .success(let actual)? = result else { return false }; return actual == expected
    }
    static func process(_ context: SteamClientContext, pid: pid_t = 100, birth: Int64 = 1, role: SteamClientProcessRole = .client, uid: uid_t = geteuid(), parent: pid_t = 1, executable: URL? = nil) -> SteamClientObservedProcess {
        let target: String
        switch role {
        case .client: target = context.steam.path
        case .helper: target = context.steam.deletingLastPathComponent().appendingPathComponent("bin/cef/cef.win7x64/steamwebhelper.exe").path
        case .service: target = context.prefix.appendingPathComponent("drive_c/Program Files (x86)/Common Files/Steam/steamservice.exe").path
        }
        return .init(identity: .init(pid: pid, uid: uid, birthSeconds: birth, birthMicroseconds: 123, executable: executable?.standardizedFileURL.resolvingSymlinksInPath().path ?? context.wine.path), parentPID: parent, prefix: context.key, target: target, role: role)
    }
    static func context(_ root: URL, _ name: String) throws -> SteamClientContext {
        let prefix = root.appendingPathComponent(name), wine = root.appendingPathComponent("engine/bin/wine64")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam"), withIntermediateDirectories: true)
        return try SteamClientContext(prefix: prefix, wine: wine, steam: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
    }
    static func send(_ broker: SteamClientLifecycle, _ context: SteamClientContext, _ args: [String] = [], environment: [String: String] = [:], _ completion: @escaping SteamClientLifecycle.Completion) {
        var env = environment; env["WINEPREFIX"] = context.prefix.path
        broker.request(prefix: context.prefix, wine: context.wine, steam: context.steam, arguments: args, environment: env, directory: context.prefix, completion: completion)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Steam lifecycle fixtures with spaces")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let launchArgs = ["-applaunch", "1903340", "-windowed"]
        do {
            let c = try context(root, "coalesced"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher)
            defer { broker.shutdown() }
            var results: [Result<SteamClientLifecycleDisposition, Error>] = []
            for _ in 0..<30 { send(broker, c, launchArgs) { expect(Thread.isMainThread, "completion runs on main"); results.append($0) } }
            until("one boot for thirty concurrent demands") { launcher.calls.count == 1 }
            expect(launcher.calls[0].request.arguments == [c.steam.path, "-silent"], "first process boots only Steam, no game command")
            expect(results.isEmpty, "spawn alone is not delivery acknowledgement")
            inspector.set(c, [process(c), process(c, pid: 101, role: .helper)])
            until("one IPC relay after client observation") { launcher.calls.count == 2 }
            expect(launcher.calls[1].request.arguments == [c.steam.path, "-ifrunning"] + launchArgs, "relay targets existing same-prefix Steam")
            var next: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, ["steam://install/526870"]) { next = $0 }
            expect(launcher.calls.count == 2 && results.isEmpty, "distinct command waits while first relay remains alive")
            launcher.calls[1].exit(0)
            until("all duplicate waiters complete exactly once") { results.count == 30 }
            expect(results.allSatisfy { succeeded($0, .forwarded) }, "all coalesced callers share actual relay result")
            until("queued distinct command gets its own relay") { launcher.calls.count == 3 }
            expect(launcher.calls[2].request.arguments == [c.steam.path, "-ifrunning", "steam://install/526870"], "queued install has no second boot")
            launcher.calls[0].exit(0) // old starter callback cannot finish a newer command
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            expect(next == nil, "stale boot exit cannot acknowledge later command")
            launcher.calls[2].exit(0); until("next relay finishes") { next != nil }
            expect(succeeded(next, .forwarded) && launcher.calls.count == 3, "one boot and two intentional transmissions")
        }
        do {
            let c = try context(root, "existing"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(c), process(c, pid: 101, role: .helper)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var a: Result<SteamClientLifecycleDisposition, Error>?, b: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { a = $0 }; until("existing connection reused") { a != nil }
            expect(succeeded(a, .reused) && launcher.calls.isEmpty, "empty connection request never spawns another live Steam client")
            send(broker, c, ["steam://open/games"]) { b = $0 }
            until("explicit opening sends IPC to existing client") { launcher.calls.count == 1 }
            expect(launcher.calls[0].request.arguments == [c.steam.path, "-ifrunning", "steam://open/games"], "explicit opening is not silently swallowed")
            launcher.calls[0].exit(0); until("explicit opening completes") { b != nil }
            expect(succeeded(b, .forwarded), "opening is reported as transmission only")
        }
        for (name, values, expected) in [("orphaned", 1, SteamClientLifecycleError.orphanedHelpers), ("multiple", 2, .multipleClients)] {
            let c = try context(root, name), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, values == 1 ? [process(c, role: .helper, parent: 1)] : [process(c), process(c, pid: 102, birth: 2)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, launchArgs) { result = $0 }; until("diagnostic \(name)") { result != nil }
            expect(failed(result, expected) && launcher.calls.isEmpty, "\(name) cannot trigger another client or kill unrelated processes")
        }
        do {
            let c = try context(root, "pid reuse"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.snapshots = [[process(c, pid: 500, birth: 1)], [process(c, pid: 500, birth: 2)]]
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, launchArgs) { result = $0 }; until("reused PID is rejected") { result != nil }
            expect(failed(result, .clientDisappeared) && launcher.calls.isEmpty, "PID equality cannot authorize delivery to a different birth identity")
        }
        do {
            let a = try context(root, "DX11"), b = try context(root, "DX12"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(a, [process(a)]); inspector.set(b, [process(b, pid: 200)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var count = 0
            send(broker, a, launchArgs, environment: ["DISPLAY_GUARD": "screenA"]) { _ in count += 1 }
            send(broker, b, launchArgs, environment: ["DISPLAY_GUARD": "screenB"]) { _ in count += 1 }
            until("distinct canonical prefixes use independent relays") { launcher.calls.count == 2 }
            expect(Set(launcher.calls.map { $0.request.environment["WINEPREFIX"]! }) == Set([a.key, b.key]), "prefixes never cross")
            launcher.calls[0].exit(0); launcher.calls[1].exit(0); until("both prefixes finish") { count == 2 }
            send(broker, a, launchArgs, environment: ["DISPLAY_GUARD": "screenC"]) { _ in count += 1 }
            until("new explicit same-game intent allowed after prior relay exits") { launcher.calls.count == 3 }
            expect(launcher.calls[2].request.environment["DISPLAY_GUARD"] == "screenC", "fresh screen guard environment is used for every intent")
            launcher.calls[2].exit(0); until("fresh intent completes") { count == 3 }
        }
        do {
            let c = try context(root, "timeout"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(c)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher, deliveryTimeout: 0.05); defer { broker.shutdown() }
            var first: Result<SteamClientLifecycleDisposition, Error>?, duplicate: Result<SteamClientLifecycleDisposition, Error>?, other: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, launchArgs) { first = $0 }; until("relay timeout is bounded") { first != nil }
            send(broker, c, launchArgs) { duplicate = $0 }; send(broker, c, ["steam://install/526870"]) { other = $0 }
            until("uncertain relay rejects duplicate and distinct demands") { duplicate != nil && other != nil }
            expect(failed(first, .deliveryUnconfirmed) && failed(duplicate, .deliveryUnconfirmed) && failed(other, .busy), "timeout cannot claim delivery or reset protection")
            expect(launcher.calls.count == 1, "timeout never spawns a replacement or kills live Steam")
            launcher.calls[0].exit(0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            var retry: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, launchArgs) { retry = $0 }; until("exact relay exit releases new explicit intent") { launcher.calls.count == 2 }
            launcher.calls[1].exit(0); until("explicit retry completes") { retry != nil }
            expect(succeeded(retry, .forwarded), "no permanent lock after timeout and exact exit")
        }
        do {
            let c = try context(root, "startup timeout"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher, startupTimeout: 0.05, pollInterval: 0.01); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?, blocked: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("startup timeout is bounded") { result != nil }
            send(broker, c) { blocked = $0 }; until("unobserved live startup stays protected") { blocked != nil }
            expect(failed(result, .startupUnconfirmed) && launcher.calls.count == 1, "startup timeout does not retry or claim connection")
            launcher.calls[0].exit(1); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            send(broker, c) { _ in }; until("exact starter exit permits explicit new startup") { launcher.calls.count == 2 }
        }
        do {
            let c = try context(root, "leases"), inspector = LifecycleInspector(), one = LifecycleLauncher(), two = LifecycleLauncher()
            let a = SteamClientLifecycle(inspector: inspector, launcher: one), b = SteamClientLifecycle(inspector: inspector, launcher: two)
            defer { a.shutdown(); b.shutdown() }
            send(a, c) { _ in }; until("first app owns startup lease") { one.calls.count == 1 }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(b, c) { result = $0 }; until("second app cannot race startup") { result != nil }
            expect(failed(result, .busy) && two.calls.isEmpty, "OS lease prevents duplicate startup across brokers")
            a.shutdown(); until("observer closes without terminating client") { one.isClosed }
            inspector.set(c, [process(c)])
            result = nil; send(b, c) { result = $0 }; until("new app adopts surviving client") { result != nil }
            expect(succeeded(result, .reused) && two.calls.isEmpty, "shutdown releases lease, preserves client and allows adoption")
        }
        do {
            let c = try context(root, "unavailable"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.failure = true
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, launchArgs) { result = $0 }; until("inspection failure returns") { result != nil }
            expect(failed(result, .observationUnavailable) && launcher.calls.isEmpty, "no unverifiable process startup")
        }
        do {
            let c = try context(root, "boundaries"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(c, uid: geteuid() + 1)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            send(broker, c) { _ in }; until("foreign UID does not masquerade as this user's session") { launcher.calls.count == 1 }
            broker.shutdown(); until("shutdown closes observer") { launcher.isClosed }
        }
        do {
            let c = try context(root, "symlink lock"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let untouched = root.appendingPathComponent("unrelated file")
            try Data("preserve".utf8).write(to: untouched)
            try fm.createSymbolicLink(at: c.prefix.appendingPathComponent(".playmelt-steam-client.lock"), withDestinationURL: untouched)
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("symlink lease rejected") { result != nil }
            expect(failed(result, .busy) && launcher.calls.isEmpty && (try? String(contentsOf: untouched, encoding: .utf8)) == "preserve", "lease cannot overwrite or follow unrelated file")
        }
        do {
            let c = try context(root, "invalid requests"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var results = 0
            for args in [["-shutdown"], ["-login", "never-a-real-account"], ["-applaunch", "../1903340"], ["steam://install/0"], ["steam://install/1903340?x=1"], ["-applaunch", "1903340", "x\0y"]] {
                send(broker, c, args) { expect(failed($0, .invalidRequest), "invalid command is refused"); results += 1 }
            }
            until("all invalid commands return") { results == 6 }
            expect(launcher.calls.isEmpty, "invalid commands never reach Wine")
        }
        do {
            let c = try context(root, "late startup"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher, startupTimeout: 0.05, pollInterval: 0.01); defer { broker.shutdown() }
            var first: Result<SteamClientLifecycleDisposition, Error>?, next: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { first = $0 }; until("slow client times out without retry") { first != nil }
            inspector.set(c, [process(c)])
            send(broker, c) { next = $0 }; until("new explicit action can adopt late client") { next != nil }
            expect(succeeded(next, .reused) && launcher.calls.count == 1, "late success cannot become a permanent barrier or another boot")
        }
        do {
            let c = try context(root, "client disappears"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(c)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c, launchArgs) { result = $0 }; until("delivery relay created") { launcher.calls.count == 1 }
            inspector.set(c, [process(c, role: .helper)])
            launcher.calls[0].exit(0); until("client disappearance is detected even after relay exit zero") { result != nil }
            expect(failed(result, .clientDisappeared), "relay zero alone cannot confirm delivery to a living client")
        }
        do {
            let c = try context(root, "real helper layouts"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            for target in ["drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe"] {
                let helper = SteamClientObservedProcess(identity: .init(pid: 700, uid: geteuid(), birthSeconds: 1, birthMicroseconds: 0, executable: c.wine.path), parentPID: 1, prefix: c.key, target: c.prefix.appendingPathComponent(target).path, role: .helper)
                inspector.set(c, [helper])
                let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher)
                var result: Result<SteamClientLifecycleDisposition, Error>?
                send(broker, c, launchArgs) { result = $0 }; until("real helper layout blocks duplicate startup") { result != nil }
                expect(failed(result, .orphanedHelpers) && launcher.calls.isEmpty, "orphaned cef.win64 is retained and reported")
                broker.shutdown()
            }
        }
        for count in [1, 2] {
            let c = try context(root, "persistent services \(count)"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let services = (0..<count).map { process(c, pid: pid_t(800 + $0), role: .service) }
            inspector.set(c, services)
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("service-only inventory permits exactly one client boot") { launcher.calls.count == 1 }
            inspector.set(c, services + [process(c)])
            until("client becomes observable beside persistent services") { result != nil }
            expect(succeeded(result, .started) && launcher.calls.count == 1, "\(count) services are not counted as clients and remain untouched")
        }
        do {
            let c = try context(root, "service and CEF"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(c, pid: 800, role: .service), process(c, pid: 801, role: .helper)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("service does not conceal orphaned CEF") { result != nil }
            expect(failed(result, .orphanedHelpers) && launcher.calls.isEmpty, "service plus orphaned CEF still cannot boot another client")
        }
        do {
            let c = try context(root, "service and client"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(c, pid: 800, role: .service), process(c)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("service plus client can be adopted") { result != nil }
            expect(succeeded(result, .reused) && launcher.calls.isEmpty, "existing client is reused without restarting its service")
        }
        do {
            let c = try context(root, "service prefix boundary"), other = try context(root, "unrelated service prefix")
            let inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            inspector.set(c, [process(other, pid: 800, role: .service)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("foreign-prefix service does not suppress selected prefix startup") { launcher.calls.count == 1 }
            expect(launcher.calls[0].request.environment["WINEPREFIX"] == c.key && launcher.calls[0].request.arguments == [c.steam.path], "foreign service never changes the target prefix/executable")
            inspector.set(c, [process(c), process(other, pid: 800, role: .service)])
            until("selected client becomes ready independently") { result != nil }
            expect(succeeded(result, .started), "foreign service neither proves a client nor creates a multiple-client error")
        }
        do {
            let c = try context(root, "service during uncertain startup"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher, startupTimeout: 0.05, pollInterval: 0.01); defer { broker.shutdown() }
            var first: Result<SteamClientLifecycleDisposition, Error>?, next: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { first = $0 }; until("starter remains protected after timeout") { first != nil }
            inspector.set(c, [process(c, pid: 800, role: .service)])
            send(broker, c) { next = $0 }; until("service is not an orphaned CEF during uncertain startup") { next != nil }
            expect(failed(next, .deliveryUnconfirmed) && launcher.calls.count == 1, "persistent service does not erase live-starter duplicate protection")
            launcher.calls[0].exit(1); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            send(broker, c) { _ in }; until("explicit next intent can boot beside service after exact starter exit") { launcher.calls.count == 2 }
        }
        do {
            let c = try context(root, "wrapper client"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let wrapper = c.wine.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PlaymeltGame.app/Contents/MacOS/wine")
            inspector.set(c, [process(c, executable: wrapper)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var opened: Result<SteamClientLifecycleDisposition, Error>?, command: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { opened = $0 }; until("same-runtime wrapper client can be adopted") { opened != nil }
            expect(succeeded(opened, .reused) && launcher.calls.isEmpty, "wrapper client reuse has zero boots")
            send(broker, c, launchArgs) { command = $0 }; until("wrapper client receives an IPC relay") { launcher.calls.count == 1 }
            expect(launcher.calls[0].request.arguments == [c.steam.path, "-ifrunning"] + launchArgs, "wrapper recognition never boots another Steam client for a game")
            launcher.calls[0].exit(0); until("wrapper IPC result confirmed") { command != nil }
            expect(succeeded(command, .forwarded), "wrapper client birth identity retained through relay acknowledgement")
            expect(!fm.fileExists(atPath: wrapper.path), "loader location discovery never creates a wrapper")
        }
        do {
            let c = try context(root, "wrapper CEF"), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
            let wrapper = c.wine.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PlaymeltGame.app/Contents/MacOS/wine64-preloader")
            inspector.set(c, [process(c, role: .helper, executable: wrapper)])
            let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
            var result: Result<SteamClientLifecycleDisposition, Error>?
            send(broker, c) { result = $0 }; until("wrapper orphaned CEF is observed") { result != nil }
            expect(failed(result, .orphanedHelpers) && launcher.calls.isEmpty, "wrapper CEF cannot be ignored to spawn a duplicate client")
        }
        do {
            let c = try context(root, "foreign wrappers")
            for foreign in ["other-runtime/PlaymeltGame.app/Contents/MacOS/wine", "different-vendor/engine/bin/wine64"] {
                let executable = root.appendingPathComponent(foreign), inspector = LifecycleInspector(), launcher = LifecycleLauncher()
                inspector.set(c, [process(c, executable: executable)])
                let broker = SteamClientLifecycle(inspector: inspector, launcher: launcher); defer { broker.shutdown() }
                var result: Result<SteamClientLifecycleDisposition, Error>?
                send(broker, c, launchArgs) { result = $0 }; until("foreign loader is not adopted or ignored to boot again") { result != nil }
                expect(failed(result, .observationUnavailable) && launcher.calls.isEmpty, "same-prefix Steam from another runtime/vendor fails closed without IPC or boot")
                expect(DarwinSteamClientProcessInspector.candidateExecutable(executable.path, context: c), "Darwin reads exact Wine basename before classifying its prefix")
                var rejected = false
                do { _ = try DarwinSteamClientProcessInspector.classify(executable: executable.path, arguments: ["C:\\Program Files (x86)\\Steam\\steam.exe"], prefix: c.key, uid: geteuid(), context: c) }
                catch SteamClientLifecycleError.observationUnavailable { rejected = true }
                expect(rejected, "Darwin classifier rejects foreign Wine only after exact UID/prefix/Steam target match")
                let other = try DarwinSteamClientProcessInspector.classify(executable: executable.path, arguments: [c.steam.path], prefix: root.appendingPathComponent("another-prefix").path, uid: geteuid(), context: c)
                expect(other == nil, "other-prefix Wine is neither adopted nor blocked by this Steam request")
                let foreignUID = try DarwinSteamClientProcessInspector.classify(executable: executable.path, arguments: [c.steam.path], prefix: c.key, uid: geteuid() + 1, context: c)
                expect(foreignUID == nil, "another UID cannot establish this user's Steam identity")
            }
            expect(!DarwinSteamClientProcessInspector.candidateExecutable(root.appendingPathComponent("Private.app/Contents/MacOS/PrivateProgram").path, context: c), "unrelated non-Wine program is not an argv/environment candidate")
            let own = c.wine.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PlaymeltGame.app/Contents/MacOS/wine")
            let classified = try DarwinSteamClientProcessInspector.classify(executable: own.path, arguments: ["C:\\Program Files (x86)\\Steam\\steam.exe"], prefix: c.key, uid: geteuid(), context: c)
            expect(classified?.role == .client, "Darwin pure classification accepts exact same-root wrapper and PE")
            let wrongPE = try DarwinSteamClientProcessInspector.classify(executable: own.path, arguments: ["C:\\Games\\NotSteam.exe"], prefix: c.key, uid: geteuid(), context: c)
            expect(wrongPE == nil, "same-root Wine alone does not prove a Steam client")
        }
        do {
            var data = withUnsafeBytes(of: Int32(2)) { Data($0) }
            data.append(Data("/loader\0\0/loader\0C:\\Program Files (x86)\\Steam\\steam.exe\0WINEPREFIX=/a prefix\0SECRET=not-returned\0".utf8))
            let parsed = DarwinSteamClientProcessInspector.parseArguments(data)
            expect(parsed?.arguments.count == 2 && parsed?.prefix == "/a prefix", "bounded procargs decoder retains only argv and prefix")
            data.append(Data("WINEPREFIX=/ambiguous\0".utf8))
            expect(DarwinSteamClientProcessInspector.parseArguments(data) == nil, "ambiguous duplicate prefix is refused")
        }
        print("SteamClientLifecycleTests: \(checks) checks PASS; inert doubles only, no Wine/Steam/game/keychain/network")
    }
}
