import Foundation

/// Proposal only. Not integrated into the build, UI, purchase or account flows.
/// Search candidates, exact editions and purchasable SKUs are separate identities.
enum StoreCatalogContract {
    static let version = 1
    static let priceTTL: TimeInterval = 300
    enum ProductKind: String, Codable { case game, dlc, bundle, demo, soundtrack, software, unknown }
    enum Availability: String, Codable { case available, notForSale, regionBlocked, unknown }
    enum SourceState: String, Codable { case ready, partial, notConfigured, approvalRequired, unavailable, rateLimited, previewOnly }
    enum IdentityEvidence: String, Codable { case verifiedCrosswalk, verifiedContents, singleStoreExact, ambiguous, unresolved }
    enum PurchaseKind: String, Codable { case oneTime, freeToKeep, freeToPlay, subscription, rental }
    enum Condition: String, Codable { case coupon, membership, accountEligibility, priorOwnership, regionUnconfirmed, taxUnconfirmed }
    enum Platform: String, Codable { case windows, macOS, linux, xboxOne, xboxSeries, playStation4, playStation5, switchConsole, unknown }
    enum LocalCompatibility: String, Codable { case nativeMac, windowsRuntimeVerified, windowsRuntimeUnverified, consoleOnly, unknown }

    struct Market: Codable, Equatable {
        let country: String, currency: String
        static let france = Market(country: "FR", currency: "EUR")
        var supported: Bool { self == .france }
    }
    struct Money: Codable, Equatable {
        let amountMinor: Int64
        let currency: String
        let exponent: Int
        var validEUR: Bool { currency == "EUR" && exponent == 2 && amountMinor >= 0 && amountMinor <= 100_000_000_000 }
    }
    struct Observation: Codable {
        let provider: String
        let state: SourceState
        let sourceURL: URL
        let retrievedAt: Date
        let providerUpdatedAt: Date?
        let expiresAt: Date?
        let evidenceID: String
        func fresh(at now: Date) -> Bool {
            let age = now.timeIntervalSince(retrievedAt)
            guard state == .ready, age >= 0, age <= StoreCatalogContract.priceTTL,
                  expiresAt.map({ $0 > now }) ?? true else { return false }
            // A recently fetched response must not hide an explicitly old provider snapshot.
            if let updated = providerUpdatedAt {
                let providerAge = now.timeIntervalSince(updated)
                guard providerAge >= -30, providerAge <= 24 * 3600 else { return false }
            }
            return true
        }
    }
    struct StoreReference: Codable, Equatable {
        let storeID: String
        let productID: String
        let offerID: String?
        let packageID: String?
        let namespace: String?
    }
    struct Edition: Codable {
        let id: String?
        let publisherLabel: String?
        let includedProductIDs: [String]
        let identityEvidence: IdentityEvidence
        let evidenceIDs: [String]
    }
    struct PlatformSupport: Codable {
        let platform: Platform
        let architecture: String?
        let sourceEvidenceID: String
    }
    struct Artwork: Codable {
        let id: String
        let url: URL
        let thumbnail: URL
        let sourceURL: URL
    }
    struct Presentation: Codable {
        let descriptionText: String?
        let publisher: String?
        let developers: [String]
        let images: [Artwork]
        let observation: Observation
    }
    struct Product: Codable {
        let id: String
        let title: String
        let kind: ProductKind
        let edition: Edition
        let storeReferences: [StoreReference]
        let presentation: Presentation?
        let platforms: [PlatformSupport]
        let localCompatibility: LocalCompatibility
        let compatibilityEvidenceID: String?
        let mediaSteamAppID: String?
    }
    struct PurchaseOffer: Codable {
        let id: String
        let productID: String
        let productKind: ProductKind
        let editionID: String?
        let identityEvidence: IdentityEvidence
        let store: StoreReference
        let sellerName: String
        let activationDRM: [String]
        let market: Market
        let availability: Availability
        let kind: PurchaseKind
        let price: Money?
        let regularPrice: Money?
        let conditions: [Condition]
        let destinationURL: URL
        let observation: Observation

        /// Eligibility for numeric ranking within the SAME exact product/edition.
        /// Never described as the cheapest price on the whole market.
        func comparable(to product: Product, market requested: Market, at now: Date, allowedDestinationHosts: Set<String>) -> Bool {
            guard requested.supported, market == requested, availability == .available,
                  productID == product.id, productKind == product.kind, product.kind != .unknown,
                  let editionID, !editionID.isEmpty, product.edition.id == editionID,
                  [.verifiedCrosswalk, .verifiedContents].contains(identityEvidence),
                  [.verifiedCrosswalk, .verifiedContents].contains(product.edition.identityEvidence),
                  !product.edition.evidenceIDs.isEmpty,
                  product.storeReferences.contains(where: { $0.storeID == store.storeID && $0.productID == store.productID }),
                  kind == .oneTime, conditions.isEmpty, let price, price.validEUR, price.amountMinor > 0,
                  observation.fresh(at: now), !observation.evidenceID.isEmpty, destinationURL.scheme == "https",
                  destinationURL.user == nil, destinationURL.password == nil, destinationURL.port == nil,
                  let host = destinationURL.host?.lowercased(), allowedDestinationHosts.contains(host) else { return false }
            return true
        }
    }
    /// Subscriptions/free trials remain outside purchaseOffers and price ranking.
    struct SubscriptionAccess: Codable {
        let productID: String
        let serviceID: String
        let tierName: String
        let platform: Platform
        let market: Market
        let included: Availability
        let billingPeriodISO8601: String?
        let recurringPrice: Money?
        let introductoryPrice: Money?
        let observation: Observation
    }
    struct Coverage: Codable {
        let provider: String
        let state: SourceState
        let storesChecked: [String]
        let market: Market
        let retrievedAt: Date?
        let retryAfter: Date?
        let truncated: Bool
        let exhaustive: Bool
        let reasonCode: String?
    }
    struct SearchRequest: Codable {
        let query: String
        let market: Market
        let limit: Int
        let cursor: String?
        var valid: Bool {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return market.supported && trimmed.count >= 2 && trimmed.count <= 120 &&
                !query.unicodeScalars.contains(where: { $0.value < 32 }) && (1...50).contains(limit) &&
                (cursor.map { $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { $0.value < 32 }) } ?? true)
        }
    }
    struct SearchResponse: Codable {
        let query: String
        let market: Market
        let products: [Product]
        let nextCursor: String?
        let coverage: [Coverage]
    }
    struct ProductDetail: Codable {
        let product: Product
        let market: Market
        let purchaseOffers: [PurchaseOffer]
        let subscriptionAccess: [SubscriptionAccess]
        let coverage: [Coverage]
    }
    enum Failure: Error { case invalidRequest, notConfigured, approvalRequired, unavailable, ambiguous, notFound, rateLimited(retryAfter: Date?) }
}

/// Proposed native-to-server boundary. No API key belongs in this protocol or JS.
/// Implementations must enforce seller URL allowlists, quotas and provider rights.
protocol StoreCatalogServing {
    func search(_ request: StoreCatalogContract.SearchRequest, completion: @escaping (Result<StoreCatalogContract.SearchResponse, StoreCatalogContract.Failure>) -> Void)
    func detail(productID: String, market: StoreCatalogContract.Market, completion: @escaping (Result<StoreCatalogContract.ProductDetail, StoreCatalogContract.Failure>) -> Void)
    func shutdown()
}
