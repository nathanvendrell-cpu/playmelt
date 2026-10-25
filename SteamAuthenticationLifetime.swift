import Foundation

/// Main-thread state for one ephemeral sign-in page. Closing or navigating the
/// page invalidates outstanding JavaScript replies without discarding the last
/// verified library held by LibraryModel.
struct SteamAuthenticationLifetime {
    private(set) var isOpen = false
    private(set) var isClosed = false
    private var generation = UUID()
    private var capture: UUID?

    mutating func open() -> Bool {
        guard !isClosed else { return false }
        if !isOpen { isOpen = true; generation = UUID(); capture = nil }
        return true
    }
    mutating func navigate() { generation = UUID(); capture = nil }
    mutating func beginCapture() -> UUID? {
        guard isOpen, !isClosed, capture == nil else { return nil }
        let token = UUID(); generation = token; capture = token; return token
    }
    mutating func finishCapture(_ token: UUID) -> Bool {
        guard isOpen, !isClosed, capture == token, generation == token else { return false }
        capture = nil; return true
    }
    mutating func releasePage() { isOpen = false; navigate() }
    mutating func shutdown() { isClosed = true; releasePage() }
}
