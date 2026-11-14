// Compile with SteamInstallCoordinator.swift only. All dependencies below are
// inert fixture boundaries: no observer, Steam, downloader or process is run.
import Foundation

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
    static var lastPrefix:URL?
    init(runtime:Runtime,appID:String,accountID:String,timeout:TimeInterval,deliver:@escaping(SteamInstallObservation,Bool,Bool)->Void){Self.starts+=1;Self.lastPrefix=runtime.prefixURL}
    func stop(){}
}

@main enum SteamCachedPayloadPipelineTests {
    static var checks=0
    static let account="76561198000000001",other="76561198000000002"
    static func expect(_ condition:Bool,_ label:String){checks+=1;if !condition{fatalError("FAIL: "+label)}}
    static func main()throws {
        let fm=FileManager.default,root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/cached-payload-fixture-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        let journal=root.appendingPathComponent("state/installation-state.json"),coordinator=SteamInstallCoordinator(recoveryURL:journal)
        defer{coordinator.shutdown()}
        func repairs(store:String="steam",installed:Bool=true,complete:Bool=true,platform:String="windows",native:Bool=false,marker:Bool=true,valid:Bool=true)->Bool {
            SteamInstallCoordinator.needsWindowsPayloadRepair(store:store,installed:installed,complete:complete,platform:platform,nativePreferred:native,payloadMarkerPresent:marker,payloadManifestValid:valid)
        }
        expect(!repairs(),"ready valid payload never returns to the Mac depot downloader")
        expect(repairs(valid:false),"invalid launch manifest or missing target enters checkpoint repair")
        expect(repairs(complete:false,marker:false,valid:false),"incomplete Windows installation enters repair instead of an impossible launch")
        expect(!repairs(platform:"mac",valid:false),"Mac installation never enters Windows payload repair")
        expect(!repairs(native:true,valid:false),"explicit/default native preference keeps the native route")
        expect(!repairs(store:"epic",valid:false) && !repairs(store:"gog",valid:false),"Epic and GOG do not enter the Steam repair path")
        expect(!repairs(marker:false,valid:false),"complete regular Steam installation without a payload marker is left unchanged")
        expect(!repairs(installed:false,valid:false),"new installs keep their normal acquisition entry")
        let repair=SteamInstallCoordinator(),repairID=repair.beginDirect(gameID:"steam:10",appID:"10",title:"Broken target",accountID:account,runtimeID:"playmelt-windows",autoLaunch:true)!
        expect(repair.permitsPayloadRepair(id:repairID,appID:"10",accountID:account,runtimeID:"playmelt-windows",needsRepair:repairs(valid:false)),"active repair can revalidate a broken target even when another binary left complete=true")
        expect(!repair.permitsPayloadRepair(id:repairID,appID:"10",accountID:account,runtimeID:"playmelt-windows",needsRepair:false),"a correct complete payload cannot use the repair exception")
        expect(!repair.permitsPayloadRepair(id:repairID,appID:"10",accountID:other,runtimeID:"playmelt-windows",needsRepair:true),"repair exception refuses another account")
        expect(!repair.permitsPayloadRepair(id:repairID,appID:"10",accountID:account,runtimeID:"playmelt-d3dmetal",needsRepair:true),"repair exception refuses another environment")
        repair.cancel()
        expect(!repair.permitsPayloadRepair(id:repairID,appID:"10",accountID:account,runtimeID:"playmelt-windows",needsRepair:true),"cancelled repair loses the duplicate-install exception")
        repair.shutdown()
        let runtime=Runtime(id:"playmelt-d3dmetal",platform:"windows",steamRoot:root.appendingPathComponent("client"),prefixURL:root.appendingPathComponent("dx12-prefix"))
        let id=coordinator.beginPreparedFiles(gameID:"steam:1903340",appID:"1903340",title:"Cached fixture",accountID:account,runtimeID:runtime.id,autoLaunch:true)!
        expect(!coordinator.isActive && !coordinator.acceptsDirect(id:id),"cached entry releases the direct/download token before official preparation")
        expect(coordinator.acceptsPrepared(id:id,accountID:account,runtimeID:runtime.id),"same game/account/runtime retain one cancellable post-stage")
        expect(coordinator.snapshot?["status"] as? String == "preparing-client","cached entry starts at client preparation")
        expect(coordinator.snapshot?["autoLaunch"] as? Bool == true,"explicit install-and-play intent survives the handoff")
        expect(SteamInstallObserver.starts == 0,"cached entry creates no observer or download")
        expect((coordinator.snapshot?["stages"] as? [[String:Any]])?.contains(where:{$0["id"] as? String == "download"}) == false,"cached entry invents no downloaded bytes or completed download stage")
        expect(!coordinator.acceptsPrepared(id:id,accountID:other,runtimeID:runtime.id),"late authorization from another account is refused")
        expect(!coordinator.acceptsPrepared(id:id,accountID:account,runtimeID:"playmelt-windows"),"late callback for another engine is refused")
        expect(!coordinator.configurePreparedFiles(id:id,accountID:other,runtimeID:runtime.id),"wrong account cannot reconfigure preserved files")
        expect(coordinator.beginPreparedFiles(gameID:"steam:20",appID:"20",title:"Second",accountID:account,runtimeID:runtime.id,autoLaunch:true) == nil,"second game cannot replace a pending preparation")
        coordinator.updatePreparedStage(id:id,status:"awaiting-account",message:"Official client requires its initial login")
        coordinator.updatePreparedStage(id:id,status:"preparing-files",message:"Reuse preserved payload")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:"d3dmetal"),"a completed local payload cannot skip official preparation before awaiting-steam")
        coordinator.updatePreparedStage(id:id,status:"awaiting-steam",message:"Official verification")
        expect(coordinator.snapshot?["id"] as? String == id.uuidString && !coordinator.isActive,"login and reuse keep the same tokenless job")
        expect(coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:"d3dmetal"),"complete preserved Windows payload can enter official followup instead of duplicate-install rejection")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:"steam-mac",platform:"mac",renderer:"native",payloadRenderer:nil),"complete native Mac installation keeps duplicate-install rejection")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:nil),"a complete game without an official-required payload gets no exception")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:other,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:"d3dmetal"),"another account cannot adopt the complete payload")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:"playmelt-windows",platform:"windows",renderer:"dxmt",payloadRenderer:"dxmt"),"another runtime cannot adopt the complete payload")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:"dxmt"),"payload renderer must match the actual runtime")
        expect(!coordinator.permitsPreparedFollowup(appID:"20",accountID:account,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:"d3dmetal"),"a second game cannot use the first game's exception")
        let followed=coordinator.begin(gameID:"steam:1903340:playmelt-d3dmetal",appID:"1903340",title:"Discovered",runtime:runtime,accountID:account,onReady:{_ in})
        expect(followed == id && coordinator.acceptsDirect(id:id),"official manifest observation inherits the original job UUID")
        expect(!coordinator.permitsPreparedFollowup(appID:"1903340",accountID:account,runtimeID:runtime.id,platform:"windows",renderer:"d3dmetal",payloadRenderer:"d3dmetal"),"the handoff exception ends when the observer owns the token")
        expect(SteamInstallObserver.starts == 1 && SteamInstallObserver.lastPrefix == runtime.prefixURL,"observer receives the selected environment without a different prefix")
        coordinator.receive(.init(status:"validating",message:"Official verification",ready:true,signature:"fixture"),id:id,onReady:{_ in})
        coordinator.receive(.init(status:"validating",message:"Official verification",ready:true,signature:"fixture"),id:id,onReady:{_ in})
        expect(coordinator.confirmLaunchContext(id:id,accountChanged:false,executionBlocked:false),"two official observations permit a fresh launch check")
        coordinator.didRequestLaunch(id:id,success:true,message:"Fixture dispatch only")
        expect(!coordinator.isActive && coordinator.snapshot?["status"] as? String == "launch-requested","dispatch completion ends the first job")
        let second=coordinator.beginPreparedFiles(gameID:"steam:20",appID:"20",title:"Second",accountID:account,runtimeID:runtime.id,autoLaunch:true)!
        expect(second != id && coordinator.acceptsPrepared(id:second,accountID:account,runtimeID:runtime.id),"next game gets its own job in the same existing environment")
        var cancelled=0;coordinator.onCancel={cancelled+=1};coordinator.cancel()
        expect(cancelled == 1 && !coordinator.acceptsPrepared(id:second,accountID:account,runtimeID:runtime.id),"cancellation retires the post-stage and its authorization callbacks")
        expect(!coordinator.configurePreparedFiles(id:second,accountID:account,runtimeID:runtime.id),"late renderer/preparation callback cannot revive cancellation")
        coordinator.updatePreparedStage(id:second,status:"awaiting-steam",message:"Late")
        expect(coordinator.snapshot?["status"] as? String == "cancelled" && coordinator.snapshot?["autoLaunch"] as? Bool == false,"cancelled work never resumes or autoplays")
        let third=coordinator.beginPreparedFiles(gameID:"steam:30",appID:"30",title:"Missing engine fixture",accountID:account,runtimeID:"playmelt-windows",autoLaunch:true)!
        expect(coordinator.configurePreparedFiles(id:third,accountID:account,runtimeID:"playmelt-d3dmetal"),"concrete renderer can be selected before an engine is available")
        coordinator.finishDirect(id:third,success:false,message:"Missing engine",code:"engine-not-ready",retryable:true,resumePoint:"official-steam-windows")
        expect(coordinator.retryContext(jobID:third.uuidString,selectedAccount:account) != nil,"engine failure preserves an explicit retry without a download token")
        let restored=SteamInstallCoordinator(recoveryURL:journal);defer{restored.shutdown()}
        expect(!restored.isActive && restored.snapshot?["autoLaunch"] as? Bool == false,"startup restoration starts nothing and disables autoplay")
        expect(SteamInstallObserver.starts == 1,"restoration and stopped work never start another observer")
        expect(restored.retryContext(jobID:third.uuidString,selectedAccount:other) == nil,"restored job cannot cross accounts")
        expect(coordinator.beginPreparedFiles(gameID:"steam:40",appID:"40",title:"Mac",accountID:account,runtimeID:"steam-mac",autoLaunch:true) == nil,"cached Windows entry cannot capture a native Mac route")
        print("\(checks) cached-payload pipeline checks passed; coordinator transitions and inert observer fixtures only; no Steam/Wine/game/network executed")
    }
}
