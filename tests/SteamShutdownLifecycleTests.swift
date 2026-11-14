// run_steam_shutdown_lifecycle.py injects the real main.swift beginShutdown()
// into this inert harness. The real coordinator/journal executes; no app, UI,
// process launcher, Steam, credentials, Wine, account or network is instantiated.
import Foundation
import CryptoKit

struct Runtime {let id:String,platform:String,steamRoot:URL;var prefixURL:URL?=nil}
enum LibraryModel {
    static func validAppID(_ id:String)->Bool {!id.isEmpty && id.count<=10 && id.allSatisfy(\.isNumber) && UInt32(id).map{$0>0} == true}
    static func validAccountID(_ id:String)->Bool {id.count==17 && id.allSatisfy(\.isNumber) && UInt64(id) != nil}
}
enum TextVDF {static func read(_ url:URL)->[String:Any]{[:]}}
extension Dictionary where Key==String,Value==Any {
    func string(_ key:String)->String {self[key] as? String ?? ""}
    func object(_ key:String)->[String:Any] {self[key] as? [String:Any] ?? [:]}
}
func steamInstallationPath(apps:URL,directory:String)->URL?{nil}
func containsLaunchBinary(_ path:URL,platform:String)->Bool{false}
final class SteamInstallObserver {
    static var starts=0
    init(runtime:Runtime,appID:String,accountID:String,timeout:TimeInterval,deliver:@escaping(SteamInstallObservation,Bool,Bool)->Void){Self.starts+=1}
    func stop(){}
}
final class Calls {var values=[String]()}
final class InertDependency {
    let name:String,calls:Calls
    var onClose:(()->Void)?
    init(_ name:String,_ calls:Calls){self.name=name;self.calls=calls}
    func closePanel(){calls.values.append(name+".close");onClose?()}
    func close(){calls.values.append(name+".close")}
    func shutdown(){calls.values.append(name+".shutdown")}
    func cancel(){calls.values.append(name+".cancel")}
    func stop(){calls.values.append(name+".stop")}
}
enum XboxCloudWindowController {static var shared=InertDependency("xbox",Calls())}
final class ShutdownHarness {
    var closing=false,queuedSteamInstall:UUID?=UUID(),scanID=UUID()
    var afterRefresh=[()->Void]()
    let installCoordinator:SteamInstallCoordinator,calls:Calls
    let gameMediaPlayer:InertDependency,gameMedia:InertDependency
    let hubBrowser:InertDependency,accountService:InertDependency,accountWebAuthentication:InertDependency
    let localGameImport:InertDependency,benchmarks:InertDependency,requestGate:InertDependency,clientLauncher:InertDependency,steamClientLifecycle:InertDependency
    var authentication:InertDependency?
    init(_ coordinator:SteamInstallCoordinator){
        installCoordinator=coordinator;calls=Calls()
        gameMediaPlayer=InertDependency("gameMediaPlayer",calls);gameMedia=InertDependency("gameMedia",calls);hubBrowser=InertDependency("hub",calls);accountService=InertDependency("account",calls)
        accountWebAuthentication=InertDependency("accountWeb",calls);localGameImport=InertDependency("localImport",calls)
        benchmarks=InertDependency("benchmarks",calls);requestGate=InertDependency("gate",calls)
        steamClientLifecycle=InertDependency("steamLifecycle",calls);clientLauncher=InertDependency("clients",calls);authentication=InertDependency("authentication",calls)
        XboxCloudWindowController.shared=InertDependency("xbox",calls)
    }
    func cancelOfficialSteamPreparation(){calls.values.append("official.stop")}
    func stopNativeInstaller(){calls.values.append("ownedInstaller.stop")}
    // @PRODUCTION_BEGIN_SHUTDOWN@
}
@main enum SteamShutdownLifecycleTests {
    enum Failure:Error {case assertion(String)}
    static var checks=0
    static let account="76561198000000001",other="76561198000000002",fm=FileManager.default
    static func check(_ condition:Bool,_ label:String)throws{checks+=1;if !condition{throw Failure.assertion(label)}}
    static func read(_ url:URL)throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]}
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),payload=root.appendingPathComponent("Payload With Spaces")
        try fm.createDirectory(at:payload,withIntermediateDirectories:true)
        let sentinel=payload.appendingPathComponent("kept.bin"),bytes=Data("unchanged fixture payload".utf8);try bytes.write(to:sentinel)
        let digest=SHA256.hash(data:Data(payload.resolvingSymlinksInPath().path.utf8)).map{String(format:"%02x",$0)}.joined(),game="steam:10:local:"+digest
        let url=root.appendingPathComponent("prepared/installation-state.json"),coordinator=SteamInstallCoordinator(recoveryURL:url)
        let id=coordinator.beginPreparedFiles(gameID:game,appID:"10",title:"Shutdown Fixture",accountID:account,runtimeID:"playmelt-d3dmetal",autoLaunch:true)!
        coordinator.updatePreparedStage(id:id,status:"preparing-files",message:"Owned file preparation in progress")
        let before=SteamInstallObserver.starts,harness=ShutdownHarness(coordinator),scan=harness.scanID
        var cancelCalls=0,lateExecution=0;coordinator.onCancel={cancelCalls+=1}
        harness.afterRefresh.append{lateExecution+=1}
        harness.hubBrowser.onClose={if !harness.closing{lateExecution+=1;_=coordinator.finishDirect(id:id,success:true,message:"Unwanted close callback")}}
        harness.beginShutdown()
        try check(harness.closing && lateExecution==0,"closing guard is active before panel close callbacks")
        try check(cancelCalls==0,"application shutdown never invokes explicit coordinator cancellation")
        try check(harness.queuedSteamInstall==nil && harness.afterRefresh.isEmpty && harness.scanID != scan,"shutdown invalidates queued work and refresh correlation")
        try check(harness.authentication==nil,"authentication owner is released after shutdown")
        try check(Set(harness.calls.values)==Set(["hub.close","gameMediaPlayer.close","gameMedia.shutdown","xbox.close","official.stop","account.shutdown","accountWeb.cancel","localImport.cancel","benchmarks.stop","gate.shutdown","ownedInstaller.stop","clients.shutdown","steamLifecycle.shutdown","authentication.shutdown"]),"production shutdown still stops every beginShutdown-owned dependency")
        let calls=harness.calls.values;harness.beginShutdown()
        try check(harness.calls.values==calls,"repeated shutdown is idempotent")
        let record=try read(url)
        try check(record["status"] as? String=="preparing-files" && (record["error"] as? [String:Any])?["code"] as? String != "cancelled","persisted nonterminal checkpoint is never replaced with user cancellation")
        try check(!coordinator.isActive && coordinator.retryContext(jobID:id.uuidString,selectedAccount:account)==nil,"closed live coordinator grants no new work")
        try check(!coordinator.finishDirect(id:id,success:true,message:"Late callback"),"queued completion cannot mutate shutdown checkpoint")
        coordinator.updatePreparedStage(id:id,status:"awaiting-steam",message:"Late callback")
        try check(try read(url)["status"] as? String=="preparing-files","late preparation callback leaves journal intact")
        let restored=SteamInstallCoordinator(recoveryURL:url);defer{restored.shutdown()}
        try check(restored.snapshot?["status"] as? String=="interrupted" && restored.snapshot?["gameId"] as? String==game,"reload restores the same interrupted local payload")
        try check(!restored.isActive && restored.snapshot?["autoLaunch"] as? Bool==false && SteamInstallObserver.starts==before,"reload performs no execution, observer or autoplay")
        try check((restored.snapshot?["recovery"] as? [String:Any])?["canRetry"] as? Bool==true,"interrupted work offers an explicit recovery action")
        try check(restored.retryContext(jobID:id.uuidString,selectedAccount:other)==nil,"recovery still rejects stale account")
        restored.updatePreparedStage(id:id,status:"preparing-client",message:"Unvalidated callback")
        try check(restored.snapshot?["status"] as? String=="interrupted","reload alone cannot resume preparation")
        let context=restored.retryContext(jobID:id.uuidString,selectedAccount:account)
        try check(context?.gameID==game && context?.runtimeID=="playmelt-d3dmetal" && context?.autoLaunch==false,"explicit recovery keeps context and disabled autoplay")
        restored.updatePreparedStage(id:id,status:"preparing-client",message:"Explicit foreground action")
        restored.updatePreparedStage(id:id,status:"awaiting-steam",message:"Explicit foreground handoff")
        let runtime=Runtime(id:"playmelt-d3dmetal",platform:"windows",steamRoot:root.appendingPathComponent("unused-steam"))
        let handed=restored.begin(gameID:game,appID:"10",title:"Recovered",runtime:runtime,accountID:account,autoLaunch:true,onReady:{_ in lateExecution+=1})
        try check(handed==id && restored.snapshot?["autoLaunch"] as? Bool==false,"only explicit action creates observer and keeps original UUID without autoplay")
        try check(SteamInstallObserver.starts==before+1 && lateExecution==0,"explicit observer creation does not execute a launch")
        var realCancel=0;restored.onCancel={realCancel+=1};restored.cancel()
        try check(realCancel==1 && restored.snapshot?["status"] as? String=="cancelled","real cancellation remains terminal and invokes cancellation cleanup")
        let cancelledHarness=ShutdownHarness(restored);cancelledHarness.beginShutdown()
        try check(realCancel==1 && (try read(url))["status"] as? String=="cancelled","closing after real cancellation neither repeats cancellation nor revives the job")
        try check(SteamInstallCoordinator(recoveryURL:url).snapshot==nil,"explicitly cancelled work never restores")
        try check(try Data(contentsOf:sentinel)==bytes,"shutdown, restore and explicit cancel never alter payload bytes")
        let directURL=root.appendingPathComponent("direct/installation-state.json"),direct=SteamInstallCoordinator(recoveryURL:directURL)
        let directID=direct.beginDirect(gameID:game,appID:"10",title:"Direct",accountID:account,runtimeID:"playmelt-windows",autoLaunch:true)!
        direct.updateDirect(id:directID,status:"downloading",message:"Measured",progress:nil,downloaded:4,total:10)
        ShutdownHarness(direct).beginShutdown()
        let directReload=SteamInstallCoordinator(recoveryURL:directURL);defer{directReload.shutdown()}
        try check(directReload.snapshot?["status"] as? String=="interrupted" && directReload.snapshot?["autoLaunch"] as? Bool==false,"download shutdown also restores interrupted without autoplay")
        try check(directReload.beginDirect(gameID:game,appID:"10",title:"New explicit action",accountID:account,runtimeID:"playmelt-windows") != nil,"a new explicit action is possible after reopen")
        let failedURL=root.appendingPathComponent("failed/installation-state.json"),failed=SteamInstallCoordinator(recoveryURL:failedURL)
        let failedID=failed.beginDirect(gameID:game,appID:"10",title:"Failure",accountID:account,runtimeID:"playmelt-windows")!
        _=failed.finishDirect(id:failedID,success:false,message:"Fixture failure",code:"network",retryable:true)
        ShutdownHarness(failed).beginShutdown();let failedReload=SteamInstallCoordinator(recoveryURL:failedURL)
        try check(failedReload.snapshot?["status"] as? String=="failed" && failedReload.retryContext(jobID:failedID.uuidString,selectedAccount:account) != nil,"existing retryable failure survives close without becoming cancelled")
        failedReload.shutdown()
        print("\(checks) production shutdown lifecycle checks passed; actual extracted main method, coordinator/journals and inert dependencies only; no UI/Steam/Wine/network")
    }
}
