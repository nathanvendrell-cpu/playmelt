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
    static func sharedSource(_ root: URL, dependency: String = "@loader_path/helper.dylib") throws -> URL {
        let lib = try source(root)
        try put(macho(dependency: dependency), lib.appendingPathComponent("external/libd3dshared.dylib"))
        try put(macho(), lib.appendingPathComponent("external/helper.dylib"))
        for name in ["d3d11", "d3d12", "dxgi", "d3d12core"] {
            let bridge = lib.appendingPathComponent("wine/x86_64-unix/\(name).so")
            if fm.fileExists(atPath: bridge.path) { try fm.removeItem(at: bridge) }
            try fm.createSymbolicLink(atPath: bridge.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        return lib
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
        expect(plan.environment["DXMT_ENABLE_NVEXT"] == nil && plan.environment["WINEDLLOVERRIDES"] == "d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d", "launch uses Apple native overrides without inherited DXMT flags")
        expect(plan.preparationEnvironment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d", "preparation retains its boot overrides")
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

        let resourcesSource = temp.appendingPathComponent("resources-source")
        let resourcesLib = try source(resourcesSource)
        let resourcesFramework = resourcesLib.appendingPathComponent("external/D3DMetal.framework/Versions/A")
        try put(macho(dependency: "@rpath/libdxccontainer.dylib"), resourcesFramework.appendingPathComponent("D3DMetal"))
        try put(macho(dependency: "@rpath/libmetalirconverter.dylib"), resourcesFramework.appendingPathComponent("Resources/libdxccontainer.dylib"))
        try put(macho(), resourcesFramework.appendingPathComponent("Resources/libmetalirconverter.dylib"))
        let resourcesStore = D3DMetalStore(root: temp.appendingPathComponent("resources/Renderers/D3DMetal"))
        try resourcesStore.importLocal(sourceURL: resourcesSource)
        let resourcesPlan = try resourcesStore.launchPlan(base: descriptor)
        let expectedResources = temp.appendingPathComponent("resources/Renderers/D3DMetal/payload/external/D3DMetal.framework/Resources").path
        expect(resourcesPlan.preparationBlockers.isEmpty, "framework Resources resolves both @rpath dependencies")
        expect(resourcesPlan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.split(separator: ":").contains(Substring(expectedResources)) == true, "framework Resources is in runtime search path")
        try fm.removeItem(at: resourcesFramework.appendingPathComponent("Resources/libmetalirconverter.dylib"))
        let missingResourcesStore = D3DMetalStore(root: temp.appendingPathComponent("missing-resources/Renderers/D3DMetal"))
        try missingResourcesStore.importLocal(sourceURL: resourcesSource)
        let missingResourcesPlan = try missingResourcesStore.launchPlan(base: descriptor)
        expect(missingResourcesPlan.preparationBlockers.contains { $0.contains("@rpath/libmetalirconverter.dylib") }, "missing framework dependency still blocks preparation")

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

        let shared = temp.appendingPathComponent("shared-bridge-source"), sharedLib = try sharedSource(shared)
        let license = Data("{\\rtf1 Synthetic license fixture}".utf8), acknowledgements = Data("{\\rtf1 Synthetic acknowledgements fixture}".utf8)
        try put(license, shared.appendingPathComponent("License.rtf"))
        try put(acknowledgements, shared.appendingPathComponent("Acknowledgements.rtf"))
        // NVIDIA shims are imported when present, but an incomplete set never
        // unlocks the translation route.
        try put(pe(), sharedLib.appendingPathComponent("wine/x86_64-windows/nvngx.dll"))
        try put(pe(), sharedLib.appendingPathComponent("wine/x86_64-windows/nvapi64.dll"))
        let sharedRoot = temp.appendingPathComponent("shared/Renderers/D3DMetal"), sharedStore = D3DMetalStore(root: sharedRoot)
        let sharedReport = try sharedStore.importLocal(sourceURL: shared)
        let sharedMach = sharedReport["machO"] as? [[String:Any]] ?? []
        let sharedFiles = sharedReport["files"] as? [[String:Any]] ?? []
        let sharedPayload = sharedRoot.appendingPathComponent("payload")
        expect(sharedMach.filter { $0["resolvedPath"] as? String == "external/libd3dshared.dylib" }.count == 4, "all shared bridge targets inspected")
        expect(sharedMach.contains { $0["path"] as? String == "external/libd3dshared.dylib" }, "shared external dylib inspected")
        expect(sharedMach.contains { $0["path"] as? String == "external/helper.dylib" }, "additional external dylib inspected")
        expect((sharedReport["dependencies"] as? [String])?.contains("@loader_path/helper.dylib") == true, "shared target dependencies reported")
        let sharedPlan = try sharedStore.launchPlan(base: descriptor)
        expect(!sharedPlan.blockedReasons.contains { $0.contains("@loader_path/helper.dylib") }, "loader path resolves from canonical shared target")
        expect(!sharedPlan.canExecute && sharedStore.snapshot()["loadTested"] as? Bool == false, "shared layout does not qualify runtime")
        expect(try fm.destinationOfSymbolicLink(atPath: sharedPayload.appendingPathComponent("wine/x86_64-unix/d3d12.so").path) == "../../external/libd3dshared.dylib", "shared bridge aliases preserved")
        expect(try Data(contentsOf: sharedPayload.appendingPathComponent("notices/License.rtf")) == license, "license contents preserved")
        expect(try Data(contentsOf: sharedPayload.appendingPathComponent("notices/Acknowledgements.rtf")) == acknowledgements, "acknowledgements contents preserved")
        expect(sharedFiles.filter { ($0["path"] as? String ?? "").hasPrefix("notices/") && ($0["sha256"] as? String)?.count == 64 }.count == 2, "both notices included in receipt hashes")
        expect(sharedFiles.contains { ($0["path"] as? String) == "wine/x86_64-windows/nvngx.dll" && ($0["sha256"] as? String)?.count == 64 }, "NVIDIA nvngx shim imported under canonical name")
        expect(sharedFiles.contains { ($0["path"] as? String) == "wine/x86_64-windows/nvapi64.dll" }, "NVIDIA nvapi64 shim imported")
        expect(sharedReport["nvidiaBridge"] as? String == "partial" && sharedStore.snapshot()["nvidiaBridge"] as? String == "partial", "partial bridge reported without unlocking")
        expect(!sharedStore.nvidiaBridgeAvailable(), "partial bridge is never available")
        let sameShared = try sharedStore.importLocal(sourceURL: shared)
        expect(sameShared["contentHash"] as? String == sharedReport["contentHash"] as? String, "shared import remains idempotent")
        try put(Data("changed notice".utf8), shared.appendingPathComponent("License.rtf"))
        rejects("notice change participates in import identity") { _ = try sharedStore.importLocal(sourceURL: shared) }
        expect(try Data(contentsOf: sharedPayload.appendingPathComponent("notices/License.rtf")) == license, "different notice cannot replace existing import")

        let bridgeSourceRoot = temp.appendingPathComponent("bridge-source"), bridgeLib = try sharedSource(bridgeSourceRoot)
        try put(pe(suffix: 2), bridgeLib.appendingPathComponent("wine/x86_64-windows/nvngx-on-metalfx.dll"))
        try put(macho(), bridgeLib.appendingPathComponent("wine/x86_64-unix/nvngx-on-metalfx.so"))
        try put(pe(suffix: 3), bridgeLib.appendingPathComponent("wine/x86_64-windows/nvapi64.dll"))
        let bridgeStoreRoot = temp.appendingPathComponent("bridge/Renderers/D3DMetal"), bridgeStore = D3DMetalStore(root: bridgeStoreRoot)
        let bridgeReport = try bridgeStore.importLocal(sourceURL: bridgeSourceRoot)
        let bridgeFiles = bridgeReport["files"] as? [[String:Any]] ?? []
        expect(bridgeReport["nvidiaBridge"] as? String == "complete", "complete NVIDIA bridge imported")
        expect((bridgeReport["nvidiaBridgeSourceNames"] as? [String:String])?["wine/x86_64-windows/nvngx.dll"] == "nvngx-on-metalfx.dll", "bridge alias stored under canonical name")
        expect(["wine/x86_64-windows/nvngx.dll", "wine/x86_64-unix/nvngx.so", "wine/x86_64-windows/nvapi64.dll"].allSatisfy { path in
            bridgeFiles.contains { ($0["path"] as? String) == path && ($0["sha256"] as? String)?.count == 64 }
        }, "required bridge files hashed in receipt")
        expect(bridgeStore.snapshot()["nvidiaBridge"] as? String == "complete" && bridgeStore.nvidiaBridgeAvailable(), "complete hashed bridge is available")
        let bridgeEnvironment = D3DMetalStore.nvidiaBridgeEnvironment([:])
        expect(bridgeEnvironment["D3DM_ENABLE_METALFX"] == "1" && bridgeEnvironment["WINEDLLOVERRIDES"] == "nvapi64,nvngx=b,n;d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d", "bridge launch environment")
        try pe(suffix: 7).write(to: bridgeStoreRoot.appendingPathComponent("payload/wine/x86_64-windows/nvngx.dll"))
        expect(!bridgeStore.nvidiaBridgeAvailable(), "tampered bridge is refused")

        for kind in ["arm", "truncated", "directory", "outside", "dependency", "external-arm"] {
            let bad = temp.appendingPathComponent("shared-invalid-" + kind), badLib = try sharedSource(bad)
            let sharedTarget = badLib.appendingPathComponent("external/libd3dshared.dylib")
            if kind == "arm" { try macho(arm: true).write(to: sharedTarget) }
            if kind == "truncated" { try Data(macho().prefix(40)).write(to: sharedTarget) }
            if kind == "directory" { try fm.removeItem(at: sharedTarget); try fm.createDirectory(at: sharedTarget, withIntermediateDirectories: false) }
            if kind == "dependency" { try macho(dependency: "/Applications/CrossOver.app/Contents/lib/bridge.dylib").write(to: sharedTarget) }
            if kind == "external-arm" { try put(macho(arm: true), badLib.appendingPathComponent("external/additional.dylib")) }
            if kind == "outside" {
                try put(macho(), bad.appendingPathComponent("outside.dylib"))
                let alias = badLib.appendingPathComponent("wine/x86_64-unix/d3d12.so")
                try fm.removeItem(at: alias); try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "../../../../outside.dylib")
            }
            rejects("invalid shared bridge " + kind) { _ = try store.inspect(sourceURL: bad) }
        }
        let extra = temp.appendingPathComponent("external-dependency-source"), extraLib = try sharedSource(extra)
        try put(macho(dependency: "/opt/unknown/shared-dependency.dylib"), extraLib.appendingPathComponent("external/additional.dylib"))
        let extraStore = D3DMetalStore(root: temp.appendingPathComponent("extra/Renderers/D3DMetal"))
        try extraStore.importLocal(sourceURL: extra)
        expect(try extraStore.launchPlan(base: descriptor).blockedReasons.contains { $0.contains("/opt/unknown/shared-dependency.dylib") }, "unreferenced external dylib dependencies block plan")

        let noticeParent = temp.appendingPathComponent("notice-parent"), selectedChild = noticeParent.appendingPathComponent("selected")
        _ = try source(selectedChild)
        try put(license, noticeParent.appendingPathComponent("License.rtf"))
        let selectedReport = try store.inspect(sourceURL: selectedChild)
        expect(!(selectedReport["files"] as? [[String:Any]] ?? []).contains { ($0["path"] as? String ?? "").hasPrefix("notices/") }, "notices never searched in parent folders")
        try fm.createSymbolicLink(atPath: selectedChild.appendingPathComponent("License.rtf").path, withDestinationPath: "../License.rtf")
        rejects("notice alias escapes selected folder") { _ = try store.inspect(sourceURL: selectedChild) }
        try fm.removeItem(at: selectedChild.appendingPathComponent("License.rtf"))
        try put(license, selectedChild.appendingPathComponent("terms/License.rtf"))
        try fm.createSymbolicLink(atPath: selectedChild.appendingPathComponent("License.rtf").path, withDestinationPath: "terms/License.rtf")
        let noticeStoreRoot = temp.appendingPathComponent("notice-internal/Renderers/D3DMetal")
        _ = try D3DMetalStore(root: noticeStoreRoot).importLocal(sourceURL: selectedChild)
        let copiedNotice = noticeStoreRoot.appendingPathComponent("payload/notices/License.rtf")
        expect(try Data(contentsOf: copiedNotice) == license, "internal notice alias contents preserved")
        expect(try fm.attributesOfItem(atPath: copiedNotice.path)[.type] as? FileAttributeType == .typeRegular, "internal notice aliases flattened")
        print("D3DMetalStore fixtures: \(checks) PASS; no Wine, GPU, network or proprietary binaries used.")
    }
}
