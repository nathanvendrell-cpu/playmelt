import Foundation
import Darwin

/// Read-only locations for the same Wine runtime. The optional game-category
/// wrapper contains copies of the loader; discovering it must never create it.
enum WineExecutableLocations {
    static func processRoots(wine: URL) -> [URL] {
        guard wine.isFileURL else { return [] }
        let bin = wine.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let root: URL?
        if bin.lastPathComponent == "bin", bin.deletingLastPathComponent().lastPathComponent == "engine" {
            root = bin.deletingLastPathComponent().deletingLastPathComponent()
        } else if bin.lastPathComponent == "MacOS", bin.deletingLastPathComponent().lastPathComponent == "Contents",
                  bin.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "PlaymeltGame.app" {
            root = bin.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        } else { root = nil }
        guard let root else { return [bin] }
        return [root.appendingPathComponent("engine"), root.appendingPathComponent("PlaymeltGame.app/Contents/MacOS")]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }
    static func loaderPaths(wine: URL) -> Set<String> {
        guard wine.isFileURL else { return [] }
        let canonical = wine.standardizedFileURL.resolvingSymlinksInPath()
        let directories = processRoots(wine: wine).map { $0.lastPathComponent == "engine" ? $0.appendingPathComponent("bin") : $0 }
        let names = ["wine", "wine64", "wine-preloader", "wine64-preloader"]
        return Set(([canonical] + directories.flatMap { directory in names.map { directory.appendingPathComponent($0) } })
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
    }
}

struct OwnedProcessRequest {
    let executable: URL
    let arguments: [String]
    let environment: [String:String]
    var directory: URL? = nil
    var input = Data()
    var timeout: TimeInterval = 60
    var outputLimit = 65536
    var failOnOverflow = true
    var mergeStandardError = true
    // Wine boot has a separate, prefix-scoped wineserver shutdown. Other bounded
    // workers must not leave helpers behind when their leader finishes.
    var preserveGroupOnSuccess = false
    // Handoff processes use /dev/null from birth, so releasing observation cannot
    // break a user's client with SIGPIPE. No credentials/input are allowed here.
    var allowsHandoff = false
    var onSpawn: ((pid_t) -> Void)? = nil
    var idlePollInterval: TimeInterval = 0.1
    var terminationGracePeriod: TimeInterval = 0.25
}
struct OwnedProcessResult {
    let output: Data
    let exitCode: Int32
    let pid: pid_t
    let handedOff: Bool
}
enum OwnedProcessError: LocalizedError {
    case cancelled, timedOut, outputLimit, inputClosed, supervision, spawn(Int32)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Opération annulée."
        case .timedOut: return "Le processus a dépassé le délai autorisé."
        case .outputLimit: return "La sortie du processus dépasse la limite autorisée."
        case .inputClosed: return "Le processus n’a pas accepté les données d’entrée."
        case .supervision: return "La supervision du processus n’a pas pu être confirmée."
        case .spawn(let code): return "Le processus n’a pas pu démarrer (\(code))."
        }
    }
}
protocol OwnedProcessRunning {
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult
}
extension OwnedProcessRunning {
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool) throws -> OwnedProcessResult {
        try run(request,cancelled:cancelled,handoff:{false},onDetachedExit:{_ in})
    }
}
final class OwnedOperationToken {
    private let lock=NSLock()
    private var value=false
    var isCancelled: Bool { lock.lock();defer{lock.unlock()};return value }
    func cancel() { lock.lock();value=true;lock.unlock() }
}

