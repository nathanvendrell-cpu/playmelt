import Foundation
import CoreFoundation

private protocol GameMediaTransportStopping { func shutdown() }

/// The shared HubTransport boundary, with a hard response bound and cancellation
/// for this on-demand catalogue. No cookies, credentials, cache or arbitrary URL.
final class GameMediaURLSessionTransport: NSObject, HubTransport, URLSessionDataDelegate, GameMediaTransportStopping {
    static let maximumBytes = 4_000_000
    private struct Record { let completion: (Data?) -> Void; var data = Data(); var accepted = false }
    private let lock = NSLock()
    private var records: [Int: Record] = [:], stopped = false
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": "Playmelt"]
        self.configuration = config; super.init()
    }
    static func allowedRequest(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return false }
        // Foundation.URL.path normalizes a trailing slash away on macOS.
        if url.host == "store.steampowered.com" { return ["/api/appdetails", "/api/storesearch"].contains(url.path) }
        return url.host == "api.steampowered.com" && url.path == "/ISteamNews/GetNewsForApp/v2"
    }
    func get(_ url: URL, completion: @escaping (Data?) -> Void) {
        guard Self.allowedRequest(url) else { completion(nil); return }
        lock.lock()
        guard !stopped else { lock.unlock(); completion(nil); return }
        let task = session.dataTask(with: url)
        records[task.taskIdentifier] = Record(completion: completion)
        lock.unlock(); task.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let accepted = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true &&
            response.url.map(Self.allowedRequest) == true && response.expectedContentLength <= Self.maximumBytes
        lock.lock(); if records[dataTask.taskIdentifier] != nil { records[dataTask.taskIdentifier]?.accepted = accepted }; lock.unlock()
        completionHandler(accepted ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var record = records[dataTask.taskIdentifier], record.accepted, !stopped else { lock.unlock(); dataTask.cancel(); return }
        if data.count > Self.maximumBytes - record.data.count {
            record.accepted = false; record.data = Data(); records[dataTask.taskIdentifier] = record
            lock.unlock(); dataTask.cancel(); return
        }
        record.data.append(data); records[dataTask.taskIdentifier] = record; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let record = records.removeValue(forKey: task.taskIdentifier), notify = !stopped; lock.unlock()
        if notify, let record { record.completion(error == nil && record.accepted ? record.data : nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowedRequest(url), url.host == task.originalRequest?.url?.host else { completionHandler(nil); return }
        completionHandler(request)
    }
    func shutdown() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; records.removeAll(); lock.unlock()
        session.invalidateAndCancel()
    }
}

struct GameMediaPart {
    var images: [[String: Any]] = [], videos: [[String: Any]] = []
    var itemCount = 0, truncated = false
}

final class GameMediaCatalog {
    static let announcementCount = 100, imageLimit = 32, videoLimit = 48, cacheLimit = 32
    static let successTTL: TimeInterval = 6 * 3600, failureTTL: TimeInterval = 5 * 60
    private struct Key: Equatable { let title: String, steamID: String? }
    private struct Entry { let key: Key, payload: [String: Any], expires: Date; var used: UInt64 }
    private final class Flight {
        let token = UUID(), gameID: String, key: Key
        var completions: [([String: Any]) -> Void], steamID: String?
        var details: GameMediaPart?, news: GameMediaPart?, detailsDone = false, newsDone = false
        init(_ gameID: String, _ key: Key, _ completion: @escaping ([String: Any]) -> Void) { self.gameID = gameID; self.key = key; completions = [completion] }
    }
    private let transport: HubTransport, now: () -> Date, queue = DispatchQueue(label: "fr.playmelt.game-media-catalog", qos: .utility)
    private let callbackLock = NSLock()
    private var callbacksClosed = false, closed = false, tick: UInt64 = 0
    private var cache: [String: Entry] = [:], flights: [String: Flight] = [:]
    private let requestTimeout: TimeInterval
    init(transport: HubTransport = GameMediaURLSessionTransport(), now: @escaping () -> Date = Date.init, requestTimeout: TimeInterval = 30) {
        self.transport = transport; self.now = now; self.requestTimeout = max(0.05, min(60, requestTimeout))
    }
    deinit { (transport as? GameMediaTransportStopping)?.shutdown() }
    func request(gameID: String, title: String, knownSteamAppID: String?, completion: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            guard !self.closed else { return }
            guard !gameID.isEmpty, gameID.utf8.count <= 256, !gameID.unicodeScalars.contains(where: { $0.value < 32 }),
                  !title.isEmpty, title.utf8.count <= 800, !HubText.normalized(title).isEmpty else {
                self.emit([completion], self.payload(gameID, status: "unavailable")); return
            }
            // A malformed explicit appID is refused, never silently replaced by search.
            if let knownSteamAppID, !Self.validAppID(knownSteamAppID) {
                self.emit([completion], self.payload(gameID, status: "unavailable")); return
            }
            let key = Key(title: HubText.normalized(title), steamID: knownSteamAppID)
            if var entry = self.cache[gameID], entry.key == key, entry.expires > self.now() {
                self.tick &+= 1; entry.used = self.tick; self.cache[gameID] = entry; self.emit([completion], entry.payload, key: key); return
            }
            if let flight = self.flights[gameID], flight.key == key {
                if flight.completions.count < 128 { flight.completions.append(completion) }
                else { self.emit([completion], self.payload(gameID, status: "unavailable")) }
                return
            }
            // A changed game mapping supersedes late responses for the old identity.
            self.flights[gameID] = nil; self.cache[gameID] = nil
            guard self.flights.count < 8 else { self.emit([completion], self.payload(gameID, status: "unavailable")); return }
            let flight = Flight(gameID, key, completion); self.flights[gameID] = flight
            self.queue.asyncAfter(deadline: .now() + self.requestTimeout) { [weak self, weak flight] in
                guard let self, let flight, self.current(flight) else { return }
                self.finish(flight, unresolvedStatus: "unavailable")
            }
            if let knownSteamAppID { self.collect(flight, appID: knownSteamAppID) }
            else {
                var url = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
                url.queryItems = [.init(name: "term", value: title), .init(name: "cc", value: "FR"), .init(name: "l", value: "french")]
                self.transport.get(url.url!) { [weak self, weak flight] data in
                    self?.queue.async { [weak self, weak flight] in
                        guard let self, let flight, self.current(flight) else { return }
                        guard let data, data.count <= GameMediaURLSessionTransport.maximumBytes,
                              let id = HubFeedStore.matchSearch(data, title: title), Self.validAppID(String(id)),
                              Self.uniqueSearchMatch(data, title: title, appID: id) else {
                            self.finish(flight, unresolvedStatus: data == nil ? "unavailable" : "unmatched"); return
                        }
                        self.collect(flight, appID: String(id))
                    }
                }
            }
        }
    }
    private func current(_ flight: Flight) -> Bool { !closed && flights[flight.gameID]?.token == flight.token }
    private func collect(_ flight: Flight, appID: String) {
        guard current(flight), flight.steamID == nil else { return }; flight.steamID = appID
        var details = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        details.queryItems = [.init(name: "appids", value: appID), .init(name: "l", value: "french"), .init(name: "cc", value: "FR")]
        var news = URLComponents(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/")!
        news.queryItems = [.init(name: "appid", value: appID), .init(name: "count", value: String(Self.announcementCount)), .init(name: "maxlength", value: "0"), .init(name: "feeds", value: "steam_community_announcements")]
        for (isDetails, url) in [(true, details.url!), (false, news.url!)] {
            transport.get(url) { [weak self, weak flight] data in
                self?.queue.async { [weak self, weak flight] in
                    guard let self, let flight, self.current(flight) else { return }
                    if isDetails {
                        guard !flight.detailsDone else { return }; flight.detailsDone = true
                        flight.details = Self.parseDetails(data, appID: appID)
                    } else {
                        guard !flight.newsDone else { return }; flight.newsDone = true
                        flight.news = Self.parseNews(data, appID: appID)
                    }
                    if flight.detailsDone && flight.newsDone { self.finish(flight) }
                }
            }
        }
    }
    private func payload(_ gameID: String, status: String) -> [String: Any] {
        ["gameId": gameID, "status": status, "images": [[String: Any]](), "videos": [[String: Any]](),
         "message": "Médias publiés par l’éditeur", "scope": ["store": "Steam", "announcementsRequested": Self.announcementCount, "youtube": "Liens et intégrations explicites des annonces éditeur Steam", "exhaustive": false]]
    }
    private func finish(_ flight: Flight, unresolvedStatus: String = "unavailable") {
        guard current(flight) else { return }
        let details = flight.details, news = flight.news
        var images = details?.images ?? [], videos = (details?.videos ?? []) + (news?.videos ?? [])
        var ids = Set<String>(); videos = videos.filter { ($0["id"] as? String).map { ids.insert($0).inserted } == true }
        videos = videos.enumerated().sorted {
            let rank: [String: Int] = ["teaser": 0, "trailer": 1, "gameplay": 2, "other": 3]
            let a = rank[$0.element["kind"] as? String ?? "other"] ?? 3, b = rank[$1.element["kind"] as? String ?? "other"] ?? 3
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let truncated = images.count > Self.imageLimit || videos.count > Self.videoLimit || details?.truncated == true || news?.truncated == true
        images = Array(images.prefix(Self.imageLimit)); videos = Array(videos.prefix(Self.videoLimit))
        let anyValid = details != nil || news != nil, anyMedia = !images.isEmpty || !videos.isEmpty
        let status = details != nil && news != nil ? (anyMedia ? "ready" : "empty") : (anyValid && anyMedia ? "partial" : unresolvedStatus)
        var output = payload(flight.gameID, status: status)
        output["images"] = images; output["videos"] = videos
        if let id = flight.steamID { output["steamAppId"] = id }
        output["sourceStatus"] = ["store": details == nil ? "unavailable" : "ready", "announcements": news == nil ? "unavailable" : "ready"]
        output["scope"] = ["store": "Steam", "announcementsRequested": Self.announcementCount, "announcementsReturned": news?.itemCount ?? 0,
            "youtube": "Liens et intégrations explicites des annonces éditeur Steam", "exhaustive": false, "truncated": truncated]
        output["officialSourceMeaning"] = "Publié dans la vitrine ou une annonce éditeur Steam ; chaîne YouTube non vérifiée séparément."
        tick &+= 1
        cache[flight.gameID] = Entry(key: flight.key, payload: output, expires: now().addingTimeInterval(details != nil && news != nil ? Self.successTTL : Self.failureTTL), used: tick)
        flights[flight.gameID] = nil
        while cache.count > Self.cacheLimit, let least = cache.min(by: { $0.value.used < $1.value.used })?.key { cache[least] = nil }
        emit(flight.completions, output, key: flight.key)
    }
    private func emit(_ completions: [([String: Any]) -> Void], _ payload: [String: Any], key: Key? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.callbackLock.lock(); let allowed = !self.callbacksClosed; self.callbackLock.unlock()
            guard allowed else { return }
            if let key, let id = payload["gameId"] as? String {
                let stillCurrent = self.queue.sync { self.cache[id]?.key == key || self.flights[id]?.key == key }
                guard stillCurrent else { return }
            }
            completions.forEach { $0(payload) }
        }
    }
    func cachedVideo(gameID: String, videoID: String) -> [String: Any]? {
        queue.sync {
            guard !closed, var entry = cache[gameID], entry.expires > now(),
                  let video = (entry.payload["videos"] as? [[String: Any]])?.first(where: { $0["id"] as? String == videoID }) else { return nil }
            tick &+= 1; entry.used = tick; cache[gameID] = entry; return video
        }
    }
    func shutdown() {
        callbackLock.lock(); callbacksClosed = true; callbackLock.unlock()
        queue.async { self.closed = true; self.flights.removeAll(); self.cache.removeAll(); (self.transport as? GameMediaTransportStopping)?.shutdown() }
    }
    static func validAppID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 10 && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value).map { $0 > 0 && $0 <= UInt32.max && String($0) == value } == true
    }
    private static func integer(_ value: Any?, zero: Bool = false) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= (zero ? 0 : 1), n.doubleValue <= Double(UInt32.max), n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    private static func uniqueSearchMatch(_ data: Data, title: String, appID: Int) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["items"] as? [[String: Any]], items.count <= 1000 else { return false }
        let exact = items.filter { HubText.normalized($0["name"] as? String ?? "") == HubText.normalized(title) }
        let ids = Set(exact.compactMap { integer($0["id"]) })
        return ids == [appID] && exact.allSatisfy { integer($0["id"]) != nil }
    }
    private static let imageHosts: Set<String> = ["shared.akamai.steamstatic.com", "shared.fastly.steamstatic.com", "shared.cloudflare.steamstatic.com", "cdn.akamai.steamstatic.com", "cdn.fastly.steamstatic.com", "cdn.cloudflare.steamstatic.com", "steamcdn-a.akamaihd.net", "cdn.steamstatic.com"]
    private static let videoHosts: Set<String> = ["video.akamai.steamstatic.com", "video.fastly.steamstatic.com", "video.cloudflare.steamstatic.com", "cdn.akamai.steamstatic.com", "cdn.fastly.steamstatic.com", "cdn.cloudflare.steamstatic.com", "steamcdn-a.akamaihd.net"]
    static func safeMediaURL(_ raw: Any?, video: Bool) -> String? {
        guard let raw = raw as? String, raw.utf8.count <= 4096, !raw.unicodeScalars.contains(where: { $0.value < 32 }),
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let host = url.host?.lowercased(), (video ? videoHosts : imageHosts).contains(host),
              !url.path.contains("\\"), !url.path.split(separator: "/").contains(".."),
              (video ? ["mp4", "webm", "m3u8"] : ["jpg", "jpeg", "png", "webp", "avif"]).contains(url.pathExtension.lowercased()) else { return nil }
        return url.absoluteString
    }
    static func kind(_ title: String) -> String {
        let words = Set(HubText.normalized(title).split(separator: " ").map(String.init))
        if words.contains("teaser") { return "teaser" }
        if words.contains("trailer") || (words.contains("bande") && words.contains("annonce")) { return "trailer" }
        if words.contains("gameplay") { return "gameplay" }; return "other"
    }
    static func parseDetails(_ data: Data?, appID: String) -> GameMediaPart? {
        guard validAppID(appID), let data, data.count <= GameMediaURLSessionTransport.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let response = root[appID] as? [String: Any],
              let success = response["success"] as? NSNumber, CFGetTypeID(success) == CFBooleanGetTypeID(), success.boolValue,
              let content = response["data"] as? [String: Any], integer(content["steam_appid"]).map(String.init) == appID else { return nil }
        var result = GameMediaPart(), seenImages = Set<String>(), seenImageIDs = Set<Int>(), seenVideos = Set<String>()
        let source = "https://store.steampowered.com/app/\(appID)/"
        let images = content["screenshots"] as? [[String: Any]] ?? []
        result.truncated = images.count > imageLimit
        for image in images.prefix(256) {
            guard let id = integer(image["id"], zero: true), let url = safeMediaURL(image["path_full"], video: false),
                  let thumb = safeMediaURL(image["path_thumbnail"], video: false), seenImages.insert(url).inserted, seenImageIDs.insert(id).inserted else { continue }
            guard result.images.count < imageLimit else { result.truncated = true; continue }
            result.images.append(["id": "steam-image:\(appID):\(id)", "url": url, "thumbnail": thumb, "sourceUrl": source])
        }
        let movies = content["movies"] as? [[String: Any]] ?? []
        result.truncated = result.truncated || movies.count > videoLimit
        for movie in movies.prefix(256) {
            guard let id = integer(movie["id"]), let rawTitle = movie["name"] as? String, !rawTitle.isEmpty, rawTitle.count <= 1000,
                  let thumb = safeMediaURL(movie["thumbnail"], video: false), seenVideos.insert(id.description).inserted else { continue }
            let mp4 = movie["mp4"] as? [String: Any] ?? [:], webm = movie["webm"] as? [String: Any] ?? [:]
            let candidates: [Any?] = [mp4["max"], mp4["480"], movie["hls_h264"], webm["max"], webm["480"]]
            guard let url = candidates.compactMap({ safeMediaURL($0, video: true) }).first else { continue }
            let title = HubText.summary(rawTitle, limit: 200)
            guard result.videos.count < videoLimit else { result.truncated = true; continue }
            result.videos.append(["id": "steam:\(id)", "title": title, "kind": kind(title), "provider": "steam", "url": url, "thumbnail": thumb, "sourceUrl": source, "officialSource": true])
        }
        return result
    }
    static func validYouTubeID(_ id: String) -> Bool { id.utf8.count == 11 && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 } }
    static func youtubeID(_ raw: String) -> String? {
        guard raw.utf8.count <= 4096, let url = URL(string: raw.replacingOccurrences(of: "&amp;", with: "&")), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtube-nocookie.com"].contains(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init); let id: String?
        if host == "youtu.be", parts.count == 1 { id = parts[0] }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host), url.path == "/watch" {
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "v" } ?? []
            id = values.count == 1 ? values[0].value : nil
        } else if parts.count == 2, ["embed", "shorts"].contains(parts[0]) { id = parts[1] }
        else { id = nil }
        return id.flatMap { validYouTubeID($0) ? $0 : nil }
    }
    static func youtubeIDs(_ text: String) -> [String] {
        guard text.utf8.count <= 250_000 else { return [] }
        var ids: [String] = [], seen = Set<String>()
        func add(_ id: String?) { if let id, validYouTubeID(id), seen.insert(id).inserted { ids.append(id) } }
        if let tags = try? NSRegularExpression(pattern: #"\[previewyoutube\s*=([^\]]{1,200})\]"#, options: [.caseInsensitive]) {
            for match in tags.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(100) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let raw = String(text[range]).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                    .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                add(raw.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init))
            }
        }
        if let urls = try? NSRegularExpression(pattern: #"https://[^\s<>\[\]"']{1,4096}"#, options: [.caseInsensitive]) {
            for match in urls.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(500) {
                guard let range = Range(match.range, in: text) else { continue }; add(youtubeID(String(text[range])))
            }
        }
        return ids
    }
    static func parseNews(_ data: Data?, appID: String) -> GameMediaPart? {
        guard validAppID(appID), let data, data.count <= GameMediaURLSessionTransport.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let news = root["appnews"] as? [String: Any],
              integer(news["appid"]).map(String.init) == appID, let items = news["newsitems"] as? [[String: Any]] else { return nil }
        var result = GameMediaPart(), seen = Set<String>()
        result.truncated = items.count > announcementCount
        for item in items.prefix(announcementCount) {
            guard item["feedname"] as? String == "steam_community_announcements", integer(item["appid"]).map(String.init) == appID,
                  let gid = item["gid"] as? String, !gid.isEmpty, gid.utf8.count <= 24, gid.utf8.allSatisfy({ (48...57).contains($0) }),
                  let rawTitle = item["title"] as? String, !rawTitle.isEmpty, rawTitle.count <= 1000,
                  let contents = item["contents"] as? String, contents.utf8.count <= 250_000 else { continue }
            let title = HubText.summary(rawTitle, limit: 200)
            result.itemCount += 1
            for id in youtubeIDs(contents) where seen.insert(id).inserted {
                guard result.videos.count < videoLimit else { result.truncated = true; continue }
                result.videos.append(["id": "youtube:\(id)", "title": title, "kind": kind(title), "provider": "youtube", "youtubeId": id,
                    "thumbnail": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", "sourceUrl": "https://store.steampowered.com/news/app/\(appID)/view/\(gid)", "officialSource": true])
            }
        }
        return result
    }
}
