import AppKit
import Sparkle

enum UpdateTransportPolicy {
    static func build(_ value:String?) -> UInt64? {
        guard let value,let number=UInt64(value),number>0,String(number)==value else{return nil};return number
    }
    static func archiveAllowed(_ url:URL?,version:String,currentBuild:String?) -> Bool {
        guard let url,let c=URLComponents(url:url,resolvingAgainstBaseURL:false),
              c.scheme=="https",c.host=="7agency.fr",c.port==nil,c.user==nil,c.password==nil,c.query==nil,c.fragment==nil,
              !url.absoluteString.contains("%"),let offered=build(version),let current=build(currentBuild),offered>current else{return false}
        let prefix="/Playmelt/compte/v1/updates/archive/"
        guard c.path.hasPrefix(prefix) else{return false}
        let parts=String(c.path.dropFirst(prefix.count)).split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        return parts.count==3 && parts[0]==version &&
            parts[1].range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil &&
            parts[2].range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\\.(zip|dmg)$",options:.regularExpression) != nil
    }
    static func itemAllowed(_ item:SUAppcastItem,currentBuild:String?,hasSigningKey:Bool)->Bool {
        guard hasSigningKey,archiveAllowed(item.fileURL,version:item.versionString,currentBuild:currentBuild),item.infoURL==nil,
              item.releaseNotesURL==nil,item.propertiesDictionary["description"]==nil,
              let enclosure=item.propertiesDictionary["enclosure"] as? [String:Any],
              let encoded=enclosure["sparkle:edSignature"] as? String,Data(base64Encoded:encoded)?.count==64 else{return false}
        return true
    }
}

