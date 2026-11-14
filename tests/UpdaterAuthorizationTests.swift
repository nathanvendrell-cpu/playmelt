import Foundation
import Sparkle

@main enum UpdaterAuthorizationTests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
    static func spin(){_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.015))}
    static func refuses(_ label:String,_ block:()throws->Void){do{try block();expect(false,label)}catch{expect(true,label)}}
    static func main()throws{
        let origin="https://7agency.fr/Playmelt/compte/v1/updates/archive/",sha=String(repeating:"a",count:64)
        let archive=origin+"30/"+sha+"/Playmelt-2.2.0.zip"
        let signature=Data(repeating:0,count:64).base64EncodedString(),key=Data(repeating:0,count:32).base64EncodedString()
        func item(_ url:String=archive,version:String="30",signature:String?=signature,description:String?=nil)->SUAppcastItem{
            var enclosure:[String:Any]=["url":url,"sparkle:version":version,"length":"100","type":"application/octet-stream"]
            if let signature{enclosure["sparkle:edSignature"]=signature}
            var fields:[String:Any]=["title":"Fixture","enclosure":enclosure]
            if let description{fields["description"]=description}
            return SUAppcastItem(dictionary:fields)!
        }
        let validItem=item()
        expect(UpdateTransportPolicy.itemAllowed(validItem,currentBuild:"29",hasSigningKey:true),"same-origin higher-build signed-shape archive passes preflight")
        expect(!UpdateTransportPolicy.itemAllowed(validItem,currentBuild:"30",hasSigningKey:true),"same build is not an update")
        expect(!UpdateTransportPolicy.itemAllowed(validItem,currentBuild:"31",hasSigningKey:true),"downgrade refused")
        expect(!UpdateTransportPolicy.itemAllowed(validItem,currentBuild:"029",hasSigningKey:true),"noncanonical current build refused")
        expect(!UpdateTransportPolicy.itemAllowed(validItem,currentBuild:"29",hasSigningKey:false),"missing Ed25519 trust key fails closed")
        expect(!UpdateTransportPolicy.itemAllowed(item(signature:nil),currentBuild:"29",hasSigningKey:true),"unsigned enclosure refused before downloading")
        expect(!UpdateTransportPolicy.itemAllowed(item(signature:"bad"),currentBuild:"29",hasSigningKey:true),"malformed signature refused")
        expect(!UpdateTransportPolicy.itemAllowed(item(description:"<img src='https://other.example/x'>"),currentBuild:"29",hasSigningKey:true),"inline release notes are disabled")
        for url in [archive.replacingOccurrences(of:"https:",with:"http:"),archive.replacingOccurrences(of:"7agency.fr",with:"other.example"),
                    archive.replacingOccurrences(of:"7agency.fr",with:"7agency.fr:443"),archive.replacingOccurrences(of:"7agency.fr",with:"user@7agency.fr"),
                    archive+"?token=x",archive+"#fragment",archive.replacingOccurrences(of:"/30/",with:"/030/"),archive.replacingOccurrences(of:sha,with:sha.uppercased()),
                    archive.replacingOccurrences(of:"Playmelt-2.2.0.zip",with:"x%2Fy.zip"),archive.replacingOccurrences(of:"Playmelt-2.2.0.zip",with:"../x.zip"),
                    archive.replacingOccurrences(of:"Playmelt-2.2.0.zip",with:"x.exe"),archive.replacingOccurrences(of:"/archive/",with:"/other/")]{
            expect(!UpdateTransportPolicy.archiveAllowed(URL(string:url),version:"30",currentBuild:"29"),"unapproved archive URL refused")
        }
        expect(!UpdateTransportPolicy.archiveAllowed(URL(string:archive),version:"31",currentBuild:"29"),"enclosure tuple must match offered build")
        let host=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil),updater=host.updater
        var clock:Double=1000,busy=false,providerCalls=0,performed:[Bool]=[],completions:[(Result<AccountUpdateGrant,Error>)->Void]=[]
        let controller=UpdaterController(now:{clock},controller:host,currentBuild:"29",signingKey:key,check:{performed.append($0)})
        controller.isBusy={busy}
        controller.updateGrantProvider={providerCalls+=1;completions.append($0)}
        let response:[String:Any]=["token":String(repeating:"u",count:43),"expiresAt":1600,"feedURL":AccountUpdateGrant.feedURL.absoluteString]
        let grant=AccountUpdateGrant(response:response,deviceToken:String(repeating:"d",count:43),now:clock)!
        expect(controller.feedURLString(for:updater)==AccountUpdateGrant.feedURL.absoluteString,"feed URL is fixed")
        expect(!controller.updater(updater,shouldDownloadReleaseNotesForUpdate:validItem),"remote release notes are disabled")
        controller.requestCheck(userInitiated:true)
        expect(providerCalls==1 && performed.isEmpty && updater.httpHeaders==nil,"no Sparkle check before a fresh grant")
        controller.requestCheck(userInitiated:true);expect(providerCalls==1,"double menu action coalesces renewal")
        completions.removeFirst()(.success(grant))
        expect(performed==[true] && updater.httpHeaders==grant.httpHeaders,"only dedicated update grant is installed for menu cycle")
        try controller.updater(updater,mayPerform:.updates)
        try controller.updater(updater,shouldProceedWithUpdate:validItem,updateCheck:.updates)
        let request=NSMutableURLRequest(url:URL(string:archive)!);request.setValue("Bearer stale-driver-copy",forHTTPHeaderField:"Authorization")
        controller.updater(updater,willDownloadUpdate:validItem,with:request)
        expect(request.value(forHTTPHeaderField:"Authorization")==grant.httpHeaders["Authorization"],"enclosure replaces the Sparkle driver's stale header snapshot")
        refuses("external enclosure rejected at selection"){try controller.updater(updater,shouldProceedWithUpdate:item(archive.replacingOccurrences(of:"7agency.fr",with:"other.example")),updateCheck:.updates)}
        let external=NSMutableURLRequest(url:URL(string:"https://other.example/archive.zip")!);external.setValue("must-not-leak",forHTTPHeaderField:"Authorization")
        controller.updater(updater,willDownloadUpdate:validItem,with:external)
        expect(external.url?.absoluteString=="about:blank" && external.allHTTPHeaderFields?.isEmpty != false,"void download callback neutralizes rejected request before send")
        expect(updater.httpHeaders==nil,"invalid enclosure clears updater headers")
        controller.updater(updater,didFinishUpdateCycleFor:.updates,error:nil)
        controller.requestCheck(userInitiated:false);expect(providerCalls==2,"next cycle requests another grant")
        controller.clearUpdateAuthorization();completions.removeFirst()(.success(grant))
        expect(updater.httpHeaders==nil && performed.count==1,"logout invalidation refuses in-flight renewal response")
        controller.requestCheck(userInitiated:true);completions.removeFirst()(.failure(AccountUpdateGrantError.refused(401)))
        expect(updater.httpHeaders==nil && performed.count==1,"renewal failure blocks a new cycle")
        busy=true;let calls=providerCalls;controller.requestCheck(userInitiated:false)
        expect(providerCalls==calls,"active work defers grant request")
        busy=false;controller.resumeWhenIdle();expect(providerCalls==calls+1,"idle opportunity renews deferred cycle")
        completions.removeFirst()(.success(grant));try controller.updater(updater,mayPerform:.updatesInBackground)
        clock=1600
        let expired=NSMutableURLRequest(url:URL(string:archive)!);expired.setValue("old",forHTTPHeaderField:"Authorization")
        controller.updater(updater,willDownloadUpdate:validItem,with:expired)
        expect(expired.url?.absoluteString=="about:blank" && updater.httpHeaders==nil,"grant expiration while user waits blocks archive download")
        controller.updater(updater,didAbortWithError:NSError(domain:"fixture",code:401))
        controller.updater(updater,didFinishUpdateCycleFor:.updatesInBackground,error:nil)
        expect(updater.httpHeaders==nil,"abort and cycle completion both clear ephemeral authorization")
        clock=1000;busy=false
        refuses("automatic scheduler needs fresh authorization"){try controller.updater(updater,mayPerform:.updatesInBackground)}
        let scheduledCalls=providerCalls
        controller.updater(updater,didFinishUpdateCycleFor:.updatesInBackground,error:nil);spin()
        expect(providerCalls==scheduledCalls+1,"scheduler veto queues one authenticated replacement cycle")
        completions.removeFirst()(.success(grant));expect(performed.last==false,"authenticated scheduler keeps background semantics")
        var immediate=0
        expect(!controller.updater(updater,willInstallUpdateOnQuit:validItem,immediateInstallationBlock:{immediate+=1}),"install-on-quit does not stall future Sparkle cycles")
        expect(immediate==0,"no immediate relaunch is requested")
        controller.clearUpdateAuthorization()
        print("Updater authorization: \(checks) PASS; Sparkle never started, URL requests remained in memory, no archive/signature-install or network claimed.")
    }
}
