import Foundation
import AppKit
import WebKit
import GameController

/// Xbox Game Pass Ultimate — Cloud Gaming & PC Game Pass connector for Playmelt.
///
/// Catalogue: the official, public Game Pass catalogue feeds (catalog.gamepass.com SIGL lists)
/// for both Cloud Gaming and PC Game Pass, resolved through the Microsoft Store display catalogue
/// (displaycatalog.mp.microsoft.com).
///
/// Each game is tagged with its capabilities: Cloud Gaming (`hasCloud`), PC Game Pass (`hasPC`), or both.
///
/// Account: the Microsoft sign-in happens inside Playmelt's Xbox Cloud window (WKWebView, persistent
/// default data store). "Connected" is reported only when a Microsoft account session cookie exists.
final class XboxConnector {
    struct Title: Codable {
        let id: String          // Microsoft Store product ID (BigId), e.g. 9NKX70BBCDRN
        let title: String
        let imageURL: String    // 16:9 hero art
        let portraitURL: String // 2:3 poster
        let developer: String
        let category: String
        var hasCloud: Bool
        var hasPC: Bool
        var hasMouseKeyboard: Bool? = nil
        var recentRank: Int? = nil

        enum CodingKeys: String, CodingKey {
            case id, title, imageURL, portraitURL, developer, category, hasCloud, hasPC, hasMouseKeyboard, recentRank
        }

        init(id: String, title: String, imageURL: String, portraitURL: String, developer: String, category: String, hasCloud: Bool, hasPC: Bool) {
            self.id = id
            self.title = title
            self.imageURL = imageURL
            self.portraitURL = portraitURL
            self.developer = developer
            self.category = category
            self.hasCloud = hasCloud
            self.hasPC = hasPC
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            imageURL = try container.decode(String.self, forKey: .imageURL)
            portraitURL = try container.decode(String.self, forKey: .portraitURL)
            developer = try container.decodeIfPresent(String.self, forKey: .developer) ?? ""
            category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
            hasCloud = try container.decodeIfPresent(Bool.self, forKey: .hasCloud) ?? true
            hasPC = try container.decodeIfPresent(Bool.self, forKey: .hasPC) ?? false
            hasMouseKeyboard = try container.decodeIfPresent(Bool.self, forKey: .hasMouseKeyboard)
            recentRank = try container.decodeIfPresent(Int.self, forKey: .recentRank)
        }

        var cloudURL: URL? {
            guard hasCloud,XboxCloudRoute.validProductID(id) else { return nil }
            // Current Xbox player route, verified through the official cloud Play button.
            return URL(string: "https://play.xbox.com/stream/\(id)/\(XboxConnector.slug(title))")
        }

        var storeURL: URL {
            URL(string: "https://www.xbox.com/fr-FR/games/store/\(XboxConnector.slug(title))/\(id)")!
        }
    }

    private struct CachedCatalog: Codable {
        let fetchedAt: Date
        let titles: [Title]
        var verifiedComplete: Bool? = nil
    }

    /// Official SIGL ids for Game Pass lists: Cloud Gaming and PC Game Pass
    static let cloudSiglID = "29a81209-df6f-41fd-a528-2ae6b91f719c"
    static let pcSiglID = "fdd9e2a7-0fee-49f6-ad69-4354098401ff"
    // Official Xbox web client's CloudPlayWithMouseAndKeyboard gallery (observed 12 Nov 2026).
    static let mouseKeyboardSiglID = "3aa7a358-f15b-476b-af7e-134a250c08a0"
    // Listes officielles « Ajouts récents » du catalogue Game Pass (observées le 13 nov. 2026).
    static let recentSiglIDs = ["163cdff5-442e-4957-97f5-1050a3546511", "f13cf6b4-57e6-4459-89df-6aec18cf0538"]
    static let market = "FR", language = "fr-fr"
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private static let failureRetryLifetime: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var titles: [Title] = []
    private var fetchedAt: Date?
    private var fetching = false
    private var lastError = ""
    private var lastAttempt: Date?
    private var signedIn = false
    private let cacheURL: URL
    private let catalogHTTP: XboxCatalogHTTPClient
    private let now: () -> Date
    private var cookieObserver:XboxCookieObserver?
    let recentGames:XboxRecentGames

