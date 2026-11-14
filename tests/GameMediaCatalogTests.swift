import Foundation

private final class MediaTransport: HubTransport {
    struct Call { let url: URL; let completion: (Data?) -> Void }
    private let lock = NSLock(); private var values: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return values }
    func get(_ url: URL, completion: @escaping (Data?) -> Void) { lock.lock(); values.append(.init(url: url, completion: completion)); lock.unlock() }
    func reply(_ index: Int, _ object: Any?) { calls[index].completion(object.flatMap { try? JSONSerialization.data(withJSONObject: $0) }) }
}
private final class MediaClock {
    private let lock = NSLock(); private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}
private final class MediaURLProtocol: URLProtocol {
    static var body = Data(), oversizedHeader = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: Self.oversizedHeader ? ["Content-Length": "4000001"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // The default transport must also enforce its bound without Content-Length.
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct GameMediaCatalogTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { guard condition() else { fatalError("FAIL: \(label)") }; checks += 1 }
    static func until(_ label: String, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        expect(condition(), label)
    }
    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static let image = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1903340/a.jpg"
    static let thumb = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/257129803/movie_600x337.jpg?t=1"
    static let hls = "https://video.akamai.steamstatic.com/store_trailers/1903340/876247/hash/1748581603/hls_264_master.m3u8?t=1"
    static func details(_ app: Int = 1903340, movies: [[String: Any]]? = nil) -> [String: Any] {
        [String(app): ["success": true, "data": ["steam_appid": app, "screenshots": [["id": 0, "path_full": image, "path_thumbnail": image]],
            "movies": movies ?? [["id": 257129803, "name": "Launch Trailer", "thumbnail": thumb, "hls_h264": hls]]]]]
    }
    static func article(gid: String = "123", title: String = "Official teaser", contents: String = "[previewyoutube=\"C_Gp_ZHwaUQ;full\"][/previewyoutube]", feed: String = "steam_community_announcements", app: Int = 1903340) -> [String: Any] {
        ["gid": gid, "title": title, "contents": contents, "feedname": feed, "appid": app]
    }
    static func news(_ app: Int = 1903340, articles: [[String: Any]]? = nil) -> [String: Any] { ["appnews": ["appid": app, "newsitems": articles ?? [article(app: app)]]] }
    static func request(_ c: GameMediaCatalog, game: String = "steam:1903340", title: String = "Clair Obscur: Expedition 33", app: String? = "1903340", completion: @escaping ([String: Any]) -> Void) {
        c.request(gameID: game, title: title, knownSteamAppID: app, completion: completion)
    }
    static func main() {
        let part = GameMediaCatalog.parseDetails(json(details()), appID: "1903340")!
        expect(part.images.count == 1 && part.videos.count == 1, "current Steam HLS shape parsed")
        expect(part.videos[0]["url"] as? String == hls && part.videos[0]["kind"] as? String == "trailer", "HLS URL and publisher title retained")
        expect(part.videos[0]["officialSource"] as? Bool == true && part.videos[0]["sourceUrl"] as? String == "https://store.steampowered.com/app/1903340/", "store provenance explicit")
        expect(GameMediaCatalog.parseDetails(json(details(526870)), appID: "1903340") == nil, "wrong appdetails root refused")
        var falseID = details(); falseID["1903340"] = ["success": true, "data": ["steam_appid": 526870]]
        expect(GameMediaCatalog.parseDetails(json(falseID), appID: "1903340") == nil, "wrong nested Steam ID refused")
        falseID["1903340"] = ["success": 1, "data": ["steam_appid": 1903340]]
        expect(GameMediaCatalog.parseDetails(json(falseID), appID: "1903340") == nil, "numeric success cannot masquerade as boolean")
        expect(GameMediaCatalog.parseDetails(Data(repeating: 0, count: 4_000_001), appID: "1903340") == nil, "oversized metadata refused before parsing")
        for url in ["http://shared.akamai.steamstatic.com/a.jpg", "https://shared.akamai.steamstatic.com.evil.invalid/a.jpg", "https://evil.invalid/shared.akamai.steamstatic.com/a.jpg", "https://u:p@shared.akamai.steamstatic.com/a.jpg", "https://shared.akamai.steamstatic.com:443/a.jpg", "file:///a.jpg", "https://shared.akamai.steamstatic.com/a.svg", "https://shared.akamai.steamstatic.com/a.jpg#x"] {
            expect(GameMediaCatalog.safeMediaURL(url, video: false) == nil, "unsafe image URL refused")
        }
        expect(GameMediaCatalog.safeMediaURL(hls, video: true) != nil && GameMediaCatalog.safeMediaURL(image, video: true) == nil, "video extension bound is independent from image bound")
        let ids = GameMediaCatalog.youtubeIDs("[previewyoutube=\"C_Gp_ZHwaUQ;full\"] [previewyoutube=&quot;C_Gp_ZHwaUQ;full&quot;] https://youtu.be/AbC12_-xYz9 [url=https://www.youtube.com/watch?v=C_Gp_ZHwaUQ&amp;t=1]trailer[/url]")
        expect(ids == ["C_Gp_ZHwaUQ", "AbC12_-xYz9"], "quoted/full preview and explicit YouTube links deduplicate")
        for id in ["short", "C_Gp_ZHwaUQx", "C_Gp_ZHwaU<", "C_Gp_ZHwaUé"] { expect(!GameMediaCatalog.validYouTubeID(id), "YouTube ID exact ASCII grammar") }
        for url in ["https://youtube.com.evil.invalid/watch?v=C_Gp_ZHwaUQ", "https://youtube.com@evil.invalid/watch?v=C_Gp_ZHwaUQ", "http://youtu.be/C_Gp_ZHwaUQ", "https://www.youtube.com/watch?v=C_Gp_ZHwaUQ&v=AbC12_-xYz9", "https://www.youtube.com/watch?v=bad", "https://www.youtube.com:443/watch?v=C_Gp_ZHwaUQ"] {
            expect(GameMediaCatalog.youtubeID(url) == nil, "wrong YouTube authority/ID refused")
        }
        let source = GameMediaCatalog.parseNews(json(news(articles: [article(), article(gid: "124"), article(gid: "125", feed: "steam_community"), article(gid: "126", app: 526870), article(gid: "../127"), article(gid: "128", title: "<img onerror='x'>Official trailer") ])), appID: "1903340")!
        expect(source.videos.count == 1, "only exact publisher feed/app and unique YouTube IDs survive")
        expect(source.videos[0]["sourceUrl"] as? String == "https://store.steampowered.com/news/app/1903340/view/123", "news source built from validated app and gid, no remote redirect")
        expect(source.itemCount == 3, "scope counts accepted publisher announcements")
        expect(GameMediaCatalog.parseNews(json(news(526870)), appID: "1903340") == nil, "wrong news application refused")
        let unsafeTitle = GameMediaCatalog.parseNews(json(news(articles: [article(title: "<img onerror='attack()'>Teaser <script>bad()</script>", contents: "https://youtu.be/AbC12_-xYz9")])), appID: "1903340")!
        expect(!(unsafeTitle.videos[0]["title"] as! String).contains("<"), "publisher title is plain text, no injected markup")
        let manyMovies = (1...60).map { ["id": $0, "name": "Trailer \($0)", "thumbnail": thumb, "hls_h264": hls] as [String: Any] }
        let bounded = GameMediaCatalog.parseDetails(json(details(movies: manyMovies)), appID: "1903340")!
        expect(bounded.videos.count == 48 && bounded.truncated, "parser and payload have an honest finite video bound")
        expect(GameMediaCatalog.kind("Gameplay trailer") == "trailer" && GameMediaCatalog.kind("Bande-annonce") == "trailer" && GameMediaCatalog.kind("Teaser officiel") == "teaser", "teasers and trailers precede gameplay")
        do {
            let transport = MediaTransport(), c = GameMediaCatalog(transport: transport); defer { c.shutdown() }
            var payloads: [[String: Any]] = []
            for _ in 0..<25 { request(c) { expect(Thread.isMainThread, "catalogue completion on main"); payloads.append($0) } }
            until("25 same-game requests use two source requests") { transport.calls.count == 2 }
            let urls = transport.calls.map(\.url.absoluteString)
            expect(urls.contains { $0.contains("count=100") && $0.contains("maxlength=0") && $0.contains("feeds=steam_community_announcements") }, "full publisher announcements requested, bounded at100")
            transport.reply(1, news()); transport.reply(0, details())
            until("coalesced callers all receive a result") { payloads.count == 25 }
            expect(payloads.allSatisfy { $0["status"] as? String == "ready" }, "both official sources produce ready catalogue")
            let videos = payloads[0]["videos"] as! [[String: Any]]
            expect(videos.map { $0["kind"] as! String } == ["teaser", "trailer"], "stable teaser/trailer priority across sources")
            expect((payloads[0]["scope"] as? [String: Any])?["exhaustive"] as? Bool == false, "scope never claims all YouTube videos")
            expect(c.cachedVideo(gameID: "steam:1903340", videoID: "youtube:C_Gp_ZHwaUQ")?["youtubeId"] as? String == "C_Gp_ZHwaUQ", "player resolves only a cached video ID")
            expect(c.cachedVideo(gameID: "another-game", videoID: "youtube:C_Gp_ZHwaUQ") == nil && c.cachedVideo(gameID: "steam:1903340", videoID: "youtube:arbitraryXX") == nil, "player cannot use another game or arbitrary ID")
            var cached = false; request(c) { _ in cached = true }; until("cached render returns") { cached }
            expect(transport.calls.count == 2, "render request causes no repeated network")
            transport.reply(0, details()); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            expect(payloads.count == 25, "duplicate transport callback cannot republish")
        }
        do {
            let transport = MediaTransport(), c = GameMediaCatalog(transport: transport); defer { c.shutdown() }
            var output: [String: Any]?
            request(c, game: "epic:exp33", app: nil) { output = $0 }; until("cross-store uses search") { transport.calls.count == 1 }
            transport.reply(0, ["items": [["id": 1903340, "name": "Clair Obscur: Expedition 33 Deluxe Edition"]]])
            until("fuzzy title is refused") { output != nil }
            expect(output?["status"] as? String == "unmatched" && transport.calls.count == 1, "different edition does not borrow media")
        }
        do {
            let transport = MediaTransport(), c = GameMediaCatalog(transport: transport); defer { c.shutdown() }
            var output: [String: Any]?
            request(c, game: "epic:exp33", app: nil) { output = $0 }; until("strict search starts") { transport.calls.count == 1 }
            transport.reply(0, ["items": [["id": 1903340, "name": "CLAIR OBSCUR: EXPEDITION 33™"]]])
            until("exact normalized title resolves") { transport.calls.count == 3 }
            transport.reply(1, details()); transport.reply(2, news()); until("cross-store exact result") { output != nil }
            expect(output?["steamAppId"] as? String == "1903340", "cross-store resolved app identity is explicit")
        }
        do {
            let transport = MediaTransport(), c = GameMediaCatalog(transport: transport); defer { c.shutdown() }
            var output: [String: Any]?
            request(c, app: nil) { output = $0 }; until("ambiguous search starts") { transport.calls.count == 1 }
            transport.reply(0, ["items": [["id": 1903340, "name": "Clair Obscur: Expedition 33"], ["id": 2, "name": "Clair Obscur: Expedition 33"]]])
            until("ambiguous exact matches return") { output != nil }
            expect(output?["status"] as? String == "unmatched" && transport.calls.count == 1, "two exact identities are not guessed")
        }
        do {
            let t = MediaTransport(), clock = MediaClock(), c = GameMediaCatalog(transport: t, now: clock.now); defer { c.shutdown() }
            var output: [String: Any]?
            request(c) { output = $0 }; until("partial fetch starts") { t.calls.count == 2 }
            t.reply(0, details()); t.reply(1, nil); until("one source failure yields partial media") { output != nil }
            expect(output?["status"] as? String == "partial", "partial data preserved without full-success claim")
            clock.advance(301); expect(c.cachedVideo(gameID: "steam:1903340", videoID: "steam:257129803") == nil, "partial/error TTL expires in5min")
            request(c) { _ in }; until("expired partial catalogue refreshes") { t.calls.count == 4 }
        }
        do {
            let t = MediaTransport(), c = GameMediaCatalog(transport: t); defer { c.shutdown() }
            var old = false, updated: [String: Any]?
            request(c, game: "same-game") { _ in old = true }; until("old identity starts") { t.calls.count == 2 }
            request(c, game: "same-game", title: "Satisfactory", app: "526870") { updated = $0 }; until("new mapping starts") { t.calls.count == 4 }
            t.reply(0, details()); t.reply(1, news()); t.reply(2, details(526870)); t.reply(3, news(526870))
            until("new identity completes") { updated != nil }
            expect(!old && updated?["steamAppId"] as? String == "526870", "late old mapping never publishes or poisons cache")
        }
        do {
            let t = MediaTransport(), c = GameMediaCatalog(transport: t, requestTimeout: 0.05); defer { c.shutdown() }
            var output: [String: Any]?
            request(c) { output = $0 }; until("missing transport callbacks have bounded deadline") { output != nil }
            expect(output?["status"] as? String == "unavailable", "deadline cannot claim empty or ready data")
            t.reply(0, details()); t.reply(1, news()); RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            expect(c.cachedVideo(gameID: "steam:1903340", videoID: "steam:257129803") == nil, "late data cannot revive timed-out flight")
        }
        do {
            let t = MediaTransport(), c = GameMediaCatalog(transport: t)
            var callback = false; request(c) { _ in callback = true }; until("shutdown fixture in flight") { t.calls.count == 2 }
            c.shutdown(); t.reply(0, details()); t.reply(1, news()); RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            expect(!callback && c.cachedVideo(gameID: "steam:1903340", videoID: "steam:257129803") == nil, "shutdown suppresses late callbacks and player cache")
        }
        do {
            let t = MediaTransport(), c = GameMediaCatalog(transport: t); defer { c.shutdown() }
            var outputs = 0
            for id in ["0", "../1903340", "01903340", "true"] { request(c, app: id) { expect($0["status"] as? String == "unavailable", "invalid known ID refused without title fallback"); outputs += 1 } }
            until("invalid explicit IDs return") { outputs == 4 }; expect(t.calls.isEmpty, "invalid identities never use network")
        }
        do {
            let t = MediaTransport(), c = GameMediaCatalog(transport: t); defer { c.shutdown() }
            var outputs = 0
            for n in 0..<33 {
                request(c, game: "game:\(n)") { _ in outputs += 1 }; until("LRU fixture fetch") { t.calls.count == (n + 1) * 2 }
                t.reply(n * 2, details()); t.reply(n * 2 + 1, news()); until("LRU fixture completion") { outputs == n + 1 }
                if n == 31 { expect(c.cachedVideo(gameID: "game:0", videoID: "steam:257129803") != nil, "touch updates LRU recency") }
            }
            expect(c.cachedVideo(gameID: "game:0", videoID: "steam:257129803") != nil && c.cachedVideo(gameID: "game:1", videoID: "steam:257129803") == nil, "LRU bounds32 and evicts least recently used rather than touched game")
        }
        do {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaURLProtocol.self]
            let t = GameMediaURLSessionTransport(configuration: config); defer { t.shutdown() }
            MediaURLProtocol.body = Data("{}".utf8); var good: Data?, done = false
            t.get(URL(string: "https://store.steampowered.com/api/appdetails?appids=1903340")!) { data in DispatchQueue.main.async { good = data; done = true } }; until("real adapter via inert URLProtocol") { done }
            expect(good == Data("{}".utf8), "adapter accepts bounded successful public API response")
            MediaURLProtocol.body = Data(repeating: 32, count: 4_000_001); done = false; good = Data()
            t.get(URL(string: "https://store.steampowered.com/api/appdetails?appids=1903340")!) { data in DispatchQueue.main.async { good = data; done = true } }; until("streaming body cap enforced without Content-Length") { done }
            expect(good == nil, "overflow never reaches catalogue parser")
            expect(!GameMediaURLSessionTransport.allowedRequest(URL(string: "https://store.steampowered.com.evil.invalid/api/appdetails")!) && !GameMediaURLSessionTransport.allowedRequest(URL(string: "https://store.steampowered.com/account/")!), "transport cannot fetch arbitrary endpoints/authorities")
            expect(GameMediaURLSessionTransport.allowedRequest(URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=1903340")!), "actual Foundation normalized news endpoint accepted")
            expect(GameMediaURLSessionTransport.allowedRequest(URL(string: "https://store.steampowered.com/api/storesearch/?term=example")!), "actual Foundation normalized cross-store search endpoint accepted")
        }
        print("GameMediaCatalogTests: \(checks) checks PASS; fixtures/URLProtocol only; no network, UI, video, client or game opened")
    }
}
