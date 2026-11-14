import Foundation
import Darwin

/// Filesystem preflight for the relocatable runtime shipped inside the app.
/// Imports, dependency functionality and code signing are qualified by packaging.
struct PortablePythonRuntime {
    let pythonURL: URL
    let legendaryExecutableURL: URL?
    let certificateURL: URL?
    let isBundled: Bool
    static func allowsDevelopment(info:[String:Any])->Bool { info["PlaymeltDevelopmentBuild"] as? Bool == true && info["PlaymeltInternalBuild"] as? Bool != true }
    static var developmentAllowed: Bool {
        if let resources=applicationResources(),let data=try?Data(contentsOf:resources.deletingLastPathComponent().appendingPathComponent("Info.plist")),
           let info=(try?PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any] {return allowsDevelopment(info:info)}
        return allowsDevelopment(info:Bundle.main.infoDictionary ?? [:])
    }
    static var developmentCandidates: [URL] { ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"].map { URL(fileURLWithPath: $0) } }
    static func epicDevelopmentCandidates(projectRoot:URL,applicationSupport:URL,development:Bool)->[URL] {
        guard development else{return []}
        return [projectRoot,applicationSupport].map{$0.appendingPathComponent("Dependencies.noindex/epic-venv/bin/python3")}
    }
    static var currentExecutableURL:URL? {
        if let url=Bundle.main.executableURL{return url}
        guard let path=CommandLine.arguments.first,path.hasPrefix("/") else{return nil}
        return URL(fileURLWithPath:path)
    }
    static func applicationResources(executableURL:URL?=PortablePythonRuntime.currentExecutableURL)->URL? {
        guard let executableURL else{return nil}
        let executable=executableURL.standardizedFileURL.resolvingSymlinksInPath(),directory=executable.deletingLastPathComponent(),contents=directory.deletingLastPathComponent()
        guard contents.lastPathComponent=="Contents",contents.deletingLastPathComponent().pathExtension=="app",
              directory.lastPathComponent=="MacOS" || (directory.lastPathComponent=="Resources" && executable.lastPathComponent=="m3-private-plan"),
              let data=try?Data(contentsOf:contents.appendingPathComponent("Info.plist")),
              let info=(try?PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],
              ["com.robtech.metalmaxgaminghub","com.robtech.metalmaxgaminghub.preview"].contains(info["CFBundleIdentifier"] as? String ?? ""),
              directory.lastPathComponent != "MacOS" || info["CFBundleExecutable"] as? String==executable.lastPathComponent else{return nil}
        let resources=contents.appendingPathComponent("Resources");var metadata=stat()
        guard lstat(resources.path,&metadata)==0,metadata.st_mode & S_IFMT==S_IFDIR else{return nil}
        return resources
    }
    static func resource(named name:String,executableURL:URL?=PortablePythonRuntime.currentExecutableURL)->URL? {
        guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),
              let resources=applicationResources(executableURL:executableURL) else{return nil}
        return regular(name,root:resources)
    }

