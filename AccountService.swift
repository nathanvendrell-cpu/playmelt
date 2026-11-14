import Foundation
import Security
import CryptoKit
import CoreFoundation

/// Dedicated update capability. It is deliberately absent from AccountRecord,
/// Codable storage, URLs, diagnostics and the JavaScript account snapshot.
struct AccountUpdateGrant {
    static let feedURL = URL(string: "https://7agency.fr/Playmelt/compte/v1/updates/appcast.xml")!
    static let ticketURL = URL(string: "https://7agency.fr/Playmelt/compte/v1/updates/ticket")!
    private let bearer: String
    let expiresAt: Double
    private let receivedAt: Double
    var httpHeaders: [String: String] { ["Authorization": "Bearer " + bearer] }
    init?(response: [String: Any], deviceToken: String, now: Double) {
        guard Set(response.keys) == ["token", "expiresAt", "feedURL"],
              let token = response["token"] as? String, !token.isEmpty, token.utf8.count <= 4096, token != deviceToken,
              token.range(of: "^[A-Za-z0-9._~+/-]+=*$", options: .regularExpression) != nil,
              let expiry = response["expiresAt"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              now.isFinite, expiry.doubleValue.isFinite, expiry.doubleValue > now, expiry.doubleValue <= now + 600,
              response["feedURL"] as? String == Self.feedURL.absoluteString else { return nil }
        bearer = token; expiresAt = expiry.doubleValue; receivedAt = now
    }
    func isValid(now: Double) -> Bool { now.isFinite && now >= receivedAt && now < expiresAt }
}
enum AccountUpdateGrantError: Error { case unavailable, accountChanged, refused(Int), invalidResponse }

struct AccountConfiguration {
    var enabled:Bool
    var url:URL?
    var publicKey:Data?
    var serviceReady:Bool
    var passwordLoginReady:Bool
    var googleLoginReady:Bool
    var complete:Bool {url != nil && publicKey?.count == 32}
    init(info:[String:Any] = Bundle.main.infoDictionary ?? [:]) {
        // Only an explicitly marked development build may bypass entitlement
        // checks. A missing or false commercial flag must not unlock a client
        // intended for distribution.
        enabled=info["PlaymeltDevelopmentBuild"] as? Bool != true || info["PlaymeltCommercialAccessEnabled"] as? Bool == true
        serviceReady=info["PlaymeltAccountServiceAvailable"] as? Bool ?? false
        passwordLoginReady=serviceReady && info["PlaymeltPasswordLoginAvailable"] as? Bool == true
        googleLoginReady=serviceReady && info["PlaymeltGoogleLoginAvailable"] as? Bool == true
        if let raw=info["PlaymeltAccountURL"] as? String,let u=URL(string:raw),u.scheme=="https",u.host != nil,u.user==nil,u.password==nil,u.query==nil,u.fragment==nil {url=u}
        publicKey=(info["PlaymeltLicensePublicKey"] as? String).flatMap{Data(base64Encoded:$0)}
    }
    func accountPage(plan:String?=nil,activateCode:Bool=false,mode:String?=nil)->URL? {
        guard complete,serviceReady,let base=url,var target=URLComponents(url:base,resolvingAgainstBaseURL:false) else{return nil}
        if let plan {guard ["monthly","quarterly","semiannual","annual","lifetime"].contains(plan) else{return nil};target.queryItems=[URLQueryItem(name:"plan",value:plan)]}
        if let mode {guard ["signup","forgot"].contains(mode) else{return nil};if !target.path.hasSuffix("/"){target.path+="/"};target.queryItems=(target.queryItems ?? [])+[URLQueryItem(name:"mode",value:mode)]}
        if activateCode {target.fragment="activation-code"}
        return target.url
    }
}
/// The browser callback never carries a device token. PKCE material stays in memory.
struct GoogleLoginAttempt {
    let id=UUID()
    let verifier:String
    let state:String
    let deadline:Double
    static func base64url(_ data:Data)->String {data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
    var challenge:String {Self.base64url(Data(SHA256.hash(data:Data(verifier.utf8))))}
    init(now:Double) throws {
        func random() throws -> String {
            var bytes=[UInt8](repeating:0,count:32)
            let status=SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)
            guard status==errSecSuccess else {throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))}
            return Self.base64url(Data(bytes))
        }
        verifier=try random();state=try random();deadline=now+600
    }
    func code(from url:URL,now:Double)->String? {
        guard now<deadline,let c=URLComponents(url:url,resolvingAgainstBaseURL:false),
              c.scheme=="playmelt",c.host=="account",c.percentEncodedPath=="/google",c.port==nil,c.user==nil,c.password==nil,c.fragment==nil,
              let items=c.queryItems,items.count==2,Set(items.map(\.name))==Set(["code","state"]),
              items.first(where:{$0.name=="state"})?.value==state,
              let code=items.first(where:{$0.name=="code"})?.value,code.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil else{return nil}
        return code
    }
    func error(from url:URL,now:Double)->String? {
        guard now<deadline,let c=URLComponents(url:url,resolvingAgainstBaseURL:false),
              c.scheme=="playmelt",c.host=="account",c.percentEncodedPath=="/google",c.port==nil,c.user==nil,c.password==nil,c.fragment==nil,
              let items=c.queryItems,items.count==2,Set(items.map(\.name))==Set(["error","state"]),
              items.first(where:{$0.name=="state"})?.value==state,
              let error=items.first(where:{$0.name=="error"})?.value,["oauth_cancelled","oauth_failed","account_link_required"].contains(error) else{return nil}
        return error
    }
    static func allowsStart(_ url:URL,base:URL)->Bool {
        guard let c=URLComponents(url:url,resolvingAgainstBaseURL:false),c.scheme=="https",c.host==base.host,c.port==base.port,c.user==nil,c.password==nil,c.fragment==nil,
              c.percentEncodedPath==base.appendingPathComponent("v1/auth/google/start").path,
              let items=c.queryItems,items.count==1,items[0].name=="native",let value=items[0].value,value.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil else{return false}
        return true
    }
}
struct AccountRecord:Codable {
    var token:String;var deviceID:String;var userID:String;var email:String
    var ticket:String?;var lastSeen:Double
}
protocol AccountCredentialStorage {
    func read()->AccountRecord?
    func write(_ record:AccountRecord)throws
    func clear()
}
private struct SystemAccountCredentials:AccountCredentialStorage {
    func read()->AccountRecord? {AccountKeychain.read()}
    func write(_ record:AccountRecord)throws {try AccountKeychain.write(record)}
    func clear(){AccountKeychain.clear()}
}
enum AccountProtectedAction {
    static func embeddedCloudCapability(for url:URL)->String? {
        guard url.scheme=="https",url.user==nil,url.password==nil,url.port==nil,let host=url.host?.lowercased() else{return nil}
        let hosts:Set<String>=["play.geforcenow.com","luna.amazon.fr","luna.amazon.com","luna.amazon.de","luna.amazon.co.uk","luna.amazon.ca","luna.amazon.it","luna.amazon.es"]
        return hosts.contains(host) ? "launch" : nil
    }
    static func capability(for action:String)->String? {
        switch action {
        case "setupWindowsRuntime","setupD3DMetalRuntime","importD3DMetal","installNvidiaBridge","installSteamWindows","installSteamD3DMetal":return "runtime.download"
        case "launchGame","installGame","installAndPlay","retryInstallAndPlay","openWindowsSteam","openD3DMetalSteam","installLocalGame","openXbox","launchXboxCloud":return "launch"
        default:return nil
        }
    }
}
enum LaunchTicket {
    static func decode(_ value:String)->Data? {
        guard value.count<16384,value.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else {return nil}
        let base=value.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        return Data(base64Encoded:base+String(repeating:"=",count:(4-base.count%4)%4))
    }
    static func verify(_ ticket:String,key:Data,user:String,device:String,now:Double,lastSeen:Double,capability:String="launch")->[String:Any]? {
        guard now.isFinite,lastSeen.isFinite,now+5>=lastSeen,!user.isEmpty,!device.isEmpty else {return nil}
        let parts=ticket.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==2,let payload=decode(String(parts[0])),let signature=decode(String(parts[1])),let pub=try? Curve25519.Signing.PublicKey(rawRepresentation:key),pub.isValidSignature(signature,for:Data(parts[0].utf8)),let claims=(try? JSONSerialization.jsonObject(with:payload)) as? [String:Any],claims["aud"] as? String == "playmelt-desktop",claims["sub"] as? String==user,claims["device"] as? String==device,let issued=claims["iat"] as? Double,let expires=claims["exp"] as? Double,issued.isFinite,expires.isFinite,issued<=now+5,expires>now,expires>issued,expires-issued<=900,["active","trialing"].contains(claims["phase"] as? String ?? ""),(claims["capabilities"] as? [String])?.contains(capability)==true else {return nil}
        return claims
    }
}
private enum AccountKeychain {
    static var query:[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.playmelt.account.v1",kSecAttrAccount as String:"desktop",kSecAttrSynchronizable as String:false]}
    static func read()->AccountRecord? {var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne;var item:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data else{return nil};return try? JSONDecoder().decode(AccountRecord.self,from:data)}
    static func write(_ record:AccountRecord)throws {let data=try JSONEncoder().encode(record),attributes:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];var status=SecItemUpdate(query as CFDictionary,attributes as CFDictionary);if status==errSecItemNotFound {status=SecItemAdd(query.merging(attributes){_,new in new} as CFDictionary,nil)};guard status==errSecSuccess else {throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))}}
    static func clear(){SecItemDelete(query as CFDictionary)}
}
private final class AccountRedirectGuard:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
/// Server-authoritative access. Cached signed grants last at most 15 minutes; no local subscription flag.
final class AccountService {
    let config:AccountConfiguration
    private var record:AccountRecord?
    private let redirectGuard=AccountRedirectGuard()
    private var session:URLSession!
    private var poll:DispatchWorkItem?
    private var generation=UUID()
    private var updateAuthorizationGeneration=UUID()
    private var updateCredentialsAwaitingVerification=false
    private var message="",userCode="",phase="",plan=""
    private var expires:Double=0
    private var pending=false
    private var closed=false
    private var refreshing=false
    private var lastRefreshAttempt:Double?
    private var loginRetryAt:Double=0
    private var hasPassword:Bool?
    private var googleAvailable=false
    private var googleAttempt:GoogleLoginAttempt?
    private var googleTimeout:DispatchWorkItem?
    private(set) var lastAuthorizationHTTPStatus:Int?
    private var lastAuthorizationResponseHTTPStatus:Int?
    private var lastAuthorizationErrorDomain:String?
    private var lastAuthorizationErrorCode:Int?
    private let credentials:AccountCredentialStorage
    private let now:()->Double
    var onChange:(()->Void)?
    var onGoogleSignInEnded:(()->Void)?
    var onUpdateAuthorizationInvalidated:(()->Void)?
    var onUpdateCredentialsReady:(()->Void)?
    init(config:AccountConfiguration=AccountConfiguration(),credentials:AccountCredentialStorage?=nil,sessionConfiguration:URLSessionConfiguration = .ephemeral,now:@escaping()->Double={Date().timeIntervalSince1970}) {
        self.config=config;self.credentials=credentials ?? SystemAccountCredentials();self.now=now;record=self.credentials.read()
        let c=sessionConfiguration;c.timeoutIntervalForRequest=20;c.timeoutIntervalForResource=25;c.httpShouldSetCookies=false
        session=URLSession(configuration:c,delegate:redirectGuard,delegateQueue:nil)
        if let r=record,let ticket=r.ticket,let key=config.publicKey,let claims=LaunchTicket.verify(ticket,key:key,user:r.userID,device:r.deviceID,now:now(),lastSeen:r.lastSeen) {phase=claims["phase"] as? String ?? "";plan=claims["plan"] as? String ?? ""}
    }
    func shutdown(){closed=true;invalidateUpdateAuthorization();refreshing=false;poll?.cancel();googleTimeout?.cancel();googleAttempt=nil;generation=UUID();onGoogleSignInEnded?();session.invalidateAndCancel()}
    func snapshot()->[String:Any] {
        var value:[String:Any]=["enabled":config.enabled,"configured":config.complete,"serviceReady":config.serviceReady,"passwordLoginReady":config.passwordLoginReady,"signedIn":record != nil,"email":record?.email ?? "","phase":phase,"plan":plan,"expiresAt":expires,"accessVerified":validGrant(),"checkingAccess":refreshing,"loginRetryAt":loginRetryAt,"pending":pending,"userCode":userCode,"message":message,"accountURL":config.url?.absoluteString ?? ""]
        value["googleLoginReady"]=config.googleLoginReady && googleAvailable
        if let status=lastAuthorizationHTTPStatus {
            value["authorizationDiagnostic"]=["httpStatus":status,
                "responseHTTPStatus":lastAuthorizationResponseHTTPStatus as Any? ?? NSNull(),
                "errorDomain":lastAuthorizationErrorDomain as Any? ?? NSNull(),
                "errorCode":lastAuthorizationErrorCode as Any? ?? NSNull()]
        }
        if let hasPassword {value["hasPassword"]=hasPassword};return value
    }
    private func request(_ path:String,body:[String:Any]?=nil,authenticated:Bool=false,onRetryAfter:((Double)->Void)?=nil,completion:@escaping(Int,[String:Any])->Void) {
        guard !closed,let base=config.url else {completion(0,[:]);return}
        var req=URLRequest(url:base.appendingPathComponent(path));req.httpMethod=body == nil ? "GET" : "POST";req.setValue("application/json",forHTTPHeaderField:"Accept")
        if let body {req.httpBody=try? JSONSerialization.data(withJSONObject:body);req.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        if authenticated {guard let token=record?.token else {completion(401,[:]);return};req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
        let requestToken = authenticated ? record?.token : nil
        let authorizationToken = path == "v1/launch-ticket" ? record?.token:nil
        session.dataTask(with:req){[weak self] data,response,error in
            let status=error == nil ? (response as? HTTPURLResponse)?.statusCode ?? 0 : 0
            let object=(data?.count ?? Int.max)<=256*1024 ? (data.flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any] ?? [:]) : [:]
            let retry=(response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Retry-After").flatMap(Double.init) ?? 60
            let responseStatus=(response as? HTTPURLResponse)?.statusCode,transportError=error as NSError?
            DispatchQueue.main.async{
                if let self,let requestToken,self.record?.token==requestToken,status==401 {self.invalidateUpdateAuthorization()}
                if let self,let authorizationToken,self.record?.token==authorizationToken,!self.closed {
                    self.lastAuthorizationResponseHTTPStatus=responseStatus
                    self.lastAuthorizationErrorDomain=transportError?.domain
                    self.lastAuthorizationErrorCode=transportError?.code
                }
                if status==429 {onRetryAfter?(retry.isFinite ? min(900,max(1,retry)) : 60)};completion(status,object)
            }
        }.resume()
    }
    func refreshSignInProviders() {
        guard !closed,config.complete,config.serviceReady,config.googleLoginReady else {googleAvailable=false;return}
        request("v1/auth/providers") { [weak self] status,data in
            guard let self,!self.closed else{return}
            self.googleAvailable=status==200 && data["google"] as? Bool == true;self.onChange?()
        }
    }
    func cancelGoogleSignIn() {
        guard googleTimeout != nil else{return}
        googleTimeout?.cancel();googleTimeout=nil;googleAttempt=nil;generation=UUID();pending=false
        onGoogleSignInEnded?();message="Connexion Google annulée.";onChange?()
    }
    func signInWithGoogle(open:@escaping(URL,@escaping(URL?)->Void)->Void) {
        guard !closed,record==nil,!pending,!refreshing,config.googleLoginReady,googleAvailable,let base=config.url else{return}
        guard now()>=loginRetryAt else{return}
        guard let attempt=try? GoogleLoginAttempt(now:now()) else {message="La connexion Google n’a pas pu démarrer.";onChange?();return}
        let attemptID=attempt.id
        poll?.cancel();generation=attemptID;googleAttempt=attempt;pending=true;message="Connexion Google…";onChange?()
        let timeout=DispatchWorkItem{[weak self] in self?.finishGoogleFailure(attemptID,message:"La connexion Google a expiré. Réessaie.")}
        googleTimeout=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+600,execute:timeout)
        request("v1/auth/google/native/start",body:["challenge":attempt.challenge,"state":attempt.state],onRetryAfter:{[weak self] delay in
            guard let self,self.generation==attemptID else{return};self.loginRetryAt=self.now()+delay
        }) { [weak self] status,data in
            guard let self,!self.closed,self.generation==attemptID else{return}
            guard status==200,let raw=data["url"] as? String,raw.count<=2048,let url=URL(string:raw),GoogleLoginAttempt.allowsStart(url,base:base) else {
                self.finishGoogleFailure(attemptID,message:status==429 ? "Trop de tentatives. Patiente avant de réessayer." : "Connexion Google momentanément indisponible.");return
            }
            open(url) { [weak self] callback in
                DispatchQueue.main.async {
                    guard let self,!self.closed,self.generation==attemptID,let live=self.googleAttempt else{return}
                    guard let callback else {self.finishGoogleFailure(attemptID,message:"Connexion Google annulée.");return}
                    if let error=live.error(from:callback,now:self.now()) {
                        let message=error=="oauth_cancelled" ? "Connexion Google annulée." : error=="account_link_required" ? "Utilise la connexion par lien e-mail sur ton compte Playmelt pour associer Google à ton compte existant." : "Connexion Google refusée. Réessaie."
                        self.finishGoogleFailure(attemptID,message:message);return
                    }
                    guard let code=live.code(from:callback,now:self.now()) else {self.finishGoogleFailure(attemptID,message:"Retour de connexion Google non valide. Réessaie.");return}
                    // Consume the callback once, before exchanging its short-lived code.
                    self.googleAttempt=nil
                    self.request("v1/auth/google/native/exchange",body:["code":code,"verifier":live.verifier,"label":"Playmelt sur Mac"],onRetryAfter:{[weak self] delay in
                        guard let self,self.generation==attemptID else{return};self.loginRetryAt=self.now()+delay
                    }) { [weak self] status,data in
                        guard let self,!self.closed,self.generation==attemptID else{return}
                        self.googleTimeout?.cancel();self.googleTimeout=nil;self.pending=false;self.onGoogleSignInEnded?()
                        guard status==200,let token=data["token"] as? String,token.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,
                              let device=data["deviceID"] as? String,UUID(uuidString:device) != nil,
                              let ttl=data["expiresIn"] as? Double,ttl.isFinite,ttl>0,ttl<=2592000 else {
                            self.message=status==429 ? "Trop de tentatives. Patiente avant de réessayer." : "Connexion Google refusée ou expirée. Réessaie.";self.onChange?();return
                        }
                        self.invalidateUpdateAuthorization();self.updateCredentialsAwaitingVerification=true;self.record=AccountRecord(token:token,deviceID:device,userID:"",email:"",lastSeen:self.now())
                        self.message="Vérification de ton accès…";self.refresh();self.onChange?()
                    }
                }
            }
        }
    }
    private func finishGoogleFailure(_ attempt:UUID,message:String) {
        guard !closed,generation==attempt else{return}
        googleTimeout?.cancel();googleTimeout=nil;googleAttempt=nil;generation=UUID();pending=false;onGoogleSignInEnded?();self.message=message;onChange?()
    }
    /// Only the Playmelt password crosses this request; it is never persisted in
    /// AccountRecord, sent to platform connectors, or returned in UI state.
    func signIn(email:String,password:String) {
        guard !closed else{return}
        guard record == nil else{message="Ton compte Playmelt est déjà connecté.";onChange?();return}
        guard config.complete,config.serviceReady,config.passwordLoginReady else{message="La connexion par mot de passe est en préparation.";onChange?();return}
        guard !pending,!refreshing else{return}
        guard now()>=loginRetryAt else{message="Patiente un instant avant de réessayer.";onChange?();return}
        let email=email.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !email.isEmpty,email.utf8.count<=254,email.contains("@"),email.rangeOfCharacter(from:.whitespacesAndNewlines)==nil,
              !password.isEmpty,password.count<=1024,password.utf8.count<=4096 else{message="Renseigne ton e-mail et ton mot de passe Playmelt.";onChange?();return}
        poll?.cancel();generation=UUID();let attempt=generation
        pending=true;userCode="";loginRetryAt=0;message="Connexion…";onChange?()
        request("v1/auth/device-login",body:["email":email,"password":password,"label":"Playmelt sur Mac"],onRetryAfter:{[weak self] delay in
            guard let self,!self.closed,self.generation==attempt else{return};self.loginRetryAt=self.now()+delay
        }){[weak self] status,data in
            guard let self,!self.closed,self.generation==attempt else{return}
            self.pending=false
            guard status==200,let token=data["token"] as? String,token.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,
                  let device=data["deviceID"] as? String,UUID(uuidString:device) != nil,
                  let ttl=data["expiresIn"] as? Double,ttl.isFinite,ttl>0,ttl<=2592000 else{
                switch status {
                case 401:self.message="E-mail ou mot de passe incorrect."
                case 429:self.message="Trop de tentatives. Patiente avant de réessayer."
                case 400:self.message="Vérifie ton e-mail et ton mot de passe."
                default:self.message="Connexion momentanément indisponible. Réessaie dans un instant."
                };self.onChange?();return
            }
            self.invalidateUpdateAuthorization();self.updateCredentialsAwaitingVerification=true;self.record=AccountRecord(token:token,deviceID:device,userID:"",email:"",lastSeen:self.now())
            self.message="Vérification de ton accès…";self.refresh();self.onChange?()
        }
    }
    func connect(open:@escaping(URL)->Void) {
        guard !closed,config.complete,config.serviceReady else {message="La connexion au compte Playmelt sera disponible à l’ouverture du service.";onChange?();return}
        poll?.cancel();generation=UUID();let generation=self.generation
        let verifier=Data((0..<32).map{_ in UInt8.random(in:0...255)}).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let challenge=SHA256.hash(data:Data(verifier.utf8)).map{String(format:"%02x",$0)}.joined()
        pending=true;message="Préparation de la connexion…";onChange?()
        request("v1/device/start",body:["challenge":challenge,"label":"Playmelt sur Mac"]) { [weak self] status,data in
            guard let self,self.generation==generation else{return}
            guard status==200,let deviceCode=data["deviceCode"] as? String,deviceCode.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,let code=data["userCode"] as? String,code.range(of:"^[A-F0-9]{10}$",options:.regularExpression) != nil,let raw=data["verificationURL"] as? String,let url=URL(string:raw),url.scheme=="https",url.host==self.config.url?.host,url.port==self.config.url?.port,url.user==nil,url.password==nil,url.path==self.config.url!.appendingPathComponent("device").path else {self.pending=false;self.message="Connexion momentanément indisponible.";self.onChange?();return}
            self.userCode=code;self.message="Confirmez ce code dans votre compte Playmelt.";self.onChange?();open(url)
            self.pollDevice(code:deviceCode,verifier:verifier,generation:generation,deadline:self.now()+600)
        }
    }
    private func pollDevice(code:String,verifier:String,generation:UUID,deadline:Double) {
        let work=DispatchWorkItem{[weak self] in
            guard let self,self.generation==generation else{return}
            guard self.now()<deadline else {self.pending=false;self.userCode="";self.message="Le code a expiré. Relancez la connexion.";self.onChange?();return}
            self.request("v1/device/token",body:["deviceCode":code,"verifier":verifier]) { [weak self] status,data in
                guard let self,self.generation==generation else{return}
                if status==428 || status==0 || status>=500 || status==429 {self.pollDevice(code:code,verifier:verifier,generation:generation,deadline:deadline);return}
                self.pending=false;self.userCode=""
                guard status==200,let token=data["token"] as? String,token.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,let device=data["deviceID"] as? String,UUID(uuidString:device) != nil else {self.message="Connexion refusée ou expirée.";self.onChange?();return}
                self.invalidateUpdateAuthorization();self.updateCredentialsAwaitingVerification=true;self.record=AccountRecord(token:token,deviceID:device,userID:"",email:"",lastSeen:self.now())
                self.refresh()
            }
        };poll=work;DispatchQueue.main.asyncAfter(deadline:.now()+5,execute:work)
    }
    func refresh() {
        guard !closed,config.serviceReady,record != nil,!refreshing else {return}
        refreshing=true;lastRefreshAttempt=now()
        let token=record!.token
        request("v1/me",authenticated:true) { [weak self] status,data in
            guard let self,self.record?.token==token else{return}
            if status==401 {self.clearLocal();self.message="Reconnectez votre compte Playmelt.";self.onChange?();return}
            guard status==200,let user=data["id"] as? String,UUID(uuidString:user) != nil else {self.refreshing=false;self.message="Compte momentanément indisponible.";self.onChange?();return}
            if self.record?.userID != user {self.invalidateUpdateAuthorization()}
            self.record?.userID=user;self.record?.email=data["email"] as? String ?? ""
            self.hasPassword=data["hasPassword"] as? Bool
            let access=data["entitlement"] as? [String:Any];self.phase=access?["phase"] as? String ?? "inactive";self.plan=access?["plan"] as? String ?? "";self.expires=access?["until"] as? Double ?? 0
            do {try self.credentials.write(self.record!)}catch{self.refreshing=false;self.record?.ticket=nil;self.message="Le compte n’a pas pu être enregistré dans le Trousseau. Réessaie avec Actualiser mon accès.";self.onChange?();return}
            if self.updateCredentialsAwaitingVerification {
                self.updateCredentialsAwaitingVerification=false
                self.onUpdateCredentialsReady?()
            }
            self.fetchGrant {_,_ in self.refreshing=false;self.onChange?()}
        }
    }
    /// Refresh web purchases and redemptions on return without polling in the background.
    func refreshAfterReturning() {
        if let last=lastRefreshAttempt,now()>=last,now()-last<5 {return}
        refresh()
    }
    private func validGrant(capability:String="launch")->Bool {
        guard let r=record,let key=config.publicKey,let ticket=r.ticket else{return false}
        return LaunchTicket.verify(ticket,key:key,user:r.userID,device:r.deviceID,now:now(),lastSeen:r.lastSeen,capability:capability) != nil
    }
    func authorize(capability:String="launch",_ completion:@escaping(Bool,String)->Void) {
        lastAuthorizationHTTPStatus=nil
        lastAuthorizationResponseHTTPStatus=nil;lastAuthorizationErrorDomain=nil;lastAuthorizationErrorCode=nil
        guard !closed else {completion(false,"Playmelt se ferme.");return}
        guard config.enabled else {completion(true,"");return}
        guard config.complete,config.serviceReady else {completion(false,"Le service de comptes n’est pas encore disponible. Les lancements sont suspendus.");return}
        guard record != nil else {completion(false,"Connectez votre compte Playmelt pour jouer.");return}
        fetchGrant(capability:capability,completion)
    }
    private func fetchGrant(capability:String="launch",_ completion:@escaping(Bool,String)->Void) {
        guard let token=record?.token else {completion(false,"Connectez votre compte Playmelt.");return}
        request("v1/launch-ticket",body:[:],authenticated:true) { [weak self] status,data in
            guard let self,!self.closed,self.record?.token==token else {completion(false,"Le compte a changé. Relancez votre action.");return}
            self.lastAuthorizationHTTPStatus=status
            let now=self.now()
            if status==200,let ticket=data["ticket"] as? String,let key=self.config.publicKey,let r=self.record,let claims=LaunchTicket.verify(ticket,key:key,user:r.userID,device:r.deviceID,now:now,lastSeen:r.lastSeen,capability:capability) {
                self.record?.ticket=ticket;self.phase=claims["phase"] as? String ?? "";self.plan=claims["plan"] as? String ?? "";self.message=""
            } else if status==0 || status>=500 {
                // A cached grant must not outlive a refund or revocation while
                // the client is offline. Keep the session, require a fresh grant.
                self.record?.ticket=nil
                let http=self.lastAuthorizationResponseHTTPStatus ?? status
                let transport=self.lastAuthorizationErrorDomain.map{" · \($0) \(self.lastAuthorizationErrorCode ?? 0)"} ?? ""
                self.message="Vérification de l’accès indisponible (HTTP \(http)\(transport)). Votre connexion est conservée. Réessayez dans un instant."
            } else {
                self.record?.ticket=nil;self.phase="inactive";self.plan="";self.message=status==402 ? "Active ton essai ou ton abonnement depuis ton compte Playmelt." : "Accès non confirmé. Reconnecte ton compte."
                if status==401 {self.clearLocal()}
            }
            let allowed=self.validGrant(capability:capability)
            if var r=self.record {r.lastSeen=max(r.lastSeen,now);do{try self.credentials.write(r);self.record=r}catch{self.message="Impossible de sécuriser l’accès dans le Trousseau.";self.record?.ticket=nil;self.onChange?();completion(false,self.message);return}}
            self.onChange?();completion(allowed,self.message)
        }
    }
    func submitReport(_ report:[String:Any],completion:@escaping(Bool,[String:Any])->Void) {
        guard config.complete,config.serviceReady,record != nil else {completion(false,[:]);return}
        let body=report.filter{["clientId","gameId","gameTitle","store","category","message","diagnostics","createdAt"].contains($0.key)}
        request("v1/support/tickets",body:body,authenticated:true){status,data in completion(status==200 || status==201,data)}
    }
    func reportStatuses(_ completion:@escaping([[String:Any]])->Void) {
        guard config.complete,config.serviceReady,record != nil else {completion([]);return}
        request("v1/support/tickets",authenticated:true){status,data in completion(status==200 ? data["tickets"] as? [[String:Any]] ?? [] : [])}
    }
    func requestUpdateGrant(completion: @escaping (Result<AccountUpdateGrant, Error>) -> Void) {
        guard !closed,!updateCredentialsAwaitingVerification,config.complete,config.serviceReady,
              config.url?.appendingPathComponent("v1/updates/ticket") == AccountUpdateGrant.ticketURL,
              let record else { completion(.failure(AccountUpdateGrantError.unavailable)); return }
        let token=record.token,epoch=updateAuthorizationGeneration
        request("v1/updates/ticket",body:[:],authenticated:true) { [weak self] status,data in
            guard let self,!self.closed,self.record?.token==token else { completion(.failure(AccountUpdateGrantError.accountChanged)); return }
            if status==401 { self.clearLocal();self.onChange?();completion(.failure(AccountUpdateGrantError.refused(status)));return }
            guard self.updateAuthorizationGeneration==epoch else { completion(.failure(AccountUpdateGrantError.accountChanged)); return }
            guard status==200 else { completion(.failure(AccountUpdateGrantError.refused(status)));return }
            guard let grant=AccountUpdateGrant(response:data,deviceToken:token,now:self.now()) else {
                completion(.failure(AccountUpdateGrantError.invalidResponse));return
            }
            completion(.success(grant))
        }
    }
    private func invalidateUpdateAuthorization(){updateAuthorizationGeneration=UUID();onUpdateAuthorizationInvalidated?()}
    func logout(completion:((Bool)->Void)?=nil){generation=UUID();poll?.cancel();if record != nil {request("v1/auth/logout",body:[:],authenticated:true){status,_ in completion?(status==200)}}else{completion?(true)};clearLocal();message="Déconnecté de ce Mac.";onChange?()}
    private func clearLocal(){invalidateUpdateAuthorization();updateCredentialsAwaitingVerification=false;googleTimeout?.cancel();googleTimeout=nil;googleAttempt=nil;onGoogleSignInEnded?();record=nil;hasPassword=nil;phase="";plan="";expires=0;pending=false;refreshing=false;lastRefreshAttempt=nil;loginRetryAt=0;userCode="";credentials.clear()}
}
