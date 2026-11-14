import Foundation

private final class BillingProbeMemory:AccountCredentialStorage {
    var record:AccountRecord?
    init(_ record:AccountRecord){self.record=record}
    func read()->AccountRecord?{record}
    func write(_ value:AccountRecord)throws{record=value}
    func clear(){record=nil}
}

/// Non-shipping hosted test tool. Fixture credentials enter through stdin only.
/// It never starts a payment, browser, game, runtime or Keychain operation.
@main enum AccountBillingHostedProbe {
    static func main() {
        do {try run()}catch {fputs("Billing probe input or output could not be processed.\n",stderr);exit(64)}
    }
    private static func run() throws {
        guard CommandLine.arguments.count==1 else{exit(64)}
        var input=Data()
        while let part=try FileHandle.standardInput.read(upToCount:4096),!part.isEmpty {
            input.append(part);guard input.count<=16384 else{exit(64)}
        }
        guard let data=try JSONSerialization.jsonObject(with:input) as? [String:Any],
              let raw=data["accountURL"] as? String,let url=URL(string:raw),url.scheme=="https",url.host=="7agency.fr",url.port==nil,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,["/Playmelt/compte-test","/Playmelt/compte-test/"].contains(url.path),
              let publicKey=data["publicKey"] as? String,Data(base64Encoded:publicKey)?.count==32,
              let token=data["token"] as? String,token.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,
              let device=data["deviceID"] as? String,UUID(uuidString:device) != nil,
              let user=data["userID"] as? String,UUID(uuidString:user) != nil,
              let expected=data["expectedAllowed"] as? Bool,
              let capability=data["capability"] as? String,["launch","runtime.download"].contains(capability),
              let label=data["caseLabel"] as? String,label.range(of:"^[a-zA-Z0-9_-]{1,60}$",options:.regularExpression) != nil else{exit(64)}
        let expectedStatus=data["expectedStatus"] as? Int ?? (expected ? 200:402)
        guard [200,401,402,403,429,503].contains(expectedStatus) else{exit(64)}
        let now=Date().timeIntervalSince1970
        let config=AccountConfiguration(info:["PlaymeltCommercialAccessEnabled":true,"PlaymeltDevelopmentBuild":false,"PlaymeltAccountServiceAvailable":true,"PlaymeltAccountURL":raw,"PlaymeltLicensePublicKey":publicKey])
        let store=BillingProbeMemory(AccountRecord(token:token,deviceID:device,userID:user,email:"",lastSeen:now))
        let service=AccountService(config:config,credentials:store)
        defer{service.shutdown()}
        var allowed:Bool?
        service.authorize(capability:capability){ok,_ in allowed=ok}
        let deadline=Date().addingTimeInterval(30)
        while allowed==nil&&Date()<deadline{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        let snapshot=service.snapshot(),verified=snapshot["accessVerified"] as? Bool==true
        let status=service.lastAuthorizationHTTPStatus ?? 0
        let passed=allowed==expected && status==expectedStatus && (allowed != true || verified) && config.enabled
        let result:[String:Any]=["caseLabel":label,"capability":capability,"completed":allowed != nil,"httpStatus":status,"expectedStatus":expectedStatus,"allowed":allowed ?? false,"expectedAllowed":expected,"passed":passed,"signedGrantVerified":verified,"accountSessionRetained":snapshot["signedIn"] as? Bool==true,"phase":snapshot["phase"] as? String ?? "","plan":snapshot["plan"] as? String ?? "","sandboxOnly":true,"keychainUsed":false,"browserOpened":false,"gameLaunched":false,"paymentStarted":false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]));print("")
        exit(passed ? 0:1)
    }
}
