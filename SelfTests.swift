import Foundation

func runSelfTests() {
    var passed = 0; var failed = 0
    func check(_ label: String, _ test: @autoclosure () -> Bool) { if test() { passed += 1; print("PASS \(label)") } else { failed += 1; print("FAIL \(label)") } }
    do {
        let fm=FileManager.default,root=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("playmelt-steam-plan-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? fm.removeItem(at:root)}
        let wine=root.appendingPathComponent("wine"),prefix=root.appendingPathComponent("prefix")
        try Data("fixture, never executed".utf8).write(to:wine);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:wine.path)
        try fm.createDirectory(at:prefix,withIntermediateDirectories:false)
        let engine=Runtime(id:"playmelt-windows",name:"Fixture",platform:"windows",steamRoot:root,appURL:nil,wineURL:wine,prefixURL:prefix,verifiedIndependentEngine:true)
        check("ready engine installs without Windows Steam",engine.installationAvailable)
        check("Windows Steam dispatch remains unavailable without client",!engine.available)
        let app:[String:Any]=["config":["launch":["0":["executable":"Game.exe","config":["BetaKey":"default"]]]]]
        check("legacy Steam platforms use the published EXE",SteamAppInfo.publishedPlatforms(app)==["windows"])
        check("default public branch is not mistaken for a beta",SteamAppInfo.windowsInstallationIssue(app).isEmpty)
        let privateApp:[String:Any]=["config":["launch":["0":["executable":"Game.exe","config":["BetaKey":"internal"]]]]]
        check("private-only publisher launch stays blocked",!SteamAppInfo.windowsInstallationIssue(privateApp).isEmpty)
        let game=LibraryModel.makeGame("10",ownership:"account-cache",metadata:["10":SteamAppInfo(name:"Fixture",platforms:["windows"],type:"game")],runtimes:[engine])
        check("catalog retains the prepared Windows installation route",game.runtimeId == engine.id && game.json(runtimes:[engine])["canInstall"] as? Bool == true)
        check("uninstalled catalog entry is never launchable",game.json(runtimes:[engine])["canLaunch"] as? Bool == false)
        let windows=root.appendingPathComponent("Windows/bin")
        try fm.createDirectory(at:windows,withIntermediateDirectories:true)
        try Data([0x4d,0x5a]).write(to:windows.appendingPathComponent("Game.exe"))
        var manifest:[String:Any]=["schema":1,"appID":"10","source":"official-steam-console-completion","executable":"bin/Game.exe","workingDirectory":"bin","renderer":"dxmt","arguments":["-publisher","two words","$(not-a-shell-command)"]]
        func writeManifest() throws {try JSONSerialization.data(withJSONObject:manifest).write(to:SteamDepotLaunchManifest.file(root),options:.atomic)}
        try writeManifest()
        check("publisher entry point and arguments survive discovery",SteamDepotLaunchManifest.read(root,appID:"10")?.arguments == manifest["arguments"] as? [String])
        check("publisher receipt cannot cross app identities",SteamDepotLaunchManifest.read(root,appID:"20") == nil)
        manifest["workingDirectory"]="../escape";try writeManifest()
        check("publisher working directory cannot escape",SteamDepotLaunchManifest.read(root,appID:"10") == nil)
        manifest["workingDirectory"]="bin";manifest["executable"]="../outside.exe";try writeManifest()
        check("publisher executable cannot escape",SteamDepotLaunchManifest.read(root,appID:"10") == nil)
        let coordinator=SteamInstallCoordinator()
        let id=coordinator.beginDirect(gameID:"steam:10",appID:"10",title:"Fixture",accountID:"76561198000000001")!
        coordinator.updateDirect(id:id,status:"preparing-engine",message:"Engine",progress:0.8,downloaded:80,total:100,phase:"Moteur")
        coordinator.updateDirect(id:id,status:"downloading",message:"Game",progress:nil,phase:"Téléchargement")
        check("game phase resets engine byte counters",(coordinator.snapshot?["bytesDownloaded"] as? NSNumber)?.uint64Value == 0 && (coordinator.snapshot?["bytesTotal"] as? NSNumber)?.uint64Value == 0)
        check("installation never silently enables automatic play",coordinator.snapshot?["autoLaunch"] as? Bool == false)
        var completionStates:[String]=[]
        coordinator.onChange={completionStates.append(coordinator.snapshot?["status"] as? String ?? "")}
        check("prepared files finish as a separate terminal state",coordinator.finishPrepared(id:id,message:"Prepared"))
        check("prepared completion never emits launch-ready",completionStates == ["files-prepared"] && !coordinator.isActive)
        check("prepared completion cannot authorize automatic play",!coordinator.permitsDirectAutoLaunch(id:id,accountID:"76561198000000001",executionBlocked:false))
        let key=#"HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Valve\Steam\Apps\CommonRedist\vcredist\2022"#
        let component=SteamPrerequisiteCheck(key:key,name:"vc2022x64",minimum:2)
        let reg=prefix.appendingPathComponent("system.reg")
        func registry(_ key:String,_ name:String,_ value:String)throws {
            let section=key.replacingOccurrences(of:#"HKEY_LOCAL_MACHINE\"#,with:"").replacingOccurrences(of:#"\"#,with:#"\\"#)
            try "[\(section)] 0\n\"\(name)\"=dword:\(value)\n".write(to:reg,atomically:true,encoding:.utf8)
        }
        check("missing CommonRedist marker is not a satisfied component",!component.isSatisfied(in:prefix))
        try registry(key.replacingOccurrences(of:#"Wow6432Node\"#,with:""),"vc2022x64","00000002")
        check("native registry view cannot satisfy the WOW view",!component.isSatisfied(in:prefix))
        try registry(key,"vc2022x86","00000002")
        check("x86 marker cannot satisfy an x64 prerequisite",!component.isSatisfied(in:prefix))
        try registry(key,"vc2022x64","00000001")
        check("old prerequisite marker does not satisfy a newer minimum",!component.isSatisfied(in:prefix))
        let descriptor=PlaymeltRuntimeDescriptor(engineID:"fixture",wineURL:wine,wineserverURL:wine,prefixURL:prefix,steamRoot:root,environment:[:],readyEngine:true,steamInstalled:true)
        manifest["executable"]="bin/Game.exe";manifest["prerequisiteChecks"]=[["key":key,"name":"vc2022x64","minimum":2]];manifest["steamClientRequired"]=true
        try writeManifest()
        check("first-start prerequisite blocks launch while its marker is absent",SteamDepotLaunchManifest.read(root,appID:"10")?.preparationIssue(accountID:"76561198000000001",descriptor:descriptor)?.contains("Composants") == true)
        try registry(key,"vc2022x64","00000002")
        check("exact current marker satisfies only its own prerequisite",component.isSatisfied(in:prefix))
        let config=root.appendingPathComponent("config");try fm.createDirectory(at:config,withIntermediateDirectories:true)
        try #""users" { "76561198000000001" { "MostRecent" "1" } }"#.write(to:config.appendingPathComponent("loginusers.vdf"),atomically:true,encoding:.utf8)
        check("real marker and matching Windows account clear known preparation",SteamDepotLaunchManifest.read(root,appID:"10")?.preparationIssue(accountID:"76561198000000001",descriptor:descriptor) == nil)
        check("changing Windows account blocks preparation again",SteamDepotLaunchManifest.read(root,appID:"10")?.preparationIssue(accountID:"76561198000000002",descriptor:descriptor) != nil)
        manifest["preparationTasks"]=[["kind":"official-installscript","message":"Composants à installer par Steam Windows"]];try writeManifest()
        check("pending components still forbid direct EXE execution",SteamDepotLaunchManifest.read(root,appID:"10")?.preparationIssue(accountID:"76561198000000001",descriptor:descriptor) != nil)
        check("pending components do not block their official Steam installer",SteamDepotLaunchManifest.read(root,appID:"10")?.officialClientIssue(accountID:"76561198000000001",descriptor:descriptor) == nil)
        check("official component handoff requires the same connected account",SteamDepotLaunchManifest.read(root,appID:"10")?.officialClientIssue(accountID:"76561198000000002",descriptor:descriptor) != nil)
        let missingClient=PlaymeltRuntimeDescriptor(engineID:"fixture",wineURL:wine,wineserverURL:wine,prefixURL:prefix,steamRoot:root,environment:[:],readyEngine:true,steamInstalled:false)
        check("component handoff never invents an installed Steam client",SteamDepotLaunchManifest.read(root,appID:"10")?.officialClientIssue(accountID:"76561198000000001",descriptor:missingClient) != nil)
        manifest["renderer"]="auto";manifest["preparationTasks"]=[["kind":"graphics-api-unknown","message":"API inconnue"]];try writeManifest()
        check("unknown graphics API remains pending",SteamDepotLaunchManifest.read(root,appID:"10")?.renderer == "auto")
        try SteamDepotLaunchManifest.chooseRenderer("d3dmetal",folder:root,appID:"10")
        check("explicit engine choice clears only the API selection",SteamDepotLaunchManifest.read(root,appID:"10")?.renderer == "d3dmetal" && SteamDepotLaunchManifest.read(root,appID:"10")?.prerequisiteChecks.count == 1)
        try SteamDepotLaunchManifest.chooseRenderer("auto",folder:root,appID:"10")
        check("automatic restores the original unknown API and its pending task after reopening",SteamDepotLaunchManifest.read(root,appID:"10")?.renderer == "auto" && SteamDepotLaunchManifest.read(root,appID:"10")?.preparationTasks.contains(where:{$0.kind == "graphics-api-unknown"}) == true)
        manifest["renderer"]="dxmt";try writeManifest()
        try SteamDepotLaunchManifest.chooseRenderer("d3dmetal",folder:root,appID:"10")
        try SteamDepotLaunchManifest.chooseRenderer("auto",folder:root,appID:"10")
        check("automatic restores an explicit publisher engine instead of the manual override",SteamDepotLaunchManifest.read(root,appID:"10")?.renderer == "dxmt")
        let settingsPath=root.appendingPathComponent("settings").path
        let settingsRoot=URL(fileURLWithPath:settingsPath.hasPrefix("/var/") ? "/private"+settingsPath:settingsPath)
        let settingsGame=GameSettingsContext(id:"steam:10",appID:"10",platform:"windows",installed:true,path:root.path,requiredRenderer:"auto")
        let settings=GameSettingsStore(root:settingsRoot),initial=settings.snapshot(game:settingsGame,hardware:[:],displays:[])
        var draft=initial["settings"] as! [String:Any];draft["backend"]="d3dmetal"
        let saved=settings.save(game:settingsGame,payload:draft,expectedRevision:initial["revision"] as? String,changedFields:["backend"])
        try SteamDepotLaunchManifest.chooseRenderer(GameSettingsStore(root:settingsRoot).requestedBackend(for:settingsGame),folder:root,appID:"10")
        check("saved manual engine survives a reconstructed settings store",saved["status"] as? String == "saved" && SteamDepotLaunchManifest.read(root,appID:"10")?.renderer == "d3dmetal")
        draft["backend"]="auto"
        let automaticSaved=settings.save(game:settingsGame,payload:draft,expectedRevision:saved["revision"] as? String,changedFields:["backend"])
        try SteamDepotLaunchManifest.chooseRenderer(GameSettingsStore(root:settingsRoot).requestedBackend(for:settingsGame),folder:root,appID:"10")
        check("saved automatic survives reopening and clears the manifest override",automaticSaved["status"] as? String == "saved" && SteamDepotLaunchManifest.read(root,appID:"10")?.renderer == "dxmt")
        var flow=SteamOfficialPreparation(gameID:"steam:10",appID:"10",runtimeID:"playmelt-windows",account:"76561198000000001",now:100)
        check("official flow first prepares its missing client",flow.next(selectedAccount:flow.account,steamInstalled:false,activeAccount:nil,now:101) == .prepareClient)
        check("official flow opens first login without consuming the game",flow.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:nil,now:102) == .openLogin)
        flow.loginOpened=true
        check("different Windows account cannot receive the installation",flow.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:"76561198000000002",now:103) == .waitForLogin)
        check("matching login resumes file reuse for the same game",flow.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:flow.account,now:104) == .prepareFiles && flow.appID == "10")
        let secondTitle=SteamOfficialPreparation(gameID:"steam:9000004",appID:"9000004",runtimeID:flow.runtimeID,account:flow.account,now:104)
        check("a second title reuses the existing Windows Steam session",secondTitle.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:flow.account,now:105) == .prepareFiles)
        let anotherTitle=SteamOfficialPreparation(gameID:"steam:9000005",appID:"9000005",runtimeID:flow.runtimeID,account:flow.account,now:104)
        check("session reuse is generic rather than tied to one game",anotherTitle.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:flow.account,now:105) != .openLogin)
        flow.reusePrepared=true
        check("handoff follows the selected app only after reuse preparation",flow.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:flow.account,now:105) == .install("steam://install/10"))
        flow.requestInFlight=true
        check("pending handoff cannot be sent twice",flow.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:flow.account,now:106) == .waitForLogin)
        check("account changes cancel the retained intent",flow.next(selectedAccount:"76561198000000002",steamInstalled:true,activeAccount:flow.account,now:107) == .cancelled)
        check("login retry has a finite lifetime",flow.next(selectedAccount:flow.account,steamInstalled:true,activeAccount:flow.account,now:2000) == .expired)
        let onlyA=SteamPreparationCancellation.decide(preparationOnly:true,requestedGame:"A",pendingGame:"A",currentJobGame:"B")
        check("cancelling preparation A preserves installation B",onlyA.preparation && !onlyA.installationJob)
        let wrong=SteamPreparationCancellation.decide(preparationOnly:true,requestedGame:"B",pendingGame:"A",currentJobGame:"B")
        check("mismatched preparation cancellation has no target",!wrong.preparation && !wrong.installationJob)
        let jobB=SteamPreparationCancellation.decide(preparationOnly:false,requestedGame:nil,pendingGame:"A",currentJobGame:"B")
        check("cancelling installation B preserves pending preparation A",!jobB.preparation && jobB.installationJob)
        let jobA=SteamPreparationCancellation.decide(preparationOnly:false,requestedGame:nil,pendingGame:"A",currentJobGame:"A")
        check("same-game cancellation includes its own preparation",jobA.preparation && jobA.installationJob)
        check("publisher minimum does not force a runtime for an unqualified title",SteamGameLaunchProfile.requiredRenderer(appID:"550") == "auto")
        let fixture=root.appendingPathComponent("Library/Application Support/Playmelt/Games/Fixture-10")
        try fm.createDirectory(at:fixture.appendingPathComponent("Windows/bin"),withIntermediateDirectories:true)
        try Data([0x4d,0x5a]).write(to:fixture.appendingPathComponent("Windows/bin/Game.exe"))
        try "20\n".write(to:fixture.appendingPathComponent("Windows/steam_appid.txt"),atomically:true,encoding:.utf8)
        try "10\n".write(to:fixture.appendingPathComponent("steam_appid.txt"),atomically:true,encoding:.utf8)
        try fm.copyItem(at:SteamDepotLaunchManifest.file(root),to:SteamDepotLaunchManifest.file(fixture))
        let suite="PlaymeltSteamFixture."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        // The test's isolated preference domain and folder are never user data.
        defer{prefs.removePersistentDomain(forName:suite)}
        let fixtureModel=LibraryModel(home:root,preferences:prefs),scanner=LibraryScanner()
        let scanned=scanner.scanSynchronously(fixtureModel.makeScanRequest())
        check("Steam receipt identity wins over an unchanged shared-depot marker",scanned.steamGames.contains(where:{$0.appId == "10" && $0.installSource == "steam-depots"}) && !scanned.steamGames.contains(where:{$0.appId == "20"}))
        check("library discovery preserves the publisher marker bytes",(try? String(contentsOf:fixture.appendingPathComponent("Windows/steam_appid.txt"),encoding:.utf8)) == "20\n")
        scanner.shutdown()
    }catch{check("Steam installation pipeline fixtures",false)}
    do {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-activity-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("activity.json");var time:TimeInterval=1000
        let activity=PlaytimeStore(fileURL:file,clock:{time})
        activity.registerBaseline(key:"fixture",totalSeconds:100)
        check("imported hours do not invent a recent play",activity.lastPlayed(for:"fixture")==0)
        activity.addSession(key:"fixture",seconds:20)
        check("confirmed session records actual play date",activity.lastPlayed(for:"fixture")==1000)
        time=2000;activity.registerBaseline(key:"fixture",totalSeconds:1000)
        check("hours synchronization preserves actual last play",activity.lastPlayed(for:"fixture")==1000)
        check("recent play survives reopen without changing date",PlaytimeStore(fileURL:file).lastPlayed(for:"fixture")==1000)
    }catch{check("activity persistence fixture",false)}
    let missingLocal=Game(id:"local:preflight-fixture",appId:"preflight-fixture",title:"Fixture",store:"local",installed:true,platform:"windows",runtimeId:"",runtimeName:"",ownership:"installed-only",path:URL(fileURLWithPath:"/nonexistent-playmelt-preflight-fixture"),complete:true,installSource:"local")
    let pendingPreflight=missingLocal.json(runtimes:[],launchPreflight:.unchecked(missingLocal))
    check("unscanned local game cannot advertise readiness",pendingPreflight["canLaunch"] as? Bool == false)
    check("unscanned game explains the pending verification",(pendingPreflight["launchBlockReason"] as? String)?.contains("Vérification") == true)
    let workerPreflight=GameLaunchPreflight.inspect(missingLocal,steamAccountID:"")
    check("worker snapshot records the missing game folder",workerPreflight.issue?.contains("introuvable") == true)
    let recordedReady=GameLaunchPreflight(directCandidate:true,issue:nil)
    check("display serialization consumes its worker snapshot without rechecking files",missingLocal.json(runtimes:[],launchPreflight:recordedReady)["canLaunch"] as? Bool == true)
    check("fresh launch preflight still rejects a stale display snapshot",localLaunchBlockReason(for:missingLocal,steamAccountID:"")?.contains("introuvable") == true)
    var loginLifetime = SteamAuthenticationLifetime()
    check("closed sign-in page cannot start capture", loginLifetime.beginCapture() == nil)
    check("sign-in page opens explicitly", loginLifetime.open())
    check("opening alone cannot capture an unfinished document", loginLifetime.beginCapture() == nil)
    let firstNavigation = loginLifetime.navigate()!
    check("first Steam document completed", loginLifetime.navigationFinished(firstNavigation))
    let firstCapture = loginLifetime.beginCapture()!
    check("duplicate sign-in capture is coalesced", loginLifetime.beginCapture() == nil)
    loginLifetime.releasePage()
    check("closing page invalidates pending sign-in result", !loginLifetime.finishCapture(firstCapture) && !loginLifetime.isOpen)
    check("released sign-in page can be reopened", loginLifetime.open())
    let reopenedNavigation = loginLifetime.navigate()!
    check("reopened Steam document completed", loginLifetime.navigationFinished(reopenedNavigation))
    let beforeNavigation = loginLifetime.beginCapture()!
    let nextNavigation = loginLifetime.navigate()!
    check("navigation invalidates previous capture", !loginLifetime.finishCapture(beforeNavigation))
    check("navigation blocks premature capture", loginLifetime.beginCapture() == nil)
    check("new Steam document completed", loginLifetime.navigationFinished(nextNavigation))
    let currentCapture = loginLifetime.beginCapture()!
    check("only current sign-in capture can finish", loginLifetime.finishCapture(currentCapture))
    check("one capture can finish only once", !loginLifetime.finishCapture(currentCapture))
    loginLifetime.shutdown()
    check("app shutdown prevents reopening sign-in page", !loginLifetime.open() && loginLifetime.beginCapture() == nil)
    var cadence = SteamInstallPollingPolicy()
    let pause = SteamInstallObservation(status: "paused", message: "Paused")
    check("paused installation uses slower fallback", cadence.delay(for: pause) == 10)
    check("unchanged pause backs off to thirty seconds", cadence.delay(for: pause) == 30)
    let activeDownload = SteamInstallObservation(status: "downloading", message: "Downloading", downloaded: 1, total: 100)
    check("resumed download returns to responsive cadence", cadence.delay(for: activeDownload) == 2)
    check("unchanged active manifest avoids two-second parsing", cadence.delay(for: activeDownload) == 5)
    let completedDownload = SteamInstallObservation(status: "installing", message: "Ready", ready: true, signature: "build:1")
    check("completion retains a second separated validation", cadence.delay(for: completedDownload) == 2 && cadence.delay(for: completedDownload) == 2)
    let parsed = try? TextVDF.parse("// comment\n\"AppState\" { \"appid\" \"427520\" \"name\" \"A \\\"quoted\\\" game\" \"path\" \"C:\\\\Games\" }")
    check("VDF nested app identifier", parsed?.object("appstate").string("appid") == "427520")
    check("VDF escaped quotes", parsed?.object("AppState").string("name") == "A \"quoted\" game")
    check("VDF escaped path", parsed?.object("AppState").string("path") == "C:\\Games")
    check("VDF truncated rejected", (try? TextVDF.parse("\"x\" { \"y\" \"z\"")) == nil)
    check("VDF orphan close rejected", (try? TextVDF.parse("}")) == nil)
    check("VDF deep nesting rejected", (try? TextVDF.parse(String(repeating: "x { ", count: 60) + String(repeating: "}", count: 60))) == nil)
    check("valid app ID", LibraryModel.validAppID("526870"))
    check("shell injection rejected", !LibraryModel.validAppID("1; touch /tmp/owned"))
    check("URL injection rejected", !LibraryModel.validAppID("1/../../2"))
    check("overflow app ID rejected", !LibraryModel.validAppID("999999999999999999"))
    check("zero app ID rejected", !LibraryModel.validAppID("0"))
    check("Steam host allowed", SteamAuthentication.allowed(URL(string: "https://steamcommunity.com/my/games/")!))
    check("Steam subdomain allowed", SteamAuthentication.allowed(URL(string: "https://store.steampowered.com/login")!))
    check("host suffix attack rejected", !SteamAuthentication.allowed(URL(string: "https://steamcommunity.com.attacker.example/")!))
    check("prefix spoof rejected", !SteamAuthentication.allowed(URL(string: "https://evilsteamcommunity.com/")!))
    check("HTTP rejected", !SteamAuthentication.allowed(URL(string: "http://steamcommunity.com/")!))
    check("file rejected", !SteamAuthentication.allowed(URL(string: "file:///tmp/index.html")!))
    check("Steam credential URL rejected", !SteamAuthentication.allowed(URL(string: "https://user:pass@steamcommunity.com/")!))
    check("Steam alternate port rejected", !SteamAuthentication.allowed(URL(string: "https://steamcommunity.com:9443/")!))
    check("artwork ID accepted", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520")!) == "427520")
    check("artwork host rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://attacker/427520")!) == nil)
    check("artwork traversal rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520/../../secret")!) == nil)
    check("artwork query rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520?path=secret")!) == nil)
    check("portrait artwork accepted", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520/portrait")!) == "427520")
    check("unknown artwork variant rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520/secret")!) == nil)
    check("artwork credential URL rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://user@steam/427520")!) == nil)
    let artworkHash = "369aba23e970440c4cee20e332d6ac4fdc2d3ce1"
    let artworkFixture: [String: Any] = ["library_assets_full": ["library_capsule": ["image": ["english": artworkHash + "/library_capsule.jpg"]], "library_header": ["image": ["english": artworkHash + "/library_header.jpg"]]]]
    check("modern portrait metadata selected", SteamAppInfo.artworkPaths(artworkFixture, portrait: true).first == artworkHash + "/library_capsule.jpg")
    check("modern landscape metadata selected", SteamAppInfo.artworkPaths(artworkFixture, portrait: false).first == artworkHash + "/library_header.jpg")
    check("metadata traversal rejected", !SteamAppInfo.validArtworkPath("../library_capsule.jpg"))
    check("metadata encoded traversal rejected", !SteamAppInfo.validArtworkPath("%2e%2e/library_capsule.jpg"))
    check("metadata external URL rejected", !SteamAppInfo.validArtworkPath("https://attacker.example/library_capsule.jpg"))
    check("metadata unrelated image rejected", !SteamAppInfo.validArtworkPath(artworkHash + "/logo.png"))
    check("metadata exact CDN path retained", SteamAppInfo.artworkURL(appID: "4731620", path: artworkHash + "/library_capsule.jpg") == "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/4731620/" + artworkHash + "/library_capsule.jpg")
    let preferenceSuite = "com.robtech.metalmax.selftest.\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName: preferenceSuite)!
    check("render protection is retired: off by default", !RenderProtection.enabled(in: prefs))
    prefs.set(true, forKey: RenderProtection.preferenceKey)
    check("render protection is retired: a stored preference cannot block launches", !RenderProtection.enabled(in: prefs))
    prefs.removeObject(forKey: RenderProtection.preferenceKey)
    check("all execution routes are protected", ["launchGame", "installGame", "installAndPlay", "setupD3DMetalRuntime", "installSteamD3DMetal", "openD3DMetalSteam", "setupWindowsRuntime", "installSteamWindows", "openWindowsSteam"].allSatisfy { RenderProtection.blocks($0, enabled: true) })
    check("read and cancel routes remain available during renders", ["refresh", "importD3DMetal", "openSteamLogin", "cancelD3DMetalRuntime", "cancelInstallAndPlay"].allSatisfy { !RenderProtection.blocks($0, enabled: true) })
    check("explicit render protection off releases action gate only", !RenderProtection.blocks("launchGame", enabled: false))
    check("Wine Metal policy preserves Mac execution", WindowsExecutionPolicy.permits(platform: "mac"))
    check("Windows requires a prepared Wine route", !WindowsExecutionPolicy.permits(platform: "windows") && WindowsExecutionPolicy.permits(platform: "windows", hasWine: true))
    check("Wine cannot masquerade as a native runtime", !WindowsExecutionPolicy.permits(platform: "mac", hasWine: true))
    check("authorized Wine Metal routes are no longer prohibited", WindowsExecutionPolicy.legacyActions.isEmpty && WindowsExecutionPolicy.mode == "wine-metal")
    check("Wine Metal policy preserves read import and cancel actions", ["refresh", "importD3DMetal", "syncLibrary", "cancelWindowsRuntime", "cancelD3DMetalRuntime", "cancelInstallAndPlay"].allSatisfy { !WindowsExecutionPolicy.legacyActions.contains($0) })
    if Bundle.main.object(forInfoDictionaryKey:"PlaymeltCommercialAccessEnabled") as? Bool == true,
       Bundle.main.object(forInfoDictionaryKey:"PlaymeltInternalBuild") as? Bool == false {
        check("released client resolves its own Python, Legendary and CA bundle", PortablePythonRuntime.resolve(requireLegendary:true,requireCertificates:true)?.isBundled == true)
    }
    let model = LibraryModel(home: URL(fileURLWithPath: "/nonexistent-metalmax-fixture"), preferences: prefs)
    check("discovery exposes only native Steam without independent engine", model.discoverRuntimes().allSatisfy { $0.id == "steam-mac" && $0.platform == "mac" })
    check("recent Steam account preferred over autologin", activeSteamAccount(["76561198000000000": ["AutoLogin": "1"], "76561198000000001": ["MostRecent": "1"]]) == "76561198000000001")
    check("official Valve bootstrap manifest URL allowed", SteamWindowsBootstrap.allowed(URL(string: "https://cdn.steamstatic.com/client/steam_client_win32")!))
    check("interactive SteamSetup is no longer the automatic route", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!))
    check("untrusted installer URL rejected", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com.evil.example/client/installer/SteamSetup.exe")!))
    check("unexpected Steam executable URL rejected", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/Other.exe")!))
    check("Steam installer query redirect rejected", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe?other=1")!))
    check("Steam disk-full error is not called a network error", SteamWindowsBootstrap.downloadErrorMessage(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).contains("Espace disque"))
    check("Steam network error is actionable", SteamWindowsBootstrap.downloadErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)).contains("réseau"))
    var requestTime: TimeInterval = 10
    let gate = SteamRequestGate(clock: { requestTime })
    let firstRequest = gate.acquire("game")!
    check("duplicate dispatch rejected while pending", gate.acquire("game") == nil)
    requestTime = 20
    check("pending dispatch stays locked until callback", gate.acquire("game") == nil)
    gate.finish("game", token: UUID())
    check("unrelated dispatch callback cannot unlock request", gate.acquire("game") == nil)
    gate.finish("game", token: firstRequest)
    let secondRequest = gate.acquire("game")!
    gate.finish("game", token: firstRequest)
    check("stale callback cannot unlock replacement request", gate.acquire("game") == nil)
    gate.finish("game", token: secondRequest)
    check("rapid repeated completed dispatch is coalesced", gate.acquire("game") == nil)
    requestTime = 23
    check("later explicit dispatch can retry", gate.acquire("game") != nil)
    gate.shutdown()
    check("shutdown refuses every new dispatch", gate.acquire("other") == nil)
    check("Satisfactory launch profile explicitly selects DX11", ScriptHandler.windowsLaunchArguments(appID: "526870") == ["-applaunch", "526870", "-dx11"])
    check("known DX12-only game has no DX11 launch profile", ScriptHandler.windowsLaunchArguments(appID: "2584270") == nil)
    let fixtureRoot = URL(fileURLWithPath: "/nonexistent-playmelt-runtime")
    let dxmtRoute = Runtime(id: "dxmt-fixture", name: "DXMT", platform: "windows", steamRoot: fixtureRoot, appURL: nil)
    var metalRoute = dxmtRoute; metalRoute.renderer = "d3dmetal"
    var previouslyQualified = metalRoute; previouslyQualified.graphicsValidated = true
    let blockedWindowsGame = Game(id: "steam:4711740", appId: "4711740", title: "Beta", store: "steam", installed: true, platform: "windows", runtimeId: previouslyQualified.id, runtimeName: "Legacy", ownership: "fixture", complete: true)
    let blockedWindowsState = blockedWindowsGame.json(runtimes: [previouslyQualified], availability: [previouslyQualified.id: true])
    check("cached availability and graphics flags cannot invent a Wine executable", blockedWindowsState["canLaunch"] as? Bool == false && (blockedWindowsState["installRoutes"] as? [[String: Any]])?.isEmpty == true)
    let nativeRoute = Runtime(id: "native-fixture", name: "Mac", platform: "mac", steamRoot: fixtureRoot, appURL: nil)
    var multiPlatform = blockedWindowsGame; multiPlatform.appId = "12345"; multiPlatform.supportedPlatforms = ["mac", "windows"]
    let macOptions = multiPlatform.json(runtimes: [previouslyQualified, nativeRoute], availability: [previouslyQualified.id: true, nativeRoute.id: true])["installRoutes"] as? [[String: Any]]
    check("complete Windows installation does not block a Mac installation", macOptions?.count == 1 && macOptions?.first?["runtimeId"] as? String == nativeRoute.id && macOptions?.first?["canInstallAndPlay"] as? Bool == true)
    let installedMacOptions = multiPlatform.json(runtimes: [nativeRoute], availability: [nativeRoute.id: true], completedRuntimeIDs: [nativeRoute.id])["installRoutes"] as? [[String: Any]]
    check("other row reporting complete Mac installation prevents duplicate installation", installedMacOptions?.first?["canInstall"] as? Bool == false)
    model.games = [multiPlatform]
    check("installation completion is bound to the requested runtime", model.hasCompleteInstallation(appID: "12345", runtimeID: previouslyQualified.id) && !model.hasCompleteInstallation(appID: "12345", runtimeID: nativeRoute.id))
    check("Mortal Shell cannot install into DXMT", !SteamGameLaunchProfile.supportsInstallation(appID: "2584270", runtime: dxmtRoute))
    check("Mortal Shell installs only into its DX12 route", SteamGameLaunchProfile.supportsInstallation(appID: "2584270", runtime: metalRoute))
    check("Mortal Shell II beta is classified as DirectX12", SteamGameLaunchProfile.requiredGraphicsAPI(appID: "4711740") == "DirectX12")
    check("Mortal Shell II beta cannot install into DXMT", !SteamGameLaunchProfile.supportsInstallation(appID: "4711740", runtime: dxmtRoute))
    check("Mortal Shell II beta has no DX11 fallback launch", SteamGameLaunchProfile.windowsArguments(appID: "4711740", renderer: "dxmt", graphicsValidated: true) == nil)
    check("prepared DX12 permits its first official Steam attempt", SteamGameLaunchProfile.windowsArguments(appID: "4711740", renderer: "d3dmetal") == ["-applaunch", "4711740"])
    check("Satisfactory keeps its DX11 route", !SteamGameLaunchProfile.supportsInstallation(appID: "526870", runtime: metalRoute))
    check("compatibility evidence is not a circular first-launch requirement", SteamGameLaunchProfile.windowsArguments(appID: "2584270", renderer: "d3dmetal") == ["-applaunch", "2584270"])
    check("unprofiled games can attempt their prepared selected route", SteamGameLaunchProfile.windowsArguments(appID: "12345", renderer: "d3dmetal") == ["-applaunch", "12345"])
    check("future qualified DX12 route uses game default API", SteamGameLaunchProfile.windowsArguments(appID: "2584270", renderer: "d3dmetal", graphicsValidated: true) == ["-applaunch", "2584270"])
    check("a qualification flag cannot turn DXMT into DX12", SteamGameLaunchProfile.windowsArguments(appID: "2584270", renderer: "dxmt", graphicsValidated: true) == nil)
    do {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("playmelt-auto-renderer-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:root)}
        func fixture(_ appID:String,_ marker:String?=nil)throws->URL {
            let folder=root.appendingPathComponent(appID),windows=folder.appendingPathComponent("Windows")
            try fm.createDirectory(at:windows,withIntermediateDirectories:true)
            try Data([0x4d,0x5a]).write(to:windows.appendingPathComponent("Game.exe"))
            if let marker {
                let file=windows.appendingPathComponent(marker)
                try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data().write(to:file)
            }
            let raw:[String:Any]=["schema":1,"appID":appID,"source":"official-steam-console-completion",
                "executable":"Game.exe","workingDirectory":"","arguments":[String](),"renderer":"auto",
                "steamClientRequired":true,"gameExecutionVerified":false,
                "preparationTasks":[["kind":"graphics-api-unknown","message":"API unknown"],["kind":"official-installscript","message":"Publisher first start"]]]
            try JSONSerialization.data(withJSONObject:raw).write(to:SteamDepotLaunchManifest.file(folder))
            return folder
        }
        let unknown=try fixture("9000001")
        let fallback=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:unknown,appID:"9000001")
        check("unknown title receives an automatic DX11 candidate",fallback?.renderer=="dxmt")
        check("automatic graphics selection retains official Steam first start",fallback?.requiresOfficialSteam==true && fallback?.preparationTasks.map(\.kind)==["official-installscript"])
        let saved=try Data(contentsOf:SteamDepotLaunchManifest.file(unknown))
        _=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:unknown,appID:"9000001")
        let reopened=try Data(contentsOf:SteamDepotLaunchManifest.file(unknown))
        check("reopening an automatic route does not rewrite its plan",reopened==saved)
        let decoded=try JSONSerialization.jsonObject(with:saved) as! [String:Any]
        check("choosing a candidate never certifies game execution",decoded["gameExecutionVerified"] as? Bool==false)
        let dx12=try fixture("9000002","Engine/Binaries/ThirdParty/D3D12Core.dll")
        let automaticDX12=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:dx12,appID:"9000002",preferredRuntimeID:"playmelt-windows")
        check("local DX12 evidence outranks a generic catalog default",automaticDX12?.renderer=="d3dmetal")
        try SteamDepotLaunchManifest.chooseRenderer("dxmt",folder:dx12,appID:"9000002")
        let manual=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:dx12,appID:"9000002")
        check("automatic setup preserves an explicit advanced override",manual?.renderer=="dxmt")
        try SteamDepotLaunchManifest.chooseRenderer("auto",folder:dx12,appID:"9000002")
        let reevaluated=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:dx12,appID:"9000002")
        check("returning to automatic re-evaluates the real files",reevaluated?.renderer=="d3dmetal")
        let required=try fixture("1903340")
        let requiredChoice=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:required,appID:"1903340",preferredRuntimeID:"playmelt-windows")
        check("required DX12 is repaired automatically from a stale catalog preference",requiredChoice?.renderer=="d3dmetal")
        let invalid=try fixture("9000003")
        do {_=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:invalid,appID:"9000003",preferredRuntimeID:"foreign-engine");check("foreign renderer request rejected",false)}
        catch {check("foreign renderer request rejected",true)}
    } catch {check("automatic renderer filesystem fixtures complete",false)}
    let originalRuntime = PlaymeltRuntimeDescriptor(engineID: "fixture", wineURL: fixtureRoot.appendingPathComponent("wine"), wineserverURL: fixtureRoot.appendingPathComponent("wineserver"), prefixURL: fixtureRoot.appendingPathComponent("dxmt-prefix"), steamRoot: fixtureRoot.appendingPathComponent("Steam"), environment: ["WINEPREFIX": "dxmt-prefix"], readyEngine: true, steamInstalled: false)
    let otherPrefix = PlaymeltRuntimeDescriptor(engineID: originalRuntime.engineID, wineURL: originalRuntime.wineURL, wineserverURL: originalRuntime.wineserverURL, prefixURL: fixtureRoot.appendingPathComponent("d3dmetal-prefix"), steamRoot: originalRuntime.steamRoot, environment: originalRuntime.environment, readyEngine: true, steamInstalled: false)
    let otherOverlay = PlaymeltRuntimeDescriptor(engineID: originalRuntime.engineID, wineURL: originalRuntime.wineURL, wineserverURL: originalRuntime.wineserverURL, prefixURL: originalRuntime.prefixURL, steamRoot: originalRuntime.steamRoot, environment: ["WINEDLLPATH_PREPEND": "other"], readyEngine: true, steamInstalled: false)
    check("installer remains bound to the selected runtime", SteamWindowsBootstrap.sameRuntime(originalRuntime, originalRuntime))
    check("installer refuses prefix change during download", !SteamWindowsBootstrap.sameRuntime(originalRuntime, otherPrefix))
    check("installer refuses overlay change during download", !SteamWindowsBootstrap.sameRuntime(originalRuntime, otherOverlay))
    let unavailableBootstrap = SteamWindowsBootstrap(downloadsRoot: fixtureRoot.appendingPathComponent("downloads"), descriptor: { nil })
    unavailableBootstrap.start()
    check("missing DX12 descriptor cannot fall back to another Steam", !unavailableBootstrap.busy && unavailableBootstrap.snapshot["steamPhase"] as? String == "failed")
    var bootstrapStopped = false
    unavailableBootstrap.shutdown { bootstrapStopped = true }
    let bootstrapDeadline = Date().addingTimeInterval(2)
    while !bootstrapStopped && Date() < bootstrapDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    check("unused Steam bootstrap shutdown completes without a process", bootstrapStopped && !unavailableBootstrap.busy)
    check("injected game launch args rejected", ScriptHandler.windowsLaunchArguments(appID: "526870 -exec anything") == nil)
    model.selectedAccountID = "76561198000000000"
    check("account mismatch rejected", !model.acceptAuthenticatedLibrary(accountID: "76561198000000001", list: [["appid": "427520", "name": "Factorio"]]))
    check("invalid game data rejected", !model.acceptAuthenticatedLibrary(accountID: "76561198000000000", list: [["appid": "bad", "name": "test"]]))
    check("mismatch never imports", model.authenticatedGames.isEmpty)
    let bad = Game(id: "test", appId: "1", title: "Test", store: "steam", installed: true, platform: "windows", runtimeId: "missing", runtimeName: "Missing", ownership: "installed-only", path: nil, complete: true)
    check("unavailable runtime cannot launch", bad.json(runtimes: [])["canLaunch"] as? Bool == false)
    check("installed game cannot install", bad.json(runtimes: [])["canInstall"] as? Bool == false)
    model.games = [Game(id: "epic-owned:one", appId: "one", title: "Owned", store: "epic", installed: false, platform: "mac", runtimeId: "epic-mac", runtimeName: "Epic", ownership: "authenticated-library")]
    model.epicSnapshot = EpicSnapshot(accountId: "fixture", displayName: "Fixture", games: [["appName": "one"]], installed: [], source: "fixture", updatedAt: "2026-10-24T00:00:00Z")
    model.epicAvailability = ["authenticated": true, "accountId": "fixture", "sessionVerified": true]
    check("owned Epic game not counted as installed", (model.state()["epic"] as? [String: Any])?["installedCount"] as? Int == 0)
    check("failed Epic refresh leaves snapshot status", (model.state()["epic"] as? [String: Any])?["status"] as? String == "snapshot")
    model.epicSnapshotFresh = true
    check("fresh authenticated Epic snapshot synced", (model.state()["epic"] as? [String: Any])?["status"] as? String == "synced")
    model.epicAvailability = ["authenticated": true, "accountId": "fixture", "sessionVerified": false]
    check("restored Epic credentials alone never verify a cached library", (model.state()["epic"] as? [String: Any])?["status"] as? String == "snapshot")
    model.epicAvailability = ["authenticated": true, "accountId": "another-account", "sessionVerified": true]
    check("Epic snapshot from another account is never current", (model.state()["epic"] as? [String: Any])?["status"] as? String == "snapshot")
    model.epicAvailability = ["authenticated": false]
    check("expired Epic session never synced", (model.state()["epic"] as? [String: Any])?["status"] as? String == "snapshot")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("metalmax-selftest-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cache = temporary.appendingPathComponent("cache")
        let fixtureHome = temporary.appendingPathComponent("home")
        let loginConfig = fixtureHome.appendingPathComponent("Library/Application Support/Steam/config")
        try FileManager.default.createDirectory(at: loginConfig, withIntermediateDirectories: true)
        try "\"users\" { \"76561198000000000\" { \"PersonaName\" \"Fixture\" \"MostRecent\" \"1\" } }".write(to: loginConfig.appendingPathComponent("loginusers.vdf"), atomically: true, encoding: .utf8)
        let authenticated = LibraryModel(home: fixtureHome, preferences: prefs)
        do {
            let domain = "Playmelt.DiscoveryTests." + UUID().uuidString
            let discoveryPreferences = UserDefaults(suiteName: domain)!
            defer { discoveryPreferences.removePersistentDomain(forName: domain) }
            let discovery = LibraryModel(home: fixtureHome, preferences: discoveryPreferences)
            discovery.selectedAccountID = ""
            let discoveredID = "76561198000000000"
            let rows: [[String: Any]] = [["appid": "427520", "name": "Factorio"]]
            check("Steam discovery requires explicit opt-in", !discovery.acceptAuthenticatedLibrary(accountID: discoveredID, list: rows))
            check("invalid discovery leaves selection and preferences unchanged", !discovery.acceptAuthenticatedLibrary(accountID: discoveredID, list: [["appid": "bad", "name": "bad"]], allowAccountDiscovery: true) && discovery.selectedAccountID.isEmpty && discoveryPreferences.string(forKey: "selectedSteamAccount") == nil)
            check("verified first Steam account can be discovered", discovery.acceptAuthenticatedLibrary(accountID: discoveredID, list: rows, source: "steamcommunity-profile-gameslist", allowAccountDiscovery: true))
            check("discovered account selection persists", discovery.selectedAccountID == discoveredID && discoveryPreferences.string(forKey: "selectedSteamAccount") == discoveredID && discovery.accounts.contains(where: { $0.id == discoveredID }))
            check("discovery cannot replace a selected account", !discovery.acceptAuthenticatedLibrary(accountID: "76561198000000001", list: rows, allowAccountDiscovery: true) && discovery.selectedAccountID == discoveredID)
            let reopened = LibraryModel(home: fixtureHome, preferences: discoveryPreferences)
            check("reopening remembers selection without claiming a live Steam login", reopened.selectedAccountID == discoveredID && reopened.liveAuthenticatedAccounts.isEmpty)
        }
        authenticated.selectedAccountID = "76561198000000000"
        check("empty Steam library cannot overwrite a snapshot", !authenticated.acceptAuthenticatedLibrary(accountID: authenticated.selectedAccountID, list: []))
        check("duplicate Steam ownership entries rejected", !authenticated.acceptAuthenticatedLibrary(accountID: authenticated.selectedAccountID, list: [["appid":"427520","name":"A"],["appid":"427520","name":"B"]]))
        check("modern Steam source accepted for matching account", authenticated.acceptAuthenticatedLibrary(accountID: authenticated.selectedAccountID, list: [["appid":"427520","name":"Factorio"]], source: "steamcommunity-profile-gameslist") && authenticated.libraryStatus == "synced")
        authenticated.beginSteamLibrarySync()
        check("new sync invalidates stale connected status", authenticated.libraryStatus == "snapshot" && authenticated.authenticatedGames[authenticated.selectedAccountID]?.count == 1 && authenticated.liveAuthenticatedAccounts.isEmpty)
        let verified180: [[String: Any]] = (0..<180).map { ["appid": String(1000 + $0), "name": "Game \($0)"] }
        authenticated.games = (0..<195).map { authenticated.makeGame(String(1000 + $0), ownership: "account-cache") }
        authenticated.mergeVerified(verified180)
        check("180 verified games replace 195 historical cards", authenticated.games.count == 180 && authenticated.games.allSatisfy { $0.ownership == "authenticated-library" })
        var otherInstalled = authenticated.makeGame("1194", ownership: "authenticated-library"); otherInstalled.installed = true
        authenticated.games.append(otherInstalled); authenticated.mergeVerified(verified180)
        check("unowned local installation preserved without ownership claim", authenticated.games.count == 181 && authenticated.games.first(where: { $0.appId == "1194" })?.ownership == "installed-only")
        let bootstrap = SteamWindowsBootstrap(runtime: RuntimeSetup(root: temporary.appendingPathComponent("runtime")))
        let staleSession = URLSession(configuration: .ephemeral)
        let staleTask = staleSession.downloadTask(with: URL(string: "https://example.invalid/never-requested")!)
        defer { staleTask.cancel(); staleSession.invalidateAndCancel() }
        bootstrap.urlSession(staleSession, downloadTask: staleTask, didWriteData: 70_000_000, totalBytesWritten: 70_000_000, totalBytesExpectedToWrite: 70_000_000)
        bootstrap.urlSession(staleSession, downloadTask: staleTask, didFinishDownloadingTo: temporary.appendingPathComponent("must-not-open"))
        bootstrap.urlSession(staleSession, task: staleTask, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        check("stale download callbacks cannot mutate or restart bootstrap", bootstrap.snapshot["steamPhase"] as? String == "idle" && !bootstrap.busy)
        let imageDirectory = cache.appendingPathComponent("4731620").appendingPathComponent(artworkHash)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let capsule = imageDirectory.appendingPathComponent("library_capsule.jpg")
        try Data([0xff,0xd8,0xff,0xd9]).write(to: capsule)
        let info = SteamAppInfo(name: "Fixture", platforms: ["macos"], type: "game", portraitAssets: [artworkHash + "/library_capsule.jpg"], landscapeAssets: [])
        let candidates = SteamArtworkHandler.candidateFiles(root: cache, appID: "4731620", info: info, portrait: true)
        check("hashed local capsule resolved before legacy paths", candidates.first == capsule.resolvingSymlinksInPath())
        check("hashed local capsule exists", candidates.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        let otherApp = cache.appendingPathComponent("999")
        try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: true)
        let unsafeHash = String(repeating: "a", count: 40)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("4731620").appendingPathComponent(unsafeHash), withDestinationURL: otherApp)
        let unsafeInfo = SteamAppInfo(name: "Fixture", platforms: [], type: "game", portraitAssets: [unsafeHash + "/library_capsule.jpg"])
        check("artwork symlink into another game rejected", !SteamArtworkHandler.candidateFiles(root: cache, appID: "4731620", info: unsafeInfo, portrait: true).contains { $0.path.hasPrefix(otherApp.path + "/") })
        let executable = temporary.appendingPathComponent("game")
        check("empty installation has no binary", !containsLaunchBinary(temporary, platform: "mac"))
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        check("MachO signature detected without execution", containsLaunchBinary(temporary, platform: "mac"))
        try Data("not a Mac executable".utf8).write(to: executable)
        check("executable text not classified as native binary", !containsLaunchBinary(temporary, platform: "mac"))
        let appInfo = temporary.appendingPathComponent("appinfo.vdf")
        try Data([0x29,0x44,0x56,0x07,0,0,0,0]).write(to: appInfo)
        check("truncated appinfo rejected", SteamAppInfo.load(appInfo).isEmpty)
        let steam = temporary.appendingPathComponent("Steam"), apps = steam.appendingPathComponent("steamapps")
        let gameDirectory = apps.appendingPathComponent("common/Fixture")
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        check("dot install directory cannot reuse another game binary", steamInstallationPath(apps: apps, directory: ".") == nil)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("common/Escape"), withDestinationURL: temporary)
        check("game directory symlink escape rejected", steamInstallationPath(apps: apps, directory: "Escape") == nil)
        let pe = gameDirectory.appendingPathComponent("Fixture.exe"); try Data([0x4d,0x5a,0,0]).write(to: pe)
        let manifest = apps.appendingPathComponent("appmanifest_526870.acf")
        let accountID = "76561198000000000"
        func writeManifest(flags: String = "4", extra: String = "", updateResult: String? = "0", downloaded: String = "100", owner: String? = nil) throws {
            let result = updateResult.map { "\"UpdateResult\" \"\($0)\"" } ?? ""
            let value = "\"AppState\" { \"appid\" \"526870\" \"StateFlags\" \"\(flags)\" \"installdir\" \"Fixture\" \"buildid\" \"123\" \"LastOwner\" \"\(owner ?? accountID)\" \"BytesToDownload\" \"100\" \"BytesDownloaded\" \"\(downloaded)\" \(result) \(extra) }"
            try value.write(to: manifest, atomically: true, encoding: .utf8)
        }
        func observe() -> SteamInstallObservation { SteamInstallManifest.inspect(manifest, appID: "526870", platform: "windows", accountID: accountID) }
        try writeManifest(); check("completed manifest and PE ready", observe().ready)
        try writeManifest(flags: "1048576"); check("100 percent bytes is not installation complete", !observe().ready && observe().status == "downloading")
        try writeManifest(flags: "516"); check("paused download never auto-launches", !observe().ready && observe().status == "paused")
        try writeManifest(flags: "131072"); check("validation phase never auto-launches", !observe().ready && observe().status == "validating")
        try writeManifest(updateResult: "54"); check("disk full reported without auto-launch", !observe().ready && observe().status == "disk-space")
        try writeManifest(updateResult: "2"); check("Steam failure stops installation job", observe().failed)
        try writeManifest(extra: "\"TargetBuildID\" \"124\""); check("target build mismatch blocks auto-launch", !observe().ready)
        try writeManifest(extra: "\"BytesToStage\" \"100\" \"BytesStaged\" \"20\""); check("pending staging blocks auto-launch", !observe().ready)
        try writeManifest(updateResult: nil); check("legacy complete manifest can omit UpdateResult", observe().ready)
        try writeManifest(owner: "76561198000000001"); check("different installation account blocks auto-launch", observe().failed)
        try writeManifest(); try FileManager.default.removeItem(at: pe); check("missing game binary blocks auto-launch", !observe().ready)
        let newerManifest = temporary.appendingPathComponent("new-library.acf")
        try "\"AppState\" {".write(to: newerManifest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: manifest.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newerManifest.path)
        check("new library manifest supersedes stale original location", SteamInstallManifest.latestManifest(in: [manifest, newerManifest]) == newerManifest)
        check("partially written manifest cannot signal ready", !SteamInstallManifest.inspect(newerManifest, appID: "526870", platform: "windows", accountID: accountID).ready)
        let prefix = temporary.appendingPathComponent("prefix"), drive = prefix.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Escape"), withDestinationURL: temporary)
        let folders = "\"libraryfolders\" { \"0\" { \"path\" \"C:\\\\Games\" } \"1\" { \"path\" \"C:\\\\..\\\\outside\" } \"2\" { \"path\" \"C:\\\\Escape\" } }"
        try folders.write(to: apps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
        let locations = SteamInstallManifest.locations(steamRoot: steam, appID: "526870", platform: "windows", prefix: prefix)
        check("owned Windows C library mapped", locations.contains { $0.path.contains("/drive_c/Games/") })
        check("Windows traversal library rejected", !locations.contains { $0.path.contains("/outside/") })
        check("Windows symlink escape library rejected", locations.count == 2)
        let coordinator = SteamInstallCoordinator()
        let fixtureRuntime = Runtime(id: "fixture", name: "Fixture", platform: "windows", steamRoot: steam, appURL: nil)
        let jobID = coordinator.begin(gameID: "steam:526870", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in }
        check("single install job starts", jobID != nil && coordinator.isActive)
        check("parallel installation job rejected", coordinator.begin(gameID: "steam:427520", appID: "427520", title: "Two", runtime: fixtureRuntime, accountID: accountID) { _ in } == nil)
        coordinator.cancel(); check("cancel stops auto-launch observation", !coordinator.isActive && coordinator.snapshot?["status"] as? String == "cancelled")
        let secondJob = coordinator.begin(gameID: "steam:427520", appID: "427520", title: "Two", runtime: fixtureRuntime, accountID: accountID) { _ in }
        if let jobID { coordinator.requestFailed(id: jobID, message: "late error") }
        check("late error from cancelled job cannot stop new job", coordinator.isActive && coordinator.snapshot?["id"] as? String == secondJob?.uuidString)
        coordinator.shutdown(); check("shutdown never resumes installation job", !coordinator.isActive)
        let observer = SteamInstallCoordinator()
        var emitted = 0, launched = 0
        observer.onChange = { emitted += 1 }
        let observedID = observer.begin(gameID: "steam:526870", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in launched += 1 }!
        let downloading = SteamInstallObservation(status: "downloading", message: "Downloading", downloaded: 10, total: 100)
        observer.receive(downloading, id: observedID) { _ in launched += 1 }
        let announcements = emitted
        observer.receive(downloading, id: observedID) { _ in launched += 1 }
        check("unchanged install observation does not redraw UI", emitted == announcements)
        let ready = SteamInstallObservation(status: "installing", message: "Ready", downloaded: 100, total: 100, ready: true, signature: "fixture:123")
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        check("one complete observation never auto-launches", launched == 0)
        observer.receive(.init(status: "paused", message: "Paused"), id: observedID) { _ in launched += 1 }
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        check("interrupted completion needs two new ready observations", launched == 0)
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        check("stable completed install hands off exactly once", launched == 1 && observer.isActive)
        check("ready job remains cancellable during library refresh", observer.snapshot?["cancellable"] as? Bool == true)
        check("account change during handoff finishes the exact job", !observer.confirmLaunchContext(id: observedID, accountChanged: true, executionBlocked: false) && !observer.isActive && observer.snapshot?["status"] as? String == "cancelled")
        check("stale handoff cannot resume after context invalidation", !observer.confirmLaunchContext(id: observedID, accountChanged: false, executionBlocked: false))
        observer.cancel()
        observer.didRequestLaunch(id: observedID, success: true, message: "late launch callback")
        check("cancellation cannot resurrect a launch callback", observer.snapshot?["status"] as? String == "cancelled")
        let timeoutID = observer.begin(gameID: "steam:526870", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in launched += 1 }!
        observer.receive(ready, id: timeoutID, expired: true) { _ in launched += 1 }
        check("expired job stops without launch", !observer.isActive && launched == 1 && observer.snapshot?["status"] as? String == "timed-out")
        let launchID = observer.begin(gameID: "steam:526870", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in }!
        observer.didRequestLaunch(id: launchID, success: true, message: "Requested")
        observer.launchFailed(id: launchID, message: "Client exited with error")
        check("late client failure replaces launch-requested status", observer.snapshot?["status"] as? String == "failed")
        let nextID = observer.begin(gameID: "steam:427520", appID: "427520", title: "Next", runtime: fixtureRuntime, accountID: accountID) { _ in }!
        observer.launchFailed(id: launchID, message: "Old failure")
        check("late launch failure cannot overwrite another job", observer.snapshot?["id"] as? String == nextID.uuidString && observer.isActive)
        observer.didRequestLaunch(id: nextID, success: true, message: "Requested")
        observer.shutdown()
        observer.launchFailed(id: nextID, message: "Callback after shutdown")
        check("shutdown ignores late client failure", observer.snapshot?["status"] as? String == "launch-requested")
        check("new app session never restores an automatic job", SteamInstallCoordinator().snapshot == nil)

        let cacheFile = temporary.appendingPathComponent("observer-cache.vdf")
        try Data("\"state\" { \"value\" \"before\" }".utf8).write(to: cacheFile)
        let readCache = SteamInstallReadCache()
        _ = readCache.read(cacheFile); _ = readCache.read(cacheFile)
        check("unchanged install input is parsed once", readCache.reads == 1)
        try Data("\"state\" { \"value\" \"after\" }".utf8).write(to: cacheFile, options: .atomic)
        check("atomic manifest replacement invalidates cache", readCache.read(cacheFile).object("state").string("value") == "after" && readCache.reads == 2)
        try FileManager.default.removeItem(at: cacheFile)
        check("deleted install input cannot return cached state", readCache.read(cacheFile).isEmpty)

        let watchedRoot = temporary.appendingPathComponent("watched-steam")
        let watchedApps = watchedRoot.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: watchedApps, withIntermediateDirectories: true)
        let watchedManifest = watchedApps.appendingPathComponent("appmanifest_526870.acf")
        try Data("\"AppState\" { \"appid\" \"526870\" \"StateFlags\" \"512\" }".utf8).write(to: watchedManifest)
        let watchedRuntime = Runtime(id: "fixture-watcher", name: "Fixture", platform: "windows", steamRoot: watchedRoot, appURL: nil)
        var observations: [String] = [], monitorStopped = false
        var monitor: SteamInstallObserver? = SteamInstallObserver(runtime: watchedRuntime, appID: "526870", accountID: "", timeout: 60) { observation, _, _ in
            check("install observation delivered on main thread", Thread.isMainThread)
            observations.append(observation.status)
        }
        defer { monitor?.stop() }
        func waitFor(_ condition: () -> Bool, seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        waitFor({ observations.contains("paused") }, seconds: 4)
        check("real filesystem observer reads paused fixture", observations == ["paused"])
        try Data("\"AppState\" { \"appid\" \"526870\" \"StateFlags\" \"1024\" \"BytesDownloaded\" \"1\" \"BytesToDownload\" \"100\" }".utf8).write(to: watchedManifest, options: .atomic)
        waitFor({ observations.contains("downloading") }, seconds: 4)
        check("directory notification bypasses long paused fallback", observations.last == "downloading")
        weak let releasedMonitor = monitor
        monitor?.stop { monitorStopped = true }; monitor = nil
        waitFor({ monitorStopped && releasedMonitor == nil }, seconds: 2)
        check("stopped observer releases sources and instance", monitorStopped && releasedMonitor == nil)
    } catch { failed += 1; print("FAIL temporary fixture setup") }
    prefs.removePersistentDomain(forName: preferenceSuite)
    print("\(passed) passed; \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
