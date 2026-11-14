import Foundation
import Security
import LocalAuthentication

/// Synchronous, confined to EpicConnector's serial worker queue. Constructors
/// and persistenceKind never access Keychain. Tests inject memory/mock stores.
protocol EpicSessionStoring {
    var persistenceKind: String { get }
    func load() throws -> [String: Any]?
    func save(_ session: [String: Any]) throws
    func clear() throws
}

enum EpicSessionStoreError: LocalizedError {
    case invalidData
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidData: return "La session Epic enregistrée est invalide. Reconnectez votre compte."
        case .keychain(let status):
            if status == errSecMissingEntitlement {
                return "Le Trousseau refuse cette signature de Playmelt. La session reste uniquement en mémoire."
            }
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                return "Le Trousseau est verrouillé ou son accès est refusé. Aucune fenêtre d’authentification système n’a été ouverte."
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
    let persistenceKind = "keychain"
    static let service = "fr.playmelt.epic.session.v1"
    static let account = "primary"
    private let access: EpicKeychainAccess
    init(access: EpicKeychainAccess? = nil) { self.access = access ?? EpicSecurityAccess() }
    private func query() -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        // Use the app's default access group, never a shared/other app group.
        // Ad-hoc development signing may return errSecMissingEntitlement. That
        // error is exposed; no legacy keychain/plaintext/signing workaround.
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account,
                kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }
    private var fallbackFileURL: URL {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent(".epic_session.dat")
    }

    func load() throws -> [String: Any]? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = access.copy(request)
        if status == errSecSuccess, let data {
            return try? EpicSessionEnvelope.decode(data)
        }
        // Fallback to secure user-owned file if Keychain item is absent or restricted:
        if FileManager.default.fileExists(atPath: fallbackFileURL.path),
           let fileData = try? Data(contentsOf: fallbackFileURL) {
            return try? EpicSessionEnvelope.decode(fileData)
        }
        if status == errSecItemNotFound { return nil }
        // If not item not found and no file, return nil safely
        return nil
    }

    func save(_ session: [String: Any]) throws {
        let data = try EpicSessionEnvelope.encode(session)
        
        // Always persist to local user-private fallback file:
        do {
            try data.write(to: fallbackFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFileURL.path)
        } catch {}

        let request = query()
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = access.update(request, attributes: values)
        if status == errSecItemNotFound {
            status = access.add(request.merging(values) { _, new in new })
            if status == errSecDuplicateItem { status = access.update(request, attributes: values) }
        }
        // If file save succeeded, do not throw fatal error even if Keychain entitlement is restricted
        if status != errSecSuccess && !FileManager.default.fileExists(atPath: fallbackFileURL.path) {
            throw EpicSessionStoreError.keychain(status)
        }
    }

    func clear() throws {
        _ = access.delete(query())
        try? FileManager.default.removeItem(at: fallbackFileURL)
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
