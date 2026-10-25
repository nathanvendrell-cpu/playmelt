import Foundation
import Darwin

struct SteamInstallPollingPolicy {
    private var previous = ""
    private var unchanged = 0
    mutating func delay(for observation: SteamInstallObservation) -> TimeInterval {
        let signature = "\(observation.status):\(observation.downloaded):\(observation.total):\(observation.ready):\(observation.signature)"
        unchanged = signature == previous ? unchanged + 1 : 0; previous = signature
        if observation.ready { return 2 }
        if ["paused", "disk-space", "awaiting-steam", "awaiting-account"].contains(observation.status) {
            return unchanged == 0 ? 10 : 30
        }
        return unchanged == 0 ? 2 : unchanged < 3 ? 5 : 10
    }
}

enum SteamInstallAccountContext {
    /// Missing/partially replaced loginusers.vdf is unknown, never evidence that
    /// the selected account is still active. Download observation may continue;
    /// automatic launch must wait for a matching local account record.
    static func permitsAutoLaunch(expected: String, active: String?) -> Bool {
        LibraryModel.validAccountID(expected) && active == expected
    }
    static func gate(_ observation: SteamInstallObservation, expected: String, active: String?) -> SteamInstallObservation {
        guard observation.ready, !permitsAutoLaunch(expected: expected, active: active) else { return observation }
        var waiting = observation
        waiting.ready = false; waiting.signature = ""; waiting.status = "awaiting-account"
        waiting.message = "Installation vérifiée. Ouvrez Steam avec le compte sélectionné pour autoriser le lancement automatique."
        return waiting
    }
}

/// A private, bounded cache used only on the observer queue. Atomic replacement,
/// deletion, metadata changes and a mutation during the read all invalidate it.
final class SteamInstallReadCache {
    private var entries: [URL: (String, [String:Any])] = [:]
    private(set) var reads = 0
    private func identity(_ url: URL) -> String? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
    func read(_ url: URL) -> [String:Any] {
        guard let stamp = identity(url) else { entries[url] = nil; return [:] }
        if let entry = entries[url], entry.0 == stamp { return entry.1 }
        let value = TextVDF.read(url); reads += 1
        if entries.count >= 64 { entries.removeAll() }
        guard identity(url) == stamp else { entries[url] = nil; return [:] }
        entries[url] = (stamp, value); return value
    }
}

/// One selected installation, with directory notifications and an adaptive
/// fallback. No recursive library scan, write to Steam, or runtime process.
final class SteamInstallObserver {
    private let queue = DispatchQueue(label: "fr.playmelt.install-observer", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var watchers: [URL: DispatchSourceFileSystemObject] = [:]
    private var policy = SteamInstallPollingPolicy()
    private let cache = SteamInstallReadCache()
    private var nextRun: TimeInterval = .greatestFiniteMagnitude
    private var lastRead: TimeInterval = -.greatestFiniteMagnitude
    private let started = ProcessInfo.processInfo.systemUptime
    private let runtime: Runtime
    private let appID: String, accountID: String
    private let timeout: TimeInterval
    private let deliver: (SteamInstallObservation, Bool, Bool) -> Void

    init(runtime: Runtime, appID: String, accountID: String, timeout: TimeInterval,
         deliver: @escaping (SteamInstallObservation, Bool, Bool) -> Void) {
        self.runtime = runtime; self.appID = appID; self.accountID = accountID
        self.timeout = timeout; self.deliver = deliver
        queue.async { [self] in
            guard !isStopped else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in self?.observe() }
            timer = source; source.resume(); schedule(after: 2)
            updateWatchers([runtime.steamRoot, runtime.steamRoot.appendingPathComponent("config"), runtime.steamRoot.appendingPathComponent("steamapps")])
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop(completion: (() -> Void)? = nil) {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            for watcher in watchers.values { watcher.cancel() }; watchers.removeAll()
            // Cancellation handlers close each descriptor on this same queue.
            if let completion { queue.async { DispatchQueue.main.async(execute: completion) } }
        }
    }
    private func schedule(after delay: TimeInterval) {
        guard !isStopped else { return }
        nextRun = ProcessInfo.processInfo.systemUptime + max(0, delay)
        timer?.schedule(deadline: .now() + max(0, delay), leeway: .milliseconds(200))
    }
    private func changed() {
        guard !isStopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let soon = max(now + 0.3, lastRead + 2)
        if soon < nextRun { schedule(after: soon - now) }
    }
    private func updateWatchers(_ candidates: [URL]) {
        let desired = Set(candidates.map { $0.standardizedFileURL }.prefix(32))
        for key in Array(watchers.keys) where !desired.contains(key) { watchers.removeValue(forKey: key)?.cancel() }
        for path in desired where watchers[path] == nil {
            let fd = open(path.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFDIR else { close(fd); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if let flags = self.watchers[path]?.data, !flags.intersection([.rename, .delete, .revoke]).isEmpty { self.watchers.removeValue(forKey: path)?.cancel() }
                self.changed()
            }
            source.setCancelHandler { close(fd) }; watchers[path] = source; source.resume()
        }
    }
    private func observe() {
        guard !isStopped else { return }
        lastRead = ProcessInfo.processInfo.systemUptime; nextRun = .greatestFiniteMagnitude
        let expired = lastRead - started >= timeout
        let users = cache.read(runtime.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users")
        let active = activeSteamAccount(users)
        let accountChanged = active != nil && !accountID.isEmpty && active != accountID
        var observation = SteamInstallObservation(status: "awaiting-steam", message: "Validez l’installation dans Steam.")
        if !expired && !accountChanged {
            let folders = cache.read(runtime.steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")).object("libraryfolders")
            let paths = SteamInstallManifest.locations(steamRoot: runtime.steamRoot, appID: appID, platform: runtime.platform, prefix: runtime.prefixURL, libraryFolders: folders)
            if let manifest = SteamInstallManifest.latestManifest(in: paths) {
                observation = SteamInstallAccountContext.gate(
                    SteamInstallManifest.inspect(manifest, appID: appID, platform: runtime.platform, accountID: accountID, cachedState: cache.read(manifest).object("AppState")),
                    expected: accountID, active: active)
            }
            updateWatchers([runtime.steamRoot, runtime.steamRoot.appendingPathComponent("config")] + paths.map { $0.deletingLastPathComponent() })
        }
        let result = observation
        DispatchQueue.main.async { [weak self] in guard let self, !self.isStopped else { return }; self.deliver(result, expired, accountChanged) }
        if !expired && !accountChanged && !observation.failed { schedule(after: min(policy.delay(for: observation), max(0, timeout - (lastRead - started)))) }
    }
    deinit { timer?.cancel(); for watcher in watchers.values { watcher.cancel() } }
}
