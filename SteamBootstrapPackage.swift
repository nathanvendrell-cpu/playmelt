import Foundation
import CryptoKit
import Darwin

enum SteamBootstrapPackageError: LocalizedError {
    case invalidManifest, invalidCache, invalidArchive, invalidClient, unsafeDestination, interrupted
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Le manifeste officiel du client Steam n’a pas le format attendu."
        case .invalidCache: return "Le cache privé du client Steam ne peut pas être vérifié. Ses fichiers ont été conservés."
        case .invalidArchive: return "Le paquet officiel Steam est incomplet ou son intégrité n’est pas vérifiée."
        case .invalidClient: return "Le paquet Steam ne contient pas le bootstrap Windows signé attendu."
        case .unsafeDestination: return "Le dossier Steam sélectionné n’appartient pas à ce moteur Playmelt."
        case .interrupted: return "Préparation du client Steam interrompue."
        }
    }
}

/// Valve's HTTPS manifest authorizes a specific, SHA-256 checked ZIP. This is
/// source integrity, not a claim to validate Windows' Authenticode trust chain.
struct SteamBootstrapPackage {
    static let method = "valve-bootstrap-package-v1"
    static let manifestURL = URL(string: "https://cdn.steamstatic.com/client/steam_client_win32")!
    static let maximumArchive = 16 * 1024 * 1024
    let filename: String, sha256: String, manifestSHA256: String
    let size: Int, manifest: Data
    var url: URL { Self.manifestURL.deletingLastPathComponent().appendingPathComponent(filename) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    init(manifest: Data) throws {
        guard !manifest.isEmpty, manifest.count <= 128 * 1024,
              let text = String(data: manifest, encoding: .utf8) else { throw SteamBootstrapPackageError.invalidManifest }
        var parser = ManifestParser(text)
        let root = try parser.parse()
        guard case .object(let windows)? = root["win32"],
              case .object(let bootstrap)? = windows["steam_win32"],
              case .text("1")? = bootstrap["IsBootstrapperPackage"],
              case .text(let filename)? = bootstrap["file"],
              filename.range(of: "^steam_win32\\.zip\\.[0-9a-f]{40}$", options: .regularExpression) != nil,
              case .text(let hash)? = bootstrap["sha2"], hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              case .text(let length)? = bootstrap["size"], !length.isEmpty, length.allSatisfy({ $0.isASCII && $0.isNumber }),
              let size = Int(length), size > 1000, size <= Self.maximumArchive else { throw SteamBootstrapPackageError.invalidManifest }
        self.filename = filename; self.sha256 = hash; self.size = size; self.manifest = manifest
        manifestSHA256 = Self.hash(manifest)
    }
    private indirect enum Value { case text(String), object([String: Value]) }
    private struct ManifestParser {
        let bytes: [UInt8]; var index = 0, entries = 0
        init(_ text: String) { bytes = Array(text.utf8) }
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func quoted() throws -> String {
            whitespace(); guard index < bytes.count, bytes[index] == 34 else { throw SteamBootstrapPackageError.invalidManifest }; index += 1
            var value = [UInt8]()
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { guard let result = String(bytes: value, encoding: .utf8) else { throw SteamBootstrapPackageError.invalidManifest }; return result }
                guard byte >= 32, value.count < 4096 else { throw SteamBootstrapPackageError.invalidManifest }
                if byte == 92 {
                    guard index < bytes.count, [34, 92].contains(bytes[index]) else { throw SteamBootstrapPackageError.invalidManifest }
                    value.append(bytes[index]); index += 1
                } else { value.append(byte) }
            }
            throw SteamBootstrapPackageError.invalidManifest
        }
        mutating func object(depth: Int, enclosed: Bool) throws -> [String: Value] {
            guard depth <= 8 else { throw SteamBootstrapPackageError.invalidManifest }; var result = [String: Value]()
            while true {
                whitespace()
                if index == bytes.count { guard !enclosed else { throw SteamBootstrapPackageError.invalidManifest }; return result }
                if bytes[index] == 125 { guard enclosed else { throw SteamBootstrapPackageError.invalidManifest }; index += 1; return result }
                let key = try quoted(); guard !key.isEmpty, result[key] == nil, entries < 512 else { throw SteamBootstrapPackageError.invalidManifest }; entries += 1
                whitespace(); guard index < bytes.count else { throw SteamBootstrapPackageError.invalidManifest }
                if bytes[index] == 123 { index += 1; result[key] = .object(try object(depth: depth + 1, enclosed: true)) }
                else { result[key] = .text(try quoted()) }
            }
        }
        mutating func parse() throws -> [String: Value] { try object(depth: 0, enclosed: false) }
    }
}

