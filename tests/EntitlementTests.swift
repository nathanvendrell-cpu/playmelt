import Foundation

/// Abonnement : faux serveur de licence et faux trousseau. Aucun réseau, aucun paiement.
final class FakeTransport: LicenseTransport {
    var responses: [String: Result<(Int, Data), Error>] = [:]
    var calls: [(String, [String: String])] = []
    func post(_ path: String, form: [String: String], completion: @escaping (Result<(Int, Data), Error>) -> Void) {
        calls.append((path, form)); completion(responses[path] ?? .failure(URLError(.notConnectedToInternet)))
    }
}
final class MemoryVault: LicenseVault {
    var stored: LicenseRecord?
    func load() -> LicenseRecord? { stored }
    func save(_ record: LicenseRecord?) -> Bool { stored = record; return true }
}

func reply(_ object: [String: Any], code: Int = 200) -> Result<(Int, Data), Error> {
    .success((code, try! JSONSerialization.data(withJSONObject: object)))
}
func license(_ accepted: String, status: String = "active", store: Int = 4242, product: Int = 77, variant: Int = 3, expires: String? = "2027-02-12T10:00:00.000000Z") -> [String: Any] {
    var key: [String: Any] = ["status": status]; key["expires_at"] = expires ?? NSNull()
    return [accepted: true, "error": NSNull(), "license_key": key, "instance": ["id": "inst-1"],
            "meta": ["store_id": store, "product_id": product, "variant_id": variant]]
}

