import Foundation
import Darwin

final class CacheMergeRunner: OwnedProcessRunning {
    let lock = NSLock()
    var title = "Bravo GOG", second = "20", registered = false, calls = 0
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func configure(title: String? = nil, second: String? = nil, registered: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let title { self.title = title }; if let second { self.second = second }; if let registered { self.registered = registered }
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        if cancelled() { throw OwnedProcessError.cancelled }
        lock.lock(); let title = title, second = second, registered = registered; calls += 1; lock.unlock()
        let query = request.arguments.last ?? ""
        let rows: [[String: Any]]
        if query.contains("AS titleJson") {
            rows = ["10", second].map { id in
                ["releaseKey":"gog_" + id,"titleJson":"{\"title\":\"\(id == "10" ? title : "Charlie GOG")\"}",
                 "imagesJson":"{\"background\":\"https://images.gog-statics.com/fixture.jpg\",\"verticalCover\":\"https://images.gog-statics.com/portrait.jpg\"}"]
            }
        } else if query.contains("FROM InstallProductJobs") { rows = [] }
        else {
            rows = registered ? [["productId":"10","platform":"osx","baseProductId":"10","installDirectory":directory.lastPathComponent,
                "manifestBuild":"123","productCount":1,"installationPath":directory.path,"buildId":"123","installationId":"41",
                "registered":1,"catalogProduct":1]] : []
        }
        return .init(output: try JSONSerialization.data(withJSONObject: rows), exitCode: 0, pid: 0, handedOff: false)
    }
}

struct FixtureSavedLibrary { var accountID: String, games: [[String:Any]], updatedAt: String }
struct LibraryScanSnapshot {
    var generation: UInt64, requestedAccountID: String, selectedAccountID: String
    var steamGames: [Game], epicInstalledGames: [Game]
    var runtimes: [String] = [], accounts: [String] = [], metadata: [String:String] = [:]
    var runtimeAvailability: [String:Bool] = [:], metrics = 0, launchPreflights: [String:String] = [:]
    var savedLibrary: FixtureSavedLibrary? = nil
}
struct FixtureXbox { var entries: [Game]; func games() -> [Game] { entries } }
struct FixtureRuntime { func descriptor() -> Int { 0 } }
struct FixtureD3D { func descriptor(base: Int) throws -> Int { base } }

/// Only dependencies are inert. applyScan is extracted verbatim from Core.swift
/// by the runner, rather than reimplementing the production merge algorithm.
final class FixtureModel {
    let gogConnector: GOGConnector
    var scanGeneration: UInt64 = 0, selectedAccountID = "fixture-account"
    var games: [Game] = [], runtimes: [String] = [], accounts: [String] = [], metadata: [String:String] = [:]
    var scannedAvailability: [String:Bool] = [:], lastScanMetrics = 0, launchPreflights: [String:String] = [:]
    var authenticatedGames: [String:[[String:Any]]] = [:], authenticatedDates: [String:String] = [:]
    var epicSnapshot: Int? = nil, warnings: [String] = []
    var windowsDescriptor: Int?, d3dMetalDescriptor: Int?
    var xboxConnector: FixtureXbox
    init(_ connector: GOGConnector, xbox: [Game]) { gogConnector = connector; xboxConnector = FixtureXbox(entries:xbox) }
    func makeScanRequest() -> UInt64 { scanGeneration += 1; return scanGeneration }
    func mergeVerified(_ list: [[String:Any]]) { fatalError("Unexpected authenticated fixture") }
    func mergeEpic(_ snapshot: Int) { fatalError("Unexpected authenticated fixture") }
    func updateLibraryStatus() {}
}
final class FixtureScanner {
    var requests: [UInt64] = [], callbacks: [(LibraryScanSnapshot) -> Void] = []
    func scan(_ request: UInt64, completion: @escaping (LibraryScanSnapshot) -> Void) { requests.append(request); callbacks.append(completion) }
    func finish(_ snapshot: LibraryScanSnapshot) { let callback = callbacks.removeFirst(); callback(snapshot) }
}
/// refresh and the GOG callback are extracted verbatim from main.swift.
final class FixtureHandler {
    let model: FixtureModel, libraryScanner = FixtureScanner(), runtimeSetup = FixtureRuntime(), d3dMetalRuntime = FixtureD3D()
    var closing = false, loading = false, scanID: UUID?, afterRefresh: [() -> Void] = []
    var sentStates: [[Game]] = [], epicMerges = 0, gogBeforeFinishMerge: [String] = []
    init(_ model: FixtureModel) { self.model = model }
    func sendState() { sentStates.append(model.games) }
    func mergeManagedEpicInstallations() { epicMerges += 1; gogBeforeFinishMerge = model.games.filter { $0.store == "gog" }.map(\.id).sorted() }
}

