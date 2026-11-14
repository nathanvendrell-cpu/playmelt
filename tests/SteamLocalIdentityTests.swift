// Compile with SteamInstallCoordinator.swift only. Payloads, observer and
// accounts are inert fixtures; no Steam, Wine, game, credential or network.
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
    static var starts=0,stops=0
    init(runtime:Runtime,appID:String,accountID:String,timeout:TimeInterval,deliver:@escaping(SteamInstallObservation,Bool,Bool)->Void){Self.starts+=1}
    func stop(){Self.stops+=1}
}
@main enum SteamLocalIdentityTests {
    enum Failure:Error {case assertion(String)}
    static var checks=0
    static let account="76561198000000001",other="76561198000000002",fm=FileManager.default
    static func check(_ condition:Bool,_ label:String)throws {checks+=1;if !condition{throw Failure.assertion(label)}}
    static func read(_ url:URL)throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]}
    static func write(_ record:[String:Any],_ url:URL)throws {
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONSerialization.data(withJSONObject:record).write(to:url)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func main()throws {
        let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/local-identity-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        var seed:[String:Any]=[:],seedHash=""
        for (index,appID) in ["10","20"].enumerated() {
            let payload=root.appendingPathComponent("Local Payload With Spaces \(index)"),sentinel=payload.appendingPathComponent("preserved.bin")
            try fm.createDirectory(at:payload,withIntermediateDirectories:true);try Data("preserved-payload-\(index)".utf8).write(to:sentinel)
            let expected=try Data(contentsOf:sentinel)
            // This is exactly LibraryScan's identity producer, using a real
            // temporary canonical folder, rather than a hand-built regex match.
            let hash=SHA256.hash(data:Data(payload.resolvingSymlinksInPath().path.utf8)).map{String(format:"%02x",$0)}.joined()
            let gameID="steam:\(appID):local:\(hash)",runtimeID=index==0 ? "playmelt-windows":"playmelt-d3dmetal",renderer=index==0 ? "dxmt":"d3dmetal"
            let runtime=Runtime(id:runtimeID,platform:"windows",steamRoot:root.appendingPathComponent("inert-steam-\(index)"),prefixURL:root.appendingPathComponent("inert-prefix-\(index)"))
            let journal=root.appendingPathComponent("live-\(index)/installation-state.json"),coordinator=SteamInstallCoordinator(recoveryURL:journal)
            defer{coordinator.shutdown()}
            let before=SteamInstallObserver.starts
            guard let id=coordinator.beginPreparedFiles(gameID:gameID,appID:appID,title:"Local Fixture \(index)",accountID:account,runtimeID:runtimeID,autoLaunch:true) else{throw Failure.assertion("preserved local payload must start")}
            try check(!coordinator.isActive && coordinator.snapshot?["status"] as? String=="preparing-client","prepared local payload starts after download with no false busy state")
            try check(SteamInstallObserver.starts==before,"beginPreparedFiles schedules no download or observer")
            try check(coordinator.acceptsPrepared(id:id,accountID:account,runtimeID:runtimeID),"local post-stage has exact context")
            try check(!coordinator.acceptsPrepared(id:id,accountID:other,runtimeID:runtimeID) && !coordinator.acceptsPrepared(id:id,accountID:account,runtimeID:"steam-mac"),"account/runtime guard survives local identity")
            try check(try read(journal)["gameId"] as? String==gameID,"local identity survives private journal save")
            try check(!String(decoding:Data(contentsOf:journal),as:UTF8.self).contains(payload.path),"only the digest, never the payload path, enters the journal")
            try check(coordinator.finishDirect(id:id,success:false,message:"Fixture client failure",code:"client-not-ready",retryable:true,resumePoint:"official-steam-windows"),"local post-stage can fail without retaining a token")
            try check(coordinator.retryContext(jobID:id.uuidString,selectedAccount:other)==nil,"wrong account cannot resume local payload")
            coordinator.updatePreparedStage(id:id,status:"preparing-client",message:"Stale callback")
            try check(coordinator.snapshot?["status"] as? String=="failed","unvalidated callback cannot revive local failure")
            let context=coordinator.retryContext(jobID:id.uuidString,selectedAccount:account)
            try check(context?.gameID==gameID && context?.appID==appID && context?.runtimeID==runtimeID,"retry keeps local digest, app and runtime correlated")
            coordinator.updatePreparedStage(id:id,status:"preparing-client",message:"Explicit retry")
            coordinator.updatePreparedStage(id:id,status:"awaiting-account",message:"Official account required")
            coordinator.updatePreparedStage(id:id,status:"preparing-files",message:"Preserved files")
            coordinator.updatePreparedStage(id:id,status:"awaiting-steam",message:"Official client")
            try check(coordinator.permitsPreparedFollowup(appID:appID,accountID:account,runtimeID:runtimeID,platform:"windows",renderer:renderer,payloadRenderer:renderer),"local prepared payload may hand off to the matching official runtime")
            try check(!coordinator.permitsPreparedFollowup(appID:appID,accountID:other,runtimeID:runtimeID,platform:"windows",renderer:renderer,payloadRenderer:renderer),"handoff still refuses stale account")
            try check(coordinator.begin(gameID:gameID,appID:appID,title:"Local Fixture",runtime:runtime,accountID:other,onReady:{_ in})==nil,"observer handoff refuses wrong account")
            var ready=0
            let handed=coordinator.begin(gameID:gameID,appID:appID,title:"Local Fixture",runtime:runtime,accountID:account,onReady:{_ in ready+=1})
            try check(handed==id && coordinator.snapshot?["gameId"] as? String==gameID,"handoff preserves the same job UUID and exact local identity")
            let observation=SteamInstallObservation(status:"installing",message:"Inert observed readiness",ready:true,signature:"fixture-\(index)")
            coordinator.receive(observation,id:id,onReady:{_ in ready+=1});try check(ready==0,"first readiness observation cannot launch")
            coordinator.receive(observation,id:id,onReady:{_ in ready+=1});try check(ready==1,"two matching observations reach handoff callback once")
            try check(coordinator.confirmLaunchContext(id:id,accountChanged:false,executionBlocked:false),"live matching account may finish dispatch")
            coordinator.didRequestLaunch(id:id,success:true,message:"Inert dispatch only")
            try check(!coordinator.isActive && coordinator.snapshot?["status"] as? String=="launch-requested","dispatch completion retires exact local job")
            try check(try Data(contentsOf:sentinel)==expected,"handoff never modifies preserved payload")

            let restoreURL=root.appendingPathComponent("restore-\(index)/installation-state.json"),unfinished=SteamInstallCoordinator(recoveryURL:restoreURL)
            let restoreID=unfinished.beginPreparedFiles(gameID:gameID,appID:appID,title:"Local Restored Fixture",accountID:account,runtimeID:runtimeID,autoLaunch:true)!
            unfinished.shutdown();let observerBefore=SteamInstallObserver.starts
            let restored=SteamInstallCoordinator(recoveryURL:restoreURL);defer{restored.shutdown()}
            try check(restored.snapshot?["gameId"] as? String==gameID && restored.snapshot?["status"] as? String=="interrupted","saved local payload restores as interrupted")
            try check(!restored.isActive && restored.snapshot?["autoLaunch"] as? Bool==false && SteamInstallObserver.starts==observerBefore,"restoration starts nothing and never recovers autoplay")
            try check(restored.retryContext(jobID:restoreID.uuidString,selectedAccount:other)==nil,"restoration cannot cross accounts")
            let restoredContext=restored.retryContext(jobID:restoreID.uuidString,selectedAccount:account)
            try check(restoredContext?.gameID==gameID && restoredContext?.autoLaunch==false,"reload to retry preserves local identity and disabled autoplay")
            restored.updatePreparedStage(id:restoreID,status:"preparing-client",message:"Explicit restored retry")
            restored.updatePreparedStage(id:restoreID,status:"awaiting-steam",message:"Official handoff")
            let wrongRuntime=Runtime(id:runtimeID=="playmelt-windows" ? "playmelt-d3dmetal":"playmelt-windows",platform:"windows",steamRoot:runtime.steamRoot)
            try check(restored.begin(gameID:gameID,appID:appID,title:"Wrong runtime",runtime:wrongRuntime,accountID:account,onReady:{_ in})==nil,"restored handoff refuses another runtime")
            let restoredHandoff=restored.begin(gameID:gameID,appID:appID,title:"Restored local",runtime:runtime,accountID:account,autoLaunch:true,onReady:{_ in})
            try check(restoredHandoff==restoreID && restored.snapshot?["autoLaunch"] as? Bool==false,"reload retry handoff keeps UUID and cannot silently re-enable autoplay")
            var cancelCalls=0;restored.onCancel={cancelCalls+=1};restored.cancel()
            try check(cancelCalls==1 && !restored.isActive && restored.snapshot?["status"] as? String=="cancelled","local cancellation stops observer exactly once")
            restored.receive(observation,id:restoreID,onReady:{_ in ready+=1});restored.updatePreparedStage(id:restoreID,status:"awaiting-steam",message:"Late")
            restored.didRequestLaunch(id:restoreID,success:true,message:"Late dispatch")
            try check(restored.snapshot?["status"] as? String=="cancelled" && restored.retryContext(jobID:restoreID.uuidString,selectedAccount:account)==nil,"stale callbacks cannot resurrect cancelled local job")
            try check(SteamInstallCoordinator(recoveryURL:restoreURL).snapshot==nil,"cancelled local job never restores")
            try check(try Data(contentsOf:sentinel)==expected,"restoration and cancellation preserve payload bytes")
            if index==0 {
                let seedURL=root.appendingPathComponent("seed/installation-state.json"),s=SteamInstallCoordinator(recoveryURL:seedURL)
                let sid=s.beginDirect(gameID:gameID,appID:appID,title:"Local Direct",accountID:account,runtimeID:runtimeID)!
                try check(s.finishDirect(id:sid,success:false,message:"Fixture",retryable:true),"direct local identity also enters retry lifecycle")
                seed=try read(seedURL);seedHash=hash;s.shutdown()
            }
        }
        let malformed=["steam:20:local:"+seedHash,"steam:10:local:"+String(seedHash.dropLast()),"steam:10:local:"+seedHash+"a",
            "steam:10:local:"+String(repeating:"A",count:64),"steam:10:local:"+String(repeating:"a",count:63)+"g",
            "steam:10:local:"+String(repeating:"a",count:61)+"../","steam:10:local:/Users/private/game",
            "steam:10:local:"+String(repeating:"a",count:63)+"\0","steam:10:local:"+seedHash+":playmelt-windows",
            "steam:10:local:"+String(repeating:"ａ",count:64),"steam:10:LOCAL:"+seedHash,"steam:10:local:file://fixture"]
        for (index,value) in malformed.enumerated() {
            let c=SteamInstallCoordinator(),runtime=Runtime(id:"playmelt-windows",platform:"windows",steamRoot:root)
            try check(c.beginDirect(gameID:value,appID:"10",title:"Invalid local",accountID:account,runtimeID:runtime.id)==nil,"invalid local identity refuses direct start")
            try check(c.beginPreparedFiles(gameID:value,appID:"10",title:"Invalid local",accountID:account,runtimeID:runtime.id,autoLaunch:true)==nil,"invalid local identity cannot masquerade as prepared payload")
            let starts=SteamInstallObserver.starts
            try check(c.begin(gameID:value,appID:"10",title:"Invalid local",runtime:runtime,accountID:account,onReady:{_ in})==nil && SteamInstallObserver.starts==starts,"observer entry cannot bypass local identity validation")
            var record=seed;record["gameId"]=value;let url=root.appendingPathComponent("invalid-\(index)/installation-state.json");try write(record,url)
            try check(SteamInstallCoordinator(recoveryURL:url).snapshot==nil,"malformed local identity is refused on journal reload")
            c.shutdown()
        }
        for gameID in ["steam:10","steam:10:playmelt-windows","steam:10:playmelt-d3dmetal","steam:10:steam-mac"] {
            let c=SteamInstallCoordinator();try check(c.beginDirect(gameID:gameID,appID:"10",title:"Existing canonical form",accountID:account) != nil,"existing canonical and runtime identities remain compatible");c.cancel()
        }
        print("\(checks) local Steam identity lifecycle checks passed; two LibraryScan-style folder hashes, journals and inert observers only; no Steam/Wine/game/network")
    }
}