@main struct EntitlementTests {
    static func main() {
        var passed = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, "FAIL: " + label); passed += 1 }
        let key = "ABCD1234-EFGH5678-IJKL9012-MNOP3456"
        var clock = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
        var config = EntitlementConfiguration(enabled: true, storeID: 4242, productIDs: [77], variantPlans: [3: .quarterly])

        // Tarifs dégressifs : prix mensuel décroissant avec la durée.
        let monthly = PlaymeltPlan.allCases.compactMap(\.monthlyEquivalentCents)
        check(monthly == monthly.sorted(by: >) && Set(monthly).count == monthly.count, "prix mensuel strictement dégressif")
        check(PlaymeltPlan.monthly.priceCents == 1999, "1 mois = 19,99 €")
        check(PlaymeltPlan.catalog().compactMap { $0["savingPercent"] as? Int } == [0, 10, 20, 30], "économies 0/10/20/30 %")
        check(PlaymeltPlan.lifetime.priceCents > PlaymeltPlan.annual.priceCents, "à vie > 1 an")

        // Désactivé (défaut) : aucun changement de comportement, aucun réseau.
        let offTransport = FakeTransport()
        let off = EntitlementStore(configuration: EntitlementConfiguration(), transport: offTransport, vault: MemoryVault())
        check(off.decision() == .unrestricted && off.decision().allowsLaunch, "désactivé = accès libre")
        off.refresh { _ in }; check(offTransport.calls.isEmpty, "désactivé = aucun appel réseau")
        check(EntitlementConfiguration.fromBundle(Bundle(for: FakeTransport.self)).enabled == false, "Info.plist sans clé = désactivé")

        // Activé mais magasin non configuré : refus prudent.
        let incomplete = EntitlementStore(configuration: EntitlementConfiguration(enabled: true), transport: FakeTransport(), vault: MemoryVault())
        check(!incomplete.decision().allowsLaunch, "configuration incomplète = refus")

        // Pas de licence = refus.
        let transport = FakeTransport(), vault = MemoryVault()
        var store = EntitlementStore(configuration: config, transport: transport, vault: vault, now: { clock })
        check(!store.decision().allowsLaunch, "sans licence = refus")

        // Clé mal formée : refusée sans réseau.
        var result: EntitlementDecision?
        store.activate(key: "x';--") { result = $0 }
        check(result?.allowsLaunch == false && transport.calls.isEmpty, "clé mal formée refusée localement")

        // Activation réussie.
        transport.responses["activate"] = reply(license("activated"))
        store.activate(key: " \(key)\n") { result = $0 }
        check(result == .entitled(plan: .quarterly, until: ISO8601DateFormatter().date(from: "2027-02-12T10:00:00Z"), offline: false), "activation réussie")
        check(transport.calls.last?.1["license_key"] == key, "clé nettoyée envoyée")
        check(vault.stored?.instanceID == "inst-1", "instance mémorisée")
        check(store.decision().allowsLaunch, "lancement autorisé après activation")
        check((store.snapshot()["keySuffix"] as? String) == "3456" && !(String(describing: store.snapshot()).contains(key)), "interface : clé masquée")

        // Redémarrage de l'app : relu depuis le trousseau.
        store = EntitlementStore(configuration: config, transport: transport, vault: vault, now: { clock })
        check(store.decision().allowsLaunch, "état relu au redémarrage")

        // Hors ligne : 7 jours de grâce, puis refus.
        transport.responses["validate"] = .failure(URLError(.notConnectedToInternet))
        clock = clock.addingTimeInterval(6 * 86_400)
        store.refresh { result = $0 }
        check(result?.allowsLaunch == true, "hors ligne J+6 accepté")
        clock = clock.addingTimeInterval(2 * 86_400)
        check(!store.decision().allowsLaunch, "hors ligne J+8 refusé")

        // Retour en ligne : validation réussie remet le compteur à zéro.
        transport.responses["validate"] = reply(license("valid"))
        store.refresh { result = $0 }
        check(result?.allowsLaunch == true && transport.calls.last?.1["instance_id"] == "inst-1", "validation en ligne")

        // Horloge reculée pour prolonger la grâce : refusée.
        clock = clock.addingTimeInterval(-3_600)
        check(!store.decision().allowsLaunch, "horloge reculée refusée")
        clock = clock.addingTimeInterval(3_600)

        // Abonnement expiré ou licence d'un autre magasin.
        transport.responses["validate"] = reply(license("valid", status: "expired"))
        store.refresh { result = $0 }
        check(result == .denied("Votre abonnement Playmelt a expiré."), "abonnement expiré")
        transport.responses["validate"] = reply(license("valid", store: 999))
        store.refresh { result = $0 }
        check(result == .denied("Cette clé n'appartient pas à Playmelt."), "clé d'un autre magasin refusée")
        transport.responses["validate"] = reply(license("valid", product: 1))
        store.refresh { result = $0 }
        check(result?.allowsLaunch == false, "clé d'un autre produit refusée")

        // Date d'expiration dépassée même si le statut dit actif.
        transport.responses["validate"] = reply(license("valid", expires: "2026-11-01T00:00:00Z"))
        store.refresh { result = $0 }
        check(result?.allowsLaunch == false, "date d'expiration dépassée")

        // Offre à vie : pas de date d'expiration.
        config.variantPlans[9] = .lifetime
        store = EntitlementStore(configuration: config, transport: transport, vault: vault, now: { clock })
        transport.responses["validate"] = reply(license("valid", variant: 9, expires: nil))
        store.refresh { result = $0 }
        check(result == .entitled(plan: .lifetime, until: nil, offline: false), "offre à vie")

        // Erreur serveur : on garde la décision hors ligne, sans effacer la licence.
        transport.responses["validate"] = reply(["error": "maintenance"], code: 503)
        store.refresh { result = $0 }
        check(result?.allowsLaunch == true && vault.stored != nil, "erreur serveur = grâce conservée")

        // Licence révoquée côté serveur : effacée localement.
        transport.responses["validate"] = reply(["valid": false, "error": "license_key not found"], code: 404)
        store.refresh { result = $0 }
        check(result?.allowsLaunch == false && vault.stored == nil, "licence révoquée effacée")

        // Désactivation de l'appareil.
        transport.responses["activate"] = reply(license("activated"))
        store.activate(key: key) { _ in }
        transport.responses["deactivate"] = reply(["deactivated": true])
        var ok = false; store.deactivate { ok = $0 }
        check(ok && vault.stored == nil && !store.decision().allowsLaunch, "désactivation")

        print("Abonnement : \(passed) PASS ; faux serveur et faux trousseau, aucun réseau ni paiement.")
    }
}
