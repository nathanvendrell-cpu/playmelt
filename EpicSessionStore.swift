import Foundation
import Darwin
import Security
import LocalAuthentication

/// Synchronous, confined to EpicConnector's serial worker queue. Constructors
/// and persistenceKind never access Keychain. Tests inject memory/mock stores.
protocol EpicSessionStoring {
    var persistenceKind: String { get }
    var persistenceBackend: String { get }
    var restorationNotice: String { get }
    func load() throws -> [String: Any]?
    func save(_ session: [String: Any]) throws
    func clear() throws
}

extension EpicSessionStoring {
    var restorationNotice: String { "" }
    var persistenceBackend: String { "custom" }
}

/// The internal bundle and an explicitly marked licensed ad-hoc client use
/// isolated login-keychain namespaces. Unmarked clients retain data protection.
/// Errors never change backend or broaden default application access controls.
enum EpicKeychainBackend: String {
    case dataProtection = "data-protection"
    case internalLogin = "internal-login"
    case clientLogin = "client-login"
    /// Repli chiffré pour une signature ad hoc : le Trousseau de protection des
    /// données refuse toute écriture sans droit d’équipe (errSecMissingEntitlement),
    /// ce qui perdait la session à chaque redémarrage. Ce backend utilise le
    /// Trousseau de session (fichier chiffré), jamais un secret en clair sur disque,
    /// avec une ACL liée au chemin stable de l’exécutable Playmelt.
    case sharedLogin = "shared-login"
    static func configured(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Self {
        func boolean(_ key: String) -> Bool? {
            guard let value = info[key] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        if boolean("PlaymeltInternalBuild") == true { return .internalLogin }
        guard info["PlaymeltClientCredentialChannel"] as? String == "adhoc-login-v1",
              boolean("PlaymeltCommercialAccessEnabled") == true,
              boolean("PlaymeltDevelopmentBuild") == false,
              boolean("PlaymeltInternalBuild") == false else { return .dataProtection }
        return .clientLogin
    }
    var service: String {
        switch self {
        case .dataProtection: return EpicKeychainSessionStore.service
        case .internalLogin: return "fr.playmelt.epic.session.internal.v1"
        case .clientLogin: return "fr.playmelt.epic.session.client-login.v1"
        case .sharedLogin: return "fr.playmelt.epic.session.shared.v1"
        }
    }
}

enum EpicSessionStoreError: LocalizedError {
    case invalidData
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidData: return "La session Epic enregistrée est invalide. Reconnectez votre compte."
        case .keychain(let status):
            if status == errSecMissingEntitlement {
                return "Le Trousseau refuse cette signature de Playmelt (code \(status)). La session reste uniquement en mémoire."
            }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                return "Le Trousseau est verrouillé ou son accès est refusé (code \(status)). Aucune fenêtre d’authentification système n’a été ouverte."
            }
            return "Le Trousseau Epic est indisponible (code \(status)). Aucune copie du secret n’est écrite sur disque."
        }
    }
    static func publicMessage(_ error: Error) -> String {
        // Never forward arbitrary backend errors which might include credentials.
        (error as? EpicSessionStoreError)?.localizedDescription ?? "Impossible d’accéder au Trousseau Epic. La session peut seulement rester en mémoire."
    }
}

enum EpicSessionEnvelope {
    static let maximumBytes = 64 * 1024
    static func validate(_ session: [String: Any]) throws -> String {
        guard let account = session["account_id"] as? String, !account.isEmpty, account.utf8.count <= 128,
              account.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              JSONSerialization.isValidJSONObject(session) else { throw EpicSessionStoreError.invalidData }
        var hasToken = false
        for key in ["refresh_token", "access_token"] {
            guard let value = session[key] else { continue }
            guard let token = value as? String, !token.isEmpty, token.utf8.count <= 16 * 1024 else { throw EpicSessionStoreError.invalidData }
            hasToken = true
        }
        guard hasToken else { throw EpicSessionStoreError.invalidData }
        return account
    }
    static func encode(_ session: [String: Any]) throws -> Data {
        let account = try validate(session)
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "account_id": account, "session": session], options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw EpicSessionStoreError.invalidData }
        return data
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes,
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = envelope["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let account = envelope["account_id"] as? String,
              let session = envelope["session"] as? [String: Any], try validate(session) == account else { throw EpicSessionStoreError.invalidData }
        return session
    }
}

