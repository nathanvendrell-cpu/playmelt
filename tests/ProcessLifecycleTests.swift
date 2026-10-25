import Foundation
import Darwin

private final class FixtureProcessRunner: OwnedProcessRunning {
    let lock=NSLock()
    var calls:[OwnedProcessRequest]=[]
    var handler:((OwnedProcessRequest,()->Bool,()->Bool)throws->OwnedProcessResult)?
    func requests()->[OwnedProcessRequest]{lock.lock();defer{lock.unlock()};return calls}
    func run(_ request:OwnedProcessRequest,cancelled:()->Bool,handoff:()->Bool,onDetachedExit:@escaping(Int32)->Void)throws->OwnedProcessResult{
        lock.lock();calls.append(request);let handler=self.handler;lock.unlock()
        return try handler?(request,cancelled,handoff) ?? .init(output:Data(),exitCode:0,pid:0,handedOff:false)
    }
}
private final class NoNetworkProtocol: URLProtocol {
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){} // Deliberately pending until the fixture cancels.
    override func stopLoading(){}
}

@main enum ProcessLifecycleTests {
    static let fm=FileManager.default
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fatalError("FAIL: "+label)}}
    static func rejects(_ label:String,_ block:()throws->Void){checks+=1;do{try block();fatalError("FAIL accepted: "+label)}catch{}}
    static func put(_ data:Data,_ path:URL)throws{try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:path)}
    static func until(_ done:()->Bool){let end=Date().addingTimeInterval(3);while !done() && Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};expect(done(),"bounded async completion")}
    static func gone(_ pid:pid_t)->Bool{kill(pid,0) == -1 && errno == ESRCH}
    static func request(_ script:String,_ args:[String]=[])->OwnedProcessRequest{
        var request=OwnedProcessRequest(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c",script,"fixture"]+args,environment:["PATH":"/usr/bin:/bin"])
        request.timeout=1;return request
    }
    static func fixtureDescriptor(_ root:URL)throws->PlaymeltRuntimeDescriptor{
        let prefix=root.appendingPathComponent("Runtime/prefix"),engine=root.appendingPathComponent("engine")
        try fm.createDirectory(at:prefix,withIntermediateDirectories:true)
        try put(try JSONSerialization.data(withJSONObject:["prefix":prefix.path,"engineID":"fixture-engine"]),prefix.deletingLastPathComponent().appendingPathComponent("prefix-owner.json"))
        return .init(engineID:"fixture-engine",wineURL:engine.appendingPathComponent("bin/wine"),wineserverURL:engine.appendingPathComponent("bin/wineserver"),prefixURL:prefix,steamRoot:prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam"),environment:["WINEPREFIX":prefix.path,"PATH":"/usr/bin:/bin"],readyEngine:true,steamInstalled:false)
    }
    static func main()throws{
        let temp=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/process-lifecycle-tests-"+UUID().uuidString)
        try fm.createDirectory(at:temp,withIntermediateDirectories:false);defer{try?fm.removeItem(at:temp)}
        let runner=OwnedProcessRunner()
        var q=request("printf out; printf err >&2; exit 7")
        let result=try runner.run(q,cancelled:{false})
        expect(result.exitCode==7 && String(decoding:result.output,as:UTF8.self)=="outerr","nonzero exit and bounded stderr preserved")
        expect(gone(result.pid),"normal leader reaped")
        q=OwnedProcessRequest(executable:URL(fileURLWithPath:"/bin/cat"),arguments:[],environment:["PATH":"/usr/bin:/bin"])
        q.input=Data(repeating:65,count:1024*1024);q.outputLimit=q.input.count;q.timeout=1
        let echo=try runner.run(q,cancelled:{false})
        expect(echo.output==q.input,"nonblocking stdin and stdout handle pipe-capacity backpressure")
        expect(gone(echo.pid),"duplex child reaped")
        q=request("exit 0");q.input=Data(repeating:66,count:1024*1024)
        rejects("closed stdin does not SIGPIPE the hub"){_=try runner.run(q,cancelled:{false})}
        let blockedPID=temp.appendingPathComponent("blocked.pid"),helperPID=temp.appendingPathComponent("helper.pid")
        q=request("printf '%s' \"$$\" > \"$1\"; /bin/sleep 1 & child=$!; printf '%s' \"$child\" > \"$2\"; trap 'kill \"$child\" 2>/dev/null; wait \"$child\"; exit 0' TERM; wait",[blockedPID.path,helperPID.path])
        q.input=Data(repeating:67,count:1024*1024);q.timeout=0.1
        let begin=ProcessInfo.processInfo.systemUptime
        rejects("blocked stdin obeys deadline"){_=try runner.run(q,cancelled:{false})}
        expect(ProcessInfo.processInfo.systemUptime-begin<2,"blocked stdin bounded under two seconds")
        let blocked=Int32(try String(contentsOf:blockedPID,encoding:.utf8))!,helper=Int32(try String(contentsOf:helperPID,encoding:.utf8))!
        until{gone(blocked)&&gone(helper)}
        let noisyPID=temp.appendingPathComponent("noisy.pid")
        q=request("trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do printf '01234567890123456789012345678901234567890123456789'; done",[noisyPID.path]);q.timeout=0.1;q.outputLimit=1024;q.failOnOverflow=false
        let noiseStart=ProcessInfo.processInfo.systemUptime
        rejects("continuous output cannot starve deadline"){_=try runner.run(q,cancelled:{false})}
        expect(ProcessInfo.processInfo.systemUptime-noiseStart<2,"continuous writer bounded under two seconds")
        expect(gone(Int32(try String(contentsOf:noisyPID,encoding:.utf8))!),"TERM-ignoring writer killed and reaped exactly")
        q=OwnedProcessRequest(executable:URL(fileURLWithPath:"/bin/cat"),arguments:[],environment:["PATH":"/usr/bin:/bin"])
        q.input=Data(repeating:68,count:65536);q.outputLimit=10;q.timeout=1
        rejects("strict output bound"){_=try runner.run(q,cancelled:{false})}
        q=request("printf should-not-run")
        rejects("cancelled before spawn"){_=try runner.run(q,cancelled:{true})}

        var detachedExit:Int32?
        q=request("/bin/sleep 0.15; exit 9");q.allowsHandoff=true
        let detached=try runner.run(q,cancelled:{false},handoff:{true},onDetachedExit:{detachedExit=$0})
        expect(detached.handedOff && !gone(detached.pid),"handoff retains a live user-owned process")
        until{detachedExit != nil}
        expect(detachedExit==9 && gone(detached.pid),"handoff exit status retained and leader reaped")
        let launcher=UserProcessLauncher()
        var clientExit:Int32?
        _=try launcher.launch(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","exit 13"],environment:["PATH":"/usr/bin:/bin"],directory:temp,onExit:{clientExit=$0})
        until{clientExit != nil};expect(clientExit==13,"client observer preserves nonzero status")
        let userPID=temp.appendingPathComponent("client.pid"),completedFile=temp.appendingPathComponent("client.finished")
        var unwantedCallback=false
        _=try launcher.launch(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","printf '%s' \"$$\" > \"$1\"; /bin/sleep 0.2; printf done > \"$2\"","fixture",userPID.path,completedFile.path],environment:["PATH":"/usr/bin:/bin"],directory:temp,onExit:{_ in unwantedCallback=true})
        until{fm.fileExists(atPath:userPID.path)};let client=Int32(try String(contentsOf:userPID,encoding:.utf8))!
        launcher.shutdown();expect(!gone(client),"hub shutdown never kills user client")
        rejects("client observer cannot resurrect after shutdown"){_=try launcher.launch(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],environment:[:],directory:nil,onExit:{_ in})}
        until{launcher.activeCount==0}
        expect(!unwantedCallback && fm.fileExists(atPath:completedFile.path) && gone(client),"client finishes naturally after silent shutdown")

        for mode in ["normal","active","cancel","handoff","late-handoff","stop-error","spawn-error"]{
            let folder=temp.appendingPathComponent(mode),descriptor=try fixtureDescriptor(folder),mock=FixtureProcessRunner()
            let operation=SteamInstallerOperation(runner:mock)
            mock.handler={request,cancelled,handoff in
                if request.executable.lastPathComponent=="ps"{
                    let text=mode=="active" ? "123 "+descriptor.wineURL.path+"\n" : ""
                    return .init(output:Data(text.utf8),exitCode:0,pid:0,handedOff:false)
                }
                if request.executable==descriptor.wineURL{
                    if mode=="spawn-error"{throw OwnedProcessError.spawn(13)}
                    request.onSpawn?(123)
                    if mode=="handoff"{
                        try put(Data([0x4d,0x5a]),descriptor.steamRoot.appendingPathComponent("steam.exe"));operation.cancel()
                        expect(handoff(),"Steam handoff wins simultaneous cancellation")
                        return .init(output:Data(),exitCode:0,pid:123,handedOff:true)
                    }
                    if mode=="late-handoff"{try put(Data([0x4d,0x5a]),descriptor.steamRoot.appendingPathComponent("steam.exe"))}
                    if mode=="cancel"{operation.cancel();expect(cancelled(),"installer sees cancellation");throw OwnedProcessError.cancelled}
                    expect(request.allowsHandoff && request.input.isEmpty,"installer has no captured account stream")
                }
                if request.executable==descriptor.wineserverURL{expect(!cancelled(),"prefix cleanup still runs after cancellation")}
                return .init(output:Data(),exitCode:mode=="stop-error" && request.arguments==["-k"] ? 1 : 0,pid:123,handedOff:false)
            }
            let run={try operation.run(installer:folder.appendingPathComponent("SteamSetup-fixture.exe"),descriptor:descriptor,current:{descriptor},onDetachedExit:{_ in})}
            if ["active","cancel","stop-error","spawn-error"].contains(mode){rejects("installer "+mode){_=try run()}}
            else{let result=try run();if mode=="late-handoff"{expect(result.handedOff,"Steam appearing on leader exit retains installer ownership record")}}
            let commands=mock.requests(),cleanup=commands.filter{$0.executable==descriptor.wineserverURL}
            if ["active","handoff","late-handoff","spawn-error"].contains(mode){expect(cleanup.isEmpty,"no prefix signals without installer ownership / after handoff")}
            else{expect(cleanup.map(\.arguments)==[["-k"],["-w"]],"independent cleanup attempts are prefix-scoped")}
            if mode=="active"{expect(!commands.contains{$0.executable==descriptor.wineURL},"existing engine process is preserved")}
            expect(commands.filter{$0.executable==descriptor.wineURL || $0.executable==descriptor.wineserverURL}.allSatisfy{$0.environment["WINEPREFIX"]==descriptor.prefixURL.path},"installer never selects a different prefix")
        }
        do{
            let descriptor=try fixtureDescriptor(temp.appendingPathComponent("foreign")),mock=FixtureProcessRunner()
            try fm.removeItem(at:descriptor.prefixURL.deletingLastPathComponent().appendingPathComponent("prefix-owner.json"))
            rejects("foreign prefix has no installer ownership"){_=try SteamInstallerOperation(runner:mock).run(installer:temp.appendingPathComponent("fixture.exe"),descriptor:descriptor,current:{descriptor},onDetachedExit:{_ in})}
            expect(mock.requests().isEmpty,"unowned prefix never invokes any process")
        }
        do{
            let descriptor=try fixtureDescriptor(temp.appendingPathComponent("closed-bootstrap")),mock=FixtureProcessRunner()
            let present=PlaymeltRuntimeDescriptor(engineID:descriptor.engineID,wineURL:descriptor.wineURL,wineserverURL:descriptor.wineserverURL,prefixURL:descriptor.prefixURL,steamRoot:descriptor.steamRoot,environment:descriptor.environment,readyEngine:true,steamInstalled:true)
            let bootstrap=SteamWindowsBootstrap(downloadsRoot:temp.appendingPathComponent("unused-downloads"),descriptor:{present},runner:mock)
            var cancelled=false,retryAccepted=false;bootstrap.cancel{cancelled=true};until{cancelled}
            bootstrap.onInstalled={retryAccepted=true};bootstrap.start()
            expect(retryAccepted,"reversible cancellation permits retry")
            var stopped=false;bootstrap.shutdown{stopped=true};until{stopped};retryAccepted=false;bootstrap.start()
            expect(!retryAccepted,"terminal shutdown rejects retry")
            expect(!bootstrap.busy && mock.requests().isEmpty && !fm.fileExists(atPath:temp.appendingPathComponent("unused-downloads").path),"closed bootstrap cannot restart download/install")
        }
        do{
            let descriptor=try fixtureDescriptor(temp.appendingPathComponent("stale-cancel")),mock=FixtureProcessRunner()
            let bootstrap=SteamWindowsBootstrap(downloadsRoot:temp.appendingPathComponent("fixture-downloads"),descriptor:{descriptor},runner:mock,sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[NoNetworkProtocol.self];return c})
            var firstCancel=false;bootstrap.cancel{firstCancel=true};bootstrap.start();until{firstCancel}
            expect(bootstrap.busy && bootstrap.snapshot["steamPhase"] as? String=="downloading","stale idle cancel cannot clear a new attempt")
            var stopped=false;bootstrap.shutdown{stopped=true};until{stopped}
            expect(!bootstrap.busy,"replacement attempt cleans up on terminal shutdown")
        }
        do{
            let descriptor=try fixtureDescriptor(temp.appendingPathComponent("cancel-generation"))
            let bootstrap=SteamWindowsBootstrap(downloadsRoot:temp.appendingPathComponent("generation-downloads"),descriptor:{descriptor},sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[NoNetworkProtocol.self];return c})
            func generation()->UUID?{Mirror(reflecting:bootstrap).children.first{$0.label=="cancelGeneration"}?.value as? UUID}
            var aDone=false,bDone=false,bGeneration:UUID?
            bootstrap.cancel{
                expect(generation()==bGeneration,"cancel A cannot consume cancellation B's ownership token")
                aDone=true
            }
            bootstrap.start()
            bootstrap.cancel{bDone=true}
            bGeneration=generation();expect(bGeneration != nil,"cancellation uses an exact generation")
            until{aDone && bDone}
            expect(generation() != bGeneration && !bootstrap.busy,"only current cancellation finishes and invalidates its token")
            var stopped=false;bootstrap.shutdown{stopped=true};until{stopped}
        }
        do{
            let descriptor=try fixtureDescriptor(temp.appendingPathComponent("retention")),file=temp.appendingPathComponent("retained-installer.exe")
            try put(Data([0x4d,0x5a]),file)
            let retention=try SteamInstallerRetention(file:file,descriptor:descriptor)
            retention.observeExit(0);retention.handoff(pid:123);retention.preserve()
            let record=try JSONSerialization.jsonObject(with:Data(contentsOf:file.appendingPathExtension("handoff.json"))) as! [String:Any]
            expect(record["leaderExitObserved"] as? Bool==true && record["fileUsageEnded"] as? Bool==false,"handoff leader exit is not full usage proof")
            expect(record["installer"] as? String==file.path && fm.fileExists(atPath:file.path),"exact handoff artifact retained without killing clients")
            expect((try fm.attributesOfItem(atPath:file.appendingPathExtension("handoff.json").path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"handoff receipt stays private")
        }

        let epicRoot=temp.appendingPathComponent("epic"),worker=epicRoot.appendingPathComponent("fixture.py")
        try put(Data("# not executed".utf8),worker)
        let epicRunner=FixtureProcessRunner()
        let snapshot:[String:Any]=["accountId":"fixture-account","displayName":"Fixture","games":[],"installed":[],"source":"fixture","updatedAt":"2026-10-25T00:00:00Z"]
        epicRunner.handler={request,cancelled,_ in
            expect(request.input.count>0 && !request.arguments.joined().contains("fixture-code"),"Epic auth code travels only through stdin")
            expect(!request.mergeStandardError && request.outputLimit==16*1024*1024,"Epic response bounded and stderr excluded")
            let input=try JSONSerialization.jsonObject(with:request.input) as! [String:Any]
            if input["action"] as? String == "sync"{expect((input["session"] as? [String:Any])?["access_token"] as? String=="fixture-token","Epic session remains memory input")}
            return .init(output:try JSONSerialization.data(withJSONObject:["ok":true,"session":["account_id":"fixture-account","access_token":"fixture-token"],"snapshot":snapshot]),exitCode:0,pid:0,handedOff:false)
        }
        let epic=EpicConnector(projectRoot:epicRoot,pythonURL:URL(fileURLWithPath:"/usr/bin/true"),workerURL:worker,runner:epicRunner,sessionStore:EpicMemorySessionStore())
        var authenticated=false;epic.authenticate(code:"fixture-code"){if case .success = $0{authenticated=true}};until{authenticated}
        expect(epic.availability()["authenticated"] as? Bool==true,"Epic memory session accepted")
        var synced=false;epic.sync{if case .success = $0{synced=true}};until{synced}
        var closed=false;epic.shutdown{closed=true};until{closed}
        expect(epic.availability()["authenticated"] as? Bool==false,"Epic shutdown clears memory session")
        let count=epicRunner.requests().count;var refused=false
        epic.authenticate(code:"fixture-code"){if case .failure = $0{refused=true}};until{refused}
        expect(epicRunner.requests().count==count,"Epic closed connector cannot create worker")
        let holding=FixtureProcessRunner()
        holding.handler={_,cancelled,_ in let end=Date().addingTimeInterval(2);while !cancelled() && Date()<end{Thread.sleep(forTimeInterval:0.005)};expect(cancelled(),"Epic pending worker observes cancellation");throw OwnedProcessError.cancelled}
        let pending=EpicConnector(projectRoot:epicRoot,pythonURL:URL(fileURLWithPath:"/usr/bin/true"),workerURL:worker,runner:holding,sessionStore:EpicMemorySessionStore())
        var requestDone=false,shutdownDone=false
        pending.authenticate(code:"fixture-code"){_ in requestDone=true};until{!holding.requests().isEmpty}
        pending.shutdown{shutdownDone=true};until{shutdownDone}
        expect(requestDone && pending.availability()["busy"] as? Bool==false,"Epic shutdown waits for worker cleanup/completion")
        let setup=RuntimeSetup(root:temp.appendingPathComponent("closed-runtime"),runner:FixtureProcessRunner())
        var setupClosed=false;setup.shutdown{setupClosed=true};until{setupClosed}
        var setupRejected=false;setup.start(progress:{_ in},completion:{if case .failure = $0{setupRejected=true}});until{setupRejected}
        expect(!fm.fileExists(atPath:setup.root.path),"closed RuntimeSetup never recreates state")
        print("Process lifecycle: \(checks) PASS; bounded CPU helpers and mock Wine/Epic only; no client/GPU/game.")
    }
}