/// Only a single regular steam.exe is accepted. Valve's package may include
/// its observed 20-byte prefix; the whole package is already SHA-256 pinned.
/// Central/local records must agree: no paths, links, devices or extra payloads.
struct SteamBootstrapZIP {
    let filename: String, expandedSize: Int
    let normalizedArchive: Data
    init(_ data: Data) throws {
        func bad() -> SteamBootstrapPackageError { .invalidArchive }
        func u16(_ p: Int) throws -> Int { guard p >= 0, p + 2 <= data.count else { throw bad() }; return Int(data[p]) | Int(data[p + 1]) << 8 }
        func u32(_ p: Int) throws -> Int { guard p >= 0, p + 4 <= data.count else { throw bad() }; return Int(data[p]) | Int(data[p + 1]) << 8 | Int(data[p + 2]) << 16 | Int(data[p + 3]) << 24 }
        guard data.count >= 22, data.count <= SteamBootstrapPackage.maximumArchive else { throw bad() }
        let end = data.count - 22
        guard try u32(end) == 0x06054b50, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == 1, try u16(end + 10) == 1, try u16(end + 20) == 0 else { throw bad() }
        let centralSize = try u32(end + 12), central = try u32(end + 16)
        guard central > 30, centralSize >= 46, central + centralSize == end, try u32(central) == 0x02014b50 else { throw bad() }
        let flags = try u16(central + 8), method = try u16(central + 10), crc = try u32(central + 16)
        let compressed = try u32(central + 20), expanded = try u32(central + 24)
        let nameCount = try u16(central + 28), extra = try u16(central + 30), comment = try u16(central + 32)
        let local = try u32(central + 42)
        let attributes = try u32(central + 38), unixType = (attributes >> 16) & 0xf000
        guard flags & ~0x808 == 0, [0, 8].contains(method), compressed > 0, expanded > 1000,
              expanded <= 32 * 1024 * 1024, expanded <= compressed * 64,
              nameCount == 9, extra <= 1024, comment == 0, centralSize == 46 + nameCount + extra,
              try u16(central + 34) == 0, [0, 20].contains(local),
              [0, 0x8000].contains(unixType), attributes & 0x10 == 0 else { throw bad() }
        guard let name = String(data: data.subdata(in: (central + 46)..<(central + 46 + nameCount)), encoding: .utf8),
              name.lowercased() == "steam.exe", try u32(local) == 0x04034b50,
              try u16(local + 6) == flags, try u16(local + 8) == method, try u16(local + 26) == nameCount else { throw bad() }
        let localExtra = try u16(local + 28), dataStart = local + 30 + nameCount + localExtra
        guard localExtra <= 1024, dataStart <= central, dataStart + compressed <= central,
              data.subdata(in: (local + 30)..<(local + 30 + nameCount)) == Data(name.utf8) else { throw bad() }
        if flags & 8 == 0 {
            guard try u32(local + 14) == crc, try u32(local + 18) == compressed, try u32(local + 22) == expanded, dataStart + compressed == central else { throw bad() }
        } else {
            var descriptor = dataStart + compressed
            if try u32(descriptor) == 0x08074b50 { descriptor += 4 }
            guard descriptor + 12 == central, try u32(descriptor) == crc, try u32(descriptor + 4) == compressed, try u32(descriptor + 8) == expanded else { throw bad() }
        }
        filename = name; expandedSize = expanded
        if local == 20 {
            // Apple's ditto rejects Valve's non-ZIP prefix. Remove those exact
            // 20 bytes and rebase the two offsets; compressed bytes and CRC are
            // unchanged. The original cached package retains its Valve SHA256.
            var normalized = Data(data.dropFirst(20))
            func replace32(_ value: Int, at offset: Int) {
                normalized.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
            }
            replace32(0, at: central - 20 + 42)
            replace32(central - 20, at: normalized.count - 22 + 16)
            normalizedArchive = normalized
        } else { normalizedArchive = data }
    }
    static func validateClient(_ data: Data) throws {
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 | Int(data[p + 2]) << 16 | Int(data[p + 3]) << 24 }
        guard data.count > 1024, data.count <= 32 * 1024 * 1024, data[0] == 0x4d, data[1] == 0x5a else { throw SteamBootstrapPackageError.invalidClient }
        let pe = u32(0x3c)
        guard pe >= 64, pe + 24 + 160 <= data.count, u32(pe) == 0x4550, [0x14c, 0x8664].contains(u16(pe + 4)) else { throw SteamBootstrapPackageError.invalidClient }
        let optional = pe + 24, magic = u16(optional)
        guard [0x10b, 0x20b].contains(magic), u16(pe + 20) >= (magic == 0x10b ? 136 : 152) else { throw SteamBootstrapPackageError.invalidClient }
        let directory = optional + (magic == 0x10b ? 96 : 112) + 32
        let certificate = u32(directory), size = u32(directory + 4)
        guard certificate >= optional + u16(pe + 20), certificate % 8 == 0, size >= 16,
              certificate + size <= data.count, u32(certificate) >= 16, u32(certificate) <= size,
              u16(certificate + 4) == 0x200, u16(certificate + 6) == 2, data[certificate + 8] == 0x30 else { throw SteamBootstrapPackageError.invalidClient }
    }
}

