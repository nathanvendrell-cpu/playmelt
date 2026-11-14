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
    private let backend: EpicKeychainBackend
    var persistenceBackend: String { backend.rawValue }
    private let access: EpicKeychainAccess
    private let legacyFileURL: URL?
    init(access: EpicKeychainAccess? = nil, legacyFileURL: URL? = nil, backend: EpicKeychainBackend = .configured()) {
        self.access = access ?? EpicSecurityAccess()
        self.backend = backend
        // Mock transports never inspect a real user's legacy file by default.
        self.legacyFileURL = legacyFileURL ?? (access == nil ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/.epic_session.dat") : nil)
    }
    private func query() -> [String: Any] {
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
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = access.copy(request)
        if status == errSecSuccess {
            guard let data else { throw EpicSessionStoreError.invalidData }
            persistenceKind = "keychain"
            return try EpicSessionEnvelope.decode(data)
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
        if status == errSecItemNotFound { return nil }
        throw EpicSessionStoreError.keychain(status)
    }
    func save(_ session: [String: Any]) throws {
        let data = try EpicSessionEnvelope.encode(session)
        let request = query()
        var values: [String: Any] = [kSecValueData as String: data]
        // kSecAttrAccessible is a data-protection keychain contract, not an
        // equivalent protection class on macOS's file-based login keychain.
        if backend == .dataProtection {
            values[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        var status = access.update(request, attributes: values)
        if status == errSecItemNotFound {
            status = access.add(request.merging(values) { _, new in new })
            if status == errSecDuplicateItem { status = access.update(request, attributes: values) }
        }
        guard status == errSecSuccess else { persistenceKind = "memory"; throw EpicSessionStoreError.keychain(status) }
        persistenceKind = "keychain"
    }
    func clear() throws {
        let status = access.delete(query())
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EpicSessionStoreError.keychain(status) }
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
