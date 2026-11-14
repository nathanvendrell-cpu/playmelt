// Inert ZIP/PE fixtures only. Real subprocess boundary permits system ditto;
// Wine, Steam, games, accounts and network are never invoked.
import Foundation
import Darwin

struct PlaymeltRuntimeDescriptor {
    let engineID:String, wineURL:URL, wineserverURL:URL, prefixURL:URL, steamRoot:URL
    let environment:[String:String]
    let readyEngine:Bool, steamInstalled:Bool
}
enum RuntimeSetupError:LocalizedError {case failed(String);var errorDescription:String?{if case .failed(let m)=self{return m};return nil}}
final class RuntimeSetup {
    let root=URL(fileURLWithPath:"/unused-inert")
    func descriptor()->PlaymeltRuntimeDescriptor{fatalError("Unused fixture")}
    static func rejectSymlinkAncestors(_ url:URL)throws {
        var current=url.standardizedFileURL
        while current.path != "/" {
            var info=stat()
            if lstat(current.path,&info)==0,info.st_mode&S_IFMT==S_IFLNK{throw RuntimeSetupError.failed("Symlink refused")}
            current.deleteLastPathComponent()
        }
    }
}
private final class FixtureRunner:OwnedProcessRunning {
    var calls=[OwnedProcessRequest](),active=false,cancelBeforeExtraction=false
    let real=OwnedProcessRunner()
    func run(_ request:OwnedProcessRequest,cancelled:()->Bool,handoff:()->Bool,onDetachedExit:@escaping(Int32)->Void)throws->OwnedProcessResult {
        calls.append(request)
        if cancelled(){throw OwnedProcessError.cancelled}
        if request.executable.path=="/bin/ps" {
            return .init(output:Data((active ? "55 /inert-engine/bin/wine\n":"").utf8),exitCode:0,pid:0,handedOff:false)
        }
        precondition(request.executable.path=="/usr/bin/ditto")
        return try real.run(request,cancelled:cancelled,handoff:handoff,onDetachedExit:onDetachedExit)
    }
}
private final class NoNetwork:URLProtocol {
    static var requests=0
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){Self.requests+=1;client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet))}
    override func stopLoading(){}
}
private final class FixtureHTTP:URLProtocol {
    static let lock=NSLock()
    static var manifest=Data(),archive=Data(),count=0,holding=false
    static func requests()->Int{lock.lock();defer{lock.unlock()};return count}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.lock.lock();Self.count+=1;let hold=Self.holding;let data=request.url!.lastPathComponent=="steam_client_win32" ? Self.manifest:Self.archive;Self.lock.unlock()
        if hold{return}
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Length":String(data.count)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
@main enum SteamBootstrapPackageTests {
    static let fm=FileManager.default
    static var count=0
    static func check(_ value:Bool,_ label:String){count+=1;if !value{fatalError("FAIL: "+label)}}
    static func reject(_ label:String,_ action:()throws->Void){do{try action();check(false,label)}catch{check(true,label)}}
    static func word(_ value:Int,_ width:Int)->Data{Data((0..<width).map{UInt8(truncatingIfNeeded:value >> ($0*8))})}
    static func put(_ value:Int,_ offset:Int,_ width:Int,_ data:inout Data){data.replaceSubrange(offset..<(offset+width),with:word(value,width))}
    static func crc(_ data:Data)->Int {
        var value:UInt32=0xffffffff
        for byte in data{value ^= UInt32(byte);for _ in 0..<8{value=(value>>1)^((value&1)==1 ? 0xedb88320:0)}}
        return Int(value ^ 0xffffffff)
    }
    static func client()->Data {
        var data=Data(repeating:0,count:2048);data[0]=0x4d;data[1]=0x5a
        put(128,0x3c,4,&data);put(0x4550,128,4,&data);put(0x14c,132,2,&data);put(224,148,2,&data)
        put(0x10b,152,2,&data);put(2032,280,4,&data);put(16,284,4,&data)
        put(16,2032,4,&data);put(0x200,2036,2,&data);put(2,2038,2,&data);data[2040]=0x30
        return data
    }
    static func zip(_ payload:Data,name:String="steam.exe",mode:Int=0x81c0,flags:Int=0,method:Int=0)->Data {
        let n=Data(name.utf8),checksum=crc(payload);var data=Data()
        for (v,w) in [(0x04034b50,4),(20,2),(flags,2),(method,2),(0,2),(0,2),(checksum,4),(payload.count,4),(payload.count,4),(n.count,2),(0,2)]{data+=word(v,w)}
        data+=n;data+=payload;let central=data.count
        for (v,w) in [(0x02014b50,4),(0x314,2),(20,2),(flags,2),(method,2),(0,2),(0,2),(checksum,4),(payload.count,4),(payload.count,4),(n.count,2),(0,2),(0,2),(0,2),(0,2),(mode<<16,4),(0,4)]{data+=word(v,w)}
        data+=n;let size=data.count-central
        for (v,w) in [(0x06054b50,4),(0,2),(0,2),(1,2),(1,2),(size,4),(central,4),(0,2)]{data+=word(v,w)}
        return data
    }
    static func manifest(_ zip:Data)->Data {
        Data(("\"win32\" { \"steam_win32\" { \"file\" \"steam_win32.zip."+String(repeating:"a",count:40)+"\" \"size\" \"\(zip.count)\" \"sha2\" \""+SteamBootstrapPackage.hash(zip)+"\" \"IsBootstrapperPackage\" \"1\" } }").utf8)
    }
    static func prefixed(_ archive:Data,_ bytes:Int=20)->Data {
        let central=archive.count-22-55;var data=Data((0..<bytes).map{UInt8($0+1)})+archive
        put(bytes,central+bytes+42,4,&data);put(central+bytes,data.count-22+16,4,&data)
        return data
    }
    static func until(_ predicate:()->Bool){let deadline=Date().addingTimeInterval(3);while !predicate() && Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};check(predicate(),"bounded callback")}
    static func leaseDescriptor(_ root:URL)->PlaymeltRuntimeDescriptor {
        let prefix=root.appendingPathComponent("prefix")
        return .init(engineID:"lease-fixture",wineURL:root.appendingPathComponent("engine/bin/wine"),wineserverURL:root.appendingPathComponent("engine/bin/wineserver"),prefixURL:prefix,steamRoot:prefix.appendingPathComponent("drive_c/Steam"),environment:[:],readyEngine:true,steamInstalled:false)
    }
    static func holdLease(_ root:URL,_ id:UUID)throws {
        let descriptor=leaseDescriptor(root),logs=root.appendingPathComponent("logs/SteamSetup")
        let lease=try SteamBootstrapLease(url:logs.appendingPathComponent("operation.lock"),runtime:descriptor)
        let journal=try SteamInstallerJournal(url:logs.appendingPathComponent("last-attempt.json"),descriptor:descriptor,method:SteamBootstrapPackage.method,intentID:id,lease:lease)
        journal.record("download-started")
        try Data("ready".utf8).write(to:root.appendingPathComponent("holder.ready"))
        Thread.sleep(forTimeInterval:10);lease.release()
    }
    static func qualifyOfficialFixture(_ root:URL)throws {
        let package=try SteamBootstrapPackage(manifest:Data(contentsOf:root.appendingPathComponent("manifest.vdf")))
        let store=SteamBootstrapPackageStore(root:root.appendingPathComponent("shared-cache"))
        try store.store(package,downloaded:root.appendingPathComponent("package.zip"))
        guard try store.cached()?.sha256==package.sha256 else{throw SteamBootstrapPackageError.invalidCache}
        let prefix=root.appendingPathComponent("inert-prefix"),steam=prefix.appendingPathComponent("drive_c/Steam")
        try fm.createDirectory(at:steam,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["prefix":prefix.path,"engineID":"inert-official-fixture"]).write(to:root.appendingPathComponent("prefix-owner.json"))
        let descriptor=PlaymeltRuntimeDescriptor(engineID:"inert-official-fixture",wineURL:URL(fileURLWithPath:"/inert-engine/bin/wine"),wineserverURL:URL(fileURLWithPath:"/inert-engine/bin/wineserver"),prefixURL:prefix,steamRoot:steam,environment:[:],readyEngine:true,steamInstalled:false)
        try store.prepare(package,descriptor:descriptor,current:{descriptor},runner:FixtureRunner(),cancelled:{false})
        let client=try Data(contentsOf:steam.appendingPathComponent("steam.exe"));try SteamBootstrapZIP.validateClient(client)
        let proof:[String:Any]=["archiveBytes":package.size,"archiveSHA256":package.sha256,"clientBytes":client.count,"clientSHA256":SteamBootstrapPackage.hash(client),"manifestSHA256":package.manifestSHA256,"officialPackagePreparedInTemporaryFixture":true,"wineSteamGameExecuted":false]
        print(String(data:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),encoding:.utf8)!)
    }
    static func main()throws {
        if CommandLine.arguments.count==4 && CommandLine.arguments[1]=="--lease-holder" {
            try holdLease(URL(fileURLWithPath:CommandLine.arguments[2]),UUID(uuidString:CommandLine.arguments[3])!);return
        }
        if CommandLine.arguments.count==2 {try qualifyOfficialFixture(URL(fileURLWithPath:CommandLine.arguments[1]));return}
        let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/steam-package-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        let payload=client(),archive=prefixed(zip(payload)),package=try SteamBootstrapPackage(manifest:manifest(archive))
        check(package.size==archive.count && package.sha256==SteamBootstrapPackage.hash(archive),"manifest pins exact archive size and SHA256")
        check(package.url.host=="cdn.steamstatic.com" && package.filename.hasPrefix("steam_win32.zip."),"package source is Valve HTTPS")
        try SteamBootstrapZIP.validateClient(payload);check(try SteamBootstrapZIP(archive).expandedSize==payload.count,"bounded ZIP fixture accepted")
        check(try SteamBootstrapZIP(zip(payload)).expandedSize==payload.count,"standard ZIP without Valve prefix remains bounded")
        reject("arbitrary executable preamble is not accepted"){_=try SteamBootstrapZIP(prefixed(zip(payload),19))}
        for bad in [Data(),Data(repeating:0,count:128*1024+1),Data("\"win32\" { \"steam_win32\" {} \"steam_win32\" {} }".utf8),Data("\"win32\" {".utf8)] {reject("malformed, oversized or duplicate manifest refused"){_=try SteamBootstrapPackage(manifest:bad)}}
        let text=String(decoding:manifest(archive),as:UTF8.self)
        for bad in [text.replacingOccurrences(of:"steam_win32.zip.",with:"../steam_win32.zip."),text.replacingOccurrences(of:"\"1\"",with:"\"0\""),text.replacingOccurrences(of:package.sha256,with:"not-a-hash")] {reject("manifest cannot authorize unknown filename/hash/bootstrap flag"){_=try SteamBootstrapPackage(manifest:Data(bad.utf8))}}
        for bad in [zip(payload,name:"../st.exe"),zip(payload,mode:0xa1ff),zip(payload,flags:1),zip(payload,method:9),archive+Data([0]),Data(archive.prefix(100))] {reject("unsafe ZIP layout refused"){_=try SteamBootstrapZIP(bad)}}
        var mismatch=archive;mismatch[50]=0x53;reject("local and central names must agree"){_=try SteamBootstrapZIP(mismatch)}
        var unsigned=payload;put(0,280,4,&unsigned);reject("MZ alone cannot authorize prepared client"){try SteamBootstrapZIP.validateClient(unsigned)}
        var truncated=payload;put(4096,280,4,&truncated);reject("certificate table must be inside payload"){try SteamBootstrapZIP.validateClient(truncated)}
        let cache=SteamBootstrapPackageStore(root:root.appendingPathComponent("shared-cache"))
        check(try cache.cached()==nil,"absent cache is a cold preparation")
        let input=root.appendingPathComponent("official-fixture.zip");try archive.write(to:input)
        try cache.store(package,downloaded:input)
        check(try cache.cached()?.sha256==package.sha256,"cache reuses exact verified package")
        let cacheHash=SteamBootstrapPackage.hash(try Data(contentsOf:cache.archiveURL(package)))
        reject("changed archive cannot replace immutable content-addressed cache"){
            var bad=archive;bad[50]^=1;try bad.write(to:input);try cache.store(package,downloaded:input)
        }
        check(SteamBootstrapPackage.hash(try Data(contentsOf:cache.archiveURL(package)))==cacheHash,"bad incoming bytes preserve verified cache")
        try archive.write(to:input)
        func descriptor(_ name:String)throws->PlaymeltRuntimeDescriptor {
            let base=root.appendingPathComponent(name),prefix=base.appendingPathComponent("prefix"),steam=prefix.appendingPathComponent("drive_c/Steam")
            try fm.createDirectory(at:steam.appendingPathComponent("steamapps/common/ExistingGame"),withIntermediateDirectories:true)
            try Data("game-sentinel".utf8).write(to:steam.appendingPathComponent("steamapps/common/ExistingGame/file.bin"))
            try fm.createDirectory(at:steam.appendingPathComponent("config"),withIntermediateDirectories:true)
            try Data("session-sentinel".utf8).write(to:steam.appendingPathComponent("config/loginusers.vdf"))
            try JSONSerialization.data(withJSONObject:["prefix":prefix.path,"engineID":name]).write(to:base.appendingPathComponent("prefix-owner.json"))
            return .init(engineID:name,wineURL:URL(fileURLWithPath:"/inert-engine/bin/wine"),wineserverURL:URL(fileURLWithPath:"/inert-engine/bin/wineserver"),prefixURL:prefix,steamRoot:steam,environment:[:],readyEngine:true,steamInstalled:false)
        }
        for name in ["DX11","DX12"] {
            let d=try descriptor(name),runner=FixtureRunner()
            try cache.prepare(package,descriptor:d,current:{d},runner:runner,cancelled:{false})
            check(try Data(contentsOf:d.steamRoot.appendingPathComponent("steam.exe"))==payload,"shared package prepares each persistent engine prefix")
            check(try Data(contentsOf:d.steamRoot.appendingPathComponent("steamapps/common/ExistingGame/file.bin"))==Data("game-sentinel".utf8),"prepared game files preserved")
            check(try Data(contentsOf:d.steamRoot.appendingPathComponent("config/loginusers.vdf"))==Data("session-sentinel".utf8),"existing official authentication preserved")
            let calls=runner.calls.count
            try cache.prepare(package,descriptor:d,current:{d},runner:runner,cancelled:{false})
            check(runner.calls.count==calls,"idempotent second preparation invokes no extraction/process")
            check(runner.calls.allSatisfy{["/bin/ps","/usr/bin/ditto"].contains($0.executable.path)},"bootstrap never executes NSIS/Wine/Steam/game")
            let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:d.steamRoot.appendingPathComponent(".playmelt-bootstrap.json"))) as! [String:Any]
            check(receipt["authenticationAssumed"] as? Bool==false && receipt["archiveSHA256"] as? String==package.sha256,"provenance receipt never claims account authentication")
        }
        let denied=try descriptor("active"),active=FixtureRunner();active.active=true
        reject("active engine is never mutated"){try cache.prepare(package,descriptor:denied,current:{denied},runner:active,cancelled:{false})}
        check(!fm.fileExists(atPath:denied.steamRoot.appendingPathComponent("steam.exe").path),"busy engine has no partially prepared client")
        reject("cancel before work cannot install"){try cache.prepare(package,descriptor:denied,current:{denied},runner:FixtureRunner(),cancelled:{true})}
        reject("runtime change cannot install"){try cache.prepare(package,descriptor:denied,current:{nil},runner:FixtureRunner(),cancelled:{false})}
        let missing=try descriptor("missing-owner");try fm.removeItem(at:missing.prefixURL.deletingLastPathComponent().appendingPathComponent("prefix-owner.json"))
        reject("foreign prefix cannot install"){try cache.prepare(package,descriptor:missing,current:{missing},runner:FixtureRunner(),cancelled:{false})}
        let linked=try descriptor("linked-client"),outside=root.appendingPathComponent("outside.bin");try Data("outside-sentinel".utf8).write(to:outside)
        try fm.createSymbolicLink(at:linked.steamRoot.appendingPathComponent("steam.exe"),withDestinationURL:outside)
        reject("symlink client cannot overwrite outside file"){try cache.prepare(package,descriptor:linked,current:{linked},runner:FixtureRunner(),cancelled:{false})}
        check(try Data(contentsOf:outside)==Data("outside-sentinel".utf8),"outside sentinel preserved")
        let live=try descriptor("cached-start"),before=NoNetwork.requests
        let bootstrap=SteamWindowsBootstrap(downloadsRoot:root.appendingPathComponent("cached-start/downloads"),cacheRoot:cache.root,descriptor:{live},runner:FixtureRunner(),sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[NoNetwork.self];return c})
        bootstrap.start(ownerID:UUID());until{bootstrap.snapshot["steamPhase"] as? String=="ready" || bootstrap.snapshot["steamPhase"] as? String=="failed"}
        check(bootstrap.snapshot["steamPhase"] as? String=="ready" && NoNetwork.requests==before,"verified cache makes game preparation independent of network/NSIS")
        var stopped=false;bootstrap.shutdown{stopped=true};until{stopped}
        let cold=try descriptor("cold-start"),coldCache=root.appendingPathComponent("cold-cache"),coldRunner=FixtureRunner()
        FixtureHTTP.manifest=manifest(archive);FixtureHTTP.archive=archive
        let coldBootstrap=SteamWindowsBootstrap(downloadsRoot:root.appendingPathComponent("cold-start/downloads"),cacheRoot:coldCache,descriptor:{cold},runner:coldRunner,sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[FixtureHTTP.self];return c})
        let requestCount=FixtureHTTP.requests()
        coldBootstrap.start(ownerID:UUID());until{coldBootstrap.snapshot["steamPhase"] as? String=="ready" || coldBootstrap.snapshot["steamPhase"] as? String=="failed"}
        check(coldBootstrap.snapshot["steamPhase"] as? String=="ready","manifest completion cannot invalidate the following package download")
        check(FixtureHTTP.requests()==requestCount+2,"cold preparation fetches exactly manifest plus authorized package")
        check(try SteamBootstrapPackageStore(root:coldCache).cached()?.sha256==package.sha256,"cold preparation persists verified package for all engines")
        check(coldRunner.calls.allSatisfy{["/bin/ps","/usr/bin/ditto"].contains($0.executable.path)},"cold preparation invokes no legacy installer")
        stopped=false;coldBootstrap.shutdown{stopped=true};until{stopped}
        let old=try descriptor("legacy-failure"),journalURL=root.appendingPathComponent("legacy-failure/logs/last.json")
        let oldJournal=try SteamInstallerJournal(url:journalURL,descriptor:old)
        oldJournal.record("completed",fields:["exitCode":1,"handedOff":false])
        let migratedIntent=UUID()
        _=try SteamInstallerJournal(url:journalURL,descriptor:old,automatic:true,method:SteamBootstrapPackage.method,intentID:migratedIntent)
        check(true,"legacy NSIS exit1 migrates once to new mechanism")
        reject("same migrated intent cannot retry permanently"){_=try SteamInstallerJournal(url:journalURL,descriptor:old,automatic:true,method:SteamBootstrapPackage.method,intentID:migratedIntent)}
        let cancelled=try descriptor("legacy-cancelled"),cancelURL=root.appendingPathComponent("legacy-cancelled/logs/last.json")
        let cancelledJournal=try SteamInstallerJournal(url:cancelURL,descriptor:cancelled);cancelledJournal.record("cancelled")
        reject("cancellation cannot resume without a new foreground intent"){_=try SteamInstallerJournal(url:cancelURL,descriptor:cancelled,automatic:true,method:SteamBootstrapPackage.method)}
        // A failed foreground request must not poison every future game. Timers
        // retain their owner UUID; a new click is represented by a different UUID.
        let retry=try descriptor("retry-intent"),retryBefore=NoNetwork.requests
        let retryBootstrap=SteamWindowsBootstrap(downloadsRoot:root.appendingPathComponent("retry-intent/downloads"),descriptor:{retry},runner:FixtureRunner(),sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[NoNetwork.self];return c})
        let firstIntent=UUID();retryBootstrap.start(ownerID:firstIntent)
        until{retryBootstrap.snapshot["steamPhase"] as? String=="failed"}
        let retryJournal=root.appendingPathComponent("retry-intent/logs/SteamSetup/last-attempt.json"),failedBytes=try Data(contentsOf:retryJournal)
        let sameIntent=SteamBootstrapIntent(ownerID:firstIntent,bootstrap:retryBootstrap)
        for _ in 0..<10{_=sameIntent.poll()}
        check(try NoNetwork.requests==retryBefore+1 && Data(contentsOf:retryJournal)==failedBytes,"same intent/timer cannot retry or rewrite failed history")
        let nextIntent=UUID();retryBootstrap.start(ownerID:nextIntent)
        until{NoNetwork.requests==retryBefore+2 && !retryBootstrap.busy}
        let retried=try JSONSerialization.jsonObject(with:Data(contentsOf:retryJournal)) as! [String:Any]
        check(retried["intentID"] as? String==nextIntent.uuidString,"a new explicit intent can retry a terminal ZIP failure")
        stopped=false;retryBootstrap.shutdown{stopped=true};until{stopped}

        let cancelRuntime=try descriptor("cancel-intent"),cancelOwner=UUID(),cancelRequests=FixtureHTTP.requests()
        FixtureHTTP.holding=true
        let cancelBootstrap=SteamWindowsBootstrap(downloadsRoot:root.appendingPathComponent("cancel-intent/downloads"),descriptor:{cancelRuntime},runner:FixtureRunner(),sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[FixtureHTTP.self];return c})
        let cancelIntent=SteamBootstrapIntent(ownerID:cancelOwner,bootstrap:cancelBootstrap)
        _=cancelIntent.poll();until{FixtureHTTP.requests()==cancelRequests+1}
        stopped=false;cancelIntent.cancel{stopped=true};until{stopped}
        for _ in 0..<10{_=cancelIntent.poll()}
        let sameCancelled=SteamBootstrapIntent(ownerID:cancelOwner,bootstrap:cancelBootstrap);_=sameCancelled.poll()
        check(FixtureHTTP.requests()==cancelRequests+1 && !cancelBootstrap.busy,"cancelled intent never resumes in the background")
        FixtureHTTP.holding=false
        let foreground=SteamBootstrapIntent(ownerID:UUID(),bootstrap:cancelBootstrap);_=foreground.poll()
        until{cancelBootstrap.snapshot["steamPhase"] as? String=="ready" || (!cancelBootstrap.busy && cancelBootstrap.snapshot["steamPhase"] as? String=="failed")}
        check(cancelBootstrap.snapshot["steamPhase"] as? String=="ready" && FixtureHTTP.requests()==cancelRequests+3,"new foreground click can resume after cancellation without NSIS")
        stopped=false;cancelBootstrap.shutdown{stopped=true};until{stopped}

        // Real OS lock survives journal writes, then is released by process
        // death. No PID lookup/age heuristic participates in product recovery.
        let crash=root.appendingPathComponent("crash-relaunch");try fm.createDirectory(at:crash,withIntermediateDirectories:true)
        let crashID=UUID(),child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments=["--lease-holder",crash.path,crashID.uuidString];child.environment=["PATH":"/usr/bin:/bin"]
        child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
        var launched=false
        defer{if launched{if child.isRunning{Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}}
        try child.run();launched=true
        let readyDeadline=Date().addingTimeInterval(3)
        while !fm.fileExists(atPath:crash.appendingPathComponent("holder.ready").path) && child.isRunning && Date()<readyDeadline{Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,fm.fileExists(atPath:crash.appendingPathComponent("holder.ready").path) else{throw RuntimeSetupError.failed("Lease helper did not become ready")}
        let crashRuntime=leaseDescriptor(crash),lockURL=crash.appendingPathComponent("logs/SteamSetup/operation.lock")
        var liveBlocked=false;do{_=try SteamBootstrapLease(url:lockURL,runtime:crashRuntime)}catch{liveBlocked=true}
        guard liveBlocked else{throw RuntimeSetupError.failed("Live lease was not exclusive")};check(true,"a live operation's OS lease blocks another preparer")
        guard Darwin.kill(child.processIdentifier,SIGKILL)==0 else{throw RuntimeSetupError.failed("Could not stop exact owned test helper")}
        child.waitUntilExit();check(child.terminationReason == .uncaughtSignal,"test exercises process death, not normal lease release")
        let recoveredLease=try SteamBootstrapLease(url:lockURL,runtime:crashRuntime);defer{recoveredLease.release()}
        let crashJournal=crash.appendingPathComponent("logs/SteamSetup/last-attempt.json"),crashHistory=try Data(contentsOf:crashJournal)
        reject("same UUID cannot replay after process restart"){_=try SteamInstallerJournal(url:crashJournal,descriptor:crashRuntime,automatic:true,method:SteamBootstrapPackage.method,intentID:crashID,lease:recoveredLease)}
        check(try Data(contentsOf:crashJournal)==crashHistory,"same UUID leaves interrupted journal intact")
        let recoveredID=UUID()
        _=try SteamInstallerJournal(url:crashJournal,descriptor:crashRuntime,automatic:true,method:SteamBootstrapPackage.method,intentID:recoveredID,lease:recoveredLease)
        check((try JSONSerialization.jsonObject(with:Data(contentsOf:crashJournal)) as! [String:Any])["intentID"] as? String==recoveredID.uuidString,"new foreground UUID resumes an inflight ZIP journal after crash")
        let legacyInflight=try descriptor("legacy-inflight"),legacyURL=root.appendingPathComponent("legacy-inflight/logs/last.json")
        let inflightJournal=try SteamInstallerJournal(url:legacyURL,descriptor:legacyInflight);inflightJournal.record("download-started")
        reject("legacy NSIS inflight journal stays conservative"){_=try SteamInstallerJournal(url:legacyURL,descriptor:legacyInflight,automatic:true,method:SteamBootstrapPackage.method,intentID:UUID(),lease:recoveredLease)}

        // Recovery replaces only the archive approved by an intact private
        // pointer, and only after a new payload has passed the full checks.
        let pointer=cache.root.appendingPathComponent("current.json"),pointerBytes=try Data(contentsOf:pointer),archiveURL=cache.archiveURL(package)
        var pointerInfo=stat();check(lstat(pointer.path,&pointerInfo)==0,"capture immutable pointer inode")
        try Data("corrupt-cache".utf8).write(to:archiveURL)
        reject("corrupted cache is not treated as ready"){_=try cache.cached()}
        check(try cache.recoveryPackage()?.sha256==package.sha256,"intact provenance authorizes an HTTPS repair request")
        let corruptBefore=try Data(contentsOf:archiveURL)
        try Data("bad fresh response".utf8).write(to:input)
        reject("unverified new payload cannot replace corrupt cache"){try cache.store(package,downloaded:input)}
        check(try Data(contentsOf:archiveURL)==corruptBefore && Data(contentsOf:pointer)==pointerBytes,"failed repair preserves archive and pointer")
        try archive.write(to:input);try cache.store(package,downloaded:input)
        var pointerAfter=stat();_=lstat(pointer.path,&pointerAfter)
        check(try cache.cached()?.sha256==package.sha256,"verified fresh payload repairs corrupt generated archive")
        check(try Data(contentsOf:pointer)==pointerBytes && pointerInfo.st_ino==pointerAfter.st_ino,"repair never overwrites provenance pointer")
        try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath:archiveURL.path)
        reject("unsafe cache mode cannot authorize recovery"){_=try cache.recoveryPackage()}
        reject("unsafe cache mode cannot be overwritten"){try cache.store(package,downloaded:input)}
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:archiveURL.path)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:cache.root.path)
        reject("nonprivate cache directory cannot be repaired"){try cache.store(package,downloaded:input)}
        check((try fm.attributesOfItem(atPath:cache.root.path)[.posixPermissions] as! NSNumber).intValue==0o755,"unsafe root permissions are not silently changed")
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:cache.root.path)
        for kind in ["hardlink","symlink"] {
            let unsafe=SteamBootstrapPackageStore(root:root.appendingPathComponent("unsafe-"+kind));try unsafe.store(package,downloaded:input)
            let target=root.appendingPathComponent("sentinel-"+kind);try Data("preserve-external-cache-sentinel".utf8).write(to:target);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            let entry=unsafe.archiveURL(package);try fm.removeItem(at:entry)
            if kind=="hardlink"{try fm.linkItem(at:target,to:entry)}else{try fm.createSymbolicLink(at:entry,withDestinationURL:target)}
            reject("linked cache never authorizes repair"){_=try unsafe.recoveryPackage()}
            reject("linked cache never replaced by fresh response"){try unsafe.store(package,downloaded:input)}
            check(try Data(contentsOf:target)==Data("preserve-external-cache-sentinel".utf8),"external linked target preserved")
        }
        let foreign=SteamBootstrapPackageStore(root:root.appendingPathComponent("foreign-pointer"));try foreign.store(package,downloaded:input)
        let foreignPointer=foreign.root.appendingPathComponent("current.json");var foreignValue=try JSONSerialization.jsonObject(with:Data(contentsOf:foreignPointer)) as! [String:Any]
        foreignValue["owner"]="unrelated";try JSONSerialization.data(withJSONObject:foreignValue).write(to:foreignPointer);let foreignBytes=try Data(contentsOf:foreignPointer)
        reject("foreign pointer never authorizes recovery"){_=try foreign.recoveryPackage()}
        reject("fresh payload never overwrites foreign pointer"){try foreign.store(package,downloaded:input)}
        check(try Data(contentsOf:foreignPointer)==foreignBytes,"foreign pointer bytes preserved")
        let repair=try descriptor("online-repair"),repairStore=SteamBootstrapPackageStore(root:root.appendingPathComponent("online-repair-cache"))
        try repairStore.store(package,downloaded:input);try Data("broken".utf8).write(to:repairStore.archiveURL(package))
        let repairRequests=FixtureHTTP.requests(),repairBootstrap=SteamWindowsBootstrap(downloadsRoot:root.appendingPathComponent("online-repair/downloads"),cacheRoot:repairStore.root,descriptor:{repair},runner:FixtureRunner(),sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[FixtureHTTP.self];return c})
        repairBootstrap.start(ownerID:UUID());until{repairBootstrap.snapshot["steamPhase"] as? String=="ready" || (!repairBootstrap.busy && repairBootstrap.snapshot["steamPhase"] as? String=="failed")}
        check(repairBootstrap.snapshot["steamPhase"] as? String=="ready" && FixtureHTTP.requests()==repairRequests+1,"corrupt owned cache repairs through one new authorized HTTPS package request")
        check(try Data(contentsOf:repair.steamRoot.appendingPathComponent("steamapps/common/ExistingGame/file.bin"))==Data("game-sentinel".utf8),"cache recovery preserves prepared games")
        stopped=false;repairBootstrap.shutdown{stopped=true};until{stopped}
        for url in ["http://cdn.steamstatic.com/client/steam_client_win32","https://example.com/client/steam_client_win32","https://cdn.steamstatic.com/client/../steam.exe","https://cdn.steamstatic.com/client/steam_client_win32?token=x"] {check(!SteamWindowsBootstrap.allowed(URL(string:url)!),"source allowlist excludes arbitrary or credentialled URL")}
        print("\(count) Steam package/cache/atomic-preparation checks passed; inert payloads, system ditto only, no network/Wine/Steam/game")
    }
}
