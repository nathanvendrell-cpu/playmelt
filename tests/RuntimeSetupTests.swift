import Foundation

@main
enum RuntimeSetupTests {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("playmelt-runtime-tests-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        func require(_ condition: @autoclosure () -> Bool, _ description: String) {
            if !condition() { fatalError(description) }
        }
        for bad in ["/etc/passwd", "../outside", "safe/../../outside", "a\\b", "a\0b"] {
            require(!RuntimeSetup.safeArchivePath(bad), "Rejected traversal: " + bad)
        }
        for good in ["wswine.bundle/bin/wine", "./highball/x86_64-windows/d3d11.dll", "Template.app/Contents/Frameworks/"] {
            require(RuntimeSetup.safeArchivePath(good), "Valid archive member: " + good)
        }
        let engine = scratch.appendingPathComponent("engine")
        try fm.createDirectory(at: engine, withIntermediateDirectories: false)
        try Data("abc".utf8).write(to: engine.appendingPathComponent("data"))
        let hash = try RuntimeSetup.sha256(engine.appendingPathComponent("data"))
        require(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "Known SHA-256")
        try fm.createSymbolicLink(atPath: engine.appendingPathComponent("inside").path, withDestinationPath: "data")
        try RuntimeSetup.validateTree(engine)
        try fm.createSymbolicLink(atPath: engine.appendingPathComponent("outside").path, withDestinationPath: "../../outside")
        do { try RuntimeSetup.validateTree(engine); fatalError("External relative symlink accepted") } catch {}
        try fm.removeItem(at: engine.appendingPathComponent("outside"))
        try fm.createSymbolicLink(atPath: engine.appendingPathComponent("absolute").path, withDestinationPath: "/etc/passwd")
        do { try RuntimeSetup.validateTree(engine); fatalError("Absolute symlink accepted") } catch {}
        try fm.removeItem(at: engine.appendingPathComponent("absolute"))
        try fm.createDirectory(at: engine.appendingPathComponent("D3DMetal.framework"), withIntermediateDirectories: false)
        do { try RuntimeSetup.validateTree(engine); fatalError("Apple renderer accepted") } catch {}
        let setup = RuntimeSetup(root: scratch.appendingPathComponent("no-side-effects"))
        require(setup.descriptor().readyEngine == false, "Missing engine is not ready")
        require(setup.descriptor().steamInstalled == false, "Missing Steam is not installed")
        require(setup.snapshot()["progress"] is NSNull, "No invented percentage")
        require(!fm.fileExists(atPath: setup.root.path), "snapshot/init have no filesystem mutations")
        require(!setup.descriptor().environment.values.contains(where: { $0.contains("CrossOver") || $0.contains("Highball.app") }), "No launcher dependency")
        require(RuntimeSetup.components.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 && $0.url.hasPrefix("https://github.com/") }, "Pinned upstream components")
        let loaderRoot = scratch.appendingPathComponent("loader")
        let ntdll = loaderRoot.appendingPathComponent("engine/lib/wine/x86_64-unix/ntdll.so")
        try fm.createDirectory(at: ntdll.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plain Wine".utf8).write(to: ntdll)
        do { try RuntimeSetup.validateOverlayLoader(loaderRoot); fatalError("Plain Wine loader accepted") } catch {}
        try Data("fixture WINEDLLPATH_PREPEND\0".utf8).write(to: ntdll)
        try RuntimeSetup.validateOverlayLoader(loaderRoot)

        // Exercise the actual system-tar path with a harmless fixture, including Apple's
        // excluded subtree and a notice outside the selected directory. No network/runtime.
        let source = scratch.appendingPathComponent("archive-source")
        let frameworks = source.appendingPathComponent("Template.app/Contents/Frameworks")
        try fm.createDirectory(at: frameworks.appendingPathComponent("renderer/d3dmetal"), withIntermediateDirectories: true)
        try Data("must not extract".utf8).write(to: frameworks.appendingPathComponent("renderer/d3dmetal/apple.dll"))
        try fm.createSymbolicLink(atPath: frameworks.appendingPathComponent("renderer/apple_gptk").path, withDestinationPath: "d3dmetal")
        try Data("runtime fixture".utf8).write(to: frameworks.appendingPathComponent("libfixture.dylib"))
        try Data("fixture notice".utf8).write(to: source.appendingPathComponent("LICENSE"))
        let archive = scratch.appendingPathComponent("fixture.tar"), pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        pack.arguments = ["-cf", archive.path, "-C", source.path, "Template.app", "LICENSE"]
        try pack.run(); pack.waitUntilExit(); require(pack.terminationStatus == 0, "Fixture archive creation")
        let assembled = scratch.appendingPathComponent("assembled")
        try fm.createDirectory(at: assembled, withIntermediateDirectories: false)
        let fixture = RuntimeComponent(name: "fixture", url: "https://example.invalid", sha256: String(repeating: "a", count: 64), archivePath: "Template.app/Contents/Frameworks", destination: "frameworks", license: "test", bytes: 0)
        try setup.extract(archive, component: fixture, assembled: assembled, staging: scratch)
        require(fm.fileExists(atPath: assembled.appendingPathComponent("frameworks/libfixture.dylib").path), "Selected runtime extracted")
        require(!fm.fileExists(atPath: assembled.appendingPathComponent("frameworks/renderer/d3dmetal").path), "Apple subtree never extracted")
        require((try? fm.destinationOfSymbolicLink(atPath: assembled.appendingPathComponent("frameworks/renderer/apple_gptk").path)) == nil, "Apple alias never extracted")
        require(fm.fileExists(atPath: assembled.appendingPathComponent("licenses/" + fixture.sha256 + "/0-LICENSE").path), "Upstream notice preserved")
        var stopped = false
        setup.shutdown { stopped = true }
        let deadline = Date().addingTimeInterval(2)
        while !stopped && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        require(stopped, "Shutdown completion after queue cleanup")
        let lockRoot = scratch.appendingPathComponent("locks")
        try fm.createDirectory(at: lockRoot, withIntermediateDirectories: false)
        let firstLock = try RuntimeSetup.acquireSetupLock(lockRoot)
        do { _ = try RuntimeSetup.acquireSetupLock(lockRoot); fatalError("Concurrent setup lock accepted") } catch {}
        RuntimeSetup.releaseSetupLock(firstLock)
        let nextLock = try RuntimeSetup.acquireSetupLock(lockRoot)
        RuntimeSetup.releaseSetupLock(nextLock)
        let lockAttributes = try fm.attributesOfItem(atPath: lockRoot.appendingPathComponent(".setup.lock").path)
        require((lockAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private lock mode")
        let symlinkLockRoot = scratch.appendingPathComponent("symlink-lock")
        try fm.createDirectory(at: symlinkLockRoot, withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: symlinkLockRoot.appendingPathComponent(".setup.lock").path, withDestinationPath: "../locks/.setup.lock")
        do { _ = try RuntimeSetup.acquireSetupLock(symlinkLockRoot); fatalError("Symlink lock accepted") } catch {}
        let prefix = scratch.appendingPathComponent("prefix-flush")
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true)
        for path in ["drive_c/windows/system32/kernel32.dll", "drive_c/windows/syswow64/kernel32.dll"] {
            try Data([0x4d, 0x5a, 0, 0]).write(to: prefix.appendingPathComponent(path))
        }
        do { try RuntimeSetup.validatePrefix(prefix); fatalError("Unflushed registry accepted") } catch {}
        for path in ["system.reg", "user.reg"] {
            try Data("WINE REGISTRY Version 2\n;; fixture written on server shutdown\n".utf8).write(to: prefix.appendingPathComponent(path))
        }
        try RuntimeSetup.validatePrefix(prefix)
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        do { try RuntimeSetup.validatePrefix(prefix); fatalError("Empty registry accepted") } catch {}
        print("RuntimeSetup: traversal, symlinks, SHA-256, Apple exclusion, missing state and read-only snapshot tests passed. No download or Wine execution.")
    }
}
