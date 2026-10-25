import Foundation

/// Main-thread state for one sign-in page. Closing or navigating the
/// page invalidates outstanding JavaScript replies without discarding the last
/// verified library held by LibraryModel or WebKit's separate persistent store.
struct SteamAuthenticationLifetime {
    /// Dedicated to the official Steam sign-in view, never the local HTML bridge.
    /// This identifier must remain stable across app launches and releases.
    static let websiteDataStoreIdentifier = UUID(uuidString: "A62964C7-E373-4D82-B3C4-D890A23E2280")!

    private(set) var isOpen = false
    private(set) var isClosed = false
    private(set) var isDocumentReady = false
    private var generation = UUID()
    private var capture: UUID?
    private var navigation: UUID?

    mutating func open() -> Bool {
        guard !isClosed else { return false }
        if !isOpen { isOpen = true; invalidateDocument() }
        return true
    }
    /// The native delegate pairs this token with the exact WKNavigation object.
    /// A late finish/failure from a replaced navigation must use its old token.
    @discardableResult mutating func navigate() -> UUID? {
        guard isOpen, !isClosed else { return nil }
        invalidateDocument()
        let token = UUID(); generation = token; navigation = token
        return token
    }
    mutating func navigationFinished(_ token: UUID) -> Bool {
        guard isOpen, !isClosed, navigation == token, generation == token else { return false }
        navigation = nil; isDocumentReady = true
        return true
    }
    @discardableResult mutating func navigationFailed(_ token: UUID) -> Bool {
        guard isOpen, !isClosed, navigation == token, generation == token else { return false }
        invalidateDocument()
        return true
    }
    /// Also used for a terminated WebKit content process. Recovery requires an
    /// explicit navigation; stale document contents cannot complete a sync.
    mutating func invalidateDocument() {
        generation = UUID(); capture = nil; navigation = nil; isDocumentReady = false
    }
    mutating func beginCapture() -> UUID? {
        guard isOpen, !isClosed, isDocumentReady, navigation == nil, capture == nil else { return nil }
        let token = UUID(); generation = token; capture = token; return token
    }
    mutating func finishCapture(_ token: UUID) -> Bool {
        guard isOpen, !isClosed, capture == token, generation == token else { return false }
        capture = nil; return true
    }
    mutating func releasePage() { isOpen = false; invalidateDocument() }
    mutating func shutdown() { isClosed = true; releasePage() }
}
