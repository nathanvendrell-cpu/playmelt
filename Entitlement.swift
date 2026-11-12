import Foundation
import Security

/// Abonnement Playmelt : offres, vérification de licence et décision de lancement.
///
/// INERTE PAR DÉFAUT : tant que `PlaymeltPaywallEnabled` n'est pas `true` dans
/// l'Info.plist, `decision()` répond `.unrestricted` et rien ne change.
///
/// Fournisseur prévu : un « merchant of record » (Lemon Squeezy) qui encaisse,
/// gère la TVA européenne, les abonnements et délivre une clé de licence par
/// achat. L'app ne voit jamais de carte bancaire : seulement la clé.
/// API publique de licence : `POST https://api.lemonsqueezy.com/v1/licenses/{activate,validate,deactivate}`.
///
/// Limite assumée : une vérification côté client se contourne en recompilant
/// le code source. Elle protège les versions officielles, pas un dépôt public.
enum PlaymeltPlan: String, CaseIterable {
    case monthly, quarterly, semiannual, annual, lifetime

    /// Prix TTC en centimes d'euro — PROPOSITION à valider par Nathan.
    /// Dégressif : plus la durée est longue, plus le prix mensuel baisse.
    var priceCents: Int {
        switch self {
        case .monthly: return 1999      // 19,99 €/mois
        case .quarterly: return 5399    // 18,00 €/mois (−10 %)
        case .semiannual: return 9599   // 16,00 €/mois (−20 %)
        case .annual: return 16799      // 14,00 €/mois (−30 %)
        case .lifetime: return 39900    // paiement unique
        }
    }
    var months: Int? {
        switch self { case .monthly: return 1; case .quarterly: return 3; case .semiannual: return 6; case .annual: return 12; case .lifetime: return nil }
    }
    var label: String {
        switch self {
        case .monthly: return "1 mois"; case .quarterly: return "3 mois"; case .semiannual: return "6 mois"
        case .annual: return "1 an"; case .lifetime: return "À vie"
        }
    }
    /// Prix mensuel équivalent, en centimes (nil pour l'offre à vie).
    var monthlyEquivalentCents: Int? { months.map { Int((Double(priceCents) / Double($0)).rounded()) } }

    static func catalog() -> [[String: Any]] {
        allCases.map { plan in
            var row: [String: Any] = ["id": plan.rawValue, "label": plan.label, "priceCents": plan.priceCents]
            if let monthly = plan.monthlyEquivalentCents { row["monthlyEquivalentCents"] = monthly }
            if let months = plan.months, let base = PlaymeltPlan.monthly.monthlyEquivalentCents {
                row["savingPercent"] = Int((100 - Double(plan.monthlyEquivalentCents!) * 100 / Double(base)).rounded())
                row["months"] = months
            }
            return row
        }
    }
}

struct EntitlementConfiguration: Equatable {
    var enabled = false
    /// Identifiants du magasin et des produits : une clé d'un autre magasin est refusée.
    var storeID: Int?
    var productIDs: Set<Int> = []
    /// Variante (offre) → plan. Rempli une fois les produits créés chez le fournisseur.
    var variantPlans: [Int: PlaymeltPlan] = [:]
    /// Jours de jeu hors ligne après la dernière vérification réussie.
    var offlineGraceDays = 7
    var checkoutURL: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> EntitlementConfiguration {
        var c = EntitlementConfiguration()
        let info = bundle.infoDictionary ?? [:]
        c.enabled = info["PlaymeltPaywallEnabled"] as? Bool ?? false
        c.storeID = (info["PlaymeltLicenseStoreID"] as? NSNumber)?.intValue
        c.productIDs = Set((info["PlaymeltLicenseProductIDs"] as? [NSNumber] ?? []).map(\.intValue))
        for (key, value) in info["PlaymeltLicenseVariantPlans"] as? [String: String] ?? [:] {
            if let id = Int(key), let plan = PlaymeltPlan(rawValue: value) { c.variantPlans[id] = plan }
        }
        c.checkoutURL = (info["PlaymeltCheckoutURL"] as? String).flatMap(URL.init(string:))
        return c
    }
    /// Activé sans identifiants de magasin = configuration incomplète : on refuse
    /// plutôt que d'accepter n'importe quelle clé.
    var complete: Bool { storeID != nil && !productIDs.isEmpty }
}

