import Foundation

enum OffersCatalog {
    static let gogURL = URL(string: "https://catalog.gog.com/v1/catalog?limit=48&order=desc:trending&discounted=eq:true&countryCode=FR&locale=fr-FR&currencyCode=EUR&productType=in:game,pack")!
    static let xboxURL = URL(string: "https://www.xbox.com/fr-FR/games/browse/game-deals")!
    static func offer(id: String, title: String, store: String, image: String, url: String, original: Double, price: Double, currency: String, end: Double = 0, platforms: [String] = []) -> [String:Any]? {
        guard !id.isEmpty, !title.isEmpty, original.isFinite, price.isFinite, original > price, price >= 0,
              original < 100_000, currency == "EUR", HubFeedStore.allowedLink(url) != nil else { return nil }
        return ["id": store + ":" + id, "title": String(title.prefix(200)), "store":store, "image":image,
            "url":url, "originalCents":Int((original * 100).rounded()), "priceCents":Int((price * 100).rounded()),
            "currency":currency, "discount":Int(((1 - price / original) * 100).rounded()),
            "end":end, "kind":price == 0 ? "giveaway" : "sale", "platforms":platforms]
    }
    static func steam(_ data: Data?) -> [[String:Any]] {
        guard let data, let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let items = (root["specials"] as? [String:Any])?["items"] as? [[String:Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? Int, item["type"] as? Int == 0,
                  let original = item["original_price"] as? Double, let price = item["final_price"] as? Double else { return nil }
            return offer(id:String(id), title:item["name"] as? String ?? "", store:"steam",
                image:item["large_capsule_image"] as? String ?? "", url:"https://store.steampowered.com/app/\(id)/",
                original:original/100, price:price/100, currency:item["currency"] as? String ?? "",
                end:item["discount_expiration"] as? Double ?? 0,
                platforms:["windows","mac","linux"].filter { item[$0 + "_available"] as? Bool == true })
        }
    }
    static func gog(_ data: Data?) -> [[String:Any]] {
        guard let data, let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let items = root["products"] as? [[String:Any]] else { return [] }
        return items.compactMap { item in
            guard let money = item["price"] as? [String:Any], let base = money["baseMoney"] as? [String:Any],
                  let final = money["finalMoney"] as? [String:Any], let original = Double(base["amount"] as? String ?? ""),
                  let price = Double(final["amount"] as? String ?? "") else { return nil }
            return offer(id:item["id"] as? String ?? "", title:item["title"] as? String ?? "", store:"gog",
                image:item["coverHorizontal"] as? String ?? "", url:item["storeLink"] as? String ?? "",
                original:original, price:price, currency:final["currency"] as? String ?? "")
        }
    }
    static func xbox(_ data: Data?) -> [[String:Any]] {
        guard let data, data.count < 4_000_000, let html = String(data:data, encoding:.utf8),
              let start = html.range(of:"window.__PRELOADED_STATE__ = "),
              let end = html.range(of:";\n", range:start.upperBound..<html.endIndex),
              let json = String(html[start.upperBound..<end.lowerBound]).data(using:.utf8),
              let root = try? JSONSerialization.jsonObject(with:json) as? [String:Any],
              let core = root["core2"] as? [String:Any], let products = core["products"] as? [String:Any],
              let summaries = products["productSummaries"] as? [String:[String:Any]] else { return [] }
        let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT:0); format.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return summaries.sorted { $0.key < $1.key }.compactMap { id, item in
            guard item["productKind"] as? String == "Game",
                  let prices = (item["specificPrices"] as? [String:Any])?["purchaseable"] as? [[String:Any]],
                  let price = prices.first(where: { p in
                    let eligibility = p["eligibilityInfo"] as? [String:Any]
                    return (p["discountPercentage"] as? Double ?? 0) > 0 && eligibility?["eligibility"] as? String == "None"
                  }), let original = price["msrp"] as? Double, let final = price["listPrice"] as? Double else { return nil }
            let images = item["images"] as? [String:[String:Any]] ?? [:]
            return offer(id:id, title:item["title"] as? String ?? "", store:"xbox",
                image:(images["superHeroArt"] ?? images["boxArt"])?["url"] as? String ?? "",
                url:"https://www.xbox.com/fr-FR/games/store/jeu/\(id)", original:original, price:final,
                currency:price["currency"] as? String ?? "", end:(price["endDateUtc"] as? String).flatMap { format.date(from:$0)?.timeIntervalSince1970 } ?? 0,
                platforms:item["availableOn"] as? [String] ?? [])
        }
    }
}
