import Foundation

/// Pure state fixtures. No WebKit instance, account, keychain, network or process.
@main enum SteamAuthenticationLifetimeTests {
    static func main() {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { fatalError(label) }
        }
        var lifetime = SteamAuthenticationLifetime()
        require(lifetime.beginCapture() == nil, "unopened page cannot be captured")
        require(lifetime.navigate() == nil, "unopened page cannot navigate")
        require(!lifetime.navigationFinished(UUID()), "unopened page rejects navigation reply")
        require(lifetime.open(), "explicit page open succeeds")
        require(!lifetime.isDocumentReady && lifetime.beginCapture() == nil, "open is not a loaded document")

        let first = lifetime.navigate()!
        require(lifetime.beginCapture() == nil, "provisional navigation cannot capture old document")
        require(!lifetime.navigationFinished(UUID()), "unrelated navigation cannot make document ready")
        require(lifetime.navigationFinished(first) && lifetime.isDocumentReady, "current finished navigation is ready")
        require(!lifetime.navigationFinished(first), "duplicate finish is ignored")
        let capture = lifetime.beginCapture()!
        require(lifetime.beginCapture() == nil, "concurrent capture coalesces")
        require(lifetime.open(), "showing existing page preserves its lifetime")
        require(lifetime.finishCapture(capture), "showing page does not discard its active capture")
        require(!lifetime.finishCapture(capture), "capture reply cannot be applied twice")

        let staleCapture = lifetime.beginCapture()!
        let oldNavigation = lifetime.navigate()!
        require(!lifetime.finishCapture(staleCapture), "navigation invalidates old JavaScript reply")
        let currentNavigation = lifetime.navigate()!
        require(!lifetime.navigationFailed(oldNavigation), "late old failure cannot invalidate current navigation")
        require(!lifetime.navigationFinished(oldNavigation), "late old finish cannot validate old document")
        require(lifetime.navigationFinished(currentNavigation), "current navigation can still finish")
        require(lifetime.isDocumentReady, "old callbacks did not discard the current document")

        let failed = lifetime.navigate()!
        require(lifetime.navigationFailed(failed), "current navigation failure is accepted")
        require(!lifetime.isDocumentReady && lifetime.beginCapture() == nil, "failed navigation cannot reuse previous document")
        require(!lifetime.navigationFinished(failed), "finish following failure remains stale")

        let recovered = lifetime.navigate()!
        require(lifetime.navigationFinished(recovered), "explicit navigation recovers from failure")
        let processCapture = lifetime.beginCapture()!
        lifetime.invalidateDocument()
        require(!lifetime.finishCapture(processCapture) && lifetime.beginCapture() == nil, "WebKit process loss invalidates capture without reading old contents")
        let processNavigation = lifetime.navigate()!
        lifetime.invalidateDocument()
        require(!lifetime.navigationFinished(processNavigation), "terminated process cannot finish its pending navigation")

        let releasedNavigation = lifetime.navigate()!
        lifetime.releasePage()
        require(!lifetime.isOpen && !lifetime.isDocumentReady, "page release clears document state")
        require(!lifetime.navigationFinished(releasedNavigation), "released page callback is ignored")
        require(lifetime.open(), "released page may reopen explicitly")
        require(lifetime.beginCapture() == nil, "reopened page must navigate before capture")
        let reopened = lifetime.navigate()!
        require(lifetime.navigationFinished(reopened), "reopened document can finish")
        let lastCapture = lifetime.beginCapture()!
        lifetime.shutdown()
        require(lifetime.isClosed && !lifetime.isOpen && !lifetime.isDocumentReady, "shutdown closes lifetime permanently")
        require(!lifetime.finishCapture(lastCapture), "shutdown suppresses JavaScript completion")
        require(!lifetime.open() && lifetime.navigate() == nil && lifetime.beginCapture() == nil, "shutdown prevents all reopening")
        require(SteamAuthenticationLifetime.websiteDataStoreIdentifier.uuidString == "A62964C7-E373-4D82-B3C4-D890A23E2280", "Steam store identifier is release-stable")
        print("SteamAuthenticationLifetime: \(checks) pure CPU checks passed; no WebKit or account data accessed")
    }
}