/// Bounded stdin/stdout multiplexing on one worker thread. No blocking pipe
/// reader/writer, shell interpolation, payload logs or global process signals.
final class OwnedProcessRunner: OwnedProcessRunning {
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        guard request.timeout > 0, request.timeout.isFinite, request.outputLimit >= 0,
              request.idlePollInterval >= 0.005, request.idlePollInterval <= 0.25,
              request.terminationGracePeriod >= 0.25, request.terminationGracePeriod <= 10,
              request.input.count <= 1024*1024, !request.allowsHandoff || request.input.isEmpty else { throw OwnedProcessError.supervision }
        if cancelled() { throw OwnedProcessError.cancelled }
        var outputFD:[Int32]=[-1,-1], inputFD:[Int32]=[-1,-1]
        defer { for fd in outputFD + inputFD where fd >= 0 { close(fd) } }
        let captures = !request.allowsHandoff && request.outputLimit > 0
        if captures { guard pipe(&outputFD)==0 else { throw OwnedProcessError.supervision } }
        if !request.input.isEmpty {
            guard socketpair(AF_UNIX,SOCK_STREAM,0,&inputFD)==0 else { throw OwnedProcessError.supervision }
            var yes:Int32=1
            guard setsockopt(inputFD[1],SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))==0 else { throw OwnedProcessError.supervision }
        }
        for fd in outputFD + inputFD where fd >= 0 { guard fcntl(fd,F_SETFD,FD_CLOEXEC)==0 else { throw OwnedProcessError.supervision } }
        if captures { guard fcntl(outputFD[0],F_SETFL,O_NONBLOCK)==0 else { throw OwnedProcessError.supervision } }
        if inputFD[1] >= 0 { guard fcntl(inputFD[1],F_SETFL,O_NONBLOCK)==0 else { throw OwnedProcessError.supervision } }
        var actions:posix_spawn_file_actions_t?, attributes:posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions)==0 else { throw OwnedProcessError.supervision }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes)==0 else { throw OwnedProcessError.supervision }
        defer { posix_spawnattr_destroy(&attributes) }
        var setup=[posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP)),posix_spawnattr_setpgroup(&attributes,0)]
        if let directory=request.directory {
            if #available(macOS 26, *) { setup.append(posix_spawn_file_actions_addchdir(&actions,directory.path)) }
            else { setup.append(Self.legacyChdir(&actions,directory.path)) }
        }
        if inputFD[0] >= 0 { setup.append(posix_spawn_file_actions_adddup2(&actions,inputFD[0],STDIN_FILENO)) }
        else { setup.append(posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0)) }
        if captures { setup.append(posix_spawn_file_actions_adddup2(&actions,outputFD[1],STDOUT_FILENO)) }
        else { setup.append(posix_spawn_file_actions_addopen(&actions,STDOUT_FILENO,"/dev/null",O_WRONLY,0)) }
        if captures && request.mergeStandardError { setup.append(posix_spawn_file_actions_adddup2(&actions,outputFD[1],STDERR_FILENO)) }
        else { setup.append(posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0)) }
        for fd in outputFD + inputFD where fd >= 0 { setup.append(posix_spawn_file_actions_addclose(&actions,fd)) }
        guard setup.allSatisfy({$0==0}) else { throw OwnedProcessError.supervision }
        var argv=([request.executable.path]+request.arguments).map{strdup($0)}+[nil]
        var envp=request.environment.keys.sorted().map{strdup($0+"="+request.environment[$0]!)}+[nil]
        defer { for p in argv {free(p)};for p in envp{free(p)} }
        var pid:pid_t=0
        let spawned=posix_spawn(&pid,request.executable.path,&actions,&attributes,&argv,&envp)
        guard spawned==0 else{throw OwnedProcessError.spawn(spawned)}
        request.onSpawn?(pid)
        if outputFD[1]>=0{close(outputFD[1]);outputFD[1] = -1}
        if inputFD[0]>=0{close(inputFD[0]);inputFD[0] = -1}
        var output=Data(),buffer=[UInt8](repeating:0,count:8192),overflow=false,inputOffset=0,inputError=false,eof = !captures
        var reaped=false,detached=false,status:Int32=0,hadIO=false
        // WNOWAIT below pins the group leader until cleanup/reap is complete.
        defer {
            if !reaped && !detached {
                _=kill(-pid,SIGKILL)
                while waitpid(pid,&status,0)<0 && errno==EINTR{}
            }
        }
        func drain() {
            guard captures && !eof else{return}
            for _ in 0..<8 {
                let n=Darwin.read(outputFD[0],&buffer,buffer.count)
                if n==0{eof=true;break};if n<0{break}
                hadIO=true
                let available=max(0,request.outputLimit-output.count)
                if n>available{overflow=true}
                if available>0{output.append(contentsOf:buffer.prefix(min(n,available)))}
            }
        }
        func feed() {
            guard inputFD[1]>=0 else{return}
            for _ in 0..<8 {
                let remaining=request.input.count-inputOffset
                if remaining==0{close(inputFD[1]);inputFD[1] = -1;break}
                let count=request.input.withUnsafeBytes { p in Darwin.write(inputFD[1],p.baseAddress!.advanced(by:inputOffset),min(8192,remaining)) }
                if count>0{inputOffset+=count;hadIO=true;continue}
                if count<0 && errno != EAGAIN && errno != EINTR { inputError=true }
                break
            }
        }
        func abort(_ reason:OwnedProcessError)throws->Never {
            _=kill(-pid,SIGTERM)
            let grace=ProcessInfo.processInfo.systemUptime+request.terminationGracePeriod
            while ProcessInfo.processInfo.systemUptime<grace{drain();Thread.sleep(forTimeInterval:0.01)}
            _=kill(-pid,SIGKILL)
            var waited:pid_t
            repeat{waited=waitpid(pid,&status,0)}while waited<0 && errno==EINTR
            guard waited==pid else{if waited<0 && errno==ECHILD{reaped=true};throw OwnedProcessError.supervision}
            reaped=true;throw reason
        }
        let deadline=ProcessInfo.processInfo.systemUptime+request.timeout
        while true {
            hadIO=false
            drain();feed()
            // Ownership transfer takes priority over a simultaneous hub shutdown.
            if request.allowsHandoff && handoff() {
                DetachedChildReaper.adopt(pid:pid,onExit:onDetachedExit);detached=true
                return .init(output:Data(),exitCode:0,pid:pid,handedOff:true)
            }
            if cancelled(){try abort(.cancelled)}
            if ProcessInfo.processInfo.systemUptime>=deadline{try abort(.timedOut)}
            if overflow && request.failOnOverflow{try abort(.outputLimit)}
            if inputError{try abort(.inputClosed)}
            var info=siginfo_t()
            let observed=waitid(P_PID,id_t(pid),&info,WEXITED|WNOHANG|WNOWAIT)
            if observed<0 {
                if errno==EINTR{continue}
                // ECHILD means another owner reaped the PID. Never signal that
                // possibly reused PID/group; the caller receives no success.
                if errno==ECHILD{reaped=true}
                throw OwnedProcessError.supervision
            }
            if info.si_pid==pid {
                if !request.preserveGroupOnSuccess{_=kill(-pid,SIGKILL)}
                var waited:pid_t
                repeat{waited=waitpid(pid,&status,0)}while waited<0 && errno==EINTR
                guard waited==pid else{if waited<0 && errno==ECHILD{reaped=true};throw OwnedProcessError.supervision}
                reaped=true
                for _ in 0..<4 where !eof {drain()}
                break
            }
            // Drain/feed promptly under backpressure, back off while idle. The
            // interactive installer explicitly uses 250 ms and no captured I/O.
            Thread.sleep(forTimeInterval:hadIO ? 0.005 : request.idlePollInterval)
        }
        if overflow && request.failOnOverflow{throw OwnedProcessError.outputLimit}
        guard inputOffset==request.input.count else{throw OwnedProcessError.inputClosed}
        let code=(status & 0x7f)==0 ? (status>>8)&255 : 128+(status & 0x7f)
        return .init(output:output,exitCode:code,pid:pid,handedOff:false)
    }
    @available(macOS,introduced:10.15,deprecated:26,message:"Compatibility path for macOS 15–25")
    private static func legacyChdir(_ actions:inout posix_spawn_file_actions_t?,_ path:String)->Int32{
        posix_spawn_file_actions_addchdir_np(&actions,path)
    }
}

