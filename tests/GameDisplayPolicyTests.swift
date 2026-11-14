import Foundation
@main enum Tests {
    static func main()throws {
        let builtin:[String:Any]=["id":"mac","isBuiltIn":true,"isPrimary":false,"desktopWidth":1728,"desktopHeight":1117,"refreshRate":120.0,"originX":1920.0,"originY":0.0]
        let hdmi:[String:Any]=["id":"hdmi","isBuiltIn":false,"isPrimary":true,"desktopWidth":1920,"desktopHeight":1080,"refreshRate":120.0,"originX":0.0,"originY":0.0]
        func rejects(_ displays:[[String:Any]],requested:String="primary"){do{_=try GameDisplayMetadata.launchTarget(displays,requested:requested);fatalError("Unexpected target accepted")}catch{}}
        let a=try GameDisplayMetadata.launchTarget([builtin,hdmi]),b=try GameDisplayMetadata.launchTarget([hdmi,builtin])
        precondition(a["id"] as? String == "hdmi");precondition(b["id"] as? String == "hdmi")
        rejects([builtin,hdmi],requested:"disconnected")
        var internalOnly=builtin;internalOnly["isPrimary"]=true
        let solo=try GameDisplayMetadata.launchTarget([internalOnly]);precondition(solo["id"] as? String == "mac")
        var secondary=hdmi;secondary["isPrimary"]=false;rejects([internalOnly,secondary])
        var bad=hdmi;bad["refreshRate"]=Double.nan;rejects([bad]);rejects([])
        let lib=URL(fileURLWithPath:CommandLine.arguments[1])
        let env=try GameDisplayMetadata.guardedEnvironment(["PATH":"fixture","PLAYMELT_BENCHMARK_SESSION":"fixture"],target:hdmi,library:lib)
        precondition(env["DYLD_INSERT_LIBRARIES"]==lib.path && env["PLAYMELT_DISPLAY_INSERT_LIBRARIES"]==lib.path)
        precondition(env["SDL_VIDEO_MAC_FULLSCREEN_SPACES"]=="0" && env["PLAYMELT_GAME_WIDTH"]=="1920" && env["PLAYMELT_GAME_HEIGHT"]=="1080")
        precondition(env["PLAYMELT_BENCHMARK_SESSION"]=="fixture" && env["PATH"]=="fixture")
        internalOnly["scale"]=2.0;internalOnly["width"]=3456;internalOnly["height"]=2234
        let retina=try GameDisplayMetadata.guardedEnvironment([:],target:internalOnly,library:lib)
        precondition(retina["PLAYMELT_DISPLAY_SCALE"]=="2")
        precondition(retina["PLAYMELT_DISPLAY_PIXEL_WIDTH"]=="3456" && retina["PLAYMELT_DISPLAY_DESKTOP_WIDTH"]=="1728")
        precondition(retina["PLAYMELT_DISPLAY_PIXEL_HEIGHT"]=="2234" && retina["PLAYMELT_DISPLAY_DESKTOP_HEIGHT"]=="1117")
        print("Display policy: 13 external selection, disconnected-screen, Mac-only, Retina geometry and process-environment checks passed")
    }
}
