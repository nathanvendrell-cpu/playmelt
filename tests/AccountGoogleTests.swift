import Foundation
import CryptoKit

private final class GoogleMemory:AccountCredentialStorage {
    var value:AccountRecord?;var writes=0,clears=0
    func read()->AccountRecord?{value}
    func write(_ value:AccountRecord)throws{self.value=value;writes+=1}
    func clear(){value=nil;clears+=1}
}
private final class GoogleHTTP:URLProtocol {
    static var response:(URLRequest)->(Int,[String:Any])={_ in (500,[:])}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){let (status,body)=Self.response(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json","Retry-After":"30"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){}
}
@main enum AccountGoogleTests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    static func until(_ done:()->Bool){let end=Date().addingTimeInterval(3);while !done()&&Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};expect(done(),"bounded callback")}
    static func body(_ r:URLRequest)->[String:Any]{if let d=r.httpBody{return (try? JSONSerialization.jsonObject(with:d)) as? [String:Any] ?? [:]};guard let stream=r.httpBodyStream else{return [:]};stream.open();defer{stream.close()};return (try? JSONSerialization.jsonObject(with:stream)) as? [String:Any] ?? [:]}
    static func main()throws {
        var now:Double=1100
        let base=URL(string:"https://example.invalid/Playmelt/compte")!,key=Curve25519.Signing.PrivateKey(),user=UUID().uuidString,device=UUID().uuidString,token=String(repeating:"t",count:43),code=String(repeating:"c",count:43)
        let info:[String:Any]=["PlaymeltCommercialAccessEnabled":true,"PlaymeltAccountServiceAvailable":true,"PlaymeltPasswordLoginAvailable":true,"PlaymeltGoogleLoginAvailable":true,"PlaymeltAccountURL":base.absoluteString,"PlaymeltLicensePublicKey":key.publicKey.rawRepresentation.base64EncodedString()]
        let attempt=try GoogleLoginAttempt(now:now),other=try GoogleLoginAttempt(now:now)
        expect(attempt.verifier.count==43&&attempt.state.count==43&&attempt.challenge.count==43,"PKCE and state sizes")
        expect(attempt.verifier != other.verifier&&attempt.state != other.state&&attempt.verifier != attempt.state,"independent secure random values")
        expect(attempt.challenge==GoogleLoginAttempt.base64url(Data(SHA256.hash(data:Data(attempt.verifier.utf8)))),"RFC S256 base64url, not hex")
        let valid="playmelt://account/google?code=\(code)&state=\(attempt.state)"
        expect(attempt.code(from:URL(string:valid)!,now:now)==code,"exact callback accepted")
        for bad in [valid+"&code="+code,valid+"&extra=x",valid+"#fragment",valid.replacingOccurrences(of:"account/",with:"other/"),valid.replacingOccurrences(of:"/google?",with:"/other?"),valid.replacingOccurrences(of:"/google?",with:"/%67oogle?"),valid.replacingOccurrences(of:"playmelt:",with:"https:"),valid.replacingOccurrences(of:"account/",with:"account:80/"),valid.replacingOccurrences(of:"account/",with:"user@account/"),valid.replacingOccurrences(of:attempt.state,with:other.state)] {expect(attempt.code(from:URL(string:bad)!,now:now)==nil,"unexpected callback rejected")}
        expect(attempt.code(from:URL(string:valid)!,now:now+600)==nil,"expired attempt cannot exchange")
        expect(attempt.error(from:URL(string:"playmelt://account/google?error=oauth_cancelled&state=\(attempt.state)")!,now:now)=="oauth_cancelled","verified cancellation")
        expect(attempt.error(from:URL(string:"playmelt://account/google?error=oauth_cancelled&state=wrong")!,now:now)==nil,"untrusted error state rejected")
        expect(attempt.error(from:URL(string:"playmelt://account/google?error=account_link_required&state=\(attempt.state)")!,now:now)=="account_link_required","existing account linking result accepted only in the current session")
        expect(attempt.error(from:URL(string:"playmelt://account/google?error=https://elsewhere.invalid&state=\(attempt.state)")!,now:now)==nil,"server callback cannot supply arbitrary links")
        let startURL=base.appendingPathComponent("v1/auth/google/start").absoluteString+"?native="+String(repeating:"n",count:43)
        expect(GoogleLoginAttempt.allowsStart(URL(string:startURL)!,base:base),"exact hosted browser entry")
        for bad in [startURL+"&return=https://elsewhere.invalid",startURL+"#x",startURL.replacingOccurrences(of:"example.invalid",with:"elsewhere.invalid"),startURL.replacingOccurrences(of:"/google/start",with:"/google/native/start"),startURL.replacingOccurrences(of:"?native=",with:"?code="),startURL+"&native="+code] {expect(!GoogleLoginAttempt.allowsStart(URL(string:bad)!,base:base),"arbitrary browser entry rejected")}
        func make(_ memory:GoogleMemory=GoogleMemory(),enabled:Bool=true)->AccountService{let cfg=URLSessionConfiguration.ephemeral;cfg.protocolClasses=[GoogleHTTP.self];return AccountService(config:AccountConfiguration(info:info.merging(["PlaymeltGoogleLoginAvailable":enabled]){_,b in b}),credentials:memory,sessionConfiguration:cfg,now:{now})}
        var requests=0
        GoogleHTTP.response={_ in requests+=1;return (200,["google":true])}
        let disabled=make(enabled:false);defer{disabled.shutdown()};disabled.refreshSignInProviders();disabled.signInWithGoogle{_,_ in preconditionFailure("disabled browser")};expect(requests==0&&disabled.snapshot()["googleLoginReady"] as? Bool==false,"unpublished native gate sends no Google request")
        let memory=GoogleMemory(),account=make(memory);defer{account.shutdown()}
        var postedState="",postedChallenge="",postedVerifier="",starts=0,exchanges=0,unpaid=false
        let claims=try JSONSerialization.data(withJSONObject:["aud":"playmelt-desktop","sub":user,"device":device,"iat":1000,"exp":1900,"phase":"active","plan":"lifetime","capabilities":["launch"]])
        let payload=GoogleLoginAttempt.base64url(claims),ticket=payload+"."+GoogleLoginAttempt.base64url(try key.signature(for:Data(payload.utf8)))
        func success(_ r:URLRequest)->(Int,[String:Any]) {
            switch r.url!.path {
            case base.appendingPathComponent("v1/auth/providers").path:expect(r.httpMethod=="GET","provider discovery is read only");return (200,["google":true])
            case base.appendingPathComponent("v1/auth/google/native/start").path:
                starts+=1;let data=body(r);postedState=data["state"] as? String ?? "";postedChallenge=data["challenge"] as? String ?? ""
                expect(Set(data.keys)==Set(["state","challenge"]),"start never sends verifier, email or password");expect(r.value(forHTTPHeaderField:"Authorization")==nil&&r.value(forHTTPHeaderField:"Cookie")==nil,"start carries no token or cookie");return (200,["url":startURL])
            case base.appendingPathComponent("v1/auth/google/native/exchange").path:
                exchanges+=1;let data=body(r);postedVerifier=data["verifier"] as? String ?? "";expect(data["code"] as? String==code&&Set(data.keys)==Set(["code","verifier","label"]),"exact exchange contract");expect(GoogleLoginAttempt.base64url(Data(SHA256.hash(data:Data(postedVerifier.utf8))))==postedChallenge,"exchange proves possession of original PKCE verifier");return (200,["token":token,"deviceID":device,"expiresIn":2592000])
            case base.appendingPathComponent("v1/me").path:return (200,["id":user,"email":"fixture@example.invalid","hasPassword":false,"entitlement":["phase":unpaid ? "inactive":"active","plan":"lifetime"]])
            case base.appendingPathComponent("v1/launch-ticket").path:return unpaid ? (402,["error":"payment_required"]):(200,["ticket":ticket])
            default:preconditionFailure("unexpected endpoint")
            }
        }
        GoogleHTTP.response=success;account.refreshSignInProviders();until{account.snapshot()["googleLoginReady"] as? Bool==true}
        var callback:((URL?)->Void)?
        account.signInWithGoogle{url,done in expect(url.absoluteString==startURL,"system browser receives only validated URL");callback=done};account.signInWithGoogle{_,_ in preconditionFailure("second browser")};account.signIn(email:"fixture@example.invalid",password:"not-sent")
        until{callback != nil};expect(starts==1,"one session, password cannot race Google")
        let returned=URL(string:"playmelt://account/google?code=\(code)&state=\(postedState)")!;callback?(returned);callback?(returned)
        until{account.snapshot()["accessVerified"] as? Bool==true};expect(exchanges==1,"callback consumed once")
        expect(memory.value?.token==token&&memory.clears==0,"same credential format, no clearing")
        let state=String(decoding:try JSONSerialization.data(withJSONObject:account.snapshot()),as:UTF8.self),stored=String(decoding:try JSONEncoder().encode(memory.value),as:UTF8.self)
        expect(!state.contains(postedVerifier) && !state.contains(code) && !stored.contains(postedVerifier) && !stored.contains(code),"OAuth proofs absent from UI and stored record")
        account.signInWithGoogle{_,_ in preconditionFailure("existing account replaced")};expect(starts==1,"existing session preserved")
        for mode in ["cancel","mismatch","expired","manual-cancel","shutdown","unpaid","exchange-denied","account-link"] {
            now=1100;unpaid=mode=="unpaid";let storage=GoogleMemory(),s=make(storage);var completion:((URL?)->Void)?;GoogleHTTP.response={r in if mode=="exchange-denied"&&r.url!.lastPathComponent=="exchange"{return (401,["error":"invalid_grant"])};return success(r)}
            s.refreshSignInProviders();until{s.snapshot()["googleLoginReady"] as? Bool==true};s.signInWithGoogle{_,done in completion=done};until{completion != nil};let before=exchanges
            let response=URL(string:mode=="account-link" ? "playmelt://account/google?error=account_link_required&state=\(postedState)" : "playmelt://account/google?code=\(code)&state=\(mode=="mismatch" ? "wrong":postedState)")!
            if mode=="expired"{now+=601};if mode=="manual-cancel"{s.cancelGoogleSignIn()};if mode=="shutdown"{s.shutdown()}
            completion?(mode=="cancel" ? nil:response)
            if mode=="unpaid" {until{storage.value != nil&&s.snapshot()["checkingAccess"] as? Bool==false};expect(s.snapshot()["accessVerified"] as? Bool==false,"Google login never invents paid access");var allowed:Bool?;s.authorize{ok,_ in allowed=ok};until{allowed != nil};expect(allowed==false,"unpaid Google account blocked")}
            else if mode != "shutdown" {until{s.snapshot()["pending"] as? Bool==false};expect(storage.writes==0&&storage.clears==0,"failed or cancelled Google leaves storage intact")}
            if ["cancel","mismatch","expired","manual-cancel","shutdown","account-link"].contains(mode){expect(exchanges==before,"invalid callback never exchanges")}
            if mode=="account-link"{expect((s.snapshot()["message"] as? String ?? "").contains("lien e-mail"),"account link advice uses existing mail sign-in, not a second account")}
            s.shutdown()
        }
        now=1100;GoogleHTTP.response=success
        let stoppedMemory=GoogleMemory(),stopped=make(stoppedMemory);var ended=0,lateCallback:((URL?)->Void)?
        stopped.onGoogleSignInEnded={ended+=1};stopped.refreshSignInProviders();until{stopped.snapshot()["googleLoginReady"] as? Bool==true};stopped.signInWithGoogle{_,done in lateCallback=done};until{lateCallback != nil};let beforeLogout=exchanges
        stopped.logout();lateCallback?(URL(string:"playmelt://account/google?code=\(code)&state=\(postedState)"))
        expect(ended==1&&stoppedMemory.clears==1&&stoppedMemory.writes==0&&exchanges==beforeLogout,"explicit logout stops only the pending Google attempt and ignores late callbacks");stopped.shutdown()
        now=1100
        for provider in [false,"true"] as [Any] {let s=make();GoogleHTTP.response={_ in (200,["google":provider])};var updated=false;s.onChange={updated=true};s.refreshSignInProviders();until{updated};expect(s.snapshot()["googleLoginReady"] as? Bool==false,"strict server provider Boolean");s.signInWithGoogle{_,_ in preconditionFailure("unavailable provider")};s.shutdown()}
        print("Google account: \(checks) checks passed; intercepted requests only, no real browser, credentials or Keychain")
    }
}
