import Foundation
import Security
import Darwin

private final class OperationKeychain: EpicKeychainAccess {
    var updateStatus = errSecMissingEntitlement, copyStatus = errSecItemNotFound
    var writes = 0
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) { (copyStatus, nil) }
    func add(_ attributes: [String: Any]) -> OSStatus { writes += 1; return updateStatus }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { writes += 1; return updateStatus }
    func delete(_ query: [String: Any]) -> OSStatus { errSecSuccess }
}
private final class OperationRunner: OwnedProcessRunning {
    private let lock = NSLock()
    var handler: (([String: Any], () -> Bool) throws -> [String: Any])!
    private var requests: [OwnedProcessRequest] = []
    var calls: [OwnedProcessRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool, onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        lock.lock(); requests.append(request); lock.unlock()
        let value = try JSONSerialization.jsonObject(with: request.input) as! [String: Any]
        return .init(output: try JSONSerialization.data(withJSONObject: handler(value, cancelled)), exitCode: 0, pid: 0, handedOff: false)
    }
}
@main enum EpicOperationTests {
    static var checks = 0
    static let session: [String: Any] = ["account_id": "fixture-account", "displayName": "Fixture", "access_token": "fixture-access", "refresh_token": "fixture-refresh"]
    static func check(_ value: Bool, _ label: String) { checks += 1; if !value { fatalError("FAIL: " + label) } }
    static func wait(_ value: () -> Bool) { let end = Date().addingTimeInterval(4); while !value() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }; check(value(), "bounded completion") }
    static func rejects(_ label: String, _ body: () throws -> Void) { do { try body(); check(false, label) } catch { check(true, label) } }
    static func main() throws {
        let fm = FileManager.default
        let fixtureParent = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.temporaryDirectory
        let root = fixtureParent.appendingPathComponent("playmelt-epic-native-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent(".epic_session.dat"), bytes = try EpicSessionEnvelope.encode(session)
        try bytes.write(to: legacy); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path)
        let before = try fm.attributesOfItem(atPath: legacy.path)[.systemFileNumber] as! NSNumber
        let keychain = OperationKeychain(), migrated = EpicKeychainSessionStore(access: keychain, legacyFileURL: legacy)
        check(try migrated.load()?["account_id"] as? String == "fixture-account", "legacy can resume without a Keychain entitlement")
        check(migrated.persistenceKind == "memory" && !migrated.restorationNotice.isEmpty, "failed migration explicitly reports memory")
        check(try Data(contentsOf: legacy) == bytes && fm.attributesOfItem(atPath: legacy.path)[.systemFileNumber] as! NSNumber == before, "legacy credential bytes and inode preserved")
        keychain.updateStatus = errSecSuccess
        check(try migrated.load()?["account_id"] as? String == "fixture-account" && migrated.persistenceKind == "keychain", "valid legacy migrates through exact Keychain transport")
        try migrated.clear(); check(try Data(contentsOf: legacy) == bytes, "disconnect never deletes legacy credential")
        check(try migrated.load() == nil, "explicit disconnect does not resurrect legacy next time")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.path)
        let unsafe = EpicKeychainSessionStore(access: OperationKeychain(), legacyFileURL: legacy)
        // Use a distinct path without the explicit-disconnect marker.
        let unsafeFile = root.appendingPathComponent("unsafe/session.dat"); try fm.createDirectory(at: unsafeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: unsafeFile); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unsafeFile.path)
        rejects("readable-by-others legacy refused") { _ = try EpicKeychainSessionStore(access: OperationKeychain(), legacyFileURL: unsafeFile).load() }; _ = unsafe

        let worker = root.appendingPathComponent("worker.py"); try Data("# mock only".utf8).write(to: worker)
        let game = root.appendingPathComponent("game"); try fm.createDirectory(at: game, withIntermediateDirectories: false)
        let exe = game.appendingPathComponent("game.exe"); try Data("fixture".utf8).write(to: exe)
        let runner = OperationRunner()
        runner.handler = { value, cancelled in
            if cancelled() { throw OwnedProcessError.cancelled }
            switch value["action"] as? String {
            case "authenticate", "sync": return ["ok": true, "session": session, "snapshot": ["accountId": "fixture-account", "displayName": "Fixture", "games": [["appName": "factory"]], "installed": [], "source": "fixture", "updatedAt": "fixture"]]
            case "install": return ["ok": true, "session": session, "installation": ["accountId": "fixture-account", "appName": "factory", "platform": "Windows", "title": "Factory", "installPath": game.path, "executable": "game.exe", "filesVerified": true]]
            default: return ["ok": true, "session": session, "launch": ["accountId": "fixture-account", "appName": "factory", "executablePath": exe.path, "workingDirectory": game.path, "arguments": ["-AUTH_PASSWORD=one-use-fixture", "-epicusername=O'Brian $(touch " + root.appendingPathComponent("injection-ran").path + ")", "-epicovt=__PLAYMELT_PRIVATE_OWNERSHIP_TOKEN__"], "ownershipToken": Data("fixture-ownership".utf8).base64EncodedString()]]
            }
        }
        let connector = EpicConnector(projectRoot: root, pythonURL: URL(fileURLWithPath: "/usr/bin/true"), workerURL: worker, runner: runner, sessionStore: EpicMemorySessionStore())
        var done = false
        connector.authenticate(code: "fixture-code") { value in check((try? value.get()) != nil, "fresh authentication admitted"); done = true }; wait { done }
        done = false
        connector.install(appName: "factory", platform: "Windows", libraryAccountID: "fixture-account") { value in check((try? value.get())?.directory.path == game.path, "fresh session install admitted"); done = true }; wait { done }
        let installRequest = runner.calls.last!, input = try JSONSerialization.jsonObject(with: installRequest.input) as! [String: Any]
        check((input["session"] as? [String: Any])?["access_token"] as? String == "fixture-access", "fresh credential goes through stdin only")
        check(!installRequest.arguments.joined().contains("fixture-access") && !installRequest.environment.values.contains("fixture-access") && installRequest.environment["LEGENDARY_CONFIG_PATH"] == nil, "worker argv/environment contain no credentials/global profile")
        let count = runner.calls.count; done = false
        connector.install(appName: "factory", platform: "Windows", libraryAccountID: "different-account") { value in check((try? value.get()) == nil, "wrong account refused"); done = true }; wait { done }
        check(runner.calls.count == count, "wrong account cannot start download worker")
        done = false; connector.install(appName: "not-owned", platform: "Windows", libraryAccountID: "fixture-account") { value in check((try? value.get()) == nil, "unknown game refused"); done = true }; wait { done }
        check(runner.calls.count == count, "unknown game cannot start worker")
        var authorization: EpicLaunchAuthorization?; done = false
        connector.authorizeLaunch(appName: "factory", platform: "Windows", directory: game, libraryAccountID: "fixture-account") { value in authorization = try? value.get(); done = true }; wait { done }
        check(authorization != nil && !String(describing: authorization!).contains("one-use-fixture"), "launch owner has redacted description")
        var ownershipFile: URL?
        try authorization!.consume { parameters in
            check(parameters.arguments.contains("-AUTH_PASSWORD=one-use-fixture"), "one-use code reserved for exact game dispatch")
            check(!String(reflecting: parameters).contains("one-use-fixture"), "parameter debug output redacted")
            ownershipFile = URL(fileURLWithPath: parameters.arguments.first { $0.hasPrefix("-epicovt=") }!.dropFirst(9).description)
        }
        check(fm.fileExists(atPath: ownershipFile!.path), "ownership token retained for game lifetime")
        rejects("authorization cannot be consumed twice") { try authorization!.consume { _ in } }
        authorization!.close(); check(!fm.fileExists(atPath: ownershipFile!.path), "exact temporary ownership token removed")
        func freshAuthorization() -> EpicLaunchAuthorization {
            var value: EpicLaunchAuthorization?; var ready = false
            connector.authorizeLaunch(appName: "factory", platform: "Windows", directory: game, libraryAccountID: "fixture-account") { result in value = try? result.get(); ready = true }; wait { ready }
            return value!
        }
        let runtime = root.appendingPathComponent("Runtime"), engine = runtime.appendingPathComponent("playmelt-wine10-dxmt-20261017/engine/bin")
        try fm.createDirectory(at: engine, withIntermediateDirectories: true)
        let childArguments = root.appendingPathComponent("exact-child-arguments"), legacyRan = root.appendingPathComponent("old-profile-touched"), environmentRan = root.appendingPathComponent("bash-env-ran")
        let fakeWine = engine.appendingPathComponent("wine")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" >'\(childArguments.path)'\nprintf 'fixture-exchange-output\\n' >&2\n".utf8).write(to: fakeWine)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeWine.path)
        let bashEnvironment = root.appendingPathComponent("untrusted-bash-env")
        try Data("printf bad >'\(environmentRan.path)'\n".utf8).write(to: bashEnvironment)
        let qualityStub = runtime.appendingPathComponent("game_display_quality.py")
        try Data("print('1 1 0 0')\n".utf8).write(to: qualityStub)
        let oldAuth = "EPIC_PARAMS=()\nLEGENDARY_BIN='old'\nprintf old >'\(legacyRan.path)'"
        let template = """
        #!/bin/bash
        # Playmelt display guard v1
        set -eo pipefail
        GAME_DIR='\(game.path)'
        RUNTIME_DIR='\(runtime.path)'
        export WINEDLLOVERRIDES="d3d12=n,b;winemenubuilder.exe=d"
        cd "$GAME_DIR"
        QUALITY_COORDINATES=$(/usr/bin/env -u PYTHONHOME -u PYTHONPATH -u PYTHONUSERBASE PYTHONNOUSERSITE=1 '/usr/bin/python3' -B '\(qualityStub.path)' --prepare 'fixture-app')
        read -r PLAYMELT_GAME_WIDTH PLAYMELT_GAME_HEIGHT PLAYMELT_GAME_X PLAYMELT_GAME_Y <<< "$QUALITY_COORDINATES"
        \(oldAuth)
        mkdir -p "$RUNTIME_DIR/logs"
        exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" 'old.exe' '-dx12' "${EPIC_PARAMS[@]}" "$@" 2>&1 | /usr/bin/tail -c 1048576 >"$RUNTIME_DIR/logs/game-factory.log"

        """
        let persisted = root.appendingPathComponent("existing-launch.command"); try Data(template.utf8).write(to: persisted)
        let scriptAuth = freshAuthorization(); var childDone = false
        try scriptAuth.launchWithScript(template, legacyAuthBlock: oldAuth, scriptExecutable: "old.exe", additionalArguments: ["--fixture"], environment: ["PATH": "/usr/bin:/bin", "BASH_ENV": bashEnvironment.path, "SHELLOPTS": "xtrace"], directory: game) { code in check(code == 0, "recognized renderer script exits normally"); childDone = true }
        wait { childDone && EpicLaunchAuthorization.activeLaunchCount == 0 }
        let childText = try String(contentsOf: childArguments, encoding: .utf8)
        check(childText.contains(exe.path) && childText.contains("-dx12") && childText.contains("-AUTH_PASSWORD=one-use-fixture"), "exact child receives fresh code and existing renderer arguments")
        check(childText.contains("O'Brian $(touch ") && !fm.fileExists(atPath: root.appendingPathComponent("injection-ran").path), "exchanged strings are literal quoted arguments without eval")
        check(!fm.fileExists(atPath: legacyRan.path) && !fm.fileExists(atPath: environmentRan.path), "old global path and inherited xtrace hook never execute")
        check(!fm.fileExists(atPath: runtime.appendingPathComponent("logs/game-factory.log").path), "game output cannot become an app diagnostic log")
        check(try Data(contentsOf: persisted) == Data(template.utf8), "original launcher bytes never contain exchange code and stay unchanged")
        for extra in ["\necho \"${EPIC_PARAMS[@]}\" >'/tmp/never-created'", "\nset -x", "\ntrap 'echo hidden' DEBUG", "\neval hidden"] {
            let rejected = freshAuthorization()
            rejects("unknown launcher output/trace/eval is refused") { try rejected.launchWithScript(template + extra, legacyAuthBlock: oldAuth, scriptExecutable: "old.exe", additionalArguments: [], environment: [:], directory: game, onExit: { _ in }) }
            rejected.close()
        }
        // Core's local manifest can choose an absolute executable while another
        // valid-looking EXE remains in the same folder. The handoff must agree
        // with that exact template target in both supported Wine locations.
        let alternate = game.appendingPathComponent("alternate-launcher.exe")
        try Data("inert alternate, never executed".utf8).write(to: alternate)
        let outside = root.appendingPathComponent("outside-approved-game.exe")
        try Data("inert outside target, never executed".utf8).write(to: outside)
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var absoluteFixturePIDs: [pid_t] = []
        for location in ["engine/bin/wine", "PlaymeltGame.app/Contents/MacOS/wine"] {
            let label = location.hasPrefix("engine/") ? "engine" : "bundle"
            let inertWine = runtime.appendingPathComponent("playmelt-wine10-dxmt-20261017/" + location)
            try fm.createDirectory(at: inertWine.deletingLastPathComponent(), withIntermediateDirectories: true)
            let argumentsFile = root.appendingPathComponent("absolute-\(label)-arguments"), pidFile = root.appendingPathComponent("absolute-\(label)-pid")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" >\(shellQuote(pidFile.path))\nprintf '%s\\n' \"$@\" >\(shellQuote(argumentsFile.path))\n".utf8).write(to: inertWine)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inertWine.path)
            let absoluteTemplate = template
                .replacingOccurrences(of: "/engine/bin/wine\" ", with: "/\(location)\" ")
                .replacingOccurrences(of: "'old.exe'", with: shellQuote(exe.path))
            let sourceFile = root.appendingPathComponent("absolute-\(label)-original.command")
            try Data(absoluteTemplate.utf8).write(to: sourceFile)
            let sourceBefore = try Data(contentsOf: sourceFile)
            check(fm.fileExists(atPath: exe.path) && fm.fileExists(atPath: alternate.path), "absolute-target fixture contains two candidate EXEs")
            let exact = freshAuthorization(); var finished = false
            try exact.launchWithScript(absoluteTemplate, legacyAuthBlock: oldAuth, scriptExecutable: exe.path,
                additionalArguments: ["--absolute-fixture", "literal argument with spaces"],
                environment: ["PATH": "/usr/bin:/bin", "BASH_ENV": bashEnvironment.path, "SHELLOPTS": "xtrace", "LEGENDARY_CONFIG_PATH": root.appendingPathComponent("never-global-profile").path], directory: game) { code in
                    check(code == 0, "absolute target admitted for \(label) inert loader"); finished = true
                }
            wait { finished && EpicLaunchAuthorization.activeLaunchCount == 0 }
            let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
            let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            absoluteFixturePIDs.append(pid)
            check(arguments.first == exe.path && !arguments.contains(alternate.path), "\(label) executes authorized absolute A, never adjacent B")
            check(arguments.contains("-dx12") && arguments.contains("--absolute-fixture") && arguments.contains("literal argument with spaces"), "\(label) preserves renderer and literal caller arguments")
            check(arguments.filter { $0 == "-AUTH_PASSWORD=one-use-fixture" }.count == 1, "\(label) receives exactly one private exchange parameter")
            let username = arguments.first { $0.hasPrefix("-epicusername=") } ?? ""
            check(username.contains("O'Brian $(touch ") && !fm.fileExists(atPath: root.appendingPathComponent("injection-ran").path), "\(label) keeps exchanged strings literal without shell expansion")
            let ovt = arguments.first { $0.hasPrefix("-epicovt=") }.map { String($0.dropFirst(9)) }
            check(ovt != nil && !fm.fileExists(atPath: ovt!), "\(label) private ownership artifact removed after exact child exit")
            check(kill(pid, 0) == -1 && errno == ESRCH, "\(label) fixture process exited and was reaped")
            check(!fm.fileExists(atPath: legacyRan.path) && !fm.fileExists(atPath: environmentRan.path), "\(label) cannot execute legacy profile or inherited BASH_ENV")
            check(!fm.fileExists(atPath: runtime.appendingPathComponent("logs/game-factory.log").path), "\(label) private game output is never an app log")
            check(try Data(contentsOf: sourceFile) == sourceBefore, "\(label) persisted template never gains exchange parameters")
            let capturedBefore = try Data(contentsOf: argumentsFile), pidBefore = try Data(contentsOf: pidFile)
            for wrongTarget in [alternate.path, outside.path] {
                let rejected = freshAuthorization()
                rejects("\(label) template A refuses a different absolute caller target") {
                    try rejected.launchWithScript(absoluteTemplate, legacyAuthBlock: oldAuth, scriptExecutable: wrongTarget, additionalArguments: [], environment: ["PATH": "/usr/bin:/bin"], directory: game, onExit: { _ in check(false, "rejected target must not execute") })
                }
                rejected.close()
                let unchangedArguments = try Data(contentsOf: argumentsFile), unchangedPID = try Data(contentsOf: pidFile)
                check(EpicLaunchAuthorization.activeLaunchCount == 0 && unchangedArguments == capturedBefore && unchangedPID == pidBefore, "\(label) rejected B/outside target starts no process and changes no child receipt")
            }
            let cannotOverride = freshAuthorization()
            rejects("\(label) caller cannot override private exchange") {
                try cannotOverride.launchWithScript(absoluteTemplate, legacyAuthBlock: oldAuth, scriptExecutable: exe.path, additionalArguments: ["-AUTH_PASSWORD=caller-override"], environment: [:], directory: game, onExit: { _ in check(false, "private override must not execute") })
            }
            cannotOverride.close()
            let afterOverride = try Data(contentsOf: argumentsFile)
            check(EpicLaunchAuthorization.activeLaunchCount == 0 && afterOverride == capturedBefore, "\(label) private override creates no child")
        }
        // This separately tests the authorization's root boundary, rather than
        // relying only on a template/caller string mismatch for an outside EXE.
        let originalHandler = runner.handler!
        runner.handler = { value, cancelled in
            var response = try originalHandler(value, cancelled)
            if var launch = response["launch"] as? [String: Any] { launch["executablePath"] = outside.path; response["launch"] = launch }
            return response
        }
        var outsideAuthorization: EpicLaunchAuthorization?; done = false
        connector.authorizeLaunch(appName: "factory", platform: "Windows", directory: game, libraryAccountID: "fixture-account") { result in
            outsideAuthorization = try? result.get(); done = true
        }
        wait { done }
        check(outsideAuthorization == nil && EpicLaunchAuthorization.activeLaunchCount == 0, "worker target outside authorized game root is refused before any script execution")
        runner.handler = originalHandler
        runner.handler = { value, cancelled in while !cancelled() { Thread.sleep(forTimeInterval: 0.005) }; throw OwnedProcessError.cancelled }
        done = false
        connector.install(appName: "factory", platform: "Windows", libraryAccountID: "fixture-account") { value in check((try? value.get()) == nil, "cancelled result cannot be ready"); done = true }
        wait { runner.calls.count > count + 1 }; connector.cancelOperation(); wait { done }
        done = false; connector.shutdown { done = true }; wait { done }

        // Real supervised fixture with a child, private stdin and structured SIGTERM cleanup.
        let pidFile = root.appendingPathComponent("fixture-pids.json"), cleanup = root.appendingPathComponent("fixture-cleaned")
        let script = root.appendingPathComponent("cancel-worker.py")
        try Data("""
        import json,sys,subprocess,signal,os
        json.load(sys.stdin)
        child=subprocess.Popen(['/bin/sleep','20'])
        def stop(signum,frame):raise SystemExit(128+signum)
        signal.signal(signal.SIGTERM,stop)
        open(\(String(reflecting: pidFile.path)),'w').write(json.dumps([os.getpid(),child.pid]))
        try:child.wait()
        finally:
         child.terminate();child.wait(timeout=2)
         open(\(String(reflecting: cleanup.path)),'w').write('cleaned')
        """.utf8).write(to: script)
        var request = OwnedProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-B", script.path], environment: ["PATH": "/usr/bin:/bin"])
        request.input = try JSONSerialization.data(withJSONObject: session); request.timeout = 5; request.terminationGracePeriod = 1
        rejects("real process group cancellation") { _ = try OwnedProcessRunner().run(request, cancelled: { fm.fileExists(atPath: pidFile.path) }) }
        let pids = try JSONSerialization.jsonObject(with: Data(contentsOf: pidFile)) as! [Int32]
        wait { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        check(fm.fileExists(atPath: cleanup.path), "cancelled worker finally completed and child reaped")
        print("Fixture process IDs reaped: " + (absoluteFixturePIDs + pids).map(String.init).joined(separator: ","))
        print("Epic operation boundaries: \(checks) PASS; fixtures only, no real account, Keychain or network; owned process group exited.")
    }
}
