import Foundation
import CryptoKit
import Sparkle

private final class FirstSignInMemory:AccountCredentialStorage {
    var value:AccountRecord?;var writes=0
    func read()->AccountRecord?{value}
    func write(_ value:AccountRecord)throws{writes+=1;self.value=value}
    func clear(){value=nil}
}
private final class FirstSignInHTTP:URLProtocol {
    static var response:(URLRequest)->(Int,[String:Any])={_ in (503,[:])}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){let(status,data)=Self.response(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:data));client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){}
}
@main enum UpdaterFirstSignInTests {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;if !value{fputs("FAIL: "+label+"\n",stderr);exit(1)}}
    static func until(_ done:()->Bool){let deadline=Date().addingTimeInterval(3);while !done()&&Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};expect(done(),"bounded callback")}
    static func body(_ request:URLRequest)->[String:Any]{if let data=request.httpBody{return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]};guard let stream=request.httpBodyStream else{return [:]};stream.open();defer{stream.close()};return (try? JSONSerialization.jsonObject(with:stream)) as? [String:Any] ?? [:]}
    static func main()throws{
        for mode in ["password","google"] {for wireReady in [false,true] {
            let memory=FirstSignInMemory(),user=UUID().uuidString,device=UUID().uuidString,token=String(repeating:"d",count:43)
            let publicKey=Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,base=URL(string:"https://7agency.fr/Playmelt/compte/")!
            let config=AccountConfiguration(info:["PlaymeltAccountURL":base.absoluteString,"PlaymeltAccountServiceAvailable":true,"PlaymeltPasswordLoginAvailable":true,"PlaymeltGoogleLoginAvailable":true,"PlaymeltLicensePublicKey":publicKey.base64EncodedString()])
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[FirstSignInHTTP.self]
            let account=AccountService(config:config,credentials:memory,sessionConfiguration:configuration,now:{1000})
            let host=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
            var performed=0,ticketRequests=0,readyEvents=0,state=""
            let updater=UpdaterController(now:{1000},controller:host,currentBuild:"29",signingKey:Data(repeating:0,count:32).base64EncodedString(),check:{interactive in expect(!interactive,"new login schedules a background check");performed+=1})
            updater.isBusy={false};updater.updateGrantProvider={account.requestUpdateGrant(completion:$0)}
            account.onUpdateAuthorizationInvalidated={updater.clearUpdateAuthorization()}
            account.onChange={updater.resumeWhenIdle()}
            if wireReady {account.onUpdateCredentialsReady={
                readyEvents+=1;expect(memory.writes>0 && memory.value?.userID==user,"credentials-ready follows verified identity and successful private save")
                updater.credentialsDidBecomeReady()
            }}
            FirstSignInHTTP.response={request in
                let path=request.url!.path
                if path.hasSuffix("/auth/providers"){return(200,["google":true])}
                if path.hasSuffix("/auth/google/native/start"){
                    state=body(request)["state"] as? String ?? ""
                    return(200,["url":base.appendingPathComponent("v1/auth/google/start").absoluteString+"?native="+String(repeating:"n",count:43)])
                }
                if path.hasSuffix("/auth/device-login") || path.hasSuffix("/auth/google/native/exchange"){return(200,["token":token,"deviceID":device,"expiresIn":2592000])}
                if path.hasSuffix("/me"){return(200,["id":user,"email":"fixture@example.test","hasPassword":mode=="password"])}
                if path.hasSuffix("/launch-ticket"){return(402,["error":"subscription_required"])}
                if path.hasSuffix("/updates/ticket"){
                    ticketRequests+=1
                    return(200,["token":String(repeating:"u",count:43),"expiresAt":1600,"feedURL":AccountUpdateGrant.feedURL.absoluteString])
                }
                return(503,[:])
            }
            updater.requestCheck(userInitiated:false)
            expect(performed==0 && ticketRequests==0,"first launch without AccountRecord does not send an authenticated update request")
            if mode=="password" {account.signIn(email:"fixture@example.test",password:"Fixture password phrase")}
            else {
                account.refreshSignInProviders();until{account.snapshot()["googleLoginReady"] as? Bool==true}
                var callback:((URL?)->Void)?
                account.signInWithGoogle{_,done in callback=done};until{callback != nil}
                callback?(URL(string:"playmelt://account/google?code="+String(repeating:"c",count:43)+"&state="+state))
            }
            until{memory.value?.userID==user && account.snapshot()["checkingAccess"] as? Bool==false && (!wireReady || performed==1)}
            expect(account.snapshot()["accessVerified"] as? Bool==false,"expired/inactive licence remains unable to launch")
            expect(performed==(wireReady ? 1:0),wireReady ? "one automatic update check after first sign-in":"negative control reproduces the old lost-startup-check bug")
            expect(ticketRequests==(wireReady ? 1:0),"only the distinct credentials event renews update transport")
            for _ in 0..<20{account.onChange?();updater.resumeWhenIdle()}
            account.refresh();until{account.snapshot()["checkingAccess"] as? Bool==false}
            expect(performed==(wireReady ? 1:0) && readyEvents==(wireReady ? 1:0),"notifications and later identity refresh cannot loop update checks")
            account.shutdown();updater.clearUpdateAuthorization()
        }}
        print("Updater first sign-in: \(checks) PASS; password/Google and negative controls, no real browser, Keychain, Sparkle cycle or network.")
    }
}
