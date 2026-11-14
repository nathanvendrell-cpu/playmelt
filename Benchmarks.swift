import AppKit

/// Private session samples. Never launches, terminates or changes a game.
final class Benchmarks {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Benchmarks", isDirectory:true)
    private let queue = DispatchQueue(label:"playmelt.benchmarks",qos:.utility)
    private let group = DispatchGroup()
    private var active: OwnedOperationToken?
    private var activeDirectory:URL?
    var onChange: (() -> Void)?
    var isRunning:Bool {active != nil}
    var enabled: Bool { UserDefaults.standard.object(forKey:"automaticBenchmarks") as? Bool ?? true }
    func setEnabled(_ value:Bool) { UserDefaults.standard.set(value,forKey:"automaticBenchmarks"); if !value { active?.cancel() };onChange?() }
    func snapshot() -> [String:Any] {
        let directories = ((try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []).sorted {$0.lastPathComponent > $1.lastPathComponent}.prefix(30)
        let rows = directories.compactMap { directory -> [String:Any]? in
            guard let data=try? Data(contentsOf:directory.appendingPathComponent("metadata.json")), data.count<100_000,
                  var metadata=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return nil }
            if let data=try? Data(contentsOf:directory.appendingPathComponent("result.json")), data.count<200_000,
               let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] { metadata["result"]=result }
            else { metadata["result"]=["status":"inconclusive","reason":activeDirectory == directory ? "collecting" : "interrupted"] }
            return metadata
        }
        return ["enabled":enabled,"running":active != nil,"sessions":rows,"available":FileManager.default.isExecutableFile(atPath:"/usr/bin/metalperftrace")]
    }
    func start(game:Game, session:String, settings:[String:Any], hardware:[String:Any]) {
        guard enabled, active == nil, let folder=game.path,
              let script=PortablePythonRuntime.resource(named:"session_benchmark.py"),
              let python=PortablePythonRuntime.resolve(),
              FileManager.default.isExecutableFile(atPath:"/usr/bin/metalperftrace") else { return }
        let windows=folder.appendingPathComponent("Windows")
        let target=FileManager.default.fileExists(atPath:windows.path) ? windows : folder
        guard let files=try? FileManager.default.subpathsOfDirectory(atPath:target.path),let relative=LocalGameManifest.read(folder)?.executable ?? localGameExecutable(appID:game.appId,files:files) else {return}
        let id=String(format:"%.0f",Date().timeIntervalSince1970)+"-"+UUID().uuidString
        let directory=root.appendingPathComponent(id,isDirectory:true)
        var safeSettings=settings["settings"] as? [String:Any] ?? [:]; safeSettings.removeValue(forKey:"launchArgs")
        let safeHardware=hardware.filter { ["chip","memoryGB","cpuCores","gpuName","thermalState","lowPowerMode"].contains($0.key) }
        let metadata:[String:Any]=["id":id,"gameId":game.id,"title":game.title,"createdAt":Date().timeIntervalSince1970,"machine":safeHardware,"settings":safeSettings,"settingsOrigin":settings["settingsOrigin"] as? String ?? "unknown","macOS":ProcessInfo.processInfo.operatingSystemVersionString,"scope":"private-session-sample","store":game.store]
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]).write(to:directory.appendingPathComponent("metadata.json"),options:.atomic)
        } catch {return}
        let token=OwnedOperationToken();active=token;activeDirectory=directory;group.enter();onChange?()
        queue.async { [weak self] in
            guard let self else {return}
            var request=OwnedProcessRequest(executable:python.pythonURL,arguments:["-B",script.path,"--session",session,"--executable",target.appendingPathComponent(relative).path,"--output",directory.path],environment:python.environment(merging:ProcessInfo.processInfo.environment))
            request.timeout=180;request.outputLimit=4096;request.terminationGracePeriod=7
            _ = try? OwnedProcessRunner().run(request,cancelled:{token.isCancelled})
            DispatchQueue.main.async { self.active=nil;self.activeDirectory=nil;self.onChange?();self.group.leave() }
        }
    }
    func stop() { active?.cancel() }
    func shutdown(_ completion:@escaping()->Void) { stop();group.notify(queue:.main,execute:completion) }
}