/// État mémorisé de la dernière vérification réussie (Keychain).
struct LicenseRecord: Codable, Equatable {
    var key: String
    var instanceID: String
    var status: String
    var variantID: Int?
    var expiresAt: Date?
    var validatedAt: Date
}

enum EntitlementDecision: Equatable {
    case unrestricted
    case entitled(plan: PlaymeltPlan?, until: Date?, offline: Bool)
    case denied(String)

    var allowsLaunch: Bool { if case .denied = self { return false }; return true }
    var message: String {
        switch self {
        case .unrestricted: return "Accès libre."
        case let .entitled(plan, until, offline):
            let name = plan?.label ?? "Abonnement"
            let date = until.map { " jusqu'au " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? ""
            return name + " actif" + date + (offline ? " (vérification hors ligne)" : "") + "."
        case let .denied(reason): return reason
        }
    }
}

protocol LicenseTransport {
    func post(_ path: String, form: [String: String], completion: @escaping (Result<(Int, Data), Error>) -> Void)
}

struct LemonSqueezyTransport: LicenseTransport {
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15; c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()
    func post(_ path: String, form: [String: String], completion: @escaping (Result<(Int, Data), Error>) -> Void) {
        guard ["activate", "validate", "deactivate"].contains(path),
              let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/" + path) else {
            completion(.failure(URLError(.badURL))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            completion(.success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())))
        }.resume()
    }
}

protocol LicenseVault {
    func load() -> LicenseRecord?
    func save(_ record: LicenseRecord?) -> Bool
}

/// Clé de licence et dernier état dans le trousseau de session de l'utilisateur.
struct KeychainLicenseVault: LicenseVault {
    var service = "com.robtech.metalmaxgaminghub.license"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "playmelt", kSecUseDataProtectionKeychain as String: true]
    }
    func load() -> LicenseRecord? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder.license.decode(LicenseRecord.self, from: data)
    }
    func save(_ record: LicenseRecord?) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard let record else { return true }
        guard let data = try? JSONEncoder.license.encode(record) else { return false }
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

extension JSONEncoder { static var license: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var license: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

final class EntitlementStore {
    let configuration: EntitlementConfiguration
    private let transport: LicenseTransport
    private let vault: LicenseVault
    private let now: () -> Date
    private let lock = NSLock()
    private var record: LicenseRecord?

    init(configuration: EntitlementConfiguration = .fromBundle(), transport: LicenseTransport = LemonSqueezyTransport(),
         vault: LicenseVault = KeychainLicenseVault(), now: @escaping () -> Date = Date.init) {
        self.configuration = configuration; self.transport = transport; self.vault = vault; self.now = now
        record = configuration.enabled ? vault.load() : nil
    }

    /// Décision synchrone, sans réseau : utilisée au moment du lancement.
    func decision() -> EntitlementDecision {
        guard configuration.enabled else { return .unrestricted }
        guard configuration.complete else { return .denied("Abonnement : configuration du magasin incomplète.") }
        lock.lock(); let current = record; lock.unlock()
        guard let current else { return .denied("Un abonnement Playmelt est nécessaire pour lancer un jeu.") }
        return evaluate(current, offline: true)
    }

    private func evaluate(_ r: LicenseRecord, offline: Bool) -> EntitlementDecision {
        let t = now()
        guard r.status == "active" else {
            return .denied(r.status == "expired" ? "Votre abonnement Playmelt a expiré." : "Licence Playmelt inactive.")
        }
        if let expires = r.expiresAt, expires <= t { return .denied("Votre abonnement Playmelt a expiré.") }
        if offline {
            let grace = TimeInterval(configuration.offlineGraceDays * 86_400)
            guard t.timeIntervalSince(r.validatedAt) <= grace, r.validatedAt <= t.addingTimeInterval(300) else {
                return .denied("Connectez-vous à Internet pour vérifier votre abonnement.")
            }
        }
        return .entitled(plan: r.variantID.flatMap { configuration.variantPlans[$0] }, until: r.expiresAt, offline: offline)
    }

