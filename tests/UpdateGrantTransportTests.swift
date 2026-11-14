import Foundation
import CryptoKit

private final class UpdateMemoryCredentials:AccountCredentialStorage {
    var value:AccountRecord?;var writes=0;var clears=0
    init(_ value:AccountRecord?){self.value=value}
    func read()->AccountRecord?{value}
    func write(_ record:AccountRecord)throws{writes+=1;value=record}
    func clear(){clears+=1;value=nil}
}
private final class UpdateTicketHTTP:URLProtocol {
    static var response:(URLRequest)->(Int,[String:Any])={_ in (503,[:])}
    static var requests:[URLRequest]=[]
    static var bodies:[Data]=[]
    static var hold=false
    static var held:[UpdateTicketHTTP]=[]
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        Self.requests.append(request)
        var body=request.httpBody ?? Data()
        if body.isEmpty,let stream=request.httpBodyStream{
            stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:1024)
            while true{let count=stream.read(&buffer,maxLength:buffer.count);if count<=0{break};body.append(contentsOf:buffer.prefix(count))}
        }
        Self.bodies.append(body)
        if Self.hold && request.url==AccountUpdateGrant.ticketURL{Self.held.append(self);return}
        finish()
    }
    func finish(){
        let (status,body)=Self.response(request)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
@main enum UpdateGrantTransportTests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
    static func until(_ done:()->Bool){let deadline=Date().addingTimeInterval(3);while !done() && Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};expect(done(),"bounded callback")}
    static func main()throws{
        let deviceToken=String(repeating:"d",count:43),updateToken=String(repeating:"u",count:43),key=Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let record=AccountRecord(token:deviceToken,deviceID:UUID().uuidString,userID:UUID().uuidString,email:"fixture@example.test",ticket:nil,lastSeen:1000)
        let config=AccountConfiguration(info:["PlaymeltAccountURL":"https://7agency.fr/Playmelt/compte/","PlaymeltAccountServiceAvailable":true,"PlaymeltPasswordLoginAvailable":true,"PlaymeltLicensePublicKey":key.base64EncodedString()])
        var clock:Double=1000
        let response:[String:Any]=["token":updateToken,"expiresAt":1600,"feedURL":AccountUpdateGrant.feedURL.absoluteString]
        let configDefault=config
        func service(_ storage:UpdateMemoryCredentials,config:AccountConfiguration?=nil)->AccountService{
            let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[UpdateTicketHTTP.self]
            return AccountService(config:config ?? configDefault,credentials:storage,sessionConfiguration:c,now:{clock})
        }
        func ask(_ service:AccountService)->Result<AccountUpdateGrant,Error>{var result:Result<AccountUpdateGrant,Error>?;service.requestUpdateGrant{result=$0};until{result != nil};return result!}
        func succeeds(_ result:Result<AccountUpdateGrant,Error>)->Bool{if case .success=result{return true};return false}
        UpdateTicketHTTP.response={_ in (200,response)}
        let storage=UpdateMemoryCredentials(record),account=service(storage);defer{account.shutdown()}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let before=try encoder.encode(storage.value)
        let result=ask(account);expect(succeeds(result),"verified device can update without a licence or launch ticket")
        guard case .success(let grant)=result else{fatalError("fixture grant missing")}
        expect(grant.httpHeaders==["Authorization":"Bearer "+updateToken],"only scoped update bearer leaves account service")
        expect(grant.isValid(now:1000) && !grant.isValid(now:1600) && !grant.isValid(now:999),"grant has bounded expiry and rejects clock rollback")
        let request=UpdateTicketHTTP.requests.last!
        expect(request.url==AccountUpdateGrant.ticketURL && request.httpMethod=="POST","fixed ticket endpoint and method")
        expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer "+deviceToken,"device credential authenticates ticket request only")
        expect(request.value(forHTTPHeaderField:"Content-Type")=="application/json","ticket content type is JSON")
        expect((try JSONSerialization.jsonObject(with:UpdateTicketHTTP.bodies.last!)) as? [String:String]==[:],"ticket request body is exactly empty object")
        let after=try encoder.encode(storage.value)
        expect(storage.writes==0 && after==before,"update grant never enters credential storage")
        let snapshot=String(data:try JSONSerialization.data(withJSONObject:account.snapshot()),encoding:.utf8)!
        expect(!snapshot.contains(updateToken) && !snapshot.contains(deviceToken),"account snapshot exposes neither credential")
        let count=UpdateTicketHTTP.requests.count;expect(succeeds(ask(account)),"next request renews update grant")
        expect(UpdateTicketHTTP.requests.count==count+1,"no cached update capability substitutes for renewal")

        for changed in [["token":""],["token":deviceToken],["token":"bad\r\nHeader"],["feedURL":"https://other.example/appcast.xml"],["feedURL":AccountUpdateGrant.feedURL.absoluteString+"?token=x"],["expiresAt":1000],["expiresAt":1601],["expiresAt":true]] as [[String:Any]] {
            let body=response.merging(changed){_,new in new}
            expect(AccountUpdateGrant(response:body,deviceToken:deviceToken,now:clock)==nil,"malformed, excessive, expired or wrong-scope grant refused")
        }
        var extra=response;extra["deviceToken"]=deviceToken
        expect(AccountUpdateGrant(response:extra,deviceToken:deviceToken,now:clock)==nil,"unexpected response fields are not passed through")
        clock = .infinity;expect(AccountUpdateGrant(response:response,deviceToken:deviceToken,now:clock)==nil,"nonfinite clock refused");clock=1000
        for status in [302,401,403,404,503] {
            let memory=UpdateMemoryCredentials(record),candidate=service(memory);defer{candidate.shutdown()}
            var invalidations=0;candidate.onUpdateAuthorizationInvalidated={invalidations+=1}
            UpdateTicketHTTP.response={_ in (status,[:])}
            expect(!succeeds(ask(candidate)),"non-200 ticket never authorizes Sparkle")
            expect(status==401 ? invalidations>0:invalidations==0,"identity invalidation is distinct from a failed renewal result")
            expect(status==401 ? memory.value==nil : memory.value?.token==deviceToken,"only unauthorized device response clears local account")
        }
        UpdateTicketHTTP.response={_ in (200,response)}
        let absent=service(UpdateMemoryCredentials(nil));defer{absent.shutdown()}
        let oldCount=UpdateTicketHTTP.requests.count;expect(!succeeds(ask(absent)),"missing device cannot update")
        expect(UpdateTicketHTTP.requests.count==oldCount,"missing credential causes no request")
        let otherConfig=AccountConfiguration(info:["PlaymeltAccountURL":"https://other.example/Playmelt/compte/","PlaymeltAccountServiceAvailable":true,"PlaymeltLicensePublicKey":key.base64EncodedString()])
        let wrongOrigin=service(UpdateMemoryCredentials(record),config:otherConfig);defer{wrongOrigin.shutdown()}
        expect(!succeeds(ask(wrongOrigin)) && UpdateTicketHTTP.requests.count==oldCount,"device token is never sent to a configurable update origin")

        UpdateTicketHTTP.hold=true
        let canceledStorage=UpdateMemoryCredentials(record),canceled=service(canceledStorage);defer{canceled.shutdown()}
        var completed=false,invalidations=0;canceled.onUpdateAuthorizationInvalidated={invalidations+=1}
        canceled.requestUpdateGrant{value in expect(!succeeds(value),"logout refuses late successful update grant");completed=true}
        until{!UpdateTicketHTTP.held.isEmpty}
        canceled.logout();expect(invalidations>0,"logout invalidates headers synchronously")
        let held=UpdateTicketHTTP.held;UpdateTicketHTTP.held=[];UpdateTicketHTTP.hold=false;held.forEach{$0.finish()};until{completed}
        expect(canceledStorage.value==nil,"late update response cannot restore logged-out account")
        let changedStorage=UpdateMemoryCredentials(record),changed=service(changedStorage);defer{changed.shutdown()}
        UpdateTicketHTTP.hold=true;var changedDone=false,identityInvalidations=0
        changed.onUpdateAuthorizationInvalidated={identityInvalidations+=1}
        changed.requestUpdateGrant{value in expect(!succeeds(value),"changed verified account refuses previously pending grant");changedDone=true}
        until{!UpdateTicketHTTP.held.isEmpty}
        UpdateTicketHTTP.response={request in
            if request.url?.path.hasSuffix("/me")==true{return (200,["id":UUID().uuidString,"email":"changed@example.test"])}
            if request.url?.path.hasSuffix("/launch-ticket")==true{return (402,[:])}
            return (200,response)
        }
        changed.refresh();until{identityInvalidations>0}
        let changedHeld=UpdateTicketHTTP.held;UpdateTicketHTTP.held=[];UpdateTicketHTTP.hold=false;changedHeld.forEach{$0.finish()};until{changedDone}
        expect(changedStorage.value?.token==deviceToken,"identity refresh clears update capability without inventing a replacement credential")
        expect(storage.writes==0,"no update grant was ever written to the fake Keychain")
        print("Update grant transport: \(checks) PASS; injected credentials and URLProtocol only, no real Keychain, update, licence or network.")
    }
}
