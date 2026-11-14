import Foundation
@main enum Tests {
    static func main() {
        var checks=0
        func expect(_ value:Bool){checks+=1;precondition(value)}
        for address in ["https://www.xbox.com/fr-FR/play/launch/fortnite/BT5P2X999VH2","https://play.xbox.com/launch/fortnite/BT5P2X999VH2","https://play.xbox.com/stream/BT5P2X999VH2/fortnite"] {
            let url=URL(string:address)!;expect(XboxCloudRoute.isCloudPage(url));expect(XboxCloudRoute.isLaunch(url));expect(XboxCloudRoute.productID(url)=="BT5P2X999VH2")
        }
        for address in ["https://xbox.com.evil.invalid/play/launch/game/BT5P2X999VH2","http://www.xbox.com/play/launch/game/BT5P2X999VH2","https://user@www.xbox.com/play/launch/game/BT5P2X999VH2","https://www.xbox.com:444/play/launch/game/BT5P2X999VH2"] {
            let url=URL(string:address)!;expect(!XboxCloudRoute.isCloudPage(url));expect(!XboxCloudRoute.isLaunch(url))
        }
        expect(XboxCloudRoute.isCloudPage(URL(string:"https://play.xbox.com/")!))
        expect(!XboxCloudRoute.isLaunch(URL(string:"https://www.xbox.com/play/games/game/BT5P2X999VH2")!))
        let product=URL(string:"https://play.xbox.com/products/9P4NV23Q6QC2/abiotic-factor")!
        expect(!XboxCloudRoute.isLaunch(product));expect(XboxCloudRoute.productID(product)=="9P4NV23Q6QC2")
        expect(!XboxCloudRoute.isLaunch(URL(string:"https://play.xbox.com/stream/not-an-id/game")!))
        expect(XboxCloudRoute.productID(URL(string:"https://play.xbox.com.invalid/stream/BT5P2X999VH2/game")!)==nil)
        expect(XboxCloudRoute.isMicrosoftSessionDomain(".login.live.com"));expect(XboxCloudRoute.isMicrosoftSessionDomain("play.xbox.com"))
        expect(!XboxCloudRoute.isMicrosoftSessionDomain("notlive.com"));expect(!XboxCloudRoute.isMicrosoftSessionDomain("xbox.com.invalid"))
        expect(XboxInputCapabilities.mode(hasCloud:true,mouseKeyboard:true)=="keyboard-mouse")
        expect(XboxInputCapabilities.mode(hasCloud:true,mouseKeyboard:false)=="controller-required")
        expect(XboxInputCapabilities.mode(hasCloud:true,mouseKeyboard:nil)=="unknown")
        expect(XboxInputCapabilities.mode(hasCloud:false,mouseKeyboard:nil)=="pc")
        let now=Date(timeIntervalSince1970:1800000000)
        func cookie(_ domain:String,_ value:String,expires:Date?,name:String="fixture")->HTTPCookie {
            var fields:[HTTPCookiePropertyKey:Any]=[.domain:domain,.path:"/",.name:name,.value:value,.secure:"TRUE"]
            if let expires {fields[.expires]=expires}
            return HTTPCookie(properties:fields)!
        }
        let legacy=cookie(".xbox.com","old",expires:now.addingTimeInterval(60)),current=cookie(".xbox.com","current",expires:now.addingTimeInterval(120))
        expect(XboxSessionCookies.migrationCandidates([legacy],current:[current],now:now).isEmpty)
        let expired=cookie(".xbox.com","expired",expires:now.addingTimeInterval(-1))
        expect(XboxSessionCookies.migrationCandidates([legacy],current:[expired],now:now).first?.value=="old")
        expect(XboxSessionCookies.migrationCandidates([expired,cookie("other.invalid","unrelated",expires:nil)],current:[],now:now).isEmpty)
        let session=cookie(".live.com","session",expires:nil),migrated=XboxSessionCookies.migrationCandidates([session],current:[],now:now)
        expect(migrated.first?.expiresDate==nil && migrated.first?.isSecure==true)
        expect(XboxSessionCookies.migrationCandidates([legacy],current:[],now:now).first?.expiresDate==legacy.expiresDate)
        let signedIn=cookie(".live.com","current-account",expires:now.addingTimeInterval(60),name:"MSPAuth")
        let oldAccount=cookie(".xbox.com","other-account",expires:now.addingTimeInterval(60),name:"XBXXtk_fixture")
        expect(XboxSessionCookies.migrationCandidates([oldAccount],current:[signedIn],now:now).isEmpty)
        print("Xbox session: \(checks) route, input-capability and cookie-domain checks passed; no personal cookies accessed")
    }
}
