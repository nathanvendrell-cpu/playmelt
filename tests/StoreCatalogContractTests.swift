// Proposed contract invariants only. No provider adapter, HTTP, UI or real price.
import Foundation

@main struct StoreCatalogContractTests {
    typealias C = StoreCatalogContract
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hosts: Set<String> = ["store.steampowered.com", "isthereanydeal.com"]
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) { guard condition() else { fatalError(label) }; checks += 1 }
    static func product(edition: String? = "fixture:standard", kind: C.ProductKind = .game, evidence: C.IdentityEvidence = .verifiedCrosswalk) -> C.Product {
        .init(id: "fixture:product", title: "Fixture Game", kind: kind,
            edition: .init(id: edition, publisherLabel: "Standard", includedProductIDs: ["fixture:base"], identityEvidence: evidence, evidenceIDs: ["fixture:mapping-proof"]),
            storeReferences: [.init(storeID: "steam", productID: "fixture:sku", offerID: nil, packageID: "fixture:package", namespace: nil)], presentation: nil,
            platforms: [.init(platform: .windows, architecture: "x86_64", sourceEvidenceID: "fixture:platform")],
            localCompatibility: .windowsRuntimeUnverified, compatibilityEvidenceID: nil, mediaSteamAppID: nil)
    }
    static func offer(edition: String? = "fixture:standard", kind: C.ProductKind = .game, identity: C.IdentityEvidence = .verifiedCrosswalk,
                      purchase: C.PurchaseKind = .oneTime, conditions: [C.Condition] = [], market: C.Market = .france,
                      price: C.Money? = .init(amountMinor: 12345, currency: "EUR", exponent: 2), availability: C.Availability = .available,
                      sourceState: C.SourceState = .ready, age: TimeInterval = 0, providerAge: TimeInterval? = nil,
                      expires: Date? = nil, destination: String = "https://store.steampowered.com/app/1/", sku: String = "fixture:sku") -> C.PurchaseOffer {
        .init(id: "fixture:offer", productID: "fixture:product", productKind: kind, editionID: edition, identityEvidence: identity,
            store: .init(storeID: "steam", productID: sku, offerID: nil, packageID: "fixture:package", namespace: nil), sellerName: "Fixture retailer", activationDRM: ["steam"],
            market: market, availability: availability, kind: purchase, price: price, regularPrice: nil, conditions: conditions,
            destinationURL: URL(string: destination)!, observation: .init(provider: "fixture-provider", state: sourceState, sourceURL: URL(string: "https://store.steampowered.com/api/appdetails")!,
                retrievedAt: now.addingTimeInterval(-age), providerUpdatedAt: providerAge.map { now.addingTimeInterval(-$0) }, expiresAt: expires, evidenceID: "fixture:price-proof"))
    }
    static func main() throws {
        let p = product()
        func eligible(_ o: C.PurchaseOffer, _ product: C.Product = p) -> Bool { o.comparable(to: product, market: .france, at: now, allowedDestinationHosts: hosts) }
        expect(eligible(offer()), "fresh exact full-price purchase must be comparable without a discount")
        expect(!eligible(offer(edition: "fixture:deluxe")), "different edition cannot compete on price")
        expect(!eligible(offer(edition: nil)), "unresolved edition cannot compete on price")
        expect(!eligible(offer(kind: .dlc)), "DLC cannot masquerade as base game")
        expect(!eligible(offer(kind: .bundle)), "bundle cannot masquerade as one title")
        expect(!eligible(offer(identity: .singleStoreExact)), "single-store title/SKU is not a cross-store equivalence proof")
        expect(!eligible(offer(identity: .unresolved)), "unresolved match cannot compete on price")
        expect(!eligible(offer(), product(evidence: .ambiguous)), "ambiguous selected edition cannot enable ranking")
        expect(!eligible(offer(sku: "fixture:other-sku")), "retailer SKU must occur in verified product references")
        for kind in [C.PurchaseKind.subscription, .rental, .freeToPlay, .freeToKeep] { expect(!eligible(offer(purchase: kind)), "access models stay separate from one-time purchase ranking") }
        for condition in [C.Condition.coupon, .membership, .accountEligibility, .priorOwnership, .regionUnconfirmed, .taxUnconfirmed] {
            expect(!eligible(offer(conditions: [condition])), "conditional price cannot be the unconditional best offer")
        }
        expect(!eligible(offer(market: .init(country: "US", currency: "EUR"))), "EUR denomination alone does not establish France availability")
        expect(!eligible(offer(market: .init(country: "FR", currency: "USD"))), "country alone does not establish EUR price")
        expect(!eligible(offer(price: nil)), "missing price never becomes zero")
        expect(!eligible(offer(price: .init(amountMinor: 0, currency: "EUR", exponent: 2))), "zero price requires explicit free-access classification, not one-time inference")
        expect(!eligible(offer(price: .init(amountMinor: -1, currency: "EUR", exponent: 2))), "negative money refused")
        expect(!eligible(offer(price: .init(amountMinor: 12345, currency: "USD", exponent: 2))), "foreign currency never silently converted")
        expect(!eligible(offer(price: .init(amountMinor: 12345, currency: "EUR", exponent: 3))), "wrong minor unit exponent refused")
        for state in [C.Availability.unknown, .notForSale, .regionBlocked] { expect(!eligible(offer(availability: state)), "unknown/unavailable is not a purchasable price row") }
        for state in [C.SourceState.notConfigured, .approvalRequired, .unavailable, .rateLimited, .previewOnly, .partial] {
            expect(!eligible(offer(sourceState: state)), "provider state must not fabricate current coverage")
        }
        expect(!eligible(offer(age: 301)), "expired application price cache excluded")
        expect(!eligible(offer(age: -60)), "future fetch timestamp refused")
        expect(!eligible(offer(providerAge: 2 * 86400)), "fresh fetch does not hide old provider data")
        expect(!eligible(offer(expires: now)), "offer expiry applies even before cache TTL")
        expect(eligible(offer(destination: "https://isthereanydeal.com/link/fixture/?affiliate=preserved")), "approved provider link remains unchanged")
        for url in ["https://store.steampowered.com.evil.invalid/app/1", "https://evil.invalid/app/1", "http://store.steampowered.com/app/1", "https://u:p@store.steampowered.com/app/1", "https://store.steampowered.com:443/app/1"] {
            expect(!eligible(offer(destination: url)), "untrusted purchase destination refused")
        }
        expect(!offer().comparable(to: p, market: .france, at: now, allowedDestinationHosts: []), "retailer allowlist is explicit and required")
        let validSearch = C.SearchRequest(query: "Game outside my library", market: .france, limit: 20, cursor: nil)
        expect(validSearch.valid, "market search is independent of ownership/library fields")
        for query in ["", "x", "two\nlines", String(repeating: "q", count: 121)] {
            expect(!C.SearchRequest(query: query, market: .france, limit: 20, cursor: nil).valid, "query length/control bounds enforced")
        }
        expect(!C.SearchRequest(query: "game", market: .france, limit: 51, cursor: nil).valid, "page size has a hard bound")
        expect(!C.SearchRequest(query: "game", market: .france, limit: 20, cursor: String(repeating: "x", count: 513)).valid, "opaque cursor has a hard bound")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(C.PurchaseOffer.self, from: encoder.encode(offer()))
        expect(roundTrip.price?.amountMinor == 12345 && roundTrip.regularPrice == nil && eligible(roundTrip), "exact minor money and missing regular price survive wire roundtrip")
        let decodedProduct = try decoder.decode(C.Product.self, from: encoder.encode(p))
        expect(decodedProduct.localCompatibility == .windowsRuntimeUnverified && decodedProduct.platforms.first?.platform == .windows, "Windows product never becomes Mac-native/verified by serialization")
        print("StoreCatalogContractTests: \(checks) checks PASS; proposal model only, no providers, credentials, HTTP, UI or purchases")
    }
}
