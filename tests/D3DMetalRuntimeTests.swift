import Foundation
import Darwin

private final class MockD3DRunner: D3DMetalCommandRunning {
    enum Mode { case success, missingSymbol, active, leftover, bootError, stopError, waitError, hold, mutate }
    let lock = NSLock()
    var mode: Mode = .success
    var commands: [D3DMetalCommand] = []
    var cleanupSawCancellation = false
    var activeProcessPath = ""
    var mutate: (() throws -> Void)?
    func list() -> [D3DMetalCommand] { lock.lock(); defer { lock.unlock() }; return commands }
    func run(_ command: D3DMetalCommand, cancelled: () -> Bool) throws -> String {
        lock.lock(); commands.append(command); let mode = self.mode; lock.unlock()
        if command.executable.lastPathComponent == "nm" { return mode == .missingSymbol ? "0000 T _other\n" : "0000 D _macdrv_functions\n" }
        if command.executable.lastPathComponent == "ps" {
            let after = list().filter { $0.executable.lastPathComponent == "ps" }.count > 1
            return mode == .active || (mode == .leftover && after) ? "123 " + activeProcessPath + "\n" : ""
        }
        if command.arguments == ["wineboot","-u"] {
            if mode == .hold {
                let deadline = Date().addingTimeInterval(3)
                while !cancelled() && Date() < deadline { Thread.sleep(forTimeInterval:0.005) }
                if cancelled() { throw RuntimeSetupError.cancelled }
                throw RuntimeSetupError.failed("fixture timeout")
            }
            if mode == .bootError { throw RuntimeSetupError.failed("fixture boot error") }
            if mode == .mutate { try mutate?() }
            return String(repeating:"fixture log\n",count:10000)
        }
        if command.arguments == ["-k"] || command.arguments == ["-w"] {
            if cancelled() { cleanupSawCancellation = true }
            if command.arguments == ["-k"] && mode == .stopError { throw RuntimeSetupError.failed("fixture stop error") }
            if command.arguments == ["-w"] && mode == .waitError { throw RuntimeSetupError.failed("fixture wait error") }
            if command.arguments == ["-w"] {
                let prefix = URL(fileURLWithPath:command.environment["WINEPREFIX"]!)
                for name in ["system.reg","user.reg"] { try D3DMetalRuntimeTests.put(Data("WINE REGISTRY Version 2\n".utf8),prefix.appendingPathComponent(name)) }
                for arch in ["system32","syswow64"] { try D3DMetalRuntimeTests.put(Data([0x4d,0x5a]),prefix.appendingPathComponent("drive_c/windows/\(arch)/kernel32.dll")) }
            }
            return ""
        }
        throw RuntimeSetupError.failed("unexpected fixture command")
    }
}

