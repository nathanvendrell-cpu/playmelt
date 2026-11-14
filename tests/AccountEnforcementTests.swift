import Foundation
import CryptoKit

private final class EnforcementMemory:AccountCredentialStorage {
    var value:AccountRecord?;var writes=0,clears=0
    init(_ value:AccountRecord?=nil){self.value=value}
    func read()->AccountRecord?{value}
    func write(_ r:AccountRecord)throws{value=r;writes+=1}
    func clear(){value=nil;clears+=1}
}
private final class EnforcementHTTP:URLProtocol {
    static var result:(Int,[String:Any])=(402,["error":"payment_required"])
    static var requests=0
    override class func canInit(with r:URLRequest)->Bool{true}
    override class func canonicalRequest(for r:URLRequest)->URLRequest{r}
    override func startLoading(){Self.requests+=1;let (status,body)=Self.result;client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){}
}
@main enum AccountEnforcementTests {
    static var checks=0
    static func expect(_ yes:Bool,_ label:String){checks+=1;precondition(yes,label)}
    static func until(_ done:()->Bool){let deadline=Date().addingTimeInterval(3);while !done() && Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};expect(done(),"bounded callback")}
    static func main()throws {
        let key=Curve25519.Signing.PrivateKey(),user=UUID().uuidString,device=UUID().uuidString
        expect(AccountProtectedAction.capability(for:"retryInstallAndPlay")=="launch","installation recovery must recheck the same paid launch access")
        for raw in ["https://luna.amazon.fr/","https://luna.amazon.com/game/example","https://play.geforcenow.com/"]{expect(AccountProtectedAction.embeddedCloudCapability(for:URL(string:raw)!)=="launch","embedded cloud requires the same paid launch access")}
        for raw in ["https://luna.amazon.fr.evil.invalid/","https://7agency.fr/Playmelt/support/","https://store.steampowered.com/","https://example.invalid/?next=https://luna.amazon.fr/","http://luna.amazon.fr/"]{expect(AccountProtectedAction.embeddedCloudCapability(for:URL(string:raw)!)==nil,"cloud host policy does not charge for support/news or trust lookalike URLs")}
        let base:[String:Any]=["PlaymeltAccountURL":"https://example.invalid/Playmelt/compte","PlaymeltAccountServiceAvailable":true,"PlaymeltLicensePublicKey":key.publicKey.rawRepresentation.base64EncodedString()]
        func make(_ flags:[String:Any],_ memory:EnforcementMemory=EnforcementMemory())->AccountService{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[EnforcementHTTP.self];return AccountService(config:AccountConfiguration(info:base.merging(flags){_,new in new}),credentials:memory,sessionConfiguration:c,now:{1100})}
        func allowed(_ service:AccountService,_ capability:String)->Bool{var result:Bool?;service.authorize(capability:capability){ok,_ in result=ok};until{result != nil};return result!}
        for flags in [[:],["PlaymeltCommercialAccessEnabled":false],["PlaymeltDevelopmentBuild":false],["PlaymeltDevelopmentBuild":false,"PlaymeltCommercialAccessEnabled":false],["PlaymeltDevelopmentBuild":"true","PlaymeltCommercialAccessEnabled":false],["PlaymeltInternalBuild":true,"PlaymeltDevelopmentBuild":false,"PlaymeltCommercialAccessEnabled":true]] as [[String:Any]] {
            let memory=EnforcementMemory(),s=make(flags,memory);defer{s.shutdown()}
            expect(s.config.enabled,"missing or false production flag cannot bypass billing")
            for capability in ["launch","runtime.download"]{expect(!allowed(s,capability),"production unsigned account denied: \(capability)")}
            expect(memory.clears==0,"an unpaid state does not delete credentials or platform sessions")
        }
        expect(EnforcementHTTP.requests==0,"unsigned denied locally before any remote authorization")
        let dev=make(["PlaymeltDevelopmentBuild":true,"PlaymeltCommercialAccessEnabled":false]);defer{dev.shutdown()};expect(!dev.config.enabled && allowed(dev,"launch"),"explicit development build is kept separate from distribution")
        let forced=make(["PlaymeltDevelopmentBuild":true,"PlaymeltCommercialAccessEnabled":true]);defer{forced.shutdown()};expect(forced.config.enabled &&  !allowed(forced,"launch"),"an enabled gate remains enforced even in development")
        func ticket(phase:String="active",expires:Double=1900,capabilities:[String]=["launch","runtime.download"])throws->String{let d=try JSONSerialization.data(withJSONObject:["aud":"playmelt-desktop","sub":user,"device":device,"iat":1000,"exp":expires,"phase":phase,"plan":"monthly","capabilities":capabilities]);let payload=GoogleLoginAttempt.base64url(d);return payload+"."+GoogleLoginAttempt.base64url(try key.signature(for:Data(payload.utf8)))}
        let cached=try ticket(),record=AccountRecord(token:String(repeating:"t",count:43),deviceID:device,userID:user,email:"fixture@example.invalid",ticket:cached,lastSeen:1000)
        let unpublished=make(["PlaymeltAccountServiceAvailable":NSNull()],EnforcementMemory(record));defer{unpublished.shutdown()}
        let beforeUnpublished=EnforcementHTTP.requests
        expect(!allowed(unpublished,"launch"),"missing service readiness cannot authorize a production client")
        expect(EnforcementHTTP.requests==beforeUnpublished,"unpublished service is rejected before network access")
        for status in [402,403] {for capability in ["launch","runtime.download"]{
            let memory=EnforcementMemory(record),s=make(["PlaymeltCommercialAccessEnabled":false],memory);defer{s.shutdown()};EnforcementHTTP.result=(status,["error":"payment_required"])
            expect(!allowed(s,capability),"remote denial overrides even a valid cached grant")
            expect(s.snapshot()["signedIn"] as? Bool==true && s.snapshot()["accessVerified"] as? Bool==false,"unpaid account remains connected but loses access")
            expect(memory.value?.ticket==nil && memory.clears==0,"denial removes grant without logging out")
        }}
        for status in [0,503,429] {
            let memory=EnforcementMemory(record),s=make([:],memory);defer{s.shutdown()};EnforcementHTTP.result=(status,[:])
            expect(!allowed(s,"launch"),"no network, service outage or rate limit never reuses a cached grant")
            expect(memory.value?.token==record.token&&memory.clears==0,"verification failure preserves the signed-in session")
        }
        for phase in ["past_due","unpaid","canceled","incomplete","paused","inactive"] {
            let s=make([:],EnforcementMemory(record));defer{s.shutdown()};EnforcementHTTP.result=(200,["ticket":try ticket(phase:phase)])
            expect(!allowed(s,"launch"),"even a signed ticket cannot authorize non-entitled phase \(phase)")
        }
        for phase in ["active","trialing"] {let s=make([:],EnforcementMemory(record));defer{s.shutdown()};EnforcementHTTP.result=(200,["ticket":try ticket(phase:phase)]);expect(allowed(s,"launch"),"server-authorized paid or approved trial accepted")}
        let expired=make([:],EnforcementMemory(record));defer{expired.shutdown()};EnforcementHTTP.result=(200,["ticket":try ticket(expires:1100)]);expect(!allowed(expired,"launch"),"expiration is enforced at the exact boundary")
        print("Account enforcement: \(checks) checks passed; no real account, Keychain, payment or game")
    }
}