/// Signed updates download in the background and install on quit. Active work defers relaunch.
final class UpdaterController:NSObject,SPUUpdaterDelegate {
    static let shared=UpdaterController()
    private var sparkle:SPUStandardUpdaterController?
    private let now:()->Double
    private let currentBuild:String?
    private let hasSigningKey:Bool
    private let checkOverride:((Bool)->Void)?
    private var grant:AccountUpdateGrant?
    private var grantGeneration=UUID()
    private var renewing=false
    private var pendingCheck:Bool?
    private var cyclePermit=false
    private var cycleActive=false
    var updateGrantProvider:((@escaping(Result<AccountUpdateGrant,Error>)->Void)->Void)?
    var onFailure:((String)->Void)?
    var isBusy:()->Bool = {true}
    private var pendingRelaunch:(()->Void)?
    private var pendingLaunchCheck=false
    private(set) var isInstalling=false
    init(now:@escaping()->Double={Date().timeIntervalSince1970},controller:SPUStandardUpdaterController?=nil,
         currentBuild:String?=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String,
         signingKey:String?=Bundle.main.object(forInfoDictionaryKey:"SUPublicEDKey") as? String,
         check:((Bool)->Void)?=nil) {
        self.now=now;self.sparkle=controller;self.currentBuild=currentBuild
        self.hasSigningKey=signingKey.flatMap{Data(base64Encoded:$0)}?.count==32;self.checkOverride=check
        super.init()
    }
    static func automaticUpdatesAllowed(info:[String:Any],identifier:String?)->Bool {
        guard let identifier,!identifier.hasSuffix(".preview"),info["PlaymeltDevelopmentBuild"] as? Bool != true else{return false}
        // Initial commercial downloads go through the authenticated account.
        // Do not fall back to the old public feed until private transport is verified.
        return info["PlaymeltAutomaticUpdatesAvailable"] as? Bool == true
    }
    var isEnabled:Bool {
        Self.automaticUpdatesAllowed(info:Bundle.main.infoDictionary ?? [:],identifier:Bundle.main.bundleIdentifier) &&
        hasSigningKey && UpdateTransportPolicy.build(currentBuild) != nil
    }
    var updaterMenuTarget:UpdaterController? {sparkle == nil ? nil:self}
    func start(){
        guard isEnabled,sparkle==nil,updateGrantProvider != nil else{return}
        let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:self,userDriverDelegate:nil)
        sparkle=controller;controller.updater.httpHeaders=nil
        _=controller.updater.clearFeedURLFromUserDefaults()
        controller.updater.sendsSystemProfile=false
        controller.startUpdater()
        pendingLaunchCheck=true
        DispatchQueue.main.async{[weak self] in self?.resumeWhenIdle()}
    }
    func resumeWhenIdle(){
        guard !isBusy() else{return}
        if let handler=pendingRelaunch {pendingRelaunch=nil;handler();return}
        if pendingLaunchCheck {pendingLaunchCheck=false;if pendingCheck==nil{pendingCheck=false}}
        authorizePendingCheck()
    }
    @objc func checkForUpdates(_ sender:Any?=nil){requestCheck(userInitiated:true)}
    func credentialsDidBecomeReady(){requestCheck(userInitiated:false)}
    func requestCheck(userInitiated:Bool){
        guard sparkle != nil else{return}
        pendingCheck=(pendingCheck ?? false) || userInitiated
        authorizePendingCheck()
    }
    private func authorizePendingCheck(){
        guard !isBusy(),!renewing,!cycleActive,let requested=pendingCheck,
              checkOverride != nil || sparkle?.updater.canCheckForUpdates==true else{return}
        guard let provider=updateGrantProvider else{clearUpdateAuthorization();onFailure?("Connectez votre compte Playmelt pour rechercher les mises à jour.");return}
        grant=nil;sparkle?.updater.httpHeaders=nil;cyclePermit=false
        renewing=true;let epoch=UUID();grantGeneration=epoch
        provider{[weak self] result in
            guard let self,self.grantGeneration==epoch,self.renewing else{return}
            self.renewing=false
            guard case .success(let value)=result,value.isValid(now:self.now()) else{
                self.clearUpdateAuthorization();self.onFailure?("La vérification des mises à jour est indisponible. Vérifiez votre connexion au compte Playmelt.");return
            }
            guard !self.isBusy() else{self.grant=nil;self.sparkle?.updater.httpHeaders=nil;return}
            self.grant=value;self.sparkle?.updater.httpHeaders=value.httpHeaders;self.cyclePermit=true
            let interactive=(self.pendingCheck ?? requested);self.pendingCheck=nil
            if let check=self.checkOverride {check(interactive)}
            else if interactive{self.sparkle?.checkForUpdates(nil)}else{self.sparkle?.updater.checkForUpdatesInBackground()}
        }
    }
    func clearUpdateAuthorization(){clearAuthorization(preservePending:false)}
    private func clearAuthorization(preservePending:Bool){
        grantGeneration=UUID();renewing=false;grant=nil;cyclePermit=false;sparkle?.updater.httpHeaders=nil
        if !preservePending{pendingCheck=nil}
    }
    func feedURLString(for updater:SPUUpdater)->String?{AccountUpdateGrant.feedURL.absoluteString}
    func updater(_ updater:SPUUpdater,mayPerform updateCheck:SPUUpdateCheck)throws{
        guard !isBusy(),cyclePermit,let grant,grant.isValid(now:now()) else{
            pendingCheck=(pendingCheck ?? false) || updateCheck == .updates
            throw NSError(domain:"PlaymeltUpdate",code:1,userInfo:[NSLocalizedDescriptionKey:"Une autorisation de mise à jour est nécessaire."])
        }
        cyclePermit=false;cycleActive=true;updater.httpHeaders=grant.httpHeaders
    }
    func updater(_ updater:SPUUpdater,shouldProceedWithUpdate item:SUAppcastItem,updateCheck:SPUUpdateCheck)throws{
        guard let grant,grant.isValid(now:now()),UpdateTransportPolicy.itemAllowed(item,currentBuild:currentBuild,hasSigningKey:hasSigningKey) else{
            throw NSError(domain:"PlaymeltUpdate",code:2,userInfo:[NSLocalizedDescriptionKey:"Cette mise à jour ne correspond pas au canal signé Playmelt."])
        }
    }
    func updater(_ updater:SPUUpdater,shouldDownloadReleaseNotesForUpdate item:SUAppcastItem)->Bool{false}
    func updater(_ updater:SPUUpdater,willDownloadUpdate item:SUAppcastItem,with request:NSMutableURLRequest){
        guard let grant,grant.isValid(now:now()),UpdateTransportPolicy.itemAllowed(item,currentBuild:currentBuild,hasSigningKey:hasSigningKey),
              UpdateTransportPolicy.archiveAllowed(request.url,version:item.versionString,currentBuild:currentBuild) else{
            request.allHTTPHeaderFields=[:];request.setValue(nil,forHTTPHeaderField:"Authorization");request.httpBody=nil;request.url=URL(string:"about:blank")
            clearUpdateAuthorization();onFailure?("La mise à jour n’est plus autorisée pour ce téléchargement. Recherchez à nouveau les mises à jour.");return
        }
        request.setValue(grant.httpHeaders["Authorization"],forHTTPHeaderField:"Authorization")
    }
    func updater(_ updater:SPUUpdater,shouldPostponeRelaunchForUpdate item:SUAppcastItem,untilInvokingBlock installHandler:@escaping()->Void)->Bool {
        guard isBusy() else{return false};pendingRelaunch=installHandler;return true
    }
    func updater(_ updater:SPUUpdater,willInstallUpdateOnQuit item:SUAppcastItem,immediateInstallationBlock immediateInstallHandler:@escaping()->Void)->Bool {
        // NO preserves install-on-quit while Sparkle continues scheduling. YES
        // would take ownership of this handler and stall all following cycles.
        return false
    }
    func updaterShouldRelaunchApplication(_ updater:SPUUpdater)->Bool {!isBusy()}
    func updater(_ updater:SPUUpdater,willInstallUpdate item:SUAppcastItem){isInstalling=true}
    func updater(_ updater:SPUUpdater,didAbortWithError error:Error){isInstalling=false;pendingRelaunch=nil;clearAuthorization(preservePending:true)}
    func updater(_ updater:SPUUpdater,didFinishUpdateCycleFor updateCheck:SPUUpdateCheck,error:Error?){
        cycleActive=false;clearAuthorization(preservePending:true)
        if pendingCheck != nil {DispatchQueue.main.async{[weak self] in self?.resumeWhenIdle()}}
    }
}
