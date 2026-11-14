import Foundation

@main struct Tests {
    static func main() throws {
        let tempPath=NSTemporaryDirectory()
        let root=URL(fileURLWithPath:tempPath.hasPrefix("/var/") ? "/private"+tempPath : tempPath).appendingPathComponent("playmelt-settings-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let game=GameSettingsContext(id:"sm2",appID:"2651280",platform:"windows",installed:true,path:"/fake",requiredRenderer:"d3dmetal")
        let store=GameSettingsStore(root:root,homeDirectory:root)
        let first=store.snapshot(game:game,hardware:[:],displays:[])
        precondition(first["status"] as? String == "ready")
        let bridgeRoot=root.appendingPathComponent("bridge");try FileManager.default.createDirectory(at:bridgeRoot,withIntermediateDirectories:false)
        let bridgeStore=GameSettingsStore(root:bridgeRoot,nvidiaBridgeAvailable:{true},homeDirectory:root)
        let bridgeSnapshot=bridgeStore.snapshot(game:game,hardware:[:],displays:[])
        func backends(_ snapshot:[String:Any]) -> [[String:String]] { (snapshot["capabilities"] as! [String:Any])["backends"] as! [[String:String]] }
        let unqualified=GameSettingsContext(id:"unqualified",appID:"10",platform:"windows",installed:true,path:"/fake",requiredRenderer:"auto")
        let choices=backends(store.snapshot(game:unqualified,hardware:[:],displays:[])).compactMap{$0["value"]}
        precondition(choices.contains("dxmt") && choices.contains("d3dmetal"),"An unknown API must have an explicit engine choice")
        precondition(backends(bridgeSnapshot).contains { $0["value"]=="d3dmetal-nv" && ($0["label"] ?? "").contains("DLSS → MetalFX") })
        precondition(!backends(first).contains { $0["value"]=="d3dmetal-nv" })
        precondition(backends(bridgeSnapshot).contains { $0["value"]=="d3dmetal-nv-rt" && ($0["label"] ?? "").contains("ray tracing") })
        precondition(!backends(first).contains { $0["value"]=="d3dmetal-nv-rt" })
        var bridgeSettings=bridgeSnapshot["settings"] as! [String:Any];bridgeSettings["backend"]="d3dmetal-nv"
        let bridgeSave=bridgeStore.save(game:game,payload:bridgeSettings,expectedRevision:bridgeSnapshot["revision"] as? String,changedFields:["backend"])
        precondition(bridgeSave["status"] as? String == "saved" && bridgeStore.requestedBackend(for:game)=="d3dmetal-nv")
        let withoutBridge = GameSettingsStore(root:bridgeRoot,homeDirectory:root)
        let recoverable = withoutBridge.snapshot(game:game,hardware:[:],displays:[])
        precondition(recoverable["status"] as? String == "ready", "Missing component must not lock the settings page")
        precondition((recoverable["launchBlockReason"] as? String ?? "").contains("pont NVIDIA"))
        precondition(withoutBridge.save(game:game,payload:bridgeSettings,expectedRevision:recoverable["revision"] as? String,changedFields:["backend"])["status"] as? String == "error", "Unavailable backend cannot be newly selected")
        var recovered = recoverable["settings"] as! [String:Any]; recovered["backend"] = "auto"
        let repair = withoutBridge.save(game:game,payload:recovered,expectedRevision:recoverable["revision"] as? String,changedFields:["backend"])
        precondition(repair["status"] as? String == "saved" && repair["launchBlockReason"] as? String == "")
        precondition(withoutBridge.requestedBackend(for:game) == "auto")
        var settings=first["settings"] as! [String:Any]
        settings["launchArgs"] = "--label 'two words' $(literal)"
        settings["backend"] = "d3dmetal"
        let saved=store.save(game:game,payload:settings,expectedRevision:first["revision"] as? String,changedFields:["launchArgs"])
        precondition(saved["status"] as? String == "saved")
        precondition(store.launchArguments(for:game)==["--label","two words","$(literal)"])
        precondition((try? GameSettingsStore.parseArguments(#"--path C:\Games\SM2 "two words" one\ two"#)) == ["--path",#"C:\Games\SM2"#,"two words","one two"])
        precondition((try? GameSettingsStore.parseArguments("one\ttwo")) == ["one","two"])
        precondition((try? GameSettingsStore.parseArguments("'one\ttwo'")) == nil)
        precondition((try? GameSettingsStore.parseArguments("bad\u{0085}")) == nil)
        precondition((try? GameSettingsStore.parseArguments("bad\u{200b}")) == nil)
        let file=root.appendingPathComponent("steam-2651280-windows.json")
        let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        precondition(doc["schemaVersion"] as? Int == 3 && doc["gameKey"] as? String == "steam-2651280-windows")
        precondition(UUID(uuidString:doc["revision"] as! String) != nil)
        precondition(doc["applyFields"] as? [String] == ["launchArgs"])
        precondition((doc["fieldRevisions"] as? [String:String]) == ["launchArgs":doc["revision"] as! String])
        let v2root=root.appendingPathComponent("legacy-v2");try FileManager.default.createDirectory(at:v2root,withIntermediateDirectories:false)
        let v2file=v2root.appendingPathComponent("steam-2651280-windows.json");var v2=doc;v2["schemaVersion"]=2;v2.removeValue(forKey:"fieldRevisions")
        let originalV2=try JSONSerialization.data(withJSONObject:v2,options:[.sortedKeys]);try originalV2.write(to:v2file)
        let v2store=GameSettingsStore(root:v2root,homeDirectory:root),v2snapshot=v2store.snapshot(game:game,hardware:[:],displays:[])
        precondition(v2snapshot["status"] as? String == "ready" && v2snapshot["applyFields"] as? [String] == ["launchArgs"])
        precondition((try? Data(contentsOf:v2file))==originalV2 && v2store.launchArguments(for:game)==["--label","two words","$(literal)"])
        var v2next=v2snapshot["settings"] as! [String:Any],v2display=v2next["display"] as! [String:Any]
        v2display["vsync"]=false;v2next["display"]=v2display
        let v3result=v2store.save(game:game,payload:v2next,expectedRevision:v2snapshot["revision"] as? String,changedFields:["display.vsync"])
        precondition(v3result["status"] as? String == "saved")
        let v3=try JSONSerialization.jsonObject(with:Data(contentsOf:v2file)) as! [String:Any]
        precondition(v3["schemaVersion"] as? Int == 3 && v3["applyFields"] as? [String] == ["display.vsync","launchArgs"])
        let v3fields=v3["fieldRevisions"] as! [String:String]
        precondition(v3fields["launchArgs"]==doc["revision"] as? String && v3fields["display.vsync"]==v3["revision"] as? String)
        precondition(((v3["settings"] as! [String:Any])["display"] as! [String:Any])["vsync"] as? Bool == false)
        for invalidMap in [["graphics.grain":v3["revision"] as! String],["display.vsync":"invalid","launchArgs":doc["revision"] as! String],["display.vsync":(v3["revision"] as! String).uppercased(),"launchArgs":doc["revision"] as! String],["display.unknown":v3["revision"] as! String,"launchArgs":doc["revision"] as! String]] {
            var invalid=v3;invalid["fieldRevisions"]=invalidMap
            try JSONSerialization.data(withJSONObject:invalid).write(to:v2file)
            precondition(v2store.snapshot(game:game,hardware:[:],displays:[])["status"] as? String == "error")
        }
        var invalidVersion=v3;invalidVersion["schemaVersion"]=true
        try JSONSerialization.data(withJSONObject:invalidVersion).write(to:v2file)
        precondition(v2store.snapshot(game:game,hardware:[:],displays:[])["status"] as? String == "error")
        try JSONSerialization.data(withJSONObject:v3).write(to:v2file)
        var dimensions=v3["settings"] as! [String:Any],dims=dimensions["display"] as! [String:Any]
        dims["width"]=1920;dimensions["display"]=dims
        let widthSave=v2store.save(game:game,payload:dimensions,expectedRevision:v3["revision"] as? String,changedFields:["display.width"])
        precondition(widthSave["status"] as? String == "saved")
        let widthRevision=widthSave["revision"] as! String
        dims["height"]=1080;dimensions["display"]=dims
        let heightSave=v2store.save(game:game,payload:dimensions,expectedRevision:widthRevision,changedFields:["display.height"])
        precondition(heightSave["status"] as? String == "saved")
        let heightRevision=heightSave["revision"] as! String
        var pending=try JSONSerialization.jsonObject(with:Data(contentsOf:v2file)) as! [String:Any]
        var pendingRevisions=pending["fieldRevisions"] as! [String:String]
        precondition(widthRevision != heightRevision && pendingRevisions["display.width"] == widthRevision && pendingRevisions["display.height"] == heightRevision && pendingRevisions["launchArgs"] == v3fields["launchArgs"])
        let sameValue=v2store.save(game:game,payload:dimensions,expectedRevision:heightRevision,changedFields:["display.width"])
        precondition(sameValue["status"] as? String == "saved")
        pending=try JSONSerialization.jsonObject(with:Data(contentsOf:v2file)) as! [String:Any]
        pendingRevisions=pending["fieldRevisions"] as! [String:String]
        precondition(pendingRevisions["display.width"] == sameValue["revision"] as? String && pendingRevisions["display.width"] != widthRevision && pendingRevisions["display.height"] == heightRevision)
        precondition(store.requestedBackend(for:game) == "auto")
        var next=settings;var nextDisplay=next["display"] as! [String:Any];nextDisplay["vsync"]=false;next["display"]=nextDisplay
        let union=store.save(game:game,payload:next,expectedRevision:doc["revision"] as? String,changedFields:["display.vsync"])
        precondition(union["status"] as? String == "saved")
        let unionFields=union["applyFields"] as! [String];precondition(unionFields == ["display.vsync","launchArgs"])
        let unionSettings=union["settings"] as! [String:Any];precondition((unionSettings["display"] as! [String:Any])["vsync"] as? Bool == false)
        let unionDoc=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        let unionRevisions=unionDoc["fieldRevisions"] as! [String:String]
        precondition(unionRevisions["launchArgs"]==doc["revision"] as? String && unionRevisions["display.vsync"]==unionDoc["revision"] as? String)
        precondition(store.launchArguments(for:game)==["--label","two words","$(literal)"])
        let newRevision=union["revision"] as? String
        precondition(store.save(game:game,payload:next,expectedRevision:newRevision,changedFields:["display.fake"])["status"] as? String == "error")
        precondition(store.save(game:game,payload:next,expectedRevision:newRevision,changedFields:["display.vsync","display.vsync"])["status"] as? String == "error")
        precondition(store.save(game:game,payload:settings,expectedRevision:first["revision"] as? String,changedFields:["launchArgs"])["status"] as? String == "error")
        precondition(GameSettingsStore(root:root,homeDirectory:root).snapshot(game:game,hardware:[:],displays:[])["status"] as? String == "ready")
        var bad=settings;bad["unexpected"]=true
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "error")
        bad=settings;var badDisplay=bad["display"] as! [String:Any];badDisplay["width"]=true;bad["display"]=badDisplay
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "error")
        badDisplay["width"] = -1;bad["display"]=badDisplay
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "error")
        bad=settings;var graphics=bad["graphics"] as! [String:Any];graphics["grain"]=Double.nan;bad["graphics"]=graphics
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "error")
        bad=settings;bad["launchArgs"]="'unclosed"
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "error")
        let mac=GameSettingsContext(id:"mac",appID:"12",platform:"macos",installed:true,path:"/fake",requiredRenderer:"")
        let mc=store.snapshot(game:mac,hardware:[:],displays:[])["capabilities"] as! [String:Any]
        precondition(mc["launchArgs"] as? Bool == false)
        precondition((store.snapshot(game:mac,hardware:[:],displays:[])["calculation"] as! [String:Any]).isEmpty)
        let epic=GameSettingsContext(id:"epic",appID:"",platform:"windows",installed:true,path:"/fake",requiredRenderer:"d3dmetal",supportsLaunchArguments:false)
        let epicSnapshot=store.snapshot(game:epic,hardware:[:],displays:[])
        precondition(epicSnapshot["status"] as? String == "ready" && (epicSnapshot["capabilities"] as! [String:Any])["launchArgs"] as? Bool == false)
        precondition(store.save(game:mac,payload:settings,expectedRevision:"00000000-0000-0000-0000-000000000000",changedFields:["launchArgs"])["status"] as? String == "error")
        let calc=store.snapshot(game:game,hardware:[:],displays:[])["calculation"] as! [String:Any]
        precondition(calc["outputPixels"] as? Int != nil)
        let screenID=UUID().uuidString
        let screen:[String:Any]=["id":screenID,"name":"Test","width":2560,"height":1440,"isPrimary":true]
        let screenSnapshot=store.snapshot(game:game,hardware:[:],displays:[screen])
        let cap=screenSnapshot["capabilities"] as! [String:Any]
        let options=cap["displays"] as! [[String:Any]];precondition(options.count==2);precondition(options[0]["width"] as? Int==2560)
        let screenCalc=screenSnapshot["calculation"] as! [String:Any]
        precondition(screenCalc["proposedDisplay"] as? String == screenID)
        bad=settings;var display=bad["display"] as! [String:Any];display["screenID"]="not-a-uuid";bad["display"]=display
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "error")
        display.removeValue(forKey:"screenID");bad["display"]=display
        precondition(store.save(game:game,payload:bad,expectedRevision:newRevision,changedFields:["launchArgs"])["status"] as? String == "saved")
        let fixture="""
        00:00:01:000 > [Settings] DirectX Version: 12
        00:00:01:001 > [Settings] Resolution: 1280x720
        00:00:01:002 > [Settings] Upscale method: FSR
        00:00:01:003 > [Settings] Frame generation: FSR
        00:00:01:004 > [Settings] End of settings.
        00:00:02:000 > [Render] fps: 45.2
        00:00:03:000 > [Settings] DirectX Version: 12
        00:00:03:001 > [Settings] Resolution: 1920x1080
        00:00:03:002 > [Settings] Upscale quality: Quality
        00:00:03:003 > [Settings] End of settings.
        00:00:04:000 > [Render] fps: 60.0
        """
        let samples=GameSettingsStore.parseLog(fixture).samples
        precondition(samples.count==2)
        let s1=samples[0]["observedSettings"] as! [String:String],s2=samples[1]["observedSettings"] as! [String:String]
        precondition(s1["Resolution"]=="1280x720" && s1["Upscale Method"]=="FSR" && s1["Frame Generation"]=="FSR")
        precondition(s2["Resolution"]=="1920x1080" && s2["Upscale Quality"]=="Quality" && s2["Upscale Method"]==nil)
        let outside=root.appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        let unsafe=GameSettingsStore(root:link.appendingPathComponent("nested"),homeDirectory:root)
        let unsafeRev=unsafe.snapshot(game:game,hardware:[:],displays:[])["revision"] as? String
        precondition(unsafe.save(game:game,payload:settings,expectedRevision:unsafeRev,changedFields:["launchArgs"])["status"] as? String == "error")
        precondition(!FileManager.default.fileExists(atPath:outside.appendingPathComponent("nested").path))
        let legacy=GameSettingsContext(id:"legacy",appID:"9",platform:"windows",installed:true,path:"/fake",requiredRenderer:"dxmt")
        let legacyFile=root.appendingPathComponent("steam-9-windows.json"),legacyBytes=Data("{\"schemaVersion\":1}".utf8)
        try legacyBytes.write(to:legacyFile)
        precondition(store.snapshot(game:legacy,hardware:[:],displays:[])["status"] as? String == "error")
        precondition((try? Data(contentsOf:legacyFile))==legacyBytes)
        // All registry/log lookups above use the fixture home, never live profiles.
        precondition((first["settings"] as! [String:Any])["performance"] == nil)
        precondition(((first["capabilities"] as! [String:Any])["performance"] as! [String:Any])["visible"] as? Bool == false)
        let sm2Performance=try store.performanceRequest(for:game,resolvedBackend:"dxmt");precondition(sm2Performance == nil)
        let perfRoot=root.appendingPathComponent("performance");try FileManager.default.createDirectory(at:perfRoot,withIntermediateDirectories:false)
        let perfStore=GameSettingsStore(root:perfRoot,homeDirectory:root)
        var keys=Set<String>()
        for platform in ["steam","epic","gog","local"] {
            let direct=GameSettingsContext(id:platform+":direct",appID:platform=="local" ? "" : "10",platform:"windows",installed:true,path:"/fixture",requiredRenderer:"auto",supportsLaunchArguments:platform=="steam",store:platform,supportsPerformanceSettings:true,supportsSpatialUpscaling:true,resolvedPerformanceBackend:"dxmt")
            let initial=perfStore.snapshot(game:direct,hardware:[:],displays:[])
            precondition(initial["status"] as? String == "ready")
            precondition((initial["applyFields"] as! [String]).isEmpty)
            let inheritedPerformance=try perfStore.performanceRequest(for:direct,resolvedBackend:"unknown");precondition(inheritedPerformance == nil)
            var requested=initial["settings"] as! [String:Any]
            requested["backend"]="d3dmetal" // Untouched draft must not change the stored backend.
            requested["performance"]=["fpsLimit":45,"metalFXScale":1.5,"outputWidth":1920,"outputHeight":1080]
            let saved=perfStore.save(game:direct,payload:requested,expectedRevision:initial["revision"] as? String,changedFields:["performance.fpsLimit","performance.metalFXScale","performance.outputWidth","performance.outputHeight"])
            precondition(saved["status"] as? String == "saved")
            precondition((saved["settings"] as! [String:Any])["backend"] as? String == "auto")
            precondition(saved["launchBlockReason"] as? String == "", "Auto uses separately resolved DXMT; renderer requirement stays auto")
            let request=try perfStore.performanceRequest(for:direct,resolvedBackend:"dxmt")!
            precondition(request.fpsLimit==45 && request.metalFXScale==1.5 && request.outputWidth==1920 && request.outputHeight==1080 && request.renderWidth==1280 && request.renderHeight==720)
            precondition(request.appliedFields.count==4)
            precondition((try? perfStore.performanceRequest(for:direct,resolvedBackend:"unknown")) == nil)
            precondition((try? perfStore.performanceRequest(for:direct,resolvedBackend:"d3dmetal")) == nil, "Spatial is DXMT-only")
            let inactive=GameSettingsContext(id:direct.id,appID:direct.appID,platform:"windows",installed:true,path:"/fixture",requiredRenderer:"auto",supportsLaunchArguments:false,store:platform,performanceReadOnlyReason:"Route désactivée dans cette fixture",resolvedPerformanceBackend:"dxmt")
            let retained=perfStore.snapshot(game:inactive,hardware:[:],displays:[])
            precondition(retained["status"] as? String == "ready" && (retained["launchBlockReason"] as? String ?? "").contains("Route désactivée"))
            precondition(((retained["settings"] as! [String:Any])["performance"] as! [String:Any])["fpsLimit"] as? Int == 45)
            do { _=try perfStore.performanceRequest(for:inactive,resolvedBackend:"dxmt");preconditionFailure("Active unavailable request must throw") } catch {}
            var disabled=retained["settings"] as! [String:Any],p=disabled["performance"] as! [String:Any];p["fpsLimit"]=0;p["metalFXScale"]=1.0;disabled["performance"]=p
            let cleared=perfStore.save(game:inactive,payload:disabled,expectedRevision:retained["revision"] as? String,changedFields:["performance.fpsLimit","performance.metalFXScale"])
            precondition(cleared["status"] as? String == "saved" && cleared["launchBlockReason"] as? String == "")
            let off=try perfStore.performanceRequest(for:inactive,resolvedBackend:"unresolved")!
            precondition(off.fpsLimit==nil && off.metalFXScale==1 && off.appliedFields.contains("performance.fpsLimit") && off.appliedFields.contains("performance.metalFXScale"))
        }
        for file in try FileManager.default.contentsOfDirectory(at:perfRoot,includingPropertiesForKeys:nil) where file.pathExtension=="json" { keys.insert(file.lastPathComponent) }
        precondition(keys.count==4 && keys.contains("steam-10-windows.json") && keys.contains("epic-10-windows.json") && keys.contains("gog-10-windows.json"))
        let fpsGame=GameSettingsContext(id:"fps-only",appID:"11",platform:"windows",installed:true,path:"/fixture",requiredRenderer:"d3dmetal",supportsPerformanceSettings:true,resolvedPerformanceBackend:"d3dmetal")
        var fpsSnapshot=perfStore.snapshot(game:fpsGame,hardware:[:],displays:[])
        for fps in [30,40,45,60,90,120] {
            var payload=fpsSnapshot["settings"] as! [String:Any],p=payload["performance"] as! [String:Any];p["fpsLimit"]=fps;payload["performance"]=p
            fpsSnapshot=perfStore.save(game:fpsGame,payload:payload,expectedRevision:fpsSnapshot["revision"] as? String,changedFields:["performance.fpsLimit"])
            precondition(fpsSnapshot["status"] as? String == "saved")
            for backend in ["dxmt","d3dmetal","d3dmetal-nv","d3dmetal-nv-rt"] { let actual=try perfStore.performanceRequest(for:fpsGame,resolvedBackend:backend);precondition(actual?.fpsLimit==fps) }
        }
        for invalid in [true as Any,29,61,Double.nan,"60"] {
            var payload=fpsSnapshot["settings"] as! [String:Any],p=payload["performance"] as! [String:Any];p["fpsLimit"]=invalid;payload["performance"]=p
            precondition(perfStore.save(game:fpsGame,payload:payload,expectedRevision:fpsSnapshot["revision"] as? String,changedFields:["performance.fpsLimit"])["status"] as? String == "error")
        }
        var badSpatial=fpsSnapshot["settings"] as! [String:Any],badGroup=badSpatial["performance"] as! [String:Any];badGroup["metalFXScale"]=2.0;badSpatial["performance"]=badGroup
        precondition(perfStore.save(game:fpsGame,payload:badSpatial,expectedRevision:fpsSnapshot["revision"] as? String,changedFields:["performance.metalFXScale"])["status"] as? String == "error")
        let dimensionsOnly=GameSettingsContext(id:"dimensions",appID:"12",platform:"windows",installed:true,path:"/fixture",requiredRenderer:"dxmt",supportsPerformanceSettings:true,supportsSpatialUpscaling:true)
        let dimInitial=perfStore.snapshot(game:dimensionsOnly,hardware:[:],displays:[]);var dimPayload=dimInitial["settings"] as! [String:Any],dimGroup=dimPayload["performance"] as! [String:Any];dimGroup["outputWidth"]=1919;dimGroup["outputHeight"]=1079;dimPayload["performance"]=dimGroup
        let dimsOnlySaved=perfStore.save(game:dimensionsOnly,payload:dimPayload,expectedRevision:dimInitial["revision"] as? String,changedFields:["performance.outputWidth","performance.outputHeight"])
        let dimensionsPerformance=try perfStore.performanceRequest(for:dimensionsOnly,resolvedBackend:"dxmt");precondition(dimsOnlySaved["status"] as? String == "saved" && dimensionsPerformance==nil)
        dimGroup["metalFXScale"]=1.5;dimPayload["performance"]=dimGroup
        let spatialSaved=perfStore.save(game:dimensionsOnly,payload:dimPayload,expectedRevision:dimsOnlySaved["revision"] as? String,changedFields:["performance.metalFXScale"])
        precondition(spatialSaved["status"] as? String == "saved")
        let rounded=try perfStore.performanceRequest(for:dimensionsOnly,resolvedBackend:"dxmt")!
        precondition(rounded.renderWidth==1278 && rounded.renderHeight==718 && rounded.outputWidth==1917 && rounded.outputHeight==1077)
        let noSpatial=GameSettingsContext(id:dimensionsOnly.id,appID:"12",platform:"windows",installed:true,path:"/fixture",requiredRenderer:"dxmt",supportsPerformanceSettings:true,spatialUpscalingReadOnlyReason:"Exécutable inconnu")
        precondition(perfStore.snapshot(game:noSpatial,hardware:[:],displays:[])["status"] as? String == "ready")
        do { _=try perfStore.performanceRequest(for:noSpatial,resolvedBackend:"dxmt");preconditionFailure("Unavailable spatial request must throw") } catch {}
        for platform in ["mac","cloud"] {
            let excluded=GameSettingsContext(id:platform,appID:"11",platform:platform,installed:true,path:"/fixture",requiredRenderer:"dxmt",store:"local",supportsPerformanceSettings:true,supportsSpatialUpscaling:true)
            let excludedPerformance=try perfStore.performanceRequest(for:excluded,resolvedBackend:"dxmt");precondition(excludedPerformance==nil)
            let cap=(perfStore.snapshot(game:excluded,hardware:[:],displays:[])["capabilities"] as! [String:Any])["performance"] as! [String:Any]
            precondition(cap["fpsLimit"] as? Bool == false && (cap["reason"] as? String ?? "").contains("Mac natifs et cloud"))
        }
        // Real local contexts retain the historical Steam filename, including SM2.
        let localSM2=GameSettingsContext(id:"local-sm2",appID:"2651280",platform:"windows",installed:true,path:"/fixture",requiredRenderer:"d3dmetal",store:"local",supportsPerformanceSettings:true,supportsSpatialUpscaling:true)
        let localSnapshot=store.snapshot(game:localSM2,hardware:[:],displays:[])
        precondition(localSnapshot["status"] as? String == "ready" && localSnapshot["revision"] as? String == store.snapshot(game:game,hardware:[:],displays:[])["revision"] as? String)
        precondition((localSnapshot["settings"] as! [String:Any])["performance"]==nil)
        let localSM2Performance=try store.performanceRequest(for:localSM2,resolvedBackend:"dxmt");precondition(localSM2Performance==nil)
        for version in [2,3] {
            let oldRoot=root.appendingPathComponent("local-old-\(version)");try FileManager.default.createDirectory(at:oldRoot,withIntermediateDirectories:false)
            var old=doc;old["schemaVersion"]=version;old["gameKey"]="steam-99-windows";old["applyFields"]=["backend"]
            var oldSettings=old["settings"] as! [String:Any];oldSettings["backend"]="d3dmetal-nv";old["settings"]=oldSettings
            if version==2 { old.removeValue(forKey:"fieldRevisions") } else { old["fieldRevisions"]=["backend":old["revision"] as! String] }
            let oldFile=oldRoot.appendingPathComponent("steam-99-windows.json"),oldBytes=try JSONSerialization.data(withJSONObject:old,options:[.sortedKeys]);try oldBytes.write(to:oldFile)
            let oldStore=GameSettingsStore(root:oldRoot,homeDirectory:root),local=GameSettingsContext(id:"local-existing",appID:"99",platform:"windows",installed:true,path:"/fixture",requiredRenderer:"auto",store:"local",supportsPerformanceSettings:false,resolvedPerformanceBackend:"dxmt")
            let loaded=oldStore.snapshot(game:local,hardware:[:],displays:[])
            let bytesAfterRead=try Data(contentsOf:oldFile);precondition(loaded["status"] as? String == "ready" && bytesAfterRead==oldBytes)
            let oldPerformance=try oldStore.performanceRequest(for:local,resolvedBackend:"dxmt");precondition(loaded["applyFields"] as? [String]==["backend"] && oldPerformance==nil)
            var repairPayload=loaded["settings"] as! [String:Any];repairPayload["backend"]="auto"
            precondition(oldStore.save(game:local,payload:repairPayload,expectedRevision:loaded["revision"] as? String,changedFields:["backend"])["status"] as? String == "saved")
            let repairedPerformance=try oldStore.performanceRequest(for:local,resolvedBackend:"dxmt");precondition(repairedPerformance==nil)
        }
        print("GameSettings tests passed; legacy namespaces, isolated homes, performance requests and explicit off verified")
    }
}
