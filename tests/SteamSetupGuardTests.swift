// Compile with OwnedProcess.swift, SteamBootstrapPackage.swift and SteamWindowsBootstrap.swift.
// Inert runtime dependencies; no engine/client/process is executed by these tests.
import Foundation
import Darwin

struct PlaymeltRuntimeDescriptor {
    let engineID:String, wineURL:URL, wineserverURL:URL, prefixURL:URL, steamRoot:URL
    let environment:[String:String]
    let readyEngine:Bool, steamInstalled:Bool
}
enum RuntimeSetupError:LocalizedError {
    case failed(String)
    var errorDescription:String?{if case .failed(let message)=self{return message};return nil}
}
final class RuntimeSetup {
    let root=URL(fileURLWithPath:"/inert-unused")
    func descriptor()->PlaymeltRuntimeDescriptor{fatalError("Unused inert runtime")}
    static func rejectSymlinkAncestors(_ url:URL)throws {
        var part=url.standardizedFileURL
        while part.path != "/" {
            if let value=try?part.resourceValues(forKeys:[.isSymbolicLinkKey]),value.isSymbolicLink==true{throw RuntimeSetupError.failed("Fixture symlink refused")}
            part.deleteLastPathComponent()
        }
    }
}
private final class GuardHTTP:URLProtocol {
    static var requests=0
    static var holding=false
    static let lock=NSLock()
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){Self.lock.lock();Self.requests+=1;let holding=Self.holding;Self.lock.unlock();if !holding{client?.urlProtocol(self,didFailWithError:URLError(.timedOut))}}
    override func stopLoading(){}
    static func count()->Int{lock.lock();defer{lock.unlock()};return requests}
    static func hold(_ value:Bool){lock.lock();holding=value;lock.unlock()}
}
private final class GuardRunner:OwnedProcessRunning {
    var calls=0
    func run(_ request:OwnedProcessRequest,cancelled:()->Bool,handoff:()->Bool,onDetachedExit:@escaping(Int32)->Void)throws->OwnedProcessResult {
        calls+=1;throw RuntimeSetupError.failed("No process is permitted in this fixture")
    }
}
private final class BusyWineRunner:OwnedProcessRunning {
    let output:Data
    var calls:[OwnedProcessRequest]=[]
    init(_ executable:URL){output=Data("12345 \(executable.path)\n".utf8)}
    func run(_ request:OwnedProcessRequest,cancelled:()->Bool,handoff:()->Bool,onDetachedExit:@escaping(Int32)->Void)throws->OwnedProcessResult {
        calls.append(request)
        guard request.executable.path=="/bin/ps" else {throw RuntimeSetupError.failed("Unexpected fixture process request")}
        return .init(output:output,exitCode:0,pid:0,handedOff:false)
    }
}
private final class Fixture {
    let base:URL, runner=GuardRunner()
    var engineID="fixture-engine",ready=true,installedHint=false
    var intentID=UUID()
    var prefix:URL
    var steam:URL{prefix.appendingPathComponent("drive_c/Steam")}
    var journalURL:URL{base.appendingPathComponent("logs/SteamSetup/last-attempt.json")}
    init(_ base:URL)throws {
        self.base=base;prefix=base.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at:steam,withIntermediateDirectories:true)
    }
    func descriptor()->PlaymeltRuntimeDescriptor {
        .init(engineID:engineID,wineURL:base.appendingPathComponent("engine/bin/wine"),wineserverURL:base.appendingPathComponent("engine/bin/wineserver"),
              prefixURL:prefix,steamRoot:steam,environment:["WINEPREFIX":prefix.path],readyEngine:ready,steamInstalled:installedHint)
    }
    func bootstrap()->SteamWindowsBootstrap {
        SteamWindowsBootstrap(downloadsRoot:base.appendingPathComponent("downloads"),descriptor:{self.descriptor()},runner:runner,
            sessionConfiguration:{let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[GuardHTTP.self];return config})
    }
    func previous(_ event:String="completed",exit:Int=1)throws->SteamInstallerJournal {
        let value=try SteamInstallerJournal(url:journalURL,descriptor:descriptor(),method:SteamBootstrapPackage.method,intentID:intentID)
        value.record(event,fields:["exitCode":exit,"handedOff":false]);return value
    }
}

