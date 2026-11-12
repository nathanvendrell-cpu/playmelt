import Foundation

/// Flux de l'Accueil : faux réseau, aucun appel réel.
final class FakeHubTransport: HubTransport {
    var routes: [String: Any] = [:]   // préfixe d'URL → objet JSON
    var calls: [URL] = []
    let lock = NSLock()
    func get(_ url: URL, completion: @escaping (Data?) -> Void) {
        lock.lock(); calls.append(url); lock.unlock()
        let hit = routes.first { url.absoluteString.hasPrefix($0.key) }?.value
        DispatchQueue.global().async { completion(hit.flatMap { try? JSONSerialization.data(withJSONObject: $0) }) }
    }
}

@main struct HubFeedTests {
    static func main() {
        var passed = 0
        func check(_ c: Bool, _ label: String) { precondition(c, "FAIL: " + label); passed += 1 }
        let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!

        // Texte
        check(HubText.normalized("FINAL FANTASY VII REBIRTH™") == "final fantasy vii rebirth", "titre normalisé")
        check(HubText.normalized("Marvel’s Spider-Man 2") == HubText.normalized("Marvel's Spider-Man 2"), "apostrophes équivalentes")
        let s = HubText.summary("[h1]Patch[/h1] [img]{STEAM_CLAN_IMAGE}/x.png[/img] Fixed <b>crash</b> &amp; https://x.y/z stutter.")
        check(s == "Patch Fixed crash & stutter.", "résumé sans balises : \(s)")
        check(HubText.summary(String(repeating: "mot ", count: 100), limit: 30).hasSuffix("…"), "résumé coupé")

        // Sélection : installés puis récents, doublons et jeux jamais lancés exclus.
        let refs = [
            HubGameRef(gameID: "a", title: "Old", store: "steam", appID: "1", installed: false, lastPlayed: 5),
            HubGameRef(gameID: "b", title: "Factorio", store: "steam", appID: "427520", installed: true, lastPlayed: 1),
            HubGameRef(gameID: "c", title: "Never", store: "steam", appID: "2", installed: false, lastPlayed: 0),
            HubGameRef(gameID: "d", title: "FINAL FANTASY VII REBIRTH", store: "epic", appID: "", installed: true, lastPlayed: 9),
            HubGameRef(gameID: "e", title: "Final Fantasy VII Rebirth", store: "steam", appID: "2909400", installed: false, lastPlayed: 3),
        ]
        check(HubFeedStore.selection(refs).map(\.gameID) == ["d", "b", "a"], "sélection ordonnée et dédoublonnée")
        check(HubGameRef(["gameId": "x", "title": String(repeating: "t", count: 201)]) == nil, "titre trop long refusé")
        check(HubGameRef(["gameId": "x", "title": "T", "store": "steam", "appId": "abc"])?.knownSteamAppID == nil, "appid non numérique ignoré")

        // Correspondance de recherche stricte.
        let search = try! JSONSerialization.data(withJSONObject: ["items": [["id": 1, "name": "FINAL FANTASY VII REMAKE"], ["id": 2909400, "name": "FINAL FANTASY VII REBIRTH"]]])
        check(HubFeedStore.matchSearch(search, title: "Final Fantasy VII Rebirth") == 2909400, "titre exact retrouvé")
        check(HubFeedStore.matchSearch(search, title: "Final Fantasy") == nil, "titre approché refusé")

        // Liens : boutiques seulement.
        check(HubFeedStore.allowedLink("https://store.steampowered.com/app/1/") != nil, "lien Steam accepté")
        check(HubFeedStore.allowedLink("https://store.epicgames.com/fr/p/flotsam") != nil, "lien Epic accepté")
        check(HubFeedStore.allowedLink("https://evil.example/store.steampowered.com") == nil, "autre hôte refusé")
        check(HubFeedStore.allowedLink("http://store.steampowered.com/app/1/") == nil, "http refusé")
        check(HubFeedStore.allowedLink("https://u:p@store.steampowered.com/") == nil, "identifiants refusés")

        // Collecte complète sur faux réseau.
        let t = FakeHubTransport()
        t.routes["https://store.steampowered.com/api/storesearch/"] = ["items": [["id": 2909400, "name": "FINAL FANTASY VII REBIRTH"]]]
        t.routes["https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=427520"] = ["appnews": ["newsitems": [
            ["gid": "111", "title": "Friday Facts #449 - 2.1 Stable", "contents": "Hello [b]world[/b]", "date": 1_792_700_000],
            ["gid": "bad/../", "title": "x", "date": 1]]]]
        t.routes["https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=2909400"] = ["appnews": ["newsitems": [
            ["gid": "222", "title": "Version 1.005 Release Notice", "contents": "", "date": 1_780_000_000, "tags": ["patchnotes"]]]]]
        t.routes["https://store-site-backend-static"] = ["data": ["Catalog": ["searchStore": ["elements": [
            ["title": "Flotsam", "keyImages": [["type": "OfferImageWide", "url": "https://cdn1.epicgames.com/f.jpg"]],
             "catalogNs": ["mappings": [["pageSlug": "flotsam"]]],
             "promotions": ["promotionalOffers": [["promotionalOffers": [["startDate": "2026-11-05T16:00:00.000Z", "endDate": "2026-11-12T16:00:00.000Z", "discountSetting": ["discountPercentage": 0]]]]], "upcomingPromotionalOffers": []]],
            ["title": "Soldes", "keyImages": [], "promotions": ["promotionalOffers": [["promotionalOffers": [["startDate": "2026-11-05T16:00:00.000Z", "endDate": "2026-11-20T16:00:00.000Z", "discountSetting": ["discountPercentage": 50]]]]]]],
            ["title": "Knightica", "keyImages": [], "productSlug": "../hack",
             "promotions": ["promotionalOffers": [], "upcomingPromotionalOffers": [["promotionalOffers": [["startDate": "2026-11-12T16:00:00.000Z", "endDate": "2026-11-19T16:00:00.000Z", "discountSetting": ["discountPercentage": 0]]]]]]],
            ["title": "Fini", "keyImages": [], "promotions": ["promotionalOffers": [["promotionalOffers": [["startDate": "2026-10-01T16:00:00.000Z", "endDate": "2026-10-08T16:00:00.000Z", "discountSetting": ["discountPercentage": 0]]]]]]],
        ]]]]]
        t.routes["https://store.steampowered.com/api/featuredcategories"] = ["new_releases": ["items": [
            ["id": 1374680, "name": "Hazard Levels", "final_price": 999, "currency": "EUR", "header_image": "https://shared.akamai.steamstatic.com/h.jpg"],
            ["id": 1374680, "name": "Hazard Levels", "final_price": 999]]]]

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hubfeed-test-\(UUID().uuidString).json")
        let store = HubFeedStore(transport: t, cacheURL: cache, now: { now })
        check(store.shouldRefresh(force: false), "cache vide = actualisation")
        var feed: [String: Any]?
        store.refresh(games: refs, force: false) { feed = $0 }
        check(!store.shouldRefresh(force: true), "pas de deuxième collecte en parallèle")
        let deadline = Date().addingTimeInterval(5)
        while feed == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let feed else { preconditionFailure("FAIL: collecte terminée") }
        let items = feed["items"] as? [[String: Any]] ?? []
        check(items.count == 2, "actus valides seulement (gid suspect écarté)")
        check(items.first?["title"] as? String == "Friday Facts #449 - 2.1 Stable", "triées par date")
        check(items.last?["kind"] as? String == "update" && items.last?["gameId"] as? String == "d", "patch associé au jeu Epic via la recherche Steam")
        check(items.first?["url"] as? String == "https://store.steampowered.com/news/app/427520/view/111", "lien d'annonce reconstruit")
        check(((feed["art"] as? [String: Any])?["d"] as? [String: Any])?["appId"] as? Int == 2909400, "illustrations du jeu Epic")
        let free = feed["freeGames"] as? [[String: Any]] ?? []
        check(free.map { $0["title"] as? String ?? "" } == ["Flotsam", "Knightica"], "offerts : 100 % seulement, terminés exclus, en cours d'abord")
        check(free.last?["url"] as? String == "https://store.epicgames.com/fr/free-games", "slug suspect remplacé")
        let releases = feed["releases"] as? [[String: Any]] ?? []
        check(releases.count == 1 && releases.first?["priceCents"] as? Int == 999, "sorties dédoublonnées")
        check(!t.calls.contains { $0.absoluteString.contains("appid=2&") }, "aucune requête pour un jeu jamais lancé")
        check(t.calls.filter { $0.absoluteString.contains("storesearch") }.count == 1, "recherche Steam seulement pour le jeu non Steam")

        // Relecture du cache : la recherche Steam n'est pas refaite.
        let t2 = FakeHubTransport()
        let reopened = HubFeedStore(transport: t2, cacheURL: cache, now: { now.addingTimeInterval(4 * 3600) })
        check(reopened.fetchedAt != nil && reopened.shouldRefresh(force: false), "cache relu, périmé après 3 h")
        var again: [String: Any]?
        reopened.refresh(games: refs, force: false) { again = $0 }
        let d2 = Date().addingTimeInterval(5)
        while again == nil && Date() < d2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(!t2.calls.contains { $0.absoluteString.contains("storesearch") }, "correspondance titre → Steam mémorisée")
        let fresh = HubFeedStore(transport: t2, cacheURL: cache, now: { now.addingTimeInterval(4 * 3600 + 60) })
        check(!fresh.shouldRefresh(force: false), "cache frais = aucun réseau")
        try? FileManager.default.removeItem(at: cache)

        print("Accueil : \(passed) PASS ; faux réseau, aucun appel réel.")
    }
}