/// Event-driven reaping only after a user-owned client has been handed off.
/// There is deliberately no cancellation or kill API for these processes.
private enum DetachedChildReaper {
    static let lock=NSLock()
    static var sources:[pid_t:DispatchSourceProcess]=[:]
    static func adopt(pid:pid_t,onExit:@escaping(Int32)->Void){
        let source=DispatchSource.makeProcessSource(identifier:pid,eventMask:.exit,queue:.global(qos:.utility))
        source.setEventHandler{
            var status:Int32=0
            var waited:pid_t
            repeat { waited=waitpid(pid,&status,0) } while waited<0 && errno==EINTR
            let code:Int32 = waited==pid ? ((status & 0x7f)==0 ? (status>>8)&255 : 128+(status & 0x7f)) : 255
            lock.lock();sources.removeValue(forKey:pid);lock.unlock();source.setEventHandler(handler:nil);source.cancel()
            DispatchQueue.main.async{onExit(code)}
        }
        lock.lock();sources[pid]=source;lock.unlock();source.resume()
    }
}

/// User-facing clients are observed, never treated as cancellable workers.
/// Closing the hub silences callbacks; Steam, Epic and games keep running.
final class UserProcessLauncher {
    private let lock=NSLock()
    private var processes:[UUID:Process]=[:]
    private var closed=false
    @discardableResult
    func launch(executable:URL,arguments:[String],environment:[String:String],directory:URL?,onExit:@escaping(Int32)->Void)throws->UUID{
        let process=Process(),id=UUID()
        process.executableURL=executable;process.arguments=arguments;process.environment=environment;process.currentDirectoryURL=directory
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        process.terminationHandler={ [weak self] child in
            DispatchQueue.main.async{
                guard let self else{return}
                self.lock.lock();self.processes[id]=nil;let notify = !self.closed;self.lock.unlock()
                if notify{onExit(child.terminationStatus)}
            }
        }
        lock.lock();defer{lock.unlock()}
        guard !closed else{throw OwnedProcessError.cancelled}
        try process.run();processes[id]=process;return id
    }
    func shutdown(){lock.lock();closed=true;lock.unlock()}
    var activeCount:Int{lock.lock();defer{lock.unlock()};return processes.count}
}
