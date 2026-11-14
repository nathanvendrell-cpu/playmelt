import AppKit
import Sparkle

/// Playmelt updater — Sparkle 2.
/// Configuration lives in Info.plist: SUFeedURL, SUPublicEDKey,
/// SUEnableAutomaticChecks (true) and SUScheduledCheckInterval (86400 s).
/// Silent daily background check; Sparkle shows its standard localized UI
/// when a newer version is found. Updates are EdDSA-signed (see .private key backup).
final class UpdaterController: NSObject {
    static let shared = UpdaterController()
    private var sparkle: SPUStandardUpdaterController?

    /// Preview builds (.preview bundle ids) never check for updates.
    var isEnabled: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return !identifier.hasSuffix(".preview")
    }

    /// Menu target once the session is started; nil for preview builds.
    var updaterMenuTarget: SPUStandardUpdaterController? { sparkle }

    /// Starts the Sparkle session. Must run once, on the main thread, at launch.
    func start() {
        guard isEnabled, sparkle == nil else { return }
        sparkle = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Manual check from the app menu (no-op while another check is running).
    func checkForUpdates() {
        sparkle?.checkForUpdates(nil)
    }
}