    /// Resolve links one component at a time. Every link target must stay inside
    /// Python; a final target inside the root cannot excuse an earlier escape.
    private static func contained(_ relative: String, root: URL) -> URL? {
        var components = relative.split(separator: "/").map(String.init), current = root, links = 0
        while !components.isEmpty {
            current.appendPathComponent(components.removeFirst())
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0 else { return nil }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 16, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return nil }
                let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : current.deletingLastPathComponent().appendingPathComponent(target)).standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else { return nil }
                components = String(resolved.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init) + components
                current = root
            } else if !components.isEmpty && metadata.st_mode & S_IFMT != S_IFDIR { return nil }
        }
        return current
    }
    private static func regular(_ relative: String, root: URL, executable: Bool = false) -> URL? {
        guard let url = contained(relative, root: root) else { return nil }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isReadableFile(atPath: url.path),
              !executable || FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
    private static func arm64(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }; defer { try? file.close() }
        guard let data = try? file.read(upToCount: 16), data.count == 16 else { return false }
        // CPython's official macOS aarch64 install-only binary is thin MH_EXECUTE.
        let bytes = [UInt8](data)
        return Array(bytes[0..<4]) == [0xcf, 0xfa, 0xed, 0xfe] &&
            Array(bytes[4..<8]) == [0x0c, 0, 0, 1] && Array(bytes[8..<12]) == [0, 0, 0, 0] && Array(bytes[12..<16]) == [2, 0, 0, 0]
    }
    private final class BuiltinCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Set<String>] = [:]
    }
    private static let builtinCache = BuiltinCache()
    private static func fileIdentity(_ metadata: stat, path: String) -> String {
        "\(path):\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
    }
    /// Some standalone builds link extension modules into Python itself. Inspect
    /// defined Mach-O symbols without executing an interpreter or spawning nm.
    /// Bound every read and cache by file identity, including nanosecond ctime.
    private static func builtinModules(_ python: URL) -> Set<String> {
        var metadata = stat()
        guard lstat(python.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return [] }
        let identity = fileIdentity(metadata, path: python.path)
        builtinCache.lock.lock()
        let cached = builtinCache.entries[identity]
        builtinCache.lock.unlock()
        if let cached { return cached }
        guard let file = try? FileHandle(forReadingFrom: python) else { return [] }
        defer { try? file.close() }
        var opened = stat()
        guard fstat(file.fileDescriptor, &opened) == 0, fileIdentity(opened, path: python.path) == identity else { return [] }
        let size = UInt64(max(0, opened.st_size))
        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
            do {
                try file.seek(toOffset: offset)
                guard let data = try file.read(upToCount: count), data.count == count else { return nil }
                return Array(data)
            } catch { return nil }
        }
        func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        func inspect() -> Set<String> {
            guard let header = read(0, 32), u32(header, 0) == 0xfeedfacf,
                  u32(header, 4) == 0x0100000c, u32(header, 12) == 2 else { return [] }
            let count = Int(u32(header, 16)), commandBytes = Int(u32(header, 20))
            guard count > 0, count <= 1024, commandBytes <= 128 * 1024,
                  let commands = read(32, commandBytes) else { return [] }
            var offset = 0, table: (UInt64, Int, UInt64, Int)?
            for _ in 0..<count {
                guard offset <= commands.count - 8 else { return [] }
                let command = u32(commands, offset), length = Int(u32(commands, offset + 4))
                guard length >= 8, length <= commands.count - offset else { return [] }
                if command == 2 { // LC_SYMTAB / nlist_64
                    guard length == 24, table == nil else { return [] }
                    let symbolCount = Int(u32(commands, offset + 12)), stringBytes = Int(u32(commands, offset + 20))
                    guard symbolCount <= 524_288, stringBytes <= 8 * 1024 * 1024 else { return [] }
                    table = (UInt64(u32(commands, offset + 8)), symbolCount * 16, UInt64(u32(commands, offset + 16)), stringBytes)
                }
                offset += length
            }
            guard offset == commands.count, let (symbolOffset, symbolBytes, stringOffset, stringBytes) = table,
                  let symbols = read(symbolOffset, symbolBytes), let strings = read(stringOffset, stringBytes) else { return [] }
            let expected = ["_ssl", "_socket", "_ctypes", "_hashlib"].map { ($0, Array(("_PyInit_" + $0).utf8)) }
            var found = Set<String>()
            for position in stride(from: 0, to: symbols.count, by: 16) {
                let type = symbols[position + 4], section = symbols[position + 5]
                // External, defined N_SECT symbol, not a debug entry or import.
                guard type & 0xe0 == 0, type & 0x0f == 0x0f, section != 0,
                      symbols[(position + 8)..<(position + 16)].contains(where: { $0 != 0 }) else { continue }
                let start = Int(u32(symbols, position))
                for (module, name) in expected where !found.contains(module) {
                    if start < strings.count, name.count < strings.count - start,
                       strings[start + name.count] == 0, strings[start..<(start + name.count)].elementsEqual(name) { found.insert(module) }
                }
                if found.count == expected.count { break }
            }
            return found
        }
        let found = inspect()
        var finished = stat()
        guard fstat(file.fileDescriptor, &finished) == 0, fileIdentity(finished, path: python.path) == identity else { return [] }
        builtinCache.lock.lock()
        if builtinCache.entries.count >= 8 { builtinCache.entries.removeAll() }
        builtinCache.entries[identity] = found
        builtinCache.lock.unlock()
        return found
    }
    static func resolve(resourcesURL: URL? = PortablePythonRuntime.applicationResources(),
                        development: Bool = PortablePythonRuntime.developmentAllowed,
                        developmentCandidates: [URL] = [],
                        requireLegendary: Bool = false, requireCertificates: Bool = false) -> PortablePythonRuntime? {
        if let resourcesURL {
            let root = resourcesURL.resolvingSymlinksInPath().appendingPathComponent("Python").standardizedFileURL
            var metadata = stat()
            if lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
               let python = regular("bin/python3", root: root, executable: true), arm64(python) {
                let library = "lib/python3.13/"
                let required = ["encodings/__init__.py", "json/__init__.py", "ssl.py", "hashlib.py", "urllib/request.py", "importlib/metadata/__init__.py", "ctypes/__init__.py"]
                let extensions = contained(library + "lib-dynload", root: root).flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
                let modules = ["_ssl", "_socket", "_ctypes", "_hashlib"]
                let missing = modules.filter { module in !extensions.contains { $0.hasPrefix(module + ".") && $0.hasSuffix(".so") && regular(library + "lib-dynload/" + $0, root: root) != nil } }
                let modulesPresent = missing.isEmpty || Set(missing).isSubset(of: builtinModules(python))
                let ca = regular(library + "site-packages/certifi/cacert.pem", root: root).flatMap { url -> URL? in
                    guard let size = (try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber, size.intValue > 0 else { return nil }
                    return url
                }
                let legendary = regular("bin/legendary", root: root, executable: true)
                let package = ["legendary/__init__.py", "legendary/cli.py", "requests/__init__.py"].allSatisfy { regular(library + "site-packages/" + $0, root: root) != nil }
                let metadataURL = regular(library + "site-packages/legendary_gl-0.21.1.dist-info/METADATA", root: root)
                let packageMetadata = metadataURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").first?.components(separatedBy: "\n") ?? []
                let version = packageMetadata.filter { $0.hasPrefix("Version:") }
                let legendaryPresent = legendary != nil && package && version == ["Version: 0.21.1"]
                if required.allSatisfy({ regular(library + $0, root: root) != nil }), modulesPresent,
                   (!requireCertificates || ca != nil), (!requireLegendary || legendaryPresent) {
                    return .init(pythonURL: python, legendaryExecutableURL: legendaryPresent ? legendary : nil, certificateURL: ca, isBundled: true)
                }
            }
        }
        // No host probing at all unless this build explicitly opts into development.
        guard development else { return nil }
        let candidates=developmentCandidates.isEmpty ? Self.developmentCandidates:developmentCandidates
        for python in candidates where FileManager.default.isExecutableFile(atPath: python.path) {
            let cli = python.deletingLastPathComponent().appendingPathComponent("legendary")
            let legendary = FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
            if !requireLegendary || legendary != nil { return .init(pythonURL: python, legendaryExecutableURL: legendary, certificateURL: nil, isBundled: false) }
        }
        return nil
    }
    func environment(merging base: [String: String]) -> [String: String] {
        var value = base
        if isBundled {
            value = value.filter { !$0.key.hasPrefix("PYTHON") && $0.key != "SSL_CERT_FILE" && $0.key != "REQUESTS_CA_BUNDLE" }
            value["PATH"] = pythonURL.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            value["PYTHONNOUSERSITE"] = "1"
            if let certificateURL { value["SSL_CERT_FILE"] = certificateURL.path }
        }
        value["PYTHONDONTWRITEBYTECODE"] = "1"
        return value
    }
}