    /// Called on the main queue when the catalogue or the sign-in state changed.
    var onUpdate: (() -> Void)?
    var onOpenCloud: ((URL, Bool) -> Void)?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         catalogConfiguration:URLSessionConfiguration?=nil,now:@escaping()->Date=Date.init,
         observeSession:Bool=true) {
        let support = home.appendingPathComponent("Library/Application Support/Playmelt", isDirectory: true)
        cacheURL = support.appendingPathComponent(".xbox_cloud_catalog.json")
        self.now=now
        recentGames=XboxRecentGames(url:support.appendingPathComponent("xbox-recent.json"))
        catalogHTTP=XboxCatalogHTTPClient(configuration:catalogConfiguration ?? .ephemeral)
        if let data = try? Data(contentsOf: cacheURL,options:.mappedIfSafe),data.count<=8*1024*1024,
           let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
           !cached.titles.isEmpty,cached.titles.count<=4000,cached.titles.allSatisfy({XboxCloudRoute.validProductID($0.id) && !$0.title.isEmpty && ($0.hasCloud || $0.hasPC)}) {
            titles = cached.titles
            fetchedAt = cached.fetchedAt
            if cached.verifiedComplete != true {lastError="Catalogue en cache : actualisation complète à vérifier."}
        }
        guard observeSession else{return}
        DispatchQueue.main.async { [weak self] in
            guard let self else{return}
            let observer=XboxCookieObserver{[weak self] in self?.refreshSignInState()}
            self.cookieObserver=observer;XboxWebSession.store.httpCookieStore.add(observer)
            self.refreshSignInState()
        }
    }
    deinit {catalogHTTP.cancel();if let cookieObserver {XboxWebSession.store.httpCookieStore.remove(cookieObserver)}}

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        let parts = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber || !$0.isASCII })
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "game" : String(joined.prefix(80))
    }

    // MARK: State

    func availability() -> [String: Any] {
        lock.lock()
        let count = titles.count
        let cloudCount = titles.filter(\.hasCloud).count
        let pcCount = titles.filter(\.hasPC).count
        let busy = fetching, error = lastError, connected = signedIn, date = fetchedAt, attempt = lastAttempt
        lock.unlock()
        var message: String
        let stale=count>0 && (!error.isEmpty || date.map{now().timeIntervalSince($0)>Self.cacheLifetime} ?? true)
        if count == 0 {
            message = busy ? "Chargement du catalogue Xbox Game Pass…" : (error.isEmpty ? "Catalogue Xbox non chargé." : error)
        } else if connected {
            message = "Session Microsoft détectée · \(cloudCount) jeux Cloud & \(pcCount) jeux PC Windows. Abonnement à vérifier dans Xbox."
        } else {
            message = "\(count) jeux Game Pass disponibles (\(cloudCount) Cloud, \(pcCount) PC). Connectez votre compte Microsoft pour jouer."
        }
        if count>0 && (!error.isEmpty || stale) {
            let lastGood=date.map{ISO8601DateFormatter().string(from:$0)} ?? "date inconnue"
            message += " " + (error.isEmpty ? "Actualisation nécessaire." : error) + " Dernier catalogue conservé : " + lastGood + "."
        }
        return [
            "catalogError":error,
            "catalogStale":stale,
            "catalogStatus":busy ? "loading" : (count==0 ? "unavailable" : stale ? "stale" : "ready"),
            "lastAttemptAt":attempt.map{ISO8601DateFormatter().string(from:$0)} ?? "",
            "status": connected ? "connected" : (count > 0 ? "requiresLogin" : (busy ? "loading" : "unavailable")),
            "available": count > 0,
            "authenticated": connected,
            "controllerConnected": !GCController.controllers().isEmpty,
            "cloudEnabled": true,
            "cloudCount": cloudCount,
            "pcCount": pcCount,
            "catalogCount": count,
            "busy": busy,
            "updatedAt": date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "cloudProvider": "Xbox Cloud Gaming",
            "message": message
        ]
    }

    func games() -> [Game] {
        lock.lock(); let list = titles; lock.unlock()
        return list.map { title in
            var platforms: [String] = []
            if title.hasCloud { platforms.append("cloud") }
            if title.hasPC { platforms.append("windows") }
            let rName = title.hasCloud && title.hasPC ? "Cloud & PC Game Pass" : (title.hasCloud ? "Xbox Cloud Gaming" : "PC Game Pass")
            var game=Game(id: "xbox:" + title.id, appId: title.id, title: title.title, store: "xbox",
                 installed: false, platform: title.hasCloud ? "cloud" : "windows",
                 runtimeId: title.hasCloud ? "xbox-cloud" : "pc-gamepass",
                 runtimeName: rName,
                 ownership: "game-pass", path: nil, complete: true,
                 epicLaunchID: title.cloudURL?.absoluteString ?? title.storeURL.absoluteString,
                 supportedPlatforms: platforms, customImageURL: title.imageURL, customPortraitURL: title.portraitURL,
                 lastPlayed: recentGames.lastPlayed(title.id), installSource: "xbox")
            game.cloudInputMode = XboxInputCapabilities.mode(hasCloud:title.hasCloud,mouseKeyboard:title.hasMouseKeyboard)
            game.gamePassRecent = title.recentRank ?? -1
            return game
        }
    }

    // MARK: Catalogue

    /// Refreshes the cloud & PC catalogue when stale (or when forced). Safe to call often.
    func refreshCatalog(force: Bool = false) {
        lock.lock()
        let now = self.now()
        let stale = fetchedAt.map { now.timeIntervalSince($0) > Self.cacheLifetime } ?? true
        // Un échec précédent est retenté régulièrement pour ne jamais rester bloqué sur un vieux cache.
        let retryDue = lastError.isEmpty == false &&
            (lastAttempt.map { now.timeIntervalSince($0) >= Self.failureRetryLifetime } ?? true)
        let needsInputMetadata = lastAttempt == nil && (titles.contains{$0.hasCloud && $0.hasMouseKeyboard == nil} || !titles.contains{$0.recentRank != nil})
        // A stale/empty cache must not bypass failure backoff through onUpdate/checkXbox.
        if !force,!lastError.isEmpty,let lastAttempt,now.timeIntervalSince(lastAttempt)<Self.failureRetryLifetime {
            lock.unlock();return
        }
        guard !fetching, force || stale || retryDue || titles.isEmpty || needsInputMetadata else { lock.unlock(); return }
        fetching = true; lastAttempt = now
        lock.unlock()
        DispatchQueue.main.async { self.onUpdate?() }

        let group = DispatchGroup(), idsLock = NSLock()
        var cloudIds:[String]?,pcIds:[String]?,mouseKeyboard:Set<String>?
        var recentLists:[Int:[String]]=[:]
        let feeds=[Self.cloudSiglID,Self.pcSiglID,Self.mouseKeyboardSiglID]+Self.recentSiglIDs
        for sigl in feeds {
            group.enter()
            let url=URL(string:"https://catalog.gamepass.com/sigls/v2?id=\(sigl)&language=\(Self.language)&market=\(Self.market)")!
            catalogHTTP.get(url) {data in
                defer{group.leave()}
                guard let data,let ids=Self.catalogIDs(data,expectedSIGL:sigl) else{return}
                idsLock.lock();defer{idsLock.unlock()}
                if sigl==Self.cloudSiglID {cloudIds=ids}
                else if sigl==Self.pcSiglID {pcIds=ids}
                else if sigl==Self.mouseKeyboardSiglID {mouseKeyboard=Set(ids)}
                else if let index=Self.recentSiglIDs.firstIndex(of:sigl) {recentLists[index]=ids}
            }
        }
        group.notify(queue:.global(qos:.userInitiated)) {[weak self] in
            guard let self else{return}
            // Both authoritative capability lists must succeed. Missing is not an empty valid list.
            guard let cloudIds,let pcIds else {
                self.finish(nil,error:"Actualisation Xbox incomplète ou indisponible. Réessayez.")
                return
            }
            var seen=Set<String>()
            let combined=(cloudIds+pcIds).filter{seen.insert($0).inserted}
            var recent:[String:Int]=[:]
            let lists=recentLists.keys.sorted().compactMap{recentLists[$0]}
            for position in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where position<list.count && recent[list[position]]==nil {recent[list[position]]=recent.count}
            }
            self.resolve(combined,cloudSet:Set(cloudIds),pcSet:Set(pcIds),mouseKeyboard:mouseKeyboard,recent:recent)
        }
    }

    /// Bounded official SIGL shape; no HTML/error page, empty list or silently dropped malformed row.
    private static func catalogIDs(_ data:Data,expectedSIGL:String)->[String]? {
        guard data.count<=XboxCatalogHTTPClient.maximumBytes,
              let rows=(try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]],
              rows.count>1,rows.count<=2001,rows.first?["siglId"] as? String==expectedSIGL else{return nil}
        var seen=Set<String>(),result:[String]=[]
        for row in rows.dropFirst() {
            guard let id=row["id"] as? String,id.range(of:"^[A-Z0-9]{12}$",options:.regularExpression) != nil else{return nil}
            if seen.insert(id).inserted {result.append(id)}
        }
        return result.isEmpty ? nil : result
    }

    private func resolve(_ ids:[String],cloudSet:Set<String>,pcSet:Set<String>,mouseKeyboard:Set<String>?,recent:[String:Int]) {
        let batches=stride(from:0,to:ids.count,by:20).map{Array(ids[$0..<min($0+20,ids.count)])}
        let group=DispatchGroup(),resultLock=NSLock()
        var resolved:[String:Title]=[:],complete=true
        for batch in batches {
            group.enter()
            var components=URLComponents(string:"https://displaycatalog.mp.microsoft.com/v7.0/products")!
            components.queryItems=[URLQueryItem(name:"bigIds",value:batch.joined(separator:",")),URLQueryItem(name:"market",value:Self.market),URLQueryItem(name:"languages",value:Self.language)]
            catalogHTTP.get(components.url!) {data in
                defer{group.leave()}
                var parsed:[String:Title]=[:]
                if let data,let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                   let products=root["Products"] as? [[String:Any]],products.count==batch.count {
                    for product in products {
                        guard let id=product["ProductId"] as? String,batch.contains(id),parsed[id]==nil,
                              var title=Self.parseProduct(product,hasCloud:cloudSet.contains(id),hasPC:pcSet.contains(id)) else{continue}
                        title.hasMouseKeyboard=cloudSet.contains(id) ? mouseKeyboard.map{$0.contains(id)} : nil
                        title.recentRank=recent[id];parsed[id]=title
                    }
                }
                resultLock.lock();defer{resultLock.unlock()}
                if parsed.count != batch.count {complete=false}
                for (id,title) in parsed {resolved[id]=title}
            }
        }
        group.notify(queue:.global(qos:.utility)) {[weak self] in
            guard complete,resolved.count==ids.count,!ids.isEmpty else {
                self?.finish(nil,error:"Réponse Microsoft incomplète ou invalide. Dernier catalogue conservé.");return
            }
            self?.finish(ids.compactMap{resolved[$0]},error:mouseKeyboard==nil ? "Commandes cloud non vérifiées : actualisez le catalogue." : "")
        }
    }

    private static func parseProduct(_ product: [String: Any], hasCloud: Bool, hasPC: Bool) -> Title? {
        guard let id = product["ProductId"] as? String,
              let localized = (product["LocalizedProperties"] as? [[String: Any]])?.first,
              let name = localized["ProductTitle"] as? String, !name.isEmpty else { return nil }
        let images = localized["Images"] as? [[String: Any]] ?? []
        func image(_ purposes: [String]) -> String {
            for purpose in purposes {
                if let uri = images.first(where: { $0["ImagePurpose"] as? String == purpose })?["Uri"] as? String {
                    return uri.hasPrefix("//") ? "https:" + uri : uri
                }
            }
            return ""
        }
        let hero = image(["SuperHeroArt", "TitledHeroArt", "BoxArt"])
        let poster = image(["Poster", "BoxArt", "BrandedKeyArt"])
        let properties = product["Properties"] as? [String: Any]
        return Title(id: id, title: String(name.prefix(200)), imageURL: hero, portraitURL: poster,
                     developer: localized["DeveloperName"] as? String ?? "",
                     category: properties?["Category"] as? String ?? "",
                     hasCloud: hasCloud, hasPC: hasPC)
    }

    private func finish(_ list: [Title]?, error: String) {
        lock.lock()
        fetching = false
        lastError = error
        if let list,!list.isEmpty {
            titles = list
            fetchedAt = now()
            if let data = try? JSONEncoder().encode(CachedCatalog(fetchedAt: fetchedAt!, titles: list,verifiedComplete:true)) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        lock.unlock()
        DispatchQueue.main.async { self.onUpdate?() }
    }

    // MARK: Microsoft account

    /// Reads the persistent WebKit cookie store used by the Xbox Cloud window. Main thread.
    func refreshSignInState() {
        XboxWebSession.store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let now = Date()
            // Jetons de session Microsoft (MSA) et Xbox Live réellement présents après sign-in.
            let sessionNames: Set<String> = ["MSPAuth", "RPSSAuth", "WLSSC", "__Host-MSAAUTH"]
            let connected = cookies.contains { cookie in
                let domain = cookie.domain.lowercased()
                let name = cookie.name
                let isXboxToken = name.hasPrefix("XBXXtk") || name.hasPrefix("XNXXtk")
                return (domain == "live.com" || domain.hasSuffix(".live.com") || domain == "xbox.com" || domain.hasSuffix(".xbox.com")) &&
                    (sessionNames.contains(name) || isXboxToken) &&
                    (cookie.expiresDate.map { $0 > now } ?? true)
            }
            self.lock.lock(); let changed = self.signedIn != connected; self.signedIn = connected; self.lock.unlock()
            if changed { self.onUpdate?() }
        }
    }

    /// Clears Microsoft & Xbox session cookies from the persistent WebKit store.
    func disconnect(completion: @escaping () -> Void) {
        XboxWebSession.disconnect { [weak self] in
            guard let self else { completion(); return }
            self.lock.lock();self.signedIn=false;self.lock.unlock()
            self.onUpdate?();completion()
        }
    }

    // MARK: Launch
    func requiresController(for url:URL)->Bool {
        guard XboxCloudRoute.isLaunch(url),let id=XboxCloudRoute.productID(url) else{return false}
        lock.lock();defer{lock.unlock()}
        return titles.first{$0.id.caseInsensitiveCompare(String(id)) == .orderedSame}?.hasMouseKeyboard == false
    }

    func launch(titleID: String, completion: @escaping (Bool, String) -> Void) {
        let clean = titleID.replacingOccurrences(of: "xbox:", with: "")
        lock.lock(); let title = titles.first(where: { $0.id == clean }); lock.unlock()
        guard let title else {
            completion(false, "Jeu Xbox introuvable dans le catalogue Game Pass actuel.")
            return
        }
        if let cloudURL = title.cloudURL {
            open(cloudURL, isGameLaunch: true)
            completion(true, "Lancement de \(title.title) sur Xbox Cloud Gaming…")
        } else {
            NSWorkspace.shared.open(title.storeURL)
            completion(true, "Ouverture de la fiche Microsoft Store de \(title.title)…")
        }
    }

    func openCatalog(completion: @escaping (Bool, String) -> Void) {
        open(URL(string: "https://www.xbox.com/fr-FR/play")!)
        completion(true, "Ouverture d’Xbox Cloud Gaming…")
    }

    /// Only Microsoft/Xbox HTTPS URLs may be opened in the cloud window.
    static func isAllowedCloudURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.port == nil else { return false }
        return host == "www.xbox.com" || host == "xbox.com" || host.hasSuffix(".xbox.com") ||
               host == "login.live.com" || host.hasSuffix(".live.com") || host == "login.microsoftonline.com"
    }

    private func open(_ url: URL, isGameLaunch: Bool = false) {
        if let onOpenCloud { onOpenCloud(url, isGameLaunch) } else { NSWorkspace.shared.open(url) }
    }
}


