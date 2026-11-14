import Foundation
import WebKit

enum XboxCloudRoute {
    static func isXboxHost(_ host: String) -> Bool { host == "xbox.com" || host.hasSuffix(".xbox.com") }
    static func isCloudPage(_ url: URL) -> Bool {
        guard url.scheme=="https",url.user==nil,url.password==nil,url.port==nil,let host=url.host?.lowercased(), isXboxHost(host) else { return false }
        return host == "play.xbox.com" || url.path.split(separator:"/").contains("play") || isLaunch(url)
    }
    static func isLaunch(_ url: URL) -> Bool {
        guard url.scheme=="https",url.user==nil,url.password==nil,url.port==nil,let host=url.host?.lowercased(),isXboxHost(host) else {return false}
        let parts=url.path.split(separator:"/")
        if host == "play.xbox.com",parts.first == "stream",parts.count>=2 {
            return validProductID(String(parts[1]))
        }
        return parts.contains("launch") && parts.last.map{validProductID(String($0))} == true
    }
    static func validProductID(_ value:String)->Bool {
        value.range(of:"^[A-Za-z0-9]{12}$",options:.regularExpression) != nil
    }
    static func productID(_ url:URL)->String? {
        guard isCloudPage(url) else{return nil}
        let parts=url.path.split(separator:"/")
        if url.host?.lowercased() == "play.xbox.com",["stream","products"].contains(parts.first.map(String.init) ?? ""),parts.count>=2,
           validProductID(String(parts[1])) {return String(parts[1]).uppercased()}
        guard parts.contains("launch") || parts.contains("games"),let last=parts.last,validProductID(String(last)) else{return nil}
        return String(last).uppercased()
    }
    static func isMicrosoftSessionDomain(_ domain:String)->Bool {
        let host=domain.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
        return ["xbox.com","live.com","microsoft.com","microsoftonline.com"].contains { host == $0 || host.hasSuffix("."+$0) }
    }
}
enum XboxInputCapabilities {
    static func mode(hasCloud:Bool,mouseKeyboard:Bool?)->String {
        hasCloud ? (mouseKeyboard.map{$0 ? "keyboard-mouse" : "controller-required"} ?? "unknown") : "pc"
    }
}
enum XboxSessionCookies {
    static func migrationCandidates(_ source:[HTTPCookie],current:[HTTPCookie],now:Date)->[HTTPCookie] {
        let sessionNames:Set<String>=["MSPAuth","RPSSAuth","WLSSC","__Host-MSAAUTH"]
        if current.contains(where:{cookie in XboxCloudRoute.isMicrosoftSessionDomain(cookie.domain) && (cookie.expiresDate.map{$0>now} ?? true) &&
            (sessionNames.contains(cookie.name) || cookie.name.hasPrefix("XBXXtk") || cookie.name.hasPrefix("XNXXtk"))}) {return []}
        return source.filter { cookie in
            XboxCloudRoute.isMicrosoftSessionDomain(cookie.domain) && (cookie.expiresDate.map{$0>now} ?? true) &&
            !current.contains{ $0.domain==cookie.domain && $0.name==cookie.name && $0.path==cookie.path && ($0.expiresDate.map{$0>now} ?? true) }
        }
    }
}
final class XboxCookieObserver:NSObject,WKHTTPCookieStoreObserver {
    var onChange:()->Void
    init(_ onChange:@escaping()->Void){self.onChange=onChange}
    func cookiesDidChange(in cookieStore:WKHTTPCookieStore){onChange()}
}

/// One WebKit-owned session for Xbox everywhere in Playmelt. Cookie values never enter app state or logs.
enum XboxWebSession {
    static let store=WKWebsiteDataStore.default()
    private static let legacyHub=WKWebsiteDataStore(forIdentifier:UUID(uuidString:"8BCDA5D0-5533-4672-A758-B265EF735D87")!)
    private static var prepared=false,preparing=false
    private static var callbacks:[()->Void]=[]
    static func prepare(_ completion:@escaping()->Void) {
        precondition(Thread.isMainThread)
        if prepared {completion();return}
        callbacks.append(completion)
        guard !preparing else{return};preparing=true
        legacyHub.httpCookieStore.getAllCookies { source in
            store.httpCookieStore.getAllCookies { current in
                let group=DispatchGroup(),now=Date()
                for cookie in XboxSessionCookies.migrationCandidates(source,current:current,now:now) {
                    // Preserve Microsoft's expiry and security flags; never turn session cookies into permanent credentials.
                    group.enter();store.httpCookieStore.setCookie(cookie){group.leave()}
                }
                group.notify(queue:.main){prepared=true;preparing=false;let pending=callbacks;callbacks=[];pending.forEach{$0()}}
            }
        }
    }
    static func disconnect(_ completion:@escaping()->Void) {
        prepare {
        let stores=[store,legacyHub],group=DispatchGroup()
        for data in stores {
            group.enter()
            data.httpCookieStore.getAllCookies {cookies in
                let removals=DispatchGroup()
                for cookie in cookies where XboxCloudRoute.isMicrosoftSessionDomain(cookie.domain) {
                    removals.enter();data.httpCookieStore.delete(cookie){removals.leave()}
                }
                removals.notify(queue:.main){group.leave()}
            }
        }
        group.notify(queue:.main){prepared=true;completion()}
        }
    }
}