@main enum SteamSetupGuardTests {
    static var checks=0
    static let fm=FileManager.default
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fatalError("FAIL: "+label)}}
    static func until(_ condition:()->Bool){let end=Date().addingTimeInterval(3);while !condition() && Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};expect(condition(),"bounded inert callback")}
    static func stop(_ bootstrap:SteamWindowsBootstrap){var stopped=false;bootstrap.shutdown{stopped=true};until{stopped}}
    static func read(_ url:URL)throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]}
    static func put(_ value:[String:Any],_ url:URL)throws{try JSONSerialization.data(withJSONObject:value).write(to:url,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    private static func blocked(_ fixture:Fixture)throws {
        let before=GuardHTTP.count(),bootstrap=fixture.bootstrap(),original=try Data(contentsOf:fixture.journalURL)
        bootstrap.start(ownerID:fixture.intentID)
        expect(bootstrap.snapshot["steamPhase"] as? String=="failed" && !bootstrap.busy,"automatic game start is terminally blocked")
        expect(GuardHTTP.count()==before && fixture.runner.calls==0,"blocked start creates no network request or process")
        expect(try Data(contentsOf:fixture.journalURL)==original,"automatic refusal leaves prior diagnostic unchanged")
        stop(bootstrap)
    }
    static func main()throws {
        let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/steam-setup-guard-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        func fixture(_ name:String)throws->Fixture{try Fixture(root.appendingPathComponent(name))}
        for (label,relative) in [("engine-wine","engine/bin/wine"),("game-wrapper-wine","PlaymeltGame.app/Contents/MacOS/wine"),("game-wrapper-server","PlaymeltGame.app/Contents/MacOS/wineserver")] {
            let f=try fixture(label),descriptor=f.descriptor()
            try put(["prefix":descriptor.prefixURL.path,"engineID":descriptor.engineID],f.base.appendingPathComponent("prefix-owner.json"))
            let wrapper=f.base.appendingPathComponent("PlaymeltGame.app")
            expect(!fm.fileExists(atPath:wrapper.path),"busy inspection does not require or create a wrapper bundle")
            let runner=BusyWineRunner(f.base.appendingPathComponent(relative))
            var blocked=false
            do {_=try SteamInstallerOperation(runner:runner).run(installer:f.base.appendingPathComponent("unused-installer.exe"),descriptor:descriptor,current:{descriptor},onDetachedExit:{_ in})}
            catch {blocked=error.localizedDescription.contains("Un programme utilise déjà Wine")}
            expect(blocked && runner.calls.count==1 && runner.calls[0].executable.path=="/bin/ps","an observed runtime, including game-category Wine, blocks setup before any installer or prefix shutdown")
            expect(!fm.fileExists(atPath:wrapper.path),"read-only process recognition never calls GameModeRuntime.ensure")
        }
        for (name,event,exit) in [("exit1","completed",1),("exit0-no-client","completed",0),("cancelled","cancelled",0),("unfinished","requested",0)] {
            let f=try fixture(name);_=try f.previous(event,exit:exit)
            try blocked(f);try blocked(f)
        }
        do {
            let f=try fixture("network-failure"),bootstrap=f.bootstrap(),before=GuardHTTP.count()
            bootstrap.start(ownerID:f.intentID);until{bootstrap.snapshot["steamPhase"] as? String=="failed"}
            expect(GuardHTTP.count()==before+1,"one first automatic attempt is allowed")
            let record=try read(f.journalURL)
            expect(record["installerSHA256"] is NSNull,"failure before download keeps an unfinalized attempt, not a fake installer hash")
            expect((record["events"] as? [[String:Any]])?.contains(where:{$0["event"] as? String=="download-failed"})==true,"network failure is persisted before another game can retry")
            stop(bootstrap);try blocked(f)
            let manual=f.bootstrap(),previousID=try read(f.journalURL)["attemptID"] as? String
            f.intentID=UUID();manual.start(ownerID:f.intentID);until{manual.snapshot["steamPhase"] as? String=="failed"}
            expect(GuardHTTP.count()==before+2,"explicit Settings repair may make one new attempt")
            expect(try read(f.journalURL)["attemptID"] as? String != previousID,"manual repair receives a fresh correlated attempt")
            stop(manual);try blocked(f)
        }
        do {
            let f=try fixture("cancelled-download"),bootstrap=f.bootstrap(),before=GuardHTTP.count()
            GuardHTTP.hold(true)
            bootstrap.start(ownerID:f.intentID);until{GuardHTTP.count()==before+1}
            var stopped=false;bootstrap.cancel{stopped=true};until{stopped};GuardHTTP.hold(false)
            expect((try read(f.journalURL)["events"] as? [[String:Any]])?.contains(where:{$0["event"] as? String=="cancelled"})==true,"download cancellation persists its nonfinal result")
            stop(bootstrap);try blocked(f)
        }
        do {
            let f=try fixture("cancel-before-session"),bootstrap=f.bootstrap(),before=GuardHTTP.count();var cancelled=false
            bootstrap.onChange={
                if bootstrap.snapshot["steamPhase"] as? String=="downloading" {
                    bootstrap.onChange=nil;bootstrap.cancel{cancelled=true}
                }
            }
            bootstrap.start(ownerID:f.intentID);until{cancelled}
            expect(GuardHTTP.count()==before && !bootstrap.busy,"cancellation from the initial callback cannot create a late session")
            stop(bootstrap);try blocked(f)
        }
        do {
            let f=try fixture("context"),journal=try f.previous()
            journal.record("stopped",fields:["reason":"PRIVATE_RAW_MESSAGE token=secret","errorType":"FixtureError",
                "accountID":"PRIVATE_ACCOUNT","matchingProcesses":["PRIVATE_PROCESS_ARGUMENTS"]])
            let raw=String(decoding:try Data(contentsOf:f.journalURL),as:UTF8.self)
            expect(!raw.contains("PRIVATE_"),"new journal events never store account, raw reason or raw process strings")
            for _ in 0..<100{journal.record("stopped",fields:["errorType":"FixtureError"])}
            expect((try read(f.journalURL)["events"] as? [[String:Any]])?.count==16,"event history stays bounded")
            expect(try Data(contentsOf:f.journalURL).count<=32*1024,"journal stays within32KB")
            f.engineID="another-engine"
            let bootstrap=f.bootstrap(),before=GuardHTTP.count();bootstrap.start(ownerID:f.intentID);until{bootstrap.snapshot["steamPhase"] as? String=="failed"}
            expect(GuardHTTP.count()==before+1,"another exact engine context is not mistaken for the failed context")
            stop(bootstrap)
            let oldSession=f.steam.appendingPathComponent("config/loginusers.vdf"),sentinel=Data("fixture-session-kept".utf8)
            try fm.createDirectory(at:oldSession.deletingLastPathComponent(),withIntermediateDirectories:true);try sentinel.write(to:oldSession)
            f.prefix=f.base.appendingPathComponent("another-prefix");try fm.createDirectory(at:f.steam,withIntermediateDirectories:true)
            let other=f.bootstrap(),previous=GuardHTTP.count();other.start(ownerID:f.intentID);until{other.snapshot["steamPhase"] as? String=="failed"}
            expect(GuardHTTP.count()==previous+1 && !fm.fileExists(atPath:f.steam.appendingPathComponent("config/loginusers.vdf").path),"another prefix is independently prepared without copying credentials")
            expect(try Data(contentsOf:oldSession)==sentinel,"existing fixture session content remains unchanged")
            stop(other)
        }
        for stamp in ["1970-01-01T00:00:00Z","2999-01-01T00:00:00Z"] {
            let f=try fixture("time-"+UUID().uuidString);_=try f.previous()
            var record=try read(f.journalURL);record["events"]=[["event":"completed","time":stamp,"exitCode":1]];try put(record,f.journalURL)
            try blocked(f)
        }
        do {
            let f=try fixture("fresh-client-priority");_=try f.previous()
            // An inert MZ file in this temporary fixture exercises the real disk
            // header check. It is not a client installation or a runtime claim.
            try Data([0x4d,0x5a]).write(to:f.steam.appendingPathComponent("steam.exe"));f.installedHint=false;f.ready=false
            let bootstrap=f.bootstrap(),before=GuardHTTP.count();var observed=0;bootstrap.onInstalled={observed+=1};bootstrap.start(ownerID:UUID())
            expect(bootstrap.snapshot["steamPhase"] as? String=="ready" && observed==1,"fresh MZ disk evidence takes priority over old failed setup and stale flag")
            expect(GuardHTTP.count()==before && f.runner.calls==0,"existing Windows client reuse invokes no installer or network")
            stop(bootstrap)
        }
        do {
            let f=try fixture("client-before-invalid-journal");_=try f.previous();try Data("{invalid".utf8).write(to:f.journalURL)
            let original=try Data(contentsOf:f.journalURL);try Data([0x4d,0x5a]).write(to:f.steam.appendingPathComponent("steam.exe"))
            let bootstrap=f.bootstrap(),before=GuardHTTP.count();bootstrap.start(ownerID:UUID())
            expect(bootstrap.snapshot["steamPhase"] as? String=="ready" && GuardHTTP.count()==before,"a disk client is reused before reading an invalid setup diagnostic")
            expect(try Data(contentsOf:f.journalURL)==original,"client reuse never repairs or overwrites unrelated diagnostic bytes")
            stop(bootstrap)
        }
        do {
            let f=try fixture("stale-client-flag");_=try f.previous();f.installedHint=true
            try blocked(f)
            let target=f.base.appendingPathComponent("outside-fixture-mz.exe");try Data([0x4d,0x5a]).write(to:target)
            try fm.createSymbolicLink(at:f.steam.appendingPathComponent("steam.exe"),withDestinationURL:target)
            try blocked(f)
        }
        let invalid=try fixture("invalid-record");_=try invalid.previous();let valid=try read(invalid.journalURL)
        for change in [
            { (r:inout [String:Any]) in r["schema"]=2 },
            { (r:inout [String:Any]) in r["schema"]=true },
            { (r:inout [String:Any]) in r["owner"]="foreign-owner" },
            { (r:inout [String:Any]) in r["prefix"]="relative-prefix" },
            { (r:inout [String:Any]) in r["attemptID"]="invalid" },
            { (r:inout [String:Any]) in r["token"]="must-not-be-read-as-control" },
            { (r:inout [String:Any]) in r["events"]=[["event":"unknown","time":"2026-11-13T00:00:00Z"]] }
        ] {
            var record=valid;change(&record);try put(record,invalid.journalURL);try blocked(invalid)
        }
        do {
            var foreign=valid;foreign["owner"]="foreign-owner";try put(foreign,invalid.journalURL)
            let before=GuardHTTP.count(),original=try Data(contentsOf:invalid.journalURL),manual=invalid.bootstrap();manual.start()
            expect(manual.snapshot["steamPhase"] as? String=="failed" && GuardHTTP.count()==before,"manual repair never bypasses journal ownership validation")
            expect(try Data(contentsOf:invalid.journalURL)==original,"foreign journal remains unchanged during explicit repair")
            stop(manual)
        }
        try Data(repeating:65,count:32*1024+1).write(to:invalid.journalURL);try blocked(invalid)
        try Data("{malformed".utf8).write(to:invalid.journalURL);try blocked(invalid)
        try put(valid,invalid.journalURL);try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath:invalid.journalURL.path);try blocked(invalid)
        try put(valid,invalid.journalURL)
        let linked=try fixture("linked-record"),target=invalid.journalURL
        try fm.createDirectory(at:linked.journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:linked.journalURL,withDestinationURL:target);try blocked(linked)
        let hard=try fixture("hard-linked-record")
        try fm.createDirectory(at:hard.journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.linkItem(at:target,to:hard.journalURL);try blocked(hard)
        let ancestor=try fixture("ancestor-link")
        try fm.createSymbolicLink(at:ancestor.base.appendingPathComponent("logs"),withDestinationURL:invalid.base.appendingPathComponent("logs"));try blocked(ancestor)
        do {
            let f=try fixture("late-event"),earlier=try f.previous()
            _=try SteamInstallerJournal(url:f.journalURL,descriptor:f.descriptor())
            let replacement=try Data(contentsOf:f.journalURL)
            earlier.record("completed",fields:["exitCode":9,"handedOff":false])
            expect(try Data(contentsOf:f.journalURL)==replacement,"an allowed late old event cannot overwrite explicit replacement")
        }
        expect(GuardHTTP.count()>0,"only isolated URLProtocol failures were exercised")
        print("\(checks) persistent Steam setup guard checks passed; CPU/filesystem/URLProtocol doubles only, no real network, Wine, Steam, client or game executed")
    }
}