/// Public catalogue transport: cap bytes before JSON parsing and cancel oversized streams.
private final class XboxCatalogHTTPClient:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    static let maximumBytes=2*1024*1024
    private struct Pending {var data=Data();let done:(Data?)->Void}
    private let lock=NSLock()
    private var pending:[Int:Pending]=[:]
    private var session:URLSession!
    init(configuration:URLSessionConfiguration) {
        super.init()
        let config=configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=45
        config.httpMaximumConnectionsPerHost=6;config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil
        session=URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }
    func get(_ url:URL,done:@escaping(Data?)->Void) {
        let task=session.dataTask(with:URLRequest(url:url,timeoutInterval:20))
        lock.lock();pending[task.taskIdentifier]=Pending(done:done);lock.unlock();task.resume()
    }
    func cancel() {session.invalidateAndCancel()}
    private func finish(_ task:URLSessionTask,valid:Bool) {
        lock.lock();let value=pending.removeValue(forKey:task.taskIdentifier);lock.unlock()
        if let value {value.done(valid && !value.data.isEmpty ? value.data : nil)}
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,
                    completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let http=response as? HTTPURLResponse,http.statusCode==200,
              response.expectedContentLength<=Int64(Self.maximumBytes) else {
            finish(dataTask,valid:false);completionHandler(.cancel);return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock()
        let tooLarge=(pending[dataTask.taskIdentifier]?.data.count ?? 0)+data.count>Self.maximumBytes
        if !tooLarge {pending[dataTask.taskIdentifier]?.data.append(data)}
        lock.unlock()
        if tooLarge {finish(dataTask,valid:false);dataTask.cancel()}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {finish(task,valid:error==nil)}
}