@main enum D3DMetalRuntimeTests {
    static let fm = FileManager.default
    static var checks = 0
    static func expect(_ value: Bool,_ label: String) { checks += 1; if !value { fatalError("FAIL: " + label) } }
    static func rejects(_ label: String,_ block: () throws -> Void) { checks += 1; do { try block(); fatalError("FAIL: accepted " + label) } catch {} }
    static func put(_ data: Data,_ url: URL) throws { try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:url) }
    static func word(_ x: UInt32,_ data: inout Data,_ offset: Int) { for i in 0..<4 { data[offset+i] = UInt8((x >> (i*8)) & 255) } }
    static func pe() -> Data { var d = Data(repeating:0,count:100); d[0]=0x4d;d[1]=0x5a;word(64,&d,60);d[64]=0x50;d[65]=0x45;d[68]=0x64;d[69]=0x86;d[88]=0x0b;d[89]=2;return d }
    static func mach() -> Data { var d = Data(repeating:0,count:56);word(0xfeedfacf,&d,0);word(0x01000007,&d,4);word(6,&d,12);word(1,&d,16);word(24,&d,20);word(0x32,&d,32);word(24,&d,36);word(1,&d,40);word(14 << 16,&d,44);return d }
    private static func fixture(_ root: URL) throws -> (D3DMetalStore,PlaymeltRuntimeDescriptor,MockD3DRunner,D3DMetalRuntime) {
        let source = root.appendingPathComponent("source")
        for name in ["d3d11","d3d12","dxgi"] {
            try put(pe(),source.appendingPathComponent("wine/x86_64-windows/\(name).dll"))
            try put(mach(),source.appendingPathComponent("wine/x86_64-unix/\(name).so"))
        }
        try put(mach(),source.appendingPathComponent("external/D3DMetal.framework/D3DMetal"))
        let store = D3DMetalStore(root:root.appendingPathComponent("Playmelt/Renderers/D3DMetal"))
        try store.importLocal(sourceURL:source)
        let engine = root.appendingPathComponent("base/engine"), prefix = root.appendingPathComponent("base/prefix")
        for name in ["wine","wineserver"] { let file=engine.appendingPathComponent("bin/"+name);try put(Data("fixture executable".utf8),file);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path) }
        try put(mach(),engine.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"))
        try put(Data("fixture WINEDLLPATH_PREPEND\0 loader".utf8),engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so"))
        let base = PlaymeltRuntimeDescriptor(engineID:"fixture-wine",wineURL:engine.appendingPathComponent("bin/wine"),wineserverURL:engine.appendingPathComponent("bin/wineserver"),prefixURL:prefix,steamRoot:prefix.appendingPathComponent("drive_c/Steam"),environment:["DYLD_FALLBACK_LIBRARY_PATH":root.appendingPathComponent("base/frameworks").path,"WINEDLLPATH_PREPEND":root.appendingPathComponent("base/renderers/dxmt/wine").path,"DXMT_ENABLE_NVEXT":"1"],readyEngine:true,steamInstalled:false)
        let runner=MockD3DRunner(), runtime=D3DMetalRuntime(store:store,runner:runner,capacity:{_ in 8_000_000_000})
        runner.activeProcessPath=base.wineURL.path
        return (store,base,runner,runtime)
    }
    static func until(_ done: () -> Bool) {
        let deadline=Date().addingTimeInterval(5)
        while !done() && Date() < deadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        expect(done(),"asynchronous operation completed")
    }
    static func start(_ runtime:D3DMetalRuntime,_ base:PlaymeltRuntimeDescriptor) -> Result<PlaymeltRuntimeDescriptor,Error> {
        var result:Result<PlaymeltRuntimeDescriptor,Error>?
        runtime.start(base:base,progress:{ _ in expect(Thread.isMainThread,"progress on main") },completion:{result=$0;expect(Thread.isMainThread,"completion on main")})
        until { result != nil }; return result!
    }
    static func success(_ result:Result<PlaymeltRuntimeDescriptor,Error>) -> Bool { if case .success = result { return true };return false }
    static func main() throws {
        let temp=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/d3dmetal-runtime-tests-"+UUID().uuidString)
        try fm.createDirectory(at:temp,withIntermediateDirectories:false);defer{try?fm.removeItem(at:temp)}
        let absentStore=D3DMetalStore(root:temp.appendingPathComponent("absent/Renderers/D3DMetal"))
        let (store,base,runner,runtime)=try fixture(temp.appendingPathComponent("success"))
        expect(D3DMetalRuntime(store:absentStore).snapshot(base:base)["status"] as? String == "missing","no import is missing")
        expect(!fm.fileExists(atPath:absentStore.isolatedRoot.path),"snapshot creates no prefix")
        expect(runtime.snapshot(base:base)["canPrepare"] as? Bool == true,"imported candidate can prepare")
        expect(runtime.snapshot(base:base)["canLaunch"] as? Bool == false,"candidate cannot launch")
        expect(success(start(runtime,base)),"mock preparation succeeds")
        let descriptor=try runtime.descriptor(base:base)!
        expect(descriptor.prefixURL != base.prefixURL && descriptor.steamRoot != base.steamRoot,"prefix and Steam isolated")
        expect(descriptor.environment["DXMT_ENABLE_NVEXT"] == nil && !(descriptor.environment["WINEDLLPATH_PREPEND"] ?? "").contains("dxmt"),"no DXMT mixed into descriptor")
        expect(runtime.snapshot(base:base)["prepared"] as? Bool == true && runtime.snapshot(base:base)["canLaunch"] as? Bool == false,"prepared is never qualified")
        expect(runtime.snapshot(base:base)["loadTested"] as? Bool == false && runtime.snapshot(base:base)["gameTested"] as? Bool == false,"no runtime proof invented")
        let runtimeCommands=runner.list().filter { $0.executable == base.wineURL || $0.executable == base.wineserverURL }
        expect(runtimeCommands.map(\.arguments) == [["wineboot","-u"],["-k"],["-w"]],"boot and scoped stop/wait sequence")
        expect(runtimeCommands.allSatisfy{$0.environment["WINEPREFIX"] == descriptor.prefixURL.path},"all Wine commands use isolated prefix")
        expect(runtimeCommands.allSatisfy{$0.timeout > 0 && $0.timeout <= 180},"every command has bounded timeout")
        expect((try fm.attributesOfItem(atPath:store.isolatedRoot.appendingPathComponent("preparation.log").path)[.size] as? NSNumber)?.intValue == 65536,"log capped at 64KiB")
        let before=runner.list().count
        for _ in 0..<10 { _=try runtime.descriptor(base:base);_=runtime.snapshot(base:base) }
        expect(runner.list().count == before,"descriptor and notifications never invoke runner")
        let relaunched=D3DMetalRuntime(store:store,runner:runner,capacity:{_ in 8_000_000_000})
        expect(try relaunched.descriptor(base:base) != nil,"prepared receipt restores without rerunning Wine")
        try put(Data([0x4d,0x5a]),descriptor.steamRoot.appendingPathComponent("steam.exe"))
        try put(Data("cache preserved".utf8),descriptor.prefixURL.appendingPathComponent("cache.keep"))
        expect(try runtime.descriptor(base:base)?.steamInstalled == true,"separate Steam presence detected")
        expect(success(start(runtime,base)) && runner.list().count == before,"used prepared prefix is idempotent")
        expect(try Data(contentsOf:descriptor.prefixURL.appendingPathComponent("cache.keep")) == Data("cache preserved".utf8),"prefix/cache preserved")
        try put(pe()+Data([9]),store.root.appendingPathComponent("payload/wine/x86_64-windows/d3d12.dll"))
        rejects("changed imported file invalidates descriptor"){_=try runtime.descriptor(base:base)}
        expect(runtime.snapshot(base:base)["status"] as? String == "blocked" && runtime.snapshot(base:base)["canPrepare"] as? Bool == false,"changed used prefix is not reinitialized")
        expect(!success(start(runtime,base)) && runner.list().count == before,"changed prepared receipt refuses all process dispatch")

        for mode in [MockD3DRunner.Mode.missingSymbol,.bootError,.stopError,.waitError] {
            let (s,b,r,t)=try fixture(temp.appendingPathComponent(UUID().uuidString));r.mode=mode
            expect(!success(start(t,b)),"preparation failure remains failure")
            expect(!fm.fileExists(atPath:s.isolatedRoot.appendingPathComponent("prefix-ready.json").path),"failure never writes ready receipt")
            let calls=r.list().map(\.arguments)
            if mode == .missingSymbol { expect(!calls.contains(["wineboot","-u"]),"missing ABI export prevents Wine") }
            else { expect(calls.contains(["-k"]) && calls.contains(["-w"]),"both cleanup attempts run independently") }
        }
        for mode in [MockD3DRunner.Mode.active,.leftover] {
            let (s,b,r,t)=try fixture(temp.appendingPathComponent(UUID().uuidString));r.mode=mode
            expect(!success(start(t,b)),"existing or leftover process blocks readiness")
            expect(!fm.fileExists(atPath:s.isolatedRoot.appendingPathComponent("prefix-ready.json").path),"process presence never receives ready receipt")
            if mode == .active { expect(!r.list().contains{$0.arguments == ["wineboot","-u"]},"existing process never interrupted") }
            else { expect(r.list().contains{$0.arguments == ["-w"]},"leftover detected after scoped cleanup") }
        }
        do {
            let (s,b,r,_)=try fixture(temp.appendingPathComponent("disk"))
            let t=D3DMetalRuntime(store:s,runner:r,capacity:{_ in 0})
            expect(!success(start(t,b)),"low disk blocked")
            expect(!r.list().contains{$0.arguments == ["wineboot","-u"]},"low disk never invokes Wine")
        }
        do {
            let (s,b,r,t)=try fixture(temp.appendingPathComponent("foreign"))
            let prefix=s.isolatedRoot.appendingPathComponent("prefix")
            try put(Data("user data".utf8),prefix.appendingPathComponent("keep"))
            expect(!success(start(t,b)),"unowned existing prefix refused")
            expect(!r.list().contains{$0.arguments == ["wineboot","-u"]},"unowned prefix never invokes Wine")
            expect(try Data(contentsOf:prefix.appendingPathComponent("keep")) == Data("user data".utf8),"unowned data preserved")
        }
        do {
            let (s,b,r,t)=try fixture(temp.appendingPathComponent("fifo"))
            try fm.createDirectory(at:s.isolatedRoot,withIntermediateDirectories:true)
            expect(mkfifo(s.isolatedRoot.appendingPathComponent(".prepare.lock").path,0o600) == 0,"fixture lock FIFO")
            expect(!success(start(t,b)),"FIFO lock rejected without blocking")
            expect(!r.list().contains{$0.arguments == ["wineboot","-u"]},"invalid lock prevents Wine")
        }
        do {
            let (s,b,r,t)=try fixture(temp.appendingPathComponent("cancel"));r.mode = .hold
            var first:Result<PlaymeltRuntimeDescriptor,Error>?,second:Result<PlaymeltRuntimeDescriptor,Error>?
            t.start(base:b,progress:{_ in},completion:{first=$0})
            until {r.list().contains{$0.arguments == ["wineboot","-u"]}}
            t.start(base:b,progress:{_ in},completion:{second=$0})
            until {second != nil};expect(!success(second!),"double start rejected")
            t.cancel();until {first != nil}
            expect(!success(first!) && t.snapshot(base:b)["status"] as? String == "cancelled","cancel is not ready")
            expect(!r.cleanupSawCancellation && r.list().contains{$0.arguments == ["-w"]},"cleanup ignores cancellation but remains scoped")
            expect(fm.fileExists(atPath:s.isolatedRoot.appendingPathComponent("prefix").path),"partial owned prefix retained")
            r.mode = .success;expect(success(start(t,b)),"owned partial prefix can be retried explicitly")
        }
        do {
            let (_,b,r,t)=try fixture(temp.appendingPathComponent("shutdown"));r.mode = .hold
            var completed=false,stopped=false
            t.start(base:b,progress:{_ in},completion:{_ in completed=true})
            until {r.list().contains{$0.arguments == ["wineboot","-u"]}}
            t.shutdown {stopped=true};until {stopped}
            expect(completed && r.list().contains{$0.arguments == ["-w"]},"shutdown waits for cleanup and completion")
            expect(!success(start(t,b)),"closed runtime refuses resurrection")
        }
        do {
            let (s,b,r,t)=try fixture(temp.appendingPathComponent("mutation"));r.mode = .mutate
            r.mutate={try put(pe()+Data([1]),s.root.appendingPathComponent("payload/wine/x86_64-windows/d3d12.dll"))}
            expect(!success(start(t,b)),"mid-prepare file mutation rejected")
            expect(!fm.fileExists(atPath:s.isolatedRoot.appendingPathComponent("prefix-ready.json").path),"mutation never receives ready receipt")
        }
        // Explicitly authorized CPU-only native supervisor test. No Wine or GPU.
        // This shell ignores TERM and emits continuously; only its own spawn group
        // is killed and its exact leader is reaped by the supervisor.
        let pidFile=temp.appendingPathComponent("writer.pid"), native=D3DMetalProcessRunner()
        let command=D3DMetalCommand(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do printf '0123456789012345678901234567890123456789012345678901234567890123456789'; done","fixture",pidFile.path],environment:["PATH":"/usr/bin:/bin"],timeout:0.15)
        let startTime=ProcessInfo.processInfo.systemUptime
        rejects("continuous output obeys timeout"){_=try native.run(command,cancelled:{false})}
        expect(ProcessInfo.processInfo.systemUptime-startTime < 3,"continuous writer cannot starve timeout")
        let pid=Int32(try String(contentsOf:pidFile,encoding:.utf8))!
        expect(kill(pid,0) == -1 && errno == ESRCH,"exact native child reaped without zombie")
        print("D3DMetalRuntime tests: \(checks) PASS; mock Wine only, one bounded CPU output-supervisor test; no GPU/game/client.")
    }
}