/// Security calls are a separately injectable boundary: tests inspect queries
/// without touching a real keychain, even when exercising the Keychain store.
protocol EpicKeychainAccess {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
private struct EpicSecurityAccess: EpicKeychainAccess {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

final class EpicKeychainSessionStore: EpicSessionStoring {
    private(set) var persistenceKind = "keychain"
    private(set) var restorationNotice = ""
    static let service = "fr.playmelt.epic.session.v1"
    static let account = "primary"
    private(set) var backend: EpicKeychainBackend
    var persistenceBackend: String { backend.rawValue }
    private let access: EpicKeychainAccess
    private let legacyFileURL: URL?
    private let legendaryFileURL: URL?
    private let accessBuilder: () -> SecAccess?
    init(access: EpicKeychainAccess? = nil, legacyFileURL: URL? = nil, backend: EpicKeychainBackend = .configured(),
         accessBuilder: (() -> SecAccess?)? = nil, legendaryFileURL: URL? = nil) {
        self.access = access ?? EpicSecurityAccess()
        self.backend = backend
        self.accessBuilder = accessBuilder ?? { nil }
        // Mock transports never inspect a real user's legacy file by default.
        self.legacyFileURL = legacyFileURL ?? (access == nil ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/.epic_session.dat") : nil)
        // Session déjà rafraîchie par le client Legendary officiel utilisé pour
        // les lanceurs directs. Migration en lecture seule, jamais réécrite.
        self.legendaryFileURL = legendaryFileURL ?? (access == nil ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/legendary/user.json") : nil)
    }
    private static func trustedAccess(path: String?) -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(path, &trusted) == errSecSuccess, let trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Session Epic Playmelt" as CFString, [trusted] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
    private func query(for backend: EpicKeychainBackend) -> [String: Any] {
        var request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: backend.service, kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: backend == .dataProtection,
            kSecAttrSynchronizable as String: false]
        if backend != .dataProtection {
            // No access groups, custom ACL, biometric bypass or iCloud storage.
            // A locked or reauthorisation-required item fails visibly instead.
            request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            return request
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        return request
    }
    private func query() -> [String: Any] { query(for: backend) }
    private func legacyData(_ file: URL) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw EpicSessionStoreError.invalidData }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= EpicSessionEnvelope.maximumBytes else { throw EpicSessionStoreError.invalidData }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count <= EpicSessionEnvelope.maximumBytes else { throw EpicSessionStoreError.invalidData }
        return data
    }
    private var legacyIgnoreURL: URL? { legacyFileURL?.deletingLastPathComponent().appendingPathComponent(".epic-legacy-disconnected") }
    private let ignoreBytes = Data("Playmelt legacy session explicitly disconnected.\n".utf8)
    func load() throws -> [String: Any]? {
        restorationNotice = ""
        var (status, data) = read(backend)
        if status == errSecMissingEntitlement, backend == .dataProtection {
            // Signature ad hoc : le Trousseau de protection des données ne peut
            // pas écrire ni lire sans droit d’équipe. La session vit alors dans
            // le Trousseau de session chiffré, lié au chemin de Playmelt.
            backend = .sharedLogin
            (status, data) = read(backend)
        }
        if backend == .dataProtection, status == errSecItemNotFound {
            // Une exécution ad hoc précédente a pu persister dans le backend
            // partagé. Il prime sur l’ancien fichier, sinon un jeton expiré
            // écraserait la session valide à chaque démarrage.
            let (sharedStatus, sharedData) = read(.sharedLogin)
            if sharedStatus == errSecSuccess {
                guard let sharedData else { throw EpicSessionStoreError.invalidData }
                backend = .sharedLogin
                persistenceKind = "keychain"
                return try EpicSessionEnvelope.decode(sharedData)
            }
            if sharedStatus != errSecItemNotFound, sharedStatus != errSecMissingEntitlement {
                throw EpicSessionStoreError.keychain(sharedStatus)
            }
        }
        if status == errSecSuccess {
            guard let data else { throw EpicSessionStoreError.invalidData }
            persistenceKind = "keychain"
            return try EpicSessionEnvelope.decode(data)
        }
        if status == errSecItemNotFound {
            // La session Legendary officielle est souvent plus récente que
            // l'ancien fichier Playmelt. Elle est lue sans être modifiée, puis
            // migrée dans le Trousseau. Cela évite une reconnexion après un
            // redéploiement.
            if let legendary = newestExternalSession() {
                do { try save(legendary) }
                catch {
                    persistenceKind = "memory"
                    restorationNotice = EpicSessionStoreError.publicMessage(error) + " La session Legendary a été reprise en mémoire ; son fichier reste inchangé."
                }
                return legendary
            }
            if let ignored = legacyIgnoreURL, FileManager.default.fileExists(atPath: ignored.path) {
                guard try legacyData(ignored) == ignoreBytes else { throw EpicSessionStoreError.invalidData }
            } else if let file = legacyFileURL, FileManager.default.fileExists(atPath: file.path) {
                let session = try EpicSessionEnvelope.decode(legacyData(file))
                do { try save(session) }
                catch {
                    persistenceKind = "memory"
                    restorationNotice = EpicSessionStoreError.publicMessage(error) + " L’ancienne session a été reprise en mémoire ; son fichier reste inchangé."
                }
                return session
            }
            return nil
        }
        throw EpicSessionStoreError.keychain(status)
    }
    /// Session écrite par le CLI Legendary du lanceur direct. Lecture seule,
    /// fichiers réguliers appartenant à l'utilisateur, taille bornée.
    private func newestExternalSession() -> [String: Any]? {
        let fm = FileManager.default
        guard let legendary = legendaryFileURL, fm.fileExists(atPath: legendary.path) else { return nil }
        func modified(_ url: URL) -> TimeInterval {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        if let legacy = legacyFileURL, fm.fileExists(atPath: legacy.path), modified(legacy) > modified(legendary) { return nil }
        guard let data = try? externalData(legendary),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (try? EpicSessionEnvelope.validate(raw)) != nil else { return nil }
        return raw
    }
    private func externalData(_ file: URL) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw EpicSessionStoreError.invalidData }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & 0o022) == 0,
              info.st_size > 0, info.st_size <= EpicSessionEnvelope.maximumBytes else { throw EpicSessionStoreError.invalidData }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count <= EpicSessionEnvelope.maximumBytes else { throw EpicSessionStoreError.invalidData }
        return data
    }
    private func read(_ backend: EpicKeychainBackend) -> (OSStatus, Data?) {
        var request = query(for: backend)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return access.copy(request)
    }
    func save(_ session: [String: Any]) throws {
        let data = try EpicSessionEnvelope.encode(session)
        do { try write(data) }
        catch EpicSessionStoreError.keychain(let status)
            where status == errSecMissingEntitlement && backend == .dataProtection {
            backend = .sharedLogin
            try write(data)
        }
    }
    private func write(_ data: Data) throws {
        var request = query()
        var values: [String: Any] = [kSecValueData as String: data]
        if backend == .dataProtection {
            values[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        } else if backend == .sharedLogin, let acl = accessBuilder() {
            values[kSecAttrAccess as String] = acl
        }
        var status = access.update(request, attributes: values)
        if status == errSecItemNotFound {
            status = access.add(request.merging(values) { _, new in new })
            if status == errSecDuplicateItem { status = access.update(request, attributes: values) }
        }
        if backend == .sharedLogin,
           [errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
            let deleted = access.delete(query())
            if deleted == errSecSuccess || deleted == errSecItemNotFound {
                status = access.add(request.merging(values) { _, new in new })
            }
        }
        guard status == errSecSuccess else { persistenceKind = "memory"; throw EpicSessionStoreError.keychain(status) }
        persistenceKind = "keychain"
    }
    func clear() throws {
        var targets: [EpicKeychainBackend] = [backend]
        if backend == .dataProtection || backend == .sharedLogin { targets = [.dataProtection, .sharedLogin] }
        var firstFailure: OSStatus?
        for target in targets {
            let status = access.delete(query(for: target))
            if status != errSecSuccess, status != errSecItemNotFound, status != errSecMissingEntitlement,
               firstFailure == nil {
                firstFailure = status
            }
        }
        if let firstFailure { throw EpicSessionStoreError.keychain(firstFailure) }
        for target in targets {
            let status = access.delete(query(for: target))
            if status != errSecSuccess, status != errSecItemNotFound, status != errSecMissingEntitlement,
               firstFailure == nil {
                firstFailure = status
            }
        }
        if let firstFailure { throw EpicSessionStoreError.keychain(firstFailure) }
        // Keep the old credential bytes untouched, but do not silently resurrect
        // a deliberately disconnected legacy session on the next app launch.
        if let file = legacyFileURL, FileManager.default.fileExists(atPath: file.path), let ignored = legacyIgnoreURL {
            if FileManager.default.fileExists(atPath: ignored.path) {
                guard try legacyData(ignored) == ignoreBytes else { throw EpicSessionStoreError.invalidData }
            } else {
                var parent = stat()
                guard lstat(file.deletingLastPathComponent().path, &parent) == 0,
                      (parent.st_mode & S_IFMT) == S_IFDIR, parent.st_uid == getuid() else { throw EpicSessionStoreError.invalidData }
                let fd = open(ignored.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw EpicSessionStoreError.invalidData }
                defer { close(fd) }
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: ignoreBytes)
            }
        }
    }
}

/// Explicit ephemeral fixture/storage option. Does not call Security and never
/// claims Keychain persistence. The connector remains responsible for lifetime.
final class EpicMemorySessionStore: EpicSessionStoring {
    let persistenceKind = "memory"
    private var data: Data?
    func load() throws -> [String: Any]? { try data.map(EpicSessionEnvelope.decode) }
    func save(_ session: [String: Any]) throws { data = try EpicSessionEnvelope.encode(session) }
    func clear() throws { data = nil }
}

// Apple contracts reviewed for macOS:
// https://developer.apple.com/documentation/security/ksecattraccessible
// https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
// https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
// https://developer.apple.com/documentation/security/ksecuseauthenticationuifail
// https://developer.apple.com/forums/thread/114456
