import Foundation
import Darwin

#if GOG_CONNECTOR_ISOLATED_TESTS
struct Game {
    var id:String,appId:String,title:String,store:String,installed:Bool,platform:String,runtimeId:String,runtimeName:String,ownership:String
    var path:URL?,complete=false,epicLaunchID="",supportedPlatforms:[String]=[],customImageURL="",customPortraitURL="",lastPlayed:Int64=0,installSource="steam"
}
#endif

private final class FixtureRunner: OwnedProcessRunning {
    private let lock=NSLock()
    private var calls:[OwnedProcessRequest]=[],children:[pid_t]=[]
    func requests()->[OwnedProcessRequest]{lock.lock();defer{lock.unlock()};return calls}
    func pids()->[pid_t]{lock.lock();defer{lock.unlock()};return children}
    func run(_ request:OwnedProcessRequest,cancelled:()->Bool,handoff:()->Bool,onDetachedExit:@escaping(Int32)->Void)throws->OwnedProcessResult {
        lock.lock();calls.append(request);lock.unlock()
        var owned=request;owned.onSpawn={[weak self] pid in self?.lock.lock();self?.children.append(pid);self?.lock.unlock()}
        return try OwnedProcessRunner().run(owned,cancelled:cancelled)
    }
}

@main enum GOGInstallObserverTests {
    static var checks=0
    static let fm=FileManager.default,product="1423049311",build="60152051833789151"
    struct Failure:Error{let message:String}
    static func expect(_ value:Bool,_ message:String)throws{checks+=1;if !value{throw Failure(message:message)}}
    static func until(_ condition:()->Bool)throws{let end=Date().addingTimeInterval(6);while !condition() && Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};try expect(condition(),"bounded asynchronous callback")}
    static func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"''")+"'"}
    static func main()throws {
        let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/gog-install-fixture-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let runner=FixtureRunner();var observers:[GOGInstallObserver]=[],connectors:[GOGConnector]=[]
        defer {
            for c in connectors{var done=false;c.shutdown{done=true};let end=Date().addingTimeInterval(6);while !done && Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
            for o in observers{var done=false;o.shutdown{done=true};let end=Date().addingTimeInterval(6);while !done && Date()<end{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}}
            try?fm.removeItem(at:root)
        }
        let jobs=root.appendingPathComponent("jobs.db"),db=root.appendingPathComponent("galaxy.db"),apps=root.appendingPathComponent("Applications")
        let gameRoot=apps.appendingPathComponent("Cyberpunk 2077"),bundle=gameRoot.appendingPathComponent("Cyberpunk2077.app"),exe=bundle.appendingPathComponent("Contents/MacOS/Cyberpunk2077")
        try fm.createDirectory(at:exe.deletingLastPathComponent(),withIntermediateDirectories:true)
        let info:[String:Any]=["CFBundleExecutable":"Cyberpunk2077","CFBundleIdentifier":"fixture.cyberpunk","CFBundleShortVersionString":"fixture"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:bundle.appendingPathComponent("Contents/Info.plist"))
        var words:[UInt32]=[0xfeedfacf,0x0100000c,0,2,0,0,0,0]
        let native=words.withUnsafeMutableBytes{Data($0)};try native.write(to:exe);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        func sql(_ target:URL,_ text:String)throws {
            var request=OwnedProcessRequest(executable:URL(fileURLWithPath:"/usr/bin/sqlite3"),arguments:[target.path],environment:["PATH":"/usr/bin:/bin"])
            request.input=Data(text.utf8);request.timeout=3
            let result=try runner.run(request,cancelled:{false},handoff:{false},onDetachedExit:{_ in})
            try expect(result.exitCode==0,"fixture SQLite write succeeds")
        }
        try sql(jobs,"""
        CREATE TABLE Jobs(jobId INTEGER PRIMARY KEY,jobType INTEGER,operationPhase INTEGER);
        CREATE TABLE InstallProductJobs(jobId INTEGER,productId INTEGER,gameName TEXT,downloadSize INTEGER,downloadProgress INTEGER,overallDownloadProgress INTEGER);
        CREATE TABLE UpdateProductJobs(jobId INTEGER,productId INTEGER,gameName TEXT,downloadSize INTEGER,isVerifying INTEGER);
        INSERT INTO Jobs VALUES(1,3,10);INSERT INTO InstallProductJobs VALUES(1,\(product),'Cyberpunk 2077',68606283631,0,0);
        CREATE TABLE AuthPrivate(token TEXT);INSERT INTO AuthPrivate VALUES('DO_NOT_EXPORT_AUTH');
        """)
        let manifest="{\"platform\":\"osx\",\"baseProductId\":\"\(product)\",\"buildId\":\"\(build)\",\"installDirectory\":\"Cyberpunk 2077\",\"products\":[{}],\"clientSecret\":\"DO_NOT_EXPORT_SECRET\",\"url\":\"https://fixture.invalid/?token=DO_NOT_EXPORT_URL\"}"
        try sql(db,"""
        CREATE TABLE Manifests(productId INTEGER,manifest TEXT);
        CREATE TABLE InstalledBaseProducts(productId INTEGER,installationPath TEXT,buildId INTEGER,installationId INTEGER);
        CREATE TABLE InstalledProducts(productId INTEGER);
        INSERT INTO Manifests VALUES(\(product),\(quote(manifest)));
        CREATE TABLE Products(id INTEGER,parentId INTEGER);CREATE TABLE LibraryReleases(releaseKey TEXT);CREATE TABLE GamePieces(releaseKey TEXT,gamePieceTypeId INTEGER,value TEXT);
        INSERT INTO LibraryReleases VALUES('gog_\(product)');INSERT INTO GamePieces VALUES('gog_\(product)',186,'{"title":"Catalog title retained"}');
        INSERT INTO GamePieces VALUES('gog_\(product)',98,'{"background":"https://images.gog-statics.com/fixture.jpg"}');
        """)
        let reader=GOGInstallMetadataReader(jobsDatabase:jobs,database:db,runner:runner,applicationsRoot:apps)
        let ghost=root.appendingPathComponent("Library/Application Support/GOG.com/Galaxy/Applications/53652320436400298/opaque-client-fixture")
        try fm.createDirectory(at:ghost.deletingLastPathComponent(),withIntermediateDirectories:true)
        let opaque=Data("client data stays untouched".utf8);try opaque.write(to:ghost)
        let observer=GOGInstallObserver(reader:reader,interval:0.25);observers.append(observer)
        let connector=GOGConnector(home:root,databaseURL:db,galaxyApp:root.appendingPathComponent("absent.app"),runner:runner,installObserver:observer);connectors.append(connector)
        var libraryUpdates=0,progressUpdates=0;connector.onUpdate={libraryUpdates+=1};connector.onInstallUpdate={progressUpdates+=1}
        try until{connector.availability()["catalogLoaded"] as? Bool == true}
        try expect(!connector.games().contains{$0.appId=="53652320436400298"} && (try? Data(contentsOf:ghost))==opaque,"phantom client wrapper is absent from catalog while all client bytes are preserved")
        let originalLibraryUpdates=libraryUpdates
        connector.startInstallObservation();try until{connector.installationJobs().count==1}
        var snapshot=connector.installationJobs()[0];let stableID=snapshot["id"] as! String
        try expect(stableID=="gog:\(product):1" && snapshot["gameId"] as? String == "gog:\(product)","observed Galaxy job keeps actual product/job identity")
        try expect(snapshot["status"] as? String == "installing" && snapshot["platform"] as? String == "mac","phase10 is not invented as network downloading; OSX platform is explicit")
        try expect(snapshot["bytesDownloaded"] is NSNull && snapshot["progress"] is NSNull && (snapshot["bytesTotal"] as? NSNumber)?.uint64Value==68606283631,"unqualified persisted zero becomes unknown while exact total is retained")
        try expect(snapshot["cancellable"] as? Bool == false && snapshot["autoLaunch"] as? Bool == false && connector.nativeLaunchURL(gameID:"gog:"+product)==nil,"partial bundle and active job never authorize native launch or cancellation")
        try expect(libraryUpdates==originalLibraryUpdates && progressUpdates>0,"progress notification alone never refreshes the catalog")
        let requestCount=runner.requests().count
        for _ in 0..<100{_=connector.games();_=connector.installationJobs();_=connector.nativeLaunchURL(gameID:product);observer.refresh()}
        let quiet=Date().addingTimeInterval(0.4);while Date()<quiet{_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}
        try expect(runner.requests().count==requestCount,"cached getters and unchanged DB/WAL signatures perform no SQL loops")
        try sql(jobs,"UPDATE InstallProductJobs SET downloadProgress=2400000000,overallDownloadProgress=9999;")
        let progressBefore=progressUpdates;observer.refresh();try until{progressUpdates>progressBefore}
        try expect(connector.installationJobs()[0]["bytesDownloaded"] is NSNull,"nonzero unqualified persisted progress is never relabeled as live bytes")
        try sql(db,"INSERT INTO InstalledBaseProducts VALUES(\(product),\(quote(gameRoot.path)),\(build),41);INSERT INTO InstalledProducts VALUES(\(product));")
        let activeRead=try reader.read(cancelled:{false})
        try expect(activeRead.installations[product] != nil,"registered installation path is independently observed")
        observer.refresh();try until{observer.installations()[product] != nil}
        let updatesBeforeCompletion = libraryUpdates
        try expect(connector.nativeLaunchURL(gameID:product)==nil,"an active installation still blocks the cached native launch URL")
        try sql(jobs,"DELETE FROM InstallProductJobs;DELETE FROM Jobs;")
        observer.refresh();try until{connector.installationJobs().first?["status"] as? String == "launch-ready"}
        try expect(libraryUpdates > updatesBeforeCompletion,"completion refreshes launch/removal capabilities even when the registered directory stays unchanged")
        snapshot=connector.installationJobs()[0]
        try expect(snapshot["id"] as? String == stableID && snapshot["progress"] is NSNull,"completed local registration preserves observed job history without a fake completed percentage")
        try expect(connector.nativeLaunchURL(gameID:"gog:"+product)?.path==bundle.path,"native launch URL is the verified app bundle, not the game folder")
        try expect(connector.verifiedInstallationDirectory(gameID:"gog:"+product)?.path==gameRoot.path,"verified installation directory is exactly the registered publisher root")
        let merged=connector.games().first{$0.appId==product}
        try expect(merged?.path?.path==bundle.path && merged?.complete==true && merged?.runtimeId=="gog-mac","registry overlays the real native path and completion")
        try expect(merged?.title=="Catalog title retained" && merged?.customImageURL.contains("fixture.jpg")==true,"local catalog title and art survive registry merge")
        try expect(connector.availability()["authenticated"] as? Bool == false && connector.availability()["sessionVerified"] as? Bool == false,"metadata never proves OAuth or reads credentials")
        let hidden=exe.deletingLastPathComponent().appendingPathComponent("temporarily-absent")
        try fm.moveItem(at:exe,to:hidden);observer.refresh();try until{connector.nativeLaunchURL(gameID:product)==nil}
        try expect(connector.verifiedInstallationDirectory(gameID:product)==nil && connector.installationJobs().first?["status"] as? String == "waiting","unchanged database cannot keep a removed executable ready")
        try fm.moveItem(at:hidden,to:exe);observer.refresh();try until{connector.nativeLaunchURL(gameID:product) != nil}
        let fresh=GOGInstallObserver(reader:reader);observers.append(fresh);fresh.start();try until{fresh.snapshots().count==1}
        let registration=fresh.snapshots()[0]
        try expect(registration["id"] as? String == "gog:\(product):installed-41" && (registration["provenance"] as? [String:Any])?["kind"] as? String == "galaxy-installed-registration","cold start records installation provenance without inventing an earlier download job")
        try expect(registration["bytesTotal"] is NSNull && registration["bytesDownloaded"] is NSNull,"cold-start installation does not invent transferred bytes")
        let serialized=String(data:try JSONSerialization.data(withJSONObject:connector.installationJobs()),encoding:.utf8)!
        try expect(!serialized.contains("DO_NOT_EXPORT") && !serialized.contains(root.path),"snapshot contains no secret, signed URL or private source path")
        let reads=runner.requests().filter{$0.arguments.first=="-readonly"}
        try expect(!reads.isEmpty && reads.allSatisfy{$0.arguments.prefix(5)==["-readonly","-batch","-init","/dev/null","-json"]},"every observed query is readonly and ignores user init scripts")
        try expect(reads.allSatisfy{let q=$0.arguments.last ?? "";return !q.contains("clientSecret") && !q.contains("AuthPrivate") && !q.contains("SELECT manifest")},"SQL allowlist never selects full manifest or auth data")
        let before=try Data(contentsOf:db);_=try reader.read(cancelled:{false});try expect(try Data(contentsOf:db)==before,"readonly query preserves fixture DB bytes")
        try sql(db,"DELETE FROM InstalledProducts;");try expect(try reader.read(cancelled:{false}).installations.isEmpty,"missing installed registration cannot become ready")
        try sql(db,"INSERT INTO InstalledProducts VALUES(\(product));UPDATE InstalledBaseProducts SET buildId=99;");try expect(try reader.read(cancelled:{false}).installations.isEmpty,"mismatched build cannot become ready")
        try sql(db,"UPDATE InstalledBaseProducts SET buildId=\(build);")
        try sql(db,"DELETE FROM LibraryReleases;");try expect(try reader.read(cancelled:{false}).installations.isEmpty,"registered native bundle without a catalog product is not qualified")
        try sql(db,"INSERT INTO LibraryReleases VALUES('gog_\(product)');INSERT INTO Products VALUES(\(product),1);")
        try expect(try reader.read(cancelled:{false}).installations.isEmpty,"a DLC/client registration cannot replace a base catalog game")
        try sql(db,"DELETE FROM Products;")
        try Data([0x4d,0x5a]).write(to:exe);try expect(try reader.read(cancelled:{false}).installations.isEmpty,"Windows or incomplete binary is never a native Mac installation")
        try native.write(to:exe)
        let real=exe.deletingLastPathComponent().appendingPathComponent("real");try fm.moveItem(at:exe,to:real);try fm.createSymbolicLink(at:exe,withDestinationURL:real)
        try expect(try reader.read(cancelled:{false}).installations.isEmpty,"symlinked executable is rejected")
        try fm.removeItem(at:exe);try fm.moveItem(at:real,to:exe)
        try sql(jobs,"INSERT INTO Jobs VALUES(2,3,10);INSERT INTO InstallProductJobs VALUES(2,\(product),'Cyberpunk 2077',68606283631,0,0);")
        observer.refresh();try until{connector.installationJobs().contains{$0["id"] as? String == "gog:\(product):2"}}
        try fm.removeItem(at:jobs);observer.refresh();try until{connector.installationJobs().contains{$0["stale"] as? Bool == true}}
        try expect(connector.nativeLaunchURL(gameID:product)==nil && connector.verifiedInstallationDirectory(gameID:product)==nil,"read failure retains history but closes native launch and uninstall paths")
        for o in observers{var stopped=false;o.shutdown{stopped=true};try until{stopped};o.refresh()}
        for c in connectors{var stopped=false;c.shutdown{stopped=true};try until{stopped}}
        for pid in runner.pids(){try expect(kill(pid,0) == -1 && errno == ESRCH,"every owned SQLite process is reaped without a zombie")}
        print("\(checks) GOG installation checks passed; isolated SQLite, inert Mach-O fixtures; no Galaxy/client/game/auth/network operation")
    }
}