@main enum GOGCacheMergeFlowTests {
    static let fm = FileManager.default
    static var checks = 0
    struct Failure: Error { let label: String }
    static func check(_ condition: Bool, _ label: String) throws { checks += 1; if !condition { throw Failure(label:label) } }
    static func until(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005)) }
        try check(condition(), "bounded callback")
    }
    static func game(_ id: String, _ title: String, _ store: String, _ path: URL?, runtime: String = "fixture") -> Game {
        var value = Game(id:id,appId:"10",title:title,store:store,installed:true,platform:store == "xbox" ? "cloud":"windows",
                         runtimeId:runtime,runtimeName:"Fixture runtime",ownership:"fixture-owned",path:path,complete:true)
        value.customImageURL="fixture-image-"+id;value.customPortraitURL="fixture-portrait-"+id
        value.lastPlayed=123;value.installSource="fixture-source";value.supportedPlatforms=[value.platform]
        return value
    }
    static func properties(_ game: Game) -> String {
        [game.id,game.appId,game.title,game.store,String(game.installed),game.platform,game.runtimeId,game.runtimeName,
         game.ownership,game.path?.path ?? "",String(game.complete),game.customImageURL,game.customPortraitURL,
         String(game.lastPlayed),game.installSource,game.supportedPlatforms.joined(separator:",")].joined(separator:"|")
    }
    static func main() throws {
        let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/gog-cache-flow-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let apps=root.appendingPathComponent("Applications"),directory=apps.appendingPathComponent("Registered GOG")
        let app=directory.appendingPathComponent("Fixture.app"),exe=app.appendingPathComponent("Contents/MacOS/Fixture")
        try fm.createDirectory(at:exe.deletingLastPathComponent(),withIntermediateDirectories:true)
        var words:[UInt32]=[0xfeedfacf,0x0100000c,0,2,0,0,0,0]
        try words.withUnsafeMutableBytes{Data($0)}.write(to:exe)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":"Fixture"],format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let database=root.appendingPathComponent("galaxy.db"),jobs=root.appendingPathComponent("jobs.db")
        try Data("inert metadata fixture".utf8).write(to:database);try Data("initial".utf8).write(to:jobs)
        let runner=CacheMergeRunner(directory:directory)
        let observer=GOGInstallObserver(reader:.init(jobsDatabase:jobs,database:database,runner:runner,applicationsRoot:apps))
        let connector=GOGConnector(home:root,databaseURL:database,galaxyApp:root.appendingPathComponent("absent.app"),runner:runner,installObserver:observer)
        defer {
            var done=false;connector.shutdown{done=true};let end=Date().addingTimeInterval(4)
            while !done && Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}
            try?fm.removeItem(at:root)
        }
        try until{connector.availability()["catalogLoaded"] as? Bool == true}
        let steamMac=game("steam:10:mac","Alpha","steam",root.appendingPathComponent("native"),runtime:"steam-mac")
        let steamWindows=game("steam:10:windows","Alpha","steam",root.appendingPathComponent("windows"),runtime:"playmelt-windows")
        let epic=game("epic:10","Delta","epic",root.appendingPathComponent("epic"))
        let xbox=game("xbox:10","Echo","xbox",nil),local=game("local:10","Zulu","local",root.appendingPathComponent("local"))
        let others=[steamMac,steamWindows,epic,xbox,local]
        var old=game("gog:10","Old GOG","gog",root.appendingPathComponent("stale"),runtime:"stale-runtime");old.lastPlayed=777
        let obsolete=game("gog:999","Obsolete GOG","gog",root.appendingPathComponent("old-install"))
        let model=FixtureModel(connector,xbox:[xbox]);model.games=others+[old,obsolete]
        let handler=FixtureHandler(model);handler.attachCurrentGOGCallback()
        connector.onUpdate?()
        try check(handler.libraryScanner.requests.isEmpty,"actual GOG callback does not request a general scan")
        try check(handler.sentStates.count==1,"actual GOG callback emits one state")
        try check(model.games.filter{$0.store != "gog"}.map(properties)==others.map(properties),"all other stores, variants, local paths and properties remain exact")
        try check(model.games.prefix(2).map(\.id)==[steamMac.id,steamWindows.id],"same-title non-GOG ordering is stable")
        try check(!model.games.contains{$0.id==obsolete.id},"obsolete GOG entries are replaced by current cache")
        let fresh=model.games.first{$0.id==old.id}!
        try check(fresh.title=="Bravo GOG" && fresh.lastPlayed==777,"fresh metadata preserves local play history")
        try check(!fresh.installed && !fresh.complete && fresh.path==nil && fresh.runtimeId != "stale-runtime","stale installation evidence is never carried forward")
        let calls=runner.count();for _ in 0..<100{_=connector.mergingLibraryGames(model.games)}
        try check(runner.count()==calls,"cache merge performs no SQL or process work")

        // Start the actual refresh function BEFORE the current-cache event.
        handler.refresh()
        let scanID=handler.scanID
        let snapshot=LibraryScanSnapshot(generation:model.scanGeneration,requestedAccountID:model.selectedAccountID,selectedAccountID:model.selectedAccountID,
                                         steamGames:[steamMac,steamWindows,local],epicInstalledGames:[epic])
        runner.configure(title:"Bravo GOG revised",second:"30");connector.invalidate()
        try until{model.games.first{$0.id=="gog:10"}?.title=="Bravo GOG revised"}
        try check(handler.libraryScanner.requests.count==1 && handler.scanID==scanID && handler.loading,"cache callback does not restart or invalidate an outstanding full scan")
        handler.libraryScanner.finish(snapshot)
        try check(!handler.loading && handler.epicMerges==1,"actual refresh completion ran")
        try check(handler.gogBeforeFinishMerge==["gog:10","gog:30"],"actual Core.applyScan already reads current GOG cache, not an earlier scan snapshot")
        try check(model.games.filter{$0.store=="gog"}.map(\.id).sorted()==["gog:10","gog:30"],"a late complete scan cannot restore removed GOG entries")
        try check(model.games.first{$0.id=="gog:10"}?.lastPlayed==777,"actual scan junction preserves local GOG history")
        try check(model.games.filter{$0.store != "gog"}.map(properties)==others.map(properties),"scan junction preserves all scanned other-store values")

        runner.configure(registered:true);try Data("registered".utf8).write(to:jobs);observer.refresh()
        try until{model.games.first{$0.id=="gog:10"}?.complete==true}
        let installed=model.games.first{$0.id=="gog:10"}!
        try check(installed.installed,"qualified native installation remains installed")
        try check(installed.path?.path==app.path,"qualified native bundle path remains exact")
        try check(installed.runtimeId=="gog-mac" && installed.lastPlayed==777,"native route and local history are retained without a full scan")
        try check(handler.libraryScanner.requests.count==1,"installation-only update does not rescan other stores")
        runner.configure(registered:false);try Data("registration removed".utf8).write(to:jobs);observer.refresh()
        try until{model.games.first{$0.id=="gog:10"}?.complete==false}
        try check(model.games.first{$0.id=="gog:10"}?.path==nil && model.games.first{$0.id=="gog:10"}?.lastPlayed==777,"lost registration removes stale launch evidence but preserves local history")

        // The real selected-account/scan guards remain active.
        handler.refresh();let stale=LibraryScanSnapshot(generation:model.scanGeneration,requestedAccountID:model.selectedAccountID,selectedAccountID:model.selectedAccountID,steamGames:[steamMac],epicInstalledGames:[])
        model.selectedAccountID="changed-fixture-account";let sent=handler.sentStates.count
        handler.libraryScanner.finish(stale)
        try check(handler.sentStates.count==sent && handler.libraryScanner.requests.count==3,"actual applyScan rejects a stale account and actual refresh requests the current context")
        let current=LibraryScanSnapshot(generation:model.scanGeneration,requestedAccountID:model.selectedAccountID,selectedAccountID:model.selectedAccountID,steamGames:[steamMac,steamWindows,local],epicInstalledGames:[epic])
        handler.libraryScanner.finish(current)
        try check(model.selectedAccountID=="changed-fixture-account" && !handler.loading,"current selected account survives scan completion")
        handler.closing=true;let before=model.games.map(properties);connector.onUpdate?()
        try check(model.games.map(properties)==before,"actual GOG callback observes shutdown guard")
        var stopped=false;connector.shutdown{stopped=true};try until{stopped}
        print("GOG cache/current-flow: \(checks) PASS; actual extracted Core/main functions, inert scanner/metadata/files; no app/client/account/network/game")
    }
}