    /// Première activation d'une clé sur ce Mac.
    func activate(key rawKey: String, completion: @escaping (EntitlementDecision) -> Void) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.enabled, configuration.complete else { completion(decision()); return }
        guard (16...128).contains(key.count), key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            completion(.denied("Clé de licence invalide.")); return
        }
        let instanceName = "Playmelt-" + (Host.current().localizedName ?? "Mac").prefix(40)
        transport.post("activate", form: ["license_key": key, "instance_name": String(instanceName)]) { [weak self] result in
            guard let self else { return }
            completion(self.handle(result, key: key, instanceID: nil, accepted: "activated"))
        }
    }

    /// Vérification en ligne (au démarrage puis périodiquement par l'appelant).
    func refresh(completion: @escaping (EntitlementDecision) -> Void) {
        guard configuration.enabled, configuration.complete else { completion(decision()); return }
        lock.lock(); let current = record; lock.unlock()
        guard let current else { completion(decision()); return }
        transport.post("validate", form: ["license_key": current.key, "instance_id": current.instanceID]) { [weak self] result in
            guard let self else { return }
            completion(self.handle(result, key: current.key, instanceID: current.instanceID, accepted: "valid"))
        }
    }

    func deactivate(completion: @escaping (Bool) -> Void) {
        lock.lock(); let current = record; record = nil; lock.unlock()
        _ = vault.save(nil)
        guard let current else { completion(true); return }
        transport.post("deactivate", form: ["license_key": current.key, "instance_id": current.instanceID]) { result in
            if case let .success((code, _)) = result { completion(code == 200) } else { completion(false) }
        }
    }

    private func handle(_ result: Result<(Int, Data), Error>, key: String, instanceID: String?, accepted: String) -> EntitlementDecision {
        guard case let .success((code, data)) = result else {
            // Réseau indisponible : la décision hors ligne (période de grâce) s'applique.
            return decision()
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return code >= 500 ? decision() : .denied("Réponse du serveur de licence illisible.")
        }
        let license = json["license_key"] as? [String: Any] ?? [:]
        let meta = json["meta"] as? [String: Any] ?? [:]
        let instance = json["instance"] as? [String: Any] ?? [:]
        guard json[accepted] as? Bool == true else {
            if code >= 500 { return decision() }
            if instanceID != nil { lock.lock(); record = nil; lock.unlock(); _ = vault.save(nil) }
            return .denied((json["error"] as? String).map { "Licence refusée : " + $0 } ?? "Licence refusée.")
        }
        // Une clé valide d'un autre magasin ou d'un autre produit est refusée.
        guard let store = (meta["store_id"] as? NSNumber)?.intValue, store == configuration.storeID,
              let product = (meta["product_id"] as? NSNumber)?.intValue, configuration.productIDs.contains(product) else {
            return .denied("Cette clé n'appartient pas à Playmelt.")
        }
        guard let instance = instanceID ?? (instance["id"] as? String), !instance.isEmpty else {
            return .denied("Activation incomplète : identifiant d'appareil manquant.")
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let expires = (license["expires_at"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
        let fresh = LicenseRecord(key: key, instanceID: instance, status: license["status"] as? String ?? "inactive",
                                  variantID: (meta["variant_id"] as? NSNumber)?.intValue, expiresAt: expires, validatedAt: now())
        lock.lock(); record = fresh; lock.unlock()
        _ = vault.save(fresh)
        return evaluate(fresh, offline: false)
    }

    /// Données pour l'interface (aucune clé complète exposée).
    func snapshot() -> [String: Any] {
        lock.lock(); let current = record; lock.unlock()
        let d = decision()
        var out: [String: Any] = ["enabled": configuration.enabled, "allowed": d.allowsLaunch, "message": d.message,
                                  "plans": PlaymeltPlan.catalog()]
        if let current { out["keySuffix"] = String(current.key.suffix(4)) }
        if let url = configuration.checkoutURL { out["checkoutURL"] = url.absoluteString }
        return out
    }
}