/// Kernel ownership, not a PID/age heuristic. A crash closes the descriptor and
/// releases flock, permitting a new explicit intent to resume the ZIP route.
final class SteamBootstrapLease {
    private var descriptor: Int32 = -1
    private let engineID: String, prefix: String
    init(url: URL, runtime: PlaymeltRuntimeDescriptor) throws {
        engineID = runtime.engineID; prefix = runtime.prefixURL.path
        try RuntimeSetup.rejectSymlinkAncestors(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var folder = stat()
        guard lstat(parent.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == geteuid(), folder.st_mode & 0o777 == 0o700 else { throw SteamBootstrapPackageError.unsafeDestination }
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SteamBootstrapPackageError.unsafeDestination }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == geteuid(), file.st_nlink == 1,
              file.st_mode & 0o777 == 0o600 else { Darwin.close(fd); throw SteamBootstrapPackageError.unsafeDestination }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw RuntimeSetupError.failed("Une préparation Steam possède encore cet environnement. Attendez sa fin avant de reprendre.") }
        descriptor = fd
    }
    func covers(_ runtime: PlaymeltRuntimeDescriptor) -> Bool { descriptor >= 0 && engineID == runtime.engineID && prefix == runtime.prefixURL.path }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
    deinit { release() }
}

final class SteamBootstrapPackageStore {
    let root: URL
    private static let gate = NSRecursiveLock(), owner = "playmelt-valve-steam-bootstrap"
    private var index: URL { root.appendingPathComponent("current.json") }
    init(root: URL) { self.root = root }
    private func ownedRoot() throws -> Bool {
        try RuntimeSetup.rejectSymlinkAncestors(root)
        var info = stat()
        if lstat(root.path, &info) != 0 { if errno == ENOENT { return false }; throw SteamBootstrapPackageError.invalidCache }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw SteamBootstrapPackageError.invalidCache }
        return true
    }
    private func ownedArchive(_ url: URL) throws -> stat? {
        try RuntimeSetup.rejectSymlinkAncestors(url)
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw SteamBootstrapPackageError.invalidCache }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else { throw SteamBootstrapPackageError.invalidCache }
        return info
    }
    private func read(_ url: URL, maximum: Int) throws -> Data {
        try RuntimeSetup.rejectSymlinkAncestors(url)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600, metadata.st_size > 0, metadata.st_size <= maximum else { throw SteamBootstrapPackageError.invalidCache }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    func archiveURL(_ package: SteamBootstrapPackage) -> URL { root.appendingPathComponent(package.sha256 + ".zip") }
    private func metadata() throws -> SteamBootstrapPackage? {
        guard try ownedRoot() else { return nil }
        try RuntimeSetup.rejectSymlinkAncestors(index)
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        let data = try read(index, maximum: 256 * 1024)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["schema", "owner", "source", "manifest", "manifestSHA256"],
              let schema = value["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              value["owner"] as? String == Self.owner, value["source"] as? String == SteamBootstrapPackage.manifestURL.absoluteString,
              let base64 = value["manifest"] as? String, let manifest = Data(base64Encoded: base64),
              value["manifestSHA256"] as? String == SteamBootstrapPackage.hash(manifest) else { throw SteamBootstrapPackageError.invalidCache }
        return try SteamBootstrapPackage(manifest: manifest)
    }
    func cached() throws -> SteamBootstrapPackage? {
        Self.gate.lock(); defer { Self.gate.unlock() }
        guard let package = try metadata() else { return nil }
        _ = try verifiedArchive(package); return package
    }
    /// Only an intact private provenance pointer can authorize repair. Never
    /// infer ownership from an MZ/ZIP header or replace an unsafe filesystem item.
    func recoveryPackage() throws -> SteamBootstrapPackage? {
        Self.gate.lock(); defer { Self.gate.unlock() }
        guard let package = try metadata() else { return nil }
        _ = try ownedArchive(archiveURL(package))
        return package
    }
    func verifiedArchive(_ package: SteamBootstrapPackage) throws -> Data {
        guard try ownedRoot() else { throw SteamBootstrapPackageError.invalidCache }
        let data = try read(archiveURL(package), maximum: SteamBootstrapPackage.maximumArchive)
        guard data.count == package.size, SteamBootstrapPackage.hash(data) == package.sha256 else { throw SteamBootstrapPackageError.invalidArchive }
        _ = try SteamBootstrapZIP(data)
        return data
    }
    func store(_ package: SteamBootstrapPackage, downloaded: URL) throws {
        Self.gate.lock(); defer { Self.gate.unlock() }
        try RuntimeSetup.rejectSymlinkAncestors(root)
        if try !ownedRoot() {try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])}
        guard try ownedRoot() else { throw SteamBootstrapPackageError.invalidCache }
        let previous = try metadata()
        if let previous { guard previous.sha256 == package.sha256, previous.filename == package.filename, previous.size == package.size else { throw SteamBootstrapPackageError.invalidCache } }
        let pointer = previous == nil ? nil : try read(index, maximum: 256 * 1024)
        // Read the actual inode, not URL resource-value caches, and never follow
        // a link or read beyond the manifest's bounded size.
        let downloadFD = Darwin.open(downloaded.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard downloadFD >= 0 else {throw SteamBootstrapPackageError.invalidArchive}
        defer {Darwin.close(downloadFD)}
        var incoming = stat()
        guard fstat(downloadFD,&incoming) == 0, incoming.st_mode&S_IFMT == S_IFREG,
              incoming.st_uid == geteuid(), incoming.st_nlink == 1, incoming.st_size == package.size,
              package.size <= SteamBootstrapPackage.maximumArchive else {throw SteamBootstrapPackageError.invalidArchive}
        var data = Data(count: package.size), offset = 0
        while offset < data.count {
            let bytes = data.withUnsafeMutableBytes {Darwin.read(downloadFD,$0.baseAddress!.advanced(by:offset),$0.count-offset)}
            if bytes < 0 && errno == EINTR {continue}
            guard bytes > 0 else {throw SteamBootstrapPackageError.invalidArchive};offset += bytes
        }
        var extra: UInt8 = 0
        guard Darwin.read(downloadFD,&extra,1) == 0 else {throw SteamBootstrapPackageError.invalidArchive}
        guard data.count == package.size, SteamBootstrapPackage.hash(data) == package.sha256 else { throw SteamBootstrapPackageError.invalidArchive }
        _ = try SteamBootstrapZIP(data)
        let archive = archiveURL(package)
        let existing = try ownedArchive(archive)
        if let existing {
            if (try? verifiedArchive(package)) == nil {
                // A cache repair is authorized by the intact pointer above and
                // by a newly received, fully checked payload. Hold the exact
                // old regular inode exclusively, and recheck before replacing.
                guard pointer != nil else { throw SteamBootstrapPackageError.invalidCache }
                let fd = Darwin.open(archive.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SteamBootstrapPackageError.invalidCache }
                defer { flock(fd, LOCK_UN); Darwin.close(fd) }
                var locked = stat()
                guard flock(fd, LOCK_EX | LOCK_NB) == 0, fstat(fd, &locked) == 0,
                      locked.st_ino == existing.st_ino, locked.st_dev == existing.st_dev,
                      locked.st_uid == geteuid(), locked.st_nlink == 1, locked.st_mode & 0o777 == 0o600 else { throw SteamBootstrapPackageError.invalidCache }
                let temporary = root.appendingPathComponent(".repair-" + UUID().uuidString)
                try data.write(to: temporary, options: .withoutOverwriting)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                let handle = try FileHandle(forWritingTo: temporary); defer {try? handle.close()}; try handle.synchronize()
                guard try ownedRoot(), let latest = try ownedArchive(archive), latest.st_ino == locked.st_ino, latest.st_dev == locked.st_dev,
                      try read(index, maximum: 256 * 1024) == pointer else { throw SteamBootstrapPackageError.invalidCache }
                guard Darwin.rename(temporary.path, archive.path) == 0 else { throw SteamBootstrapPackageError.invalidCache }
            }
        } else {
            let temporary = root.appendingPathComponent(".cache-" + UUID().uuidString)
            try data.write(to: temporary, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if Darwin.link(temporary.path, archive.path) != 0 { _ = try verifiedArchive(package) }
        }
        // current.json is an immutable provenance pointer. Repair never rewrites
        // it, including when a CDN publishes a newer manifest in the meantime.
        if previous != nil { return }
        let receipt: [String: Any] = ["schema": 1, "owner": Self.owner, "source": SteamBootstrapPackage.manifestURL.absoluteString,
                                     "manifest": package.manifest.base64EncodedString(), "manifestSHA256": package.manifestSHA256]
        let temporary = root.appendingPathComponent(".index-" + UUID().uuidString)
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if Darwin.link(temporary.path, index.path) != 0 {
            guard let concurrent = try metadata(), concurrent.sha256 == package.sha256 else { throw SteamBootstrapPackageError.invalidCache }
        }
    }
    func prepare(_ package: SteamBootstrapPackage, descriptor: PlaymeltRuntimeDescriptor, current: () -> PlaymeltRuntimeDescriptor?,
                 runner: OwnedProcessRunning, cancelled: @escaping () -> Bool) throws {
        func validateDestination() throws {
            guard !cancelled() else { throw SteamBootstrapPackageError.interrupted }
            guard descriptor.readyEngine, SteamInstallerOperation.ownsPrefix(descriptor), let fresh = current(), SteamWindowsBootstrap.sameRuntime(descriptor, fresh),
                  descriptor.steamRoot.standardizedFileURL.path.hasPrefix(descriptor.prefixURL.standardizedFileURL.path + "/drive_c/") else { throw SteamBootstrapPackageError.unsafeDestination }
            try RuntimeSetup.rejectSymlinkAncestors(descriptor.steamRoot)
        }
        try validateDestination()
        let archive = try verifiedArchive(package), layout = try SteamBootstrapZIP(archive)
        let destination = descriptor.steamRoot.appendingPathComponent("steam.exe")
        if SteamInstallerOperation.steamPresent(descriptor) { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SteamBootstrapPackageError.unsafeDestination }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        var scan = OwnedProcessRequest(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,comm="], environment: environment)
        scan.timeout = 5; scan.outputLimit = 8 * 1024 * 1024
        let processes = try runner.run(scan, cancelled: cancelled)
        let engine = descriptor.wineURL.deletingLastPathComponent().deletingLastPathComponent().path + "/"
        guard processes.exitCode == 0, !String(decoding: processes.output, as: UTF8.self).split(separator: "\n").contains(where: { $0.contains(engine) || $0.contains(descriptor.prefixURL.path + "/") }) else { throw RuntimeSetupError.failed("Un programme utilise ce moteur Windows. La préparation Steam reprendra après sa fermeture.") }
        let staging = root.appendingPathComponent(".extract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        // Extract the verified snapshot rather than reopening a shared cache
        // path after hashing it. This also isolates concurrent engine requests.
        let snapshot = staging.appendingPathComponent("source.zip"), payloadRoot = staging.appendingPathComponent("payload")
        try layout.normalizedArchive.write(to: snapshot, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        var extraction = OwnedProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", snapshot.path, payloadRoot.path], environment: environment)
        extraction.timeout = 30; extraction.outputLimit = 64 * 1024
        guard try runner.run(extraction, cancelled: cancelled).exitCode == 0 else { throw SteamBootstrapPackageError.invalidArchive }
        let contents = try FileManager.default.contentsOfDirectory(atPath: payloadRoot.path)
        guard contents == [layout.filename] else { throw SteamBootstrapPackageError.invalidArchive }
        let extracted = payloadRoot.appendingPathComponent(layout.filename)
        try RuntimeSetup.rejectSymlinkAncestors(extracted)
        let attributes = try FileManager.default.attributesOfItem(atPath: extracted.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue == layout.expandedSize else { throw SteamBootstrapPackageError.invalidArchive }
        let client = try Data(contentsOf: extracted); try SteamBootstrapZIP.validateClient(client)
        try validateDestination()
        if SteamInstallerOperation.steamPresent(descriptor) { return }
        try FileManager.default.createDirectory(at: descriptor.steamRoot, withIntermediateDirectories: true)
        let temporary = descriptor.steamRoot.appendingPathComponent(".playmelt-steam-" + UUID().uuidString)
        try client.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        try validateDestination()
        guard Darwin.link(temporary.path, destination.path) == 0 else {
            if SteamInstallerOperation.steamPresent(descriptor) { return }
            throw SteamBootstrapPackageError.unsafeDestination
        }
        let receipt: [String: Any] = ["schema": 1, "owner": Self.owner, "method": SteamBootstrapPackage.method,
            "engineID": descriptor.engineID, "archiveSHA256": package.sha256, "manifestSHA256": package.manifestSHA256,
            "clientSHA256": SteamBootstrapPackage.hash(client), "clientBytes": client.count,
            "source": SteamBootstrapPackage.manifestURL.absoluteString, "authenticationAssumed": false]
        let receiptURL = descriptor.steamRoot.appendingPathComponent(".playmelt-bootstrap.json")
        try RuntimeSetup.rejectSymlinkAncestors(receiptURL)
        if !FileManager.default.fileExists(atPath: receiptURL.path) {
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        }
    }
}
