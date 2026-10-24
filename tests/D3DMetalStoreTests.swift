import Foundation
import Darwin

// Synthetic headers only: these files are never executed or dynamically loaded.
@main enum D3DMetalStoreTests {
    static let fm = FileManager.default
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        checks += 1; if !value { fatalError("FAIL: " + label) }
    }
    static func rejects(_ label: String, _ block: () throws -> Void) {
        checks += 1; do { try block(); fatalError("FAIL: accepted " + label) } catch {}
    }
    static func put(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    static func word(_ value: UInt32, _ data: inout Data, _ offset: Int) {
        for i in 0..<4 { data[offset+i] = UInt8((value >> (8*i)) & 255) }
    }
    static func pe(x64: Bool = true, suffix: UInt8 = 0) -> Data {
        var data = Data(repeating: 0, count: 160)
        data[0] = 0x4d; data[1] = 0x5a; word(64, &data, 60)
        data[64] = 0x50; data[65] = 0x45
        data[68] = x64 ? 0x64 : 0x4c; data[69] = x64 ? 0x86 : 0x01
        data[88] = 0x0b; data[89] = x64 ? 0x02 : 0x01; data[159] = suffix
        return data
    }
    static func macho(dependency: String = "/usr/lib/libSystem.B.dylib", arm: Bool = false) -> Data {
        let name = Data(dependency.utf8) + Data([0]); let commandSize = (24 + name.count + 7) / 8 * 8
        var data = Data(repeating: 0, count: 32 + 24 + commandSize)
        word(0xfeedfacf, &data, 0); word(arm ? 0x0100000c : 0x01000007, &data, 4)
        word(6, &data, 12); word(2, &data, 16); word(UInt32(24 + commandSize), &data, 20)
        word(0x32, &data, 32); word(24, &data, 36); word(1, &data, 40); word(14 << 16, &data, 44)
        word(0x0c, &data, 56); word(UInt32(commandSize), &data, 60); word(24, &data, 64)
        data.replaceSubrange(80..<(80 + name.count), with: name)
        return data
    }
    static func source(_ root: URL, layout: String = "redist/lib", dependency: String = "/usr/lib/libSystem.B.dylib") throws -> URL {
        let lib = layout.isEmpty ? root : root.appendingPathComponent(layout)
        for name in ["dxgi", "d3d11", "d3d12"] {
            try put(pe(), lib.appendingPathComponent("wine/x86_64-windows/\(name).dll"))
            try put(macho(dependency: dependency), lib.appendingPathComponent("wine/x86_64-unix/\(name).so"))
        }
        let framework = lib.appendingPathComponent("external/D3DMetal.framework")
        try put(macho(), framework.appendingPathComponent("Versions/A/D3DMetal"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "fixture-3.0"], format: .xml, options: 0)
        try put(plist, framework.appendingPathComponent("Versions/A/Resources/Info.plist"))
        for (path, target) in [("Versions/Current", "A"), ("D3DMetal", "Versions/Current/D3DMetal"), ("Resources", "Versions/Current/Resources")] {
            try fm.createSymbolicLink(atPath: framework.appendingPathComponent(path).path, withDestinationPath: target)
        }
        return lib
    }
    static func base(_ root: URL, environment extra: [String: String] = [:]) throws -> PlaymeltRuntimeDescriptor {
        let engine = root.appendingPathComponent("base/engine"), prefix = root.appendingPathComponent("base/prefix")
        try put(Data([1,2,3]), engine.appendingPathComponent("bin/wine"))
        try put(Data([4,5,6]), engine.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"))
        var env = ["DYLD_FALLBACK_LIBRARY_PATH": root.appendingPathComponent("base/frameworks").path,
                   "DYLD_FALLBACK_FRAMEWORK_PATH": root.appendingPathComponent("base/frameworks").path,
                   "WINEDLLPATH_PREPEND": root.appendingPathComponent("base/renderers/dxmt/wine").path,
                   "DXMT_ENABLE_NVEXT": "1", "WINEDLLOVERRIDES": "dxgi=n"]
        for (key,value) in extra { env[key] = value }
        return .init(engineID: "fixture-wine", wineURL: engine.appendingPathComponent("bin/wine"), wineserverURL: engine.appendingPathComponent("bin/wineserver"), prefixURL: prefix,
                     steamRoot: prefix.appendingPathComponent("drive_c/Steam"), environment: env, readyEngine: true, steamInstalled: false)
    }
    static func main() throws {
        let temp = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Products.noindex/playmelt-d3dmetal-tests-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) } // exact fixture directory created above
        let apple = temp.appendingPathComponent("AppleFixture"), lib = try source(apple)
        let storeRoot = temp.appendingPathComponent("Playmelt/Renderers/D3DMetal")
        let store = D3DMetalStore(root: storeRoot)
        expect(store.snapshot()["imported"] as? Bool == false, "initial missing")
        expect(!fm.fileExists(atPath: storeRoot.path), "snapshot creates no files")
        for layout in ["redist/lib", "lib", ""] {
            let src = temp.appendingPathComponent("layout-" + UUID().uuidString)
            _ = try source(src, layout: layout)
            let report = try store.inspect(sourceURL: src)
            expect(report["layout"] as? String == (layout.isEmpty ? "direct" : layout), "layout normalization")
            expect(report["loadTested"] as? Bool == false && report["abiStatus"] as? String == "unverified", "inspection does not qualify ABI")
        }
        let report = try store.importLocal(sourceURL: apple)
        let payload = storeRoot.appendingPathComponent("payload")
        expect(fm.fileExists(atPath: payload.appendingPathComponent("receipt.json").path), "receipt shares payload transaction")
        expect(!fm.fileExists(atPath: storeRoot.appendingPathComponent("receipt.json").path), "no separate receipt")
        let same = try store.importLocal(sourceURL: apple)
        expect(report["importedAt"] as? String == same["importedAt"] as? String, "same hash idempotent")
        expect(store.snapshot()["imported"] as? Bool == true && store.snapshot()["loadTested"] as? Bool == false, "import presence only")
        expect(!(try JSONSerialization.data(withJSONObject: report)).contains(Data(temp.path.utf8)), "receipt excludes source absolute paths")
        try pe(suffix: 1).write(to: lib.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))
        rejects("different import replaces existing") { _ = try store.importLocal(sourceURL: apple) }
        expect(try D3DMetalStore.hash(payload.appendingPathComponent("wine/x86_64-windows/d3d12.dll")) != D3DMetalStore.hash(lib.appendingPathComponent("wine/x86_64-windows/d3d12.dll")), "original payload preserved")
        try pe().write(to: lib.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))

        let failureRoot = temp.appendingPathComponent("failed/Renderers/D3DMetal")
        let failing = D3DMetalStore(root: failureRoot, writeReceipt: { _,_ in throw RuntimeSetupError.failed("fixture-write-failure") })
        rejects("receipt write fails") { _ = try failing.importLocal(sourceURL: apple) }
        expect(!fm.fileExists(atPath: failureRoot.appendingPathComponent("payload").path), "receipt failure leaves no payload")
        expect(try fm.contentsOfDirectory(atPath: failureRoot.path).allSatisfy { !$0.hasPrefix(".import-") }, "receipt failure cleans own staging")

        for kind in ["fifo", "symlink", "hardlink", "public"] {
            let target = temp.appendingPathComponent("lock-" + kind)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let lock = target.appendingPathComponent(".import.lock"), other = target.appendingPathComponent("other")
            if kind == "fifo" { expect(mkfifo(lock.path, 0o600) == 0, "fixture FIFO") }
            else if kind == "symlink" { try fm.createSymbolicLink(atPath: lock.path, withDestinationPath: "other") }
            else if kind == "hardlink" { try put(Data([1]), other); try fm.linkItem(at: other, to: lock) }
            else { try put(Data([1]), lock); try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lock.path) }
            rejects("lock " + kind) { _ = try D3DMetalStore(root: target).importLocal(sourceURL: apple) }
        }
        let descriptor = try base(temp)
        let plan = try store.launchPlan(base: descriptor)
        expect(!plan.canExecute && plan.blockedReasons.count >= 3, "unqualified route stays blocked")
        expect(plan.prefixURL != descriptor.prefixURL && plan.environment["WINEPREFIX"] == plan.prefixURL.path, "separate DX12 prefix")
        expect(plan.environment["WINEDLLPATH_PREPEND"] == payload.appendingPathComponent("wine").path, "one Apple overlay only")
        expect(plan.environment["DXMT_ENABLE_NVEXT"] == nil && plan.environment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d", "no inherited DXMT flags/overrides")
        expect(plan.environment["CX_D3DMETALPATH"] == payload.appendingPathComponent("external").path, "upstream Apple bridge contract")
        let wrong = try base(temp, environment: ["DYLD_FALLBACK_LIBRARY_PATH": "/Applications/CrossOver.app/Contents/lib"])
        rejects("application dependency") { _ = try store.launchPlan(base: wrong) }
        let dxmt = try base(temp, environment: ["DYLD_FALLBACK_LIBRARY_PATH": temp.appendingPathComponent("renderers/dxmt/wine").path])
        rejects("DXMT dependency") { _ = try store.launchPlan(base: dxmt) }
        let unknownSource = temp.appendingPathComponent("unknown-source")
        _ = try source(unknownSource, dependency: "/opt/unknown/vendor.dylib")
        let unknownStore = D3DMetalStore(root: temp.appendingPathComponent("unknown/Renderers/D3DMetal"))
        try unknownStore.importLocal(sourceURL: unknownSource)
        let unknownPlan = try unknownStore.launchPlan(base: descriptor)
        expect(unknownPlan.blockedReasons.contains { $0.contains("/opt/unknown/vendor.dylib") }, "unknown absolute dependency blocks plan")

        let probe = temp.appendingPathComponent("probe.exe"); try put(pe(), probe)
        func response(_ request: D3DMetalProbeRequest, fields: [String:Any] = [:]) throws -> Data {
            var value: [String:Any] = ["schema":1, "kind":"playmelt-d3d12-probe", "nonce":request.nonce, "dxgiLoaded":true, "d3d12Loaded":true,
                "deviceCreated":true, "featureLevel":"12_0", "hresult":0, "adapterFlags":0, "adapterVendorID":0x106b,
                "dxgiModule":"C:\\windows\\system32\\dxgi.dll", "d3d12Module":"C:\\windows\\system32\\d3d12.dll"]
            for (key, v) in fields { value[key] = v }; return try JSONSerialization.data(withJSONObject: value)
        }
        var request = try store.prepareProbe(base: descriptor, executableURL: probe)
        let valid = try store.validateProbeResponse(response(request), request: request, exitCode: 0)
        expect(valid["probeResponseValidated"] as? Bool == true && valid["loadTested"] as? Bool == false && valid["routeEnabled"] as? Bool == false, "response contract does not prove loading")
        rejects("probe replay") { _ = try store.validateProbeResponse(response(request), request: request, exitCode: 0) }
        for fields: [String:Any] in [["nonce":"wrong"], ["adapterFlags":2], ["dxgiModule":"C:\\..\\dxgi.dll"], ["deviceCreated":false], ["d3d12Module":"C:\\windows\\system32\\vkd3d.dll"]] {
            request = try store.prepareProbe(base: descriptor, executableURL: probe)
            rejects("invalid probe contract") { _ = try store.validateProbeResponse(response(request, fields: fields), request: request, exitCode: 0) }
        }
        request = try store.prepareProbe(base: descriptor, executableURL: probe)
        try pe(suffix: 9).write(to: probe)
        rejects("changed probe hash") { _ = try store.validateProbeResponse(response(request), request: request, exitCode: 0) }
        expect(store.snapshot()["loadTested"] as? Bool == false, "no fixture can promote runtime proof")

        let alias = payload.appendingPathComponent("external/D3DMetal.framework/Versions/Current")
        try fm.removeItem(at: alias); try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "../Versions/A")
        rejects("changed alias even same target") { _ = try store.launchPlan(base: descriptor) }
        rejects("changed alias on idempotent import") { _ = try store.importLocal(sourceURL: apple) }
        try fm.removeItem(at: alias); try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: temp.path)
        rejects("escaping payload alias") { _ = try store.launchPlan(base: descriptor) }
        for kind in ["missing", "x86", "arm", "truncated", "escape"] {
            let invalid = temp.appendingPathComponent("invalid-" + kind), badLib = try source(invalid)
            let dll = badLib.appendingPathComponent("wine/x86_64-windows/d3d12.dll"), so = badLib.appendingPathComponent("wine/x86_64-unix/d3d12.so")
            if kind == "missing" { try fm.removeItem(at: dll) }
            if kind == "x86" { try pe(x64: false).write(to: dll) }
            if kind == "arm" { try macho(arm: true).write(to: so) }
            if kind == "truncated" { try Data(macho().prefix(40)).write(to: so) }
            if kind == "escape" { try fm.createSymbolicLink(atPath: badLib.appendingPathComponent("external/escape").path, withDestinationPath: temp.path) }
            rejects("invalid source " + kind) { _ = try store.inspect(sourceURL: invalid) }
        }
        rejects("application source") { _ = try store.inspect(sourceURL: temp.appendingPathComponent("CrossOver.app")) }
        let mixedSource = temp.appendingPathComponent("renderers/dxmt/import")
        _ = try source(mixedSource)
        rejects("DXMT source") { _ = try store.inspect(sourceURL: mixedSource) }
        print("D3DMetalStore fixtures: \(checks) PASS; no Wine, GPU, network or proprietary binaries used.")
    }
}
