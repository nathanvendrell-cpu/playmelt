import Foundation

@main struct Tests {
    static func main() throws {
        let tempPath=NSTemporaryDirectory()
        let root=URL(fileURLWithPath:tempPath.hasPrefix("/var/") ? "/private"+tempPath : tempPath).appendingPathComponent("playmelt-settings-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let game=GameSettingsContext(id:"sm2",appID:"2651280",platform:"windows",installed:true,path:"/fake",requiredRenderer:"d3dmetal")
        let store=GameSettingsStore(root:root)
        let first=store.snapshot(game:game,hardware:[:],displays:[])
        precondition(first["status"] as? String == "ready")
        let bridgeRoot=root.appendingPathComponent("bridge");try FileManager.default.createDirectory(at:bridgeRoot,withIntermediateDirectories:false)
        let bridgeStore=GameSettingsStore(root:bridgeRoot,nvidiaBridgeAvailable:{true})
        let bridgeSnapshot=bridgeStore.snapshot(game:game,hardware:[:],displays:[])
        func backends(_ snapshot:[String:Any]) -> [[String:String]] { (snapshot["capabilities"] as! [String:Any])["backends"] as! [[String:String]] }
        precondition(backends(bridgeSnapshot).contains { $0["value"]=="d3dmetal-nv" && ($0["label"] ?? "").contains("DLSS → MetalFX") })
        precondition(!backends(first).contains { $0["value"]=="d3dmetal-nv" })
        precondition(backends(bridgeSnapshot).contains { $0["value"]=="d3dmetal-nv-rt" && ($0["label"] ?? "").contains("ray tracing") })
        precondition(!backends(first).contains { $0["value"]=="d3dmetal-nv-rt" })
        var bridgeSettings=bridgeSnapshot["settings"] as! [String:Any];bridgeSettings["backend"]="d3dmetal-nv"
        let bridgeSave=bridgeStore.save(game:game,payload:bridgeSettings,expectedRevision:bridgeSnapshot["revision"] as? String,changedFields:["backend"])
        precondition(bridgeSave["status"] as? String == "saved" && bridgeStore.requestedBackend(for:game)=="d3dmetal-nv")
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
        let v2store=GameSettingsStore(root:v2root),v2snapshot=v2store.snapshot(game:game,hardware:[:],displays:[])
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
        precondition(GameSettingsStore(root:root).snapshot(game:game,hardware:[:],displays:[])["status"] as? String == "ready")
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
        let unsafe=GameSettingsStore(root:link.appendingPathComponent("nested"))
        let unsafeRev=unsafe.snapshot(game:game,hardware:[:],displays:[])["revision"] as? String
        precondition(unsafe.save(game:game,payload:settings,expectedRevision:unsafeRev,changedFields:["launchArgs"])["status"] as? String == "error")
        precondition(!FileManager.default.fileExists(atPath:outside.appendingPathComponent("nested").path))
        let legacy=GameSettingsContext(id:"legacy",appID:"9",platform:"windows",installed:true,path:"/fake",requiredRenderer:"dxmt")
        let legacyFile=root.appendingPathComponent("steam-9-windows.json"),legacyBytes=Data("{\"schemaVersion\":1}".utf8)
        try legacyBytes.write(to:legacyFile)
        precondition(store.snapshot(game:legacy,hardware:[:],displays:[])["status"] as? String == "error")
        precondition((try? Data(contentsOf:legacyFile))==legacyBytes)
        print("GameSettings tests passed")
    }
}
