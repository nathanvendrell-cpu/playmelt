import Foundation

@main enum GameModeRuntimeTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let engine = root.appendingPathComponent(GameModeRuntime.engineID + "/engine")
        for directory in ["bin", "lib", "share"] { try fm.createDirectory(at: engine.appendingPathComponent(directory), withIntermediateDirectories: true) }
        let bytes = Data("inert Wine file fixture; never executed".utf8)
        for name in ["wine", "wineserver"] {
            let file = engine.appendingPathComponent("bin/" + name)
            try bytes.write(to: file); try fm.setAttributes([.posixPermissions:0o700], ofItemAtPath: file.path)
        }
        let wrapper = root.appendingPathComponent(GameModeRuntime.engineID + "/" + GameModeRuntime.bundleName)
        var checks = 0
        func check(_ condition: Bool, _ reason: String) throws {
            checks += 1
            if !condition { throw NSError(domain: "GameModeRuntimeTests", code: checks, userInfo: [NSLocalizedDescriptionKey:reason]) }
        }
        try check(GameModeRuntime.ensure(runtimeRoot: root), "An inert complete engine can prepare its game-category wrapper")
        try check(GameModeRuntime.ensure(runtimeRoot: root), "A valid wrapper can be reused")
        for name in ["wine", "wineserver"] {
            let copy = wrapper.appendingPathComponent("Contents/MacOS/" + name)
            let prior = try fm.attributesOfItem(atPath: copy.path)
            let oldTime = prior[.modificationDate] as! Date
            try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath: copy.path)
            try check(!fm.isExecutableFile(atPath: copy.path), "The fixture actually removed the execute bit")
            try check((try fm.attributesOfItem(atPath: copy.path)[.modificationDate] as! Date) == oldTime, "Removing execute permission preserves the old size/mtime cache signature")
            let repaired = GameModeRuntime.ensure(runtimeRoot: root)
            try check(!repaired || fm.isExecutableFile(atPath: copy.path), "The production code repairs or rejects a non-executable cached copy")
            try check(repaired, "An intact source allows wrapper repair")
            try check((try Data(contentsOf: engine.appendingPathComponent("bin/" + name))) == bytes, "Repair preserves the original engine bytes")
            try check(fm.isExecutableFile(atPath: engine.appendingPathComponent("bin/" + name).path), "Repair preserves original engine execution rights")
        }
        try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath: engine.appendingPathComponent("bin/wine").path)
        try check(!GameModeRuntime.ensure(runtimeRoot: root), "An unusable original engine fails closed without choosing its cached wrapper")
        print("GameModeRuntime: \(checks) checks passed; inert files only, nothing executed")
    }
}
