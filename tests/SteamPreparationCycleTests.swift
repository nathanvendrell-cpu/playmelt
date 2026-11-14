import Foundation
import Darwin

private final class CycleHTTP:URLProtocol {
    enum Mode {case hold,fail,installer}
    static let lock=NSLock()
    static var mode:Mode = .hold,requests=0,stops=0
    static func configure(_ mode:Mode,reset:Bool=true){lock.lock();Self.mode=mode;if reset{requests=0;stops=0};lock.unlock()}
    static func counts()->(Int,Int){lock.lock();defer{lock.unlock()};return(requests,stops)}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.lock.lock();Self.requests+=1;let mode=Self.mode;Self.lock.unlock()
        switch mode {
        case .hold:break
        case .fail:client?.urlProtocol(self,didFailWithError:URLError(.timedOut))
        case .installer:
            let bytes=Data([0x4d,0x5a])+Data(repeating:0,count:1024)
            let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Length":String(bytes.count)])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading(){Self.lock.lock();Self.stops+=1;Self.lock.unlock()}
}
private final class CycleRunner:OwnedProcessRunning {
    let lock=NSLock();private var calls:[OwnedProcessRequest]=[]
    func requests()->[OwnedProcessRequest]{lock.lock();defer{lock.unlock()};return calls}
    func run(_ request:OwnedProcessRequest,cancelled:()->Bool,handoff:()->Bool,onDetachedExit:@escaping(Int32)->Void)throws->OwnedProcessResult {
        lock.lock();calls.append(request);lock.unlock()
        if cancelled(){throw OwnedProcessError.cancelled}
        // No executable is run. Malformed source data must fail before any
        // extraction or legacy installer could be invoked.
        return .init(output:Data(),exitCode:0,pid:0,handedOff:false)
    }
}
@main enum Tests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fatalError("FAIL "+label)}}
    static func until(_ done:()->Bool){let deadline=Date().addingTimeInterval(5);while !done() && Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};expect(done(),"bounded callback")}
    static func main()throws{
        let fm=FileManager.default,root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/steam-cycle-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        func fixture(_ name:String)throws->(SteamWindowsBootstrap,CycleRunner,URL){
            let base=root.appendingPathComponent(name),prefix=base.appendingPathComponent("prefix"),steam=prefix.appendingPathComponent("drive_c/Steam")
            try fm.createDirectory(at:steam,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["prefix":prefix.path,"engineID":"fixture"]).write(to:base.appendingPathComponent("prefix-owner.json"))
            let runner=CycleRunner()
            let bootstrap=SteamWindowsBootstrap(downloadsRoot:base.appendingPathComponent("downloads"),descriptor:{
                .init(engineID:"fixture",wineURL:base.appendingPathComponent("engine/bin/wine"),wineserverURL:base.appendingPathComponent("engine/bin/wineserver"),prefixURL:prefix,steamRoot:steam,environment:["WINEPREFIX":prefix.path],readyEngine:true,steamInstalled:fm.fileExists(atPath:steam.appendingPathComponent("steam.exe").path))
            },runner:runner,sessionConfiguration:{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[CycleHTTP.self];return c})
            return(bootstrap,runner,steam)
        }
        func shutdown(_ bootstrap:SteamWindowsBootstrap){var done=false;bootstrap.shutdown{done=true};until{done}}
        do{
            CycleHTTP.configure(.fail);let (bootstrap,_,_)=try fixture("network-failure"),intent=SteamBootstrapIntent(ownerID:UUID(),bootstrap:bootstrap)
            _=intent.poll();until{bootstrap.snapshot["steamPhase"] as? String == "failed"}
            for _ in 0..<10{if case .stopped = intent.poll(){}else{expect(false,"network failure is terminal")}}
            expect(CycleHTTP.counts().0==1,"timer polling cannot redownload after network failure")
            var done=false;intent.cancel{done=true};until{done};expect(!bootstrap.busy,"failed attempt cleanup finished");shutdown(bootstrap)
        }
        do{
            CycleHTTP.configure(.installer);let (bootstrap,runner,_)=try fixture("invalid-manifest"),intent=SteamBootstrapIntent(ownerID:UUID(),bootstrap:bootstrap)
            _=intent.poll();until{bootstrap.snapshot["steamPhase"] as? String == "failed"}
            for _ in 0..<10{_=intent.poll()}
            expect(CycleHTTP.counts().0==1,"invalid manifest cannot redownload on polling")
            expect(runner.requests().isEmpty,"invalid manifest invokes no extraction, Wine or installer")
            let journalURL=root.appendingPathComponent("invalid-manifest/logs/SteamSetup/last-attempt.json")
            let diagnostic=try JSONSerialization.jsonObject(with:Data(contentsOf:journalURL)) as! [String:Any]
            let events=diagnostic["events"] as! [[String:Any]]
            expect(diagnostic["installerSHA256"] is NSNull,"invalid manifest never produces an invented archive hash")
            expect(events.contains{$0["event"] as? String == "stopped"},"invalid source stops without any installation success claim")
            expect(diagnostic["stdoutCaptured"] as? Bool==false && diagnostic["stderrCaptured"] as? Bool==false && diagnostic["signalFromWaitStatusAvailable"] as? Bool==false,"diagnostic limits are explicit and preserve null handoff streams")
            expect(diagnostic["environment"]==nil && diagnostic["arguments"]==nil && diagnostic["accountID"]==nil,"diagnostic excludes environment, arguments and account credentials")
            expect((try fm.attributesOfItem(atPath:journalURL.path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"attempt journal is private")
            expect((try fm.attributesOfItem(atPath:journalURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue==0o700,"atomic journal writes stay in a private directory")
            let diagnosticInstaller=root.appendingPathComponent("diagnostic-fixture.exe")
            try Data([0x4d,0x5a]).write(to:diagnosticInstaller)
            let descriptor=PlaymeltRuntimeDescriptor(engineID:"fixture",wineURL:root.appendingPathComponent("wine"),wineserverURL:root.appendingPathComponent("wineserver"),prefixURL:root.appendingPathComponent("prefix"),steamRoot:root.appendingPathComponent("Steam"),environment:["PRIVATE_FIXTURE":"never recorded"],readyEngine:true,steamInstalled:false)
            let earlier=try SteamInstallerJournal(url:journalURL,installer:diagnosticInstaller,descriptor:descriptor)
            _=try SteamInstallerJournal(url:journalURL,installer:diagnosticInstaller,descriptor:descriptor)
            let currentJournal=try Data(contentsOf:journalURL)
            earlier.record("late-detached-exit",fields:["exitCode":9])
            expect(try Data(contentsOf:journalURL)==currentJournal,"a late old attempt cannot overwrite the newer diagnostic")
            var done=false;intent.cancel{done=true};until{done};shutdown(bootstrap)
        }
        do{
            CycleHTTP.configure(.hold);let (bootstrap,_,_)=try fixture("download-cancel"),intent=SteamBootstrapIntent(ownerID:UUID(),bootstrap:bootstrap)
            _=intent.poll();until{CycleHTTP.counts().0==1}
            var done=false;intent.cancel{done=true};until{done}
            expect(CycleHTTP.counts().1>=1 && !bootstrap.busy,"cancel completion waits for owned network stop")
            for _ in 0..<10{_=intent.poll()};expect(CycleHTTP.counts().0==1,"cancelled timer cannot start a new download");shutdown(bootstrap)
        }
        do{
            CycleHTTP.configure(.hold);let (bootstrap,_,_)=try fixture("manual-bootstrap")
            bootstrap.start();until{CycleHTTP.counts().0==1}
            let unrelated=SteamBootstrapIntent(ownerID:UUID(),bootstrap:bootstrap);_=unrelated.poll()
            var done=false;unrelated.cancel{done=true};until{done}
            expect(bootstrap.busy && CycleHTTP.counts().1==0,"intent cancellation preserves an unrelated manual bootstrap");shutdown(bootstrap)
        }
        do{
            CycleHTTP.configure(.fail);let (bootstrap,_,_)=try fixture("manual-replacement"),intent=SteamBootstrapIntent(ownerID:UUID(),bootstrap:bootstrap)
            _=intent.poll();until{bootstrap.snapshot["steamPhase"] as? String == "failed"}
            CycleHTTP.configure(.hold,reset:false);bootstrap.start();until{CycleHTTP.counts().0==2}
            let stops=CycleHTTP.counts().1
            var done=false;intent.cancel{done=true};until{done}
            expect(bootstrap.busy && CycleHTTP.counts().1==stops,"old intention cannot cancel a manual replacement attempt")
            shutdown(bootstrap)
        }
        do{
            CycleHTTP.configure(.hold);let (bootstrap,runner,steam)=try fixture("user-client")
            try Data([0x4d,0x5a]).write(to:steam.appendingPathComponent("steam.exe"))
            let intent=SteamBootstrapIntent(ownerID:UUID(),bootstrap:bootstrap);expect(intent.poll() == .ready,"existing user client is handed off")
            var done=false;intent.cancel{done=true};until{done}
            expect(runner.requests().isEmpty && CycleHTTP.counts().0==0,"cancel cannot stop or reinstall the transferred user client")
            expect(fm.fileExists(atPath:steam.appendingPathComponent("steam.exe").path),"user client remains intact");shutdown(bootstrap)
        }
        print("\(checks) Steam preparation lifecycle checks passed; no real network, Steam, Wine or game executed")
    }
}
