import Foundation
import CryptoKit

private final class MemoryPasswordCredentials:AccountCredentialStorage {
    var value:AccountRecord?;var writes=0,clears=0
    init(_ value:AccountRecord?=nil){self.value=value}
    func read()->AccountRecord?{value}
    func write(_ record:AccountRecord)throws{writes+=1;value=record}
    func clear(){clears+=1;value=nil}
}
private final class PasswordHTTPFixture:URLProtocol {
    static var headers:[String:String]=[:]
    static var response:(URLRequest)->(Int,[String:Any])={_ in (500,[:])}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        let (status,body)=Self.response(request)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:Self.headers.merging(["Content-Type":"application/json"]){a,_ in a})!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
@main enum PasswordTests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    static func until(_ done:()->Bool){let end=Date().addingTimeInterval(3);while !done()&&Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};expect(done(),"bounded account callback")}
    static func body(_ request:URLRequest)->[String:Any]{
        if let data=request.httpBody{return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]}
        guard let stream=request.httpBodyStream else{return [:]};stream.open();defer{stream.close()};return (try? JSONSerialization.jsonObject(with:stream)) as? [String:Any] ?? [:]
    }
    static func main()throws {
        var clock:Double=1100
        let key=Curve25519.Signing.PrivateKey(),user=UUID().uuidString,device=UUID().uuidString,token=String(repeating:"s",count:43),secret=" fixture-password-DO-NOT-RETAIN "
        let info:[String:Any]=["PlaymeltCommercialAccessEnabled":true,"PlaymeltAccountServiceAvailable":true,"PlaymeltPasswordLoginAvailable":true,"PlaymeltAccountURL":"https://example.invalid/Playmelt/compte","PlaymeltLicensePublicKey":key.publicKey.rawRepresentation.base64EncodedString()]
        func service(_ store:MemoryPasswordCredentials,override:[String:Any]=[:])->AccountService{let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[PasswordHTTPFixture.self];return AccountService(config:AccountConfiguration(info:info.merging(override){_,b in b}),credentials:store,sessionConfiguration:c,now:{clock})}
        func encoded(_ d:Data)->String{d.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
        let claims=try JSONSerialization.data(withJSONObject:["aud":"playmelt-desktop","sub":user,"device":device,"iat":1000,"exp":1900,"phase":"active","plan":"lifetime","capabilities":["launch","runtime.download"]])
        let payload=encoded(claims),ticket=payload+"."+encoded(try key.signature(for:Data(payload.utf8)))
        let storage=MemoryPasswordCredentials(),account=service(storage);defer{account.shutdown()}
        var requests=0
        PasswordHTTPFixture.response={request in
            requests+=1
            switch request.url!.lastPathComponent {
            case "device-login":
                let data=body(request)
                expect(request.httpMethod=="POST"&&request.url!.path=="/Playmelt/compte/v1/auth/device-login","exact password contract endpoint")
                expect(request.url!.query==nil&&request.value(forHTTPHeaderField:"Authorization")==nil&&request.value(forHTTPHeaderField:"Cookie")==nil,"password request has no cookies, bearer token or credentials in URL")
                expect(Set(data.keys)==Set(["email","password","label"]),"only Playmelt credentials and label are sent")
                expect(data["email"] as? String=="fixture@example.invalid"&&data["password"] as? String==secret,"email trimmed but password preserved exactly")
                return (200,["token":token,"deviceID":device,"expiresIn":2592000])
            case "me":return (200,["id":user,"email":"fixture@example.invalid","hasPassword":true,"entitlement":["phase":"active","plan":"lifetime","until":NSNull()]])
            case "launch-ticket":return (200,["ticket":ticket])
            default:return (404,[:])
            }
        }
        account.signIn(email:" fixture@example.invalid ",password:secret);account.signIn(email:"fixture@example.invalid",password:secret)
        until{account.snapshot()["accessVerified"] as? Bool==true}
        expect(requests==3,"duplicate submits coalesce and licence is separately checked")
        expect(storage.value?.token==token&&storage.value?.ticket==ticket&&storage.value?.userID==user,"only existing credential-record contract is persisted")
        expect(account.snapshot()["hasPassword"] as? Bool==true,"password availability comes from verified me response")
        expect(!String(decoding:try JSONEncoder().encode(storage.value!),as:UTF8.self).contains(secret),"password is absent from persisted credentials")
        expect(!String(decoding:try JSONSerialization.data(withJSONObject:account.snapshot()),as:UTF8.self).contains(secret),"password is absent from UI state")
        let previous=storage.value;requests=0;account.signIn(email:"other@example.invalid",password:secret)
        expect(requests==0&&storage.value?.token==previous?.token&&storage.clears==0,"existing connection is never replaced by password migration")
        for gate in [["PlaymeltPasswordLoginAvailable":false],["PlaymeltAccountServiceAvailable":false]] {
            let s=service(MemoryPasswordCredentials(),override:gate);defer{s.shutdown()};s.signIn(email:"fixture@example.invalid",password:secret)
            expect(s.snapshot()["pending"] as? Bool==false&&requests==0,"undeployed password service never receives credentials")
        }
        for status in [400,401,403,429,503] {
            let memory=MemoryPasswordCredentials(),s=service(memory);defer{s.shutdown()};PasswordHTTPFixture.response={_ in (status,["error":secret])}
            s.signIn(email:"fixture@example.invalid",password:secret);until{s.snapshot()["pending"] as? Bool==false}
            expect(memory.writes==0&&memory.clears==0&&s.snapshot()["signedIn"] as? Bool==false,"failed sign-in leaves storage untouched")
            expect(!(s.snapshot()["message"] as? String ?? "").contains(secret),"server errors cannot echo a password")
        }
        let limited=service(MemoryPasswordCredentials());defer{limited.shutdown()};requests=0;PasswordHTTPFixture.headers=["Retry-After":"30"];PasswordHTTPFixture.response={_ in requests+=1;return (429,["error":"too_many_requests"])}
        limited.signIn(email:"fixture@example.invalid",password:secret);until{limited.snapshot()["pending"] as? Bool==false}
        expect(limited.snapshot()["loginRetryAt"] as? Double==clock+30,"Retry-After bounds the next attempt")
        limited.signIn(email:"fixture@example.invalid",password:secret);expect(requests==1,"cooldown does not send another credential request")
        PasswordHTTPFixture.headers=[:];clock+=31;PasswordHTTPFixture.response={_ in requests+=1;return (401,["error":"invalid_credentials"])}
        limited.signIn(email:"fixture@example.invalid",password:secret);until{requests==2&&limited.snapshot()["pending"] as? Bool==false}
        let unpaidStorage=MemoryPasswordCredentials(),unpaid=service(unpaidStorage);defer{unpaid.shutdown()}
        PasswordHTTPFixture.response={r in switch r.url!.lastPathComponent{case "device-login":return (200,["token":token,"deviceID":device,"expiresIn":2592000]);case "me":return (200,["id":user,"email":"fixture@example.invalid","hasPassword":true,"entitlement":["phase":"inactive"]]);default:return (402,["error":"payment_required"])}}
        unpaid.signIn(email:"fixture@example.invalid",password:secret);until{unpaidStorage.value != nil&&unpaid.snapshot()["checkingAccess"] as? Bool==false}
        expect(unpaid.snapshot()["signedIn"] as? Bool==true&&unpaid.snapshot()["accessVerified"] as? Bool==false,"login success never invents a licence")
        var allowed:Bool?;unpaid.authorize{ok,_ in allowed=ok};until{allowed != nil};expect(allowed==false,"unpaid authenticated account remains blocked")
        for bad in ["bad",String(repeating:"x",count:44)] {
            let memory=MemoryPasswordCredentials(),s=service(memory);defer{s.shutdown()};PasswordHTTPFixture.response={_ in (200,["token":bad,"deviceID":device,"expiresIn":2592000])}
            s.signIn(email:"fixture@example.invalid",password:secret);until{s.snapshot()["pending"] as? Bool==false};expect(memory.writes==0&&s.snapshot()["signedIn"] as? Bool==false,"malformed token cannot enter Keychain state")
        }
        requests=0;PasswordHTTPFixture.response={_ in requests+=1;return (500,[:])}
        let invalid=service(MemoryPasswordCredentials());defer{invalid.shutdown()};invalid.signIn(email:"",password:secret);invalid.signIn(email:"fixture@example.invalid",password:"")
        expect(requests==0,"empty credentials never cross the network")
        let lateStorage=MemoryPasswordCredentials(),late=service(lateStorage);PasswordHTTPFixture.response={_ in (200,["token":token,"deviceID":device,"expiresIn":2592000])};late.signIn(email:"fixture@example.invalid",password:secret);late.shutdown()
        let end=Date().addingTimeInterval(0.05);while Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}
        expect(lateStorage.value==nil&&lateStorage.writes==0,"shutdown ignores late password responses")
        print("Password account: \(checks) intercepted transport checks passed; no real credentials, browser or Keychain used")
    }
}
