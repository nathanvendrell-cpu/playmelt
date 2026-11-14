import Foundation
import CryptoKit

private final class MemoryCredentials:AccountCredentialStorage {
    var value:AccountRecord?
    var failsWrite=false
    var clears=0
    init(_ value:AccountRecord?){self.value=value}
    func read()->AccountRecord?{value}
    func write(_ value:AccountRecord)throws{if failsWrite {throw NSError(domain:"fixture",code:1)};self.value=value}
    func clear(){clears+=1;value=nil}
}
private final class AccountHTTPFixture:URLProtocol {
    static var response:(URLRequest)->(Int,[String:Any]) = {_ in (500,[:])}
    static var failure:Error?
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        if let error=Self.failure {client?.urlProtocol(self,didFailWithError:error);return}
        let (status,body)=Self.response(request)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
@main enum AccountTransportTests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    static func until(seconds:Double=3,_ done:()->Bool){let deadline=Date().addingTimeInterval(seconds);while !done() && Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};expect(done(),"bounded callback")}
    static func main()throws {
        let secret=Curve25519.Signing.PrivateKey(),user=UUID().uuidString,device=UUID().uuidString,token=String(repeating:"a",count:43)
        let config=AccountConfiguration(info:["PlaymeltCommercialAccessEnabled":true,"PlaymeltAccountServiceAvailable":true,"PlaymeltAccountURL":"https://example.invalid/Playmelt/compte/","PlaymeltLicensePublicKey":secret.publicKey.rawRepresentation.base64EncodedString()])
        func encoded(_ data:Data)->String{data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
        func ticket(capabilities:[String]=["launch","runtime.download"],expiry:Double=1900,plan:String="monthly",phase:String="trialing")throws->String {
            let data=try JSONSerialization.data(withJSONObject:["aud":"playmelt-desktop","sub":user,"device":device,"iat":1000,"exp":expiry,"phase":phase,"plan":plan,"capabilities":capabilities])
            let payload=encoded(data);return payload+"."+encoded(try secret.signature(for:Data(payload.utf8)))
        }
        let valid=try ticket(),grant=AccountRecord(token:token,deviceID:device,userID:user,email:"fixture@example.invalid",ticket:valid,lastSeen:1000)
        var clock:Double=1100
        func service(_ storage:MemoryCredentials)->AccountService {let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[AccountHTTPFixture.self];return AccountService(config:config,credentials:storage,sessionConfiguration:c,now:{clock})}
        func allowed(_ account:AccountService,capability:String="launch")->Bool {var result:Bool?;account.authorize(capability:capability){ok,_ in result=ok};until{result != nil};return result!}
        let store=MemoryCredentials(grant);var account=service(store);defer{account.shutdown()}
        AccountHTTPFixture.response={request in
            expect(request.url?.path=="/Playmelt/compte/v1/launch-ticket","account prefix preserved")
            expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+token,"device token only in auth header")
            expect(request.url?.query==nil && request.httpMethod=="POST","no credentials in URL")
            return (200,["ticket":valid])
        }
        expect(allowed(account),"online signed ticket accepted")
        AccountHTTPFixture.response={_ in (503,[:])}
        expect(!allowed(account),"offline client cannot reuse an old grant after a possible refund or revocation")
        let serverDiagnostic=account.snapshot()["authorizationDiagnostic"] as? [String:Any]
        expect(serverDiagnostic?["httpStatus"] as? Int==503 && serverDiagnostic?["responseHTTPStatus"] as? Int==503,"authenticated server503 remains distinguishable from transport failure")
        expect(account.snapshot()["message"] as? String != nil && (account.snapshot()["message"] as? String)?.contains("HTTP 503")==true,"server failure is visible without requesting a logout")
        AccountHTTPFixture.failure=URLError(.timedOut)
        expect(!allowed(account),"transport timeout cannot authorize from an old grant")
        let timeoutDiagnostic=account.snapshot()["authorizationDiagnostic"] as? [String:Any]
        expect(timeoutDiagnostic?["httpStatus"] as? Int==0 && timeoutDiagnostic?["errorDomain"] as? String==NSURLErrorDomain && timeoutDiagnostic?["errorCode"] as? Int==NSURLErrorTimedOut,"exact timeout domain and code are retained for the authorization request")
        expect(store.value?.token==token,"transport diagnostics preserve the existing connection")
        expect(Set(timeoutDiagnostic?.keys.map{$0} ?? [])==["httpStatus","responseHTTPStatus","errorDomain","errorCode"],"diagnostics contain no record, URL, token or response body")
        AccountHTTPFixture.failure=nil
        clock=1900;expect(!allowed(account),"cached ticket expires at boundary")
        clock=900;expect(!allowed(account),"clock rollback blocks cached access")
        clock=1100;account.shutdown();store.value=grant;account=service(store)
        for status in [401,402,403,200] {
            let memory=MemoryCredentials(grant),s=service(memory);defer{s.shutdown()}
            AccountHTTPFixture.response={_ in (status,[:])}
            expect(!allowed(s),"server refusal or invalid 200 never falls back")
            expect((s.snapshot()["authorizationDiagnostic"] as? [String:Any])?["httpStatus"] as? Int==status,"refused and invalid200 responses retain their exact status without changing the gate")
            expect(memory.value?.ticket==nil,"refused grant removed")
            if status==401 {expect(memory.value==nil,"revoked device cleared")}
        }
        let launchOnly=try ticket(capabilities:["launch"])
        AccountHTTPFixture.response={_ in (200,["ticket":launchOnly])}
        expect(!allowed(account,capability:"runtime.download"),"runtime requires its own capability")
        expect(allowed(account),"launch capability remains sufficient for launch")
        store.failsWrite=true;AccountHTTPFixture.response={_ in (200,["ticket":valid])}
        expect(!allowed(account),"credential write failure blocks launch");store.failsWrite=false
        let missing=service(MemoryCredentials(nil));defer{missing.shutdown()}
        expect(!allowed(missing),"unsigned client denied")
        let inactive=service(MemoryCredentials(grant));defer{inactive.shutdown()}
        AccountHTTPFixture.response={request in
            if request.url?.path.hasSuffix("/support/tickets")==true {return (201,["id":"ticket-1","status":"received"])}
            return (402,[:])
        }
        expect(!allowed(inactive),"inactive subscription denied launch")
        var reported=false
        inactive.submitReport(["clientId":UUID().uuidString,"gameId":"fixture","category":"launch","message":"Fixture report"]){ok,_ in expect(ok,"support remains available without a paid licence");reported=true};until{reported}
        let revoked=service(MemoryCredentials(grant));defer{revoked.shutdown()}
        AccountHTTPFixture.response={_ in (200,["ticket":valid])}
        var completed=false
        revoked.authorize{ok,_ in expect(!ok,"logout cancels pending authorization");completed=true}
        revoked.logout();until{completed}
        let lifetime=try ticket(plan:"lifetime",phase:"active"),life=service(MemoryCredentials(grant));defer{life.shutdown()}
        AccountHTTPFixture.response={_ in (200,["ticket":lifetime])}
        expect(allowed(life),"signed lifetime access accepted")
        expect(life.snapshot()["plan"] as? String == "lifetime" && life.snapshot()["accessVerified"] as? Bool == true,"lifetime status follows verified server ticket")
        clock=1900;AccountHTTPFixture.response={_ in (503,[:])};expect(!allowed(life),"lifetime licence still needs a fresh short-lived ticket")
        expect(life.snapshot()["accessVerified"] as? Bool == false,"expired lifetime ticket is not displayed as verified")
        clock=1100
        let unavailableConfig=AccountConfiguration(info:["PlaymeltCommercialAccessEnabled":true,"PlaymeltAccountServiceAvailable":false,"PlaymeltAccountURL":"https://example.invalid/Playmelt/compte/","PlaymeltLicensePublicKey":secret.publicKey.rawRepresentation.base64EncodedString()])
        let unavailable=AccountService(config:unavailableConfig,credentials:MemoryCredentials(grant),now:{clock});defer{unavailable.shutdown()}
        expect(!allowed(unavailable),"unavailable service cannot activate the commercial gate")
        var opened=false;unavailable.connect{_ in opened=true};expect(!opened,"unpublished account service never opens a sign-in browser")
        let returned=service(MemoryCredentials(grant));defer{returned.shutdown()}
        var reads=0,grants=0
        AccountHTTPFixture.response={request in
            if request.url?.path.hasSuffix("/v1/me")==true {
                reads+=1;return (200,["id":user,"email":"fixture@example.invalid","entitlement":["plan":"lifetime","phase":"active","until":NSNull()]])
            }
            grants+=1;return (200,["ticket":lifetime])
        }
        returned.refresh();returned.refreshAfterReturning();returned.refresh()
        until{grants==1 && returned.snapshot()["accessVerified"] as? Bool==true}
        expect(reads==1 && grants==1,"concurrent activation refreshes share one request")
        expect(returned.snapshot()["plan"] as? String=="lifetime" && returned.snapshot()["expiresAt"] as? Double==0,"web lifetime redemption updates native state without an invented expiry")
        returned.refreshAfterReturning();expect(reads==1,"rapid focus changes do not poll the account")
        clock+=6;returned.refreshAfterReturning();until{grants==2}
        expect(reads==2,"return from the account refreshes entitlement and signed access")
        let failedStorage=MemoryCredentials(grant);failedStorage.failsWrite=true
        let failedRefresh=service(failedStorage);defer{failedRefresh.shutdown()}
        failedRefresh.refresh();until{failedRefresh.snapshot()["checkingAccess"] as? Bool==false}
        expect(failedStorage.clears==0&&failedStorage.value?.token==grant.token,"a Keychain write error never erases an existing connection")
        expect(failedRefresh.snapshot()["signedIn"] as? Bool==true&&failedRefresh.snapshot()["accessVerified"] as? Bool==false,"failed persistence retains the session but does not authorize access")
        expect(failedRefresh.snapshot()["message"] as? String != "","Keychain failure remains visible and retryable")
        let readsBeforeClose=reads;clock+=6;returned.shutdown();returned.refreshAfterReturning();expect(reads==readsBeforeClose,"closed application never refreshes on focus")
        let pairedStorage=MemoryCredentials(nil),paired=service(pairedStorage);defer{paired.shutdown()}
        var challenge="",verifiedPairing=false,browserOpened=false
        AccountHTTPFixture.response={request in
            let object=request.httpBody.flatMap{try? JSONSerialization.jsonObject(with:$0)} ?? request.httpBodyStream.flatMap{stream -> Any? in stream.open();defer{stream.close()};return try? JSONSerialization.jsonObject(with:stream)}
            let body=object as? [String:Any] ?? [:]
            switch request.url?.lastPathComponent {
            case "start":
                challenge=body["challenge"] as? String ?? ""
                expect(challenge.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,"pairing sends only the SHA256 challenge")
                return (200,["deviceCode":String(repeating:"d",count:43),"userCode":"ABCDEF1234","verificationURL":"https://example.invalid/Playmelt/compte/device"])
            case "token":
                let verifier=body["verifier"] as? String ?? ""
                expect(verifier.count==43 && SHA256.hash(data:Data(verifier.utf8)).map{String(format:"%02x",$0)}.joined()==challenge,"pairing proves possession of the original verifier")
                expect(body["deviceCode"] as? String==String(repeating:"d",count:43),"poll uses the matching device challenge")
                verifiedPairing=true;return (200,["token":token,"deviceID":device])
            case "me":return (200,["id":user,"email":"fixture@example.invalid","entitlement":["plan":"lifetime","phase":"active","until":NSNull()]])
            case "launch-ticket":return (200,["ticket":lifetime])
            default:return (404,[:])
            }
        }
        paired.connect{url in browserOpened=url.path=="/Playmelt/compte/device"}
        until(seconds:7){paired.snapshot()["accessVerified"] as? Bool==true}
        expect(browserOpened && verifiedPairing,"approved pairing reaches native verified access")
        expect(pairedStorage.value?.deviceID==device && pairedStorage.value?.userID==user,"paired account is persisted through the credential abstraction")
        for address in ["https://other.invalid/Playmelt/compte/device","https://example.invalid/another/device","http://example.invalid/Playmelt/compte/device"] {
            let rejected=service(MemoryCredentials(nil));defer{rejected.shutdown()}
            AccountHTTPFixture.response={_ in (200,["deviceCode":String(repeating:"d",count:43),"userCode":"ABCDEF1234","verificationURL":address])}
            var wrongBrowser=false
            rejected.connect{_ in wrongBrowser=true};until{rejected.snapshot()["pending"] as? Bool==false}
            expect(!wrongBrowser && rejected.snapshot()["signedIn"] as? Bool==false,"pairing rejects unexpected verification destination")
        }
        account.shutdown();expect(!allowed(account),"shutdown cannot authorize new work")
        for action in ["setupWindowsRuntime","setupD3DMetalRuntime","importD3DMetal","installNvidiaBridge","installSteamWindows","installSteamD3DMetal"] {expect(AccountProtectedAction.capability(for:action)=="runtime.download","runtime action protected: "+action)}
        for action in ["launchGame","installGame","installAndPlay","openWindowsSteam","openD3DMetalSteam","installLocalGame","openXbox","launchXboxCloud"] {expect(AccountProtectedAction.capability(for:action)=="launch","game entry protected: "+action)}
        for action in ["submitGameIssue","refreshGameIssues","openPlaymeltAccount","disconnectPlaymelt","savePlayerProfile"] {expect(AccountProtectedAction.capability(for:action)==nil,"support and profile accessible: "+action)}
        print("Account transport: \(checks) checks passed; intercepted HTTPS only, no real account or Keychain mutations")
    }
}
