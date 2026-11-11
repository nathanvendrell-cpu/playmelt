import Foundation
import CryptoKit
import CoreFoundation
import Darwin

struct GameSettingsContext {
    let id: String
    let appID: String
    let platform: String
    let installed: Bool
    let path: String
    let requiredRenderer: String
    let supportsLaunchArguments: Bool
    init(id:String,appID:String,platform:String,installed:Bool,path:String,requiredRenderer:String,supportsLaunchArguments:Bool=true) {
        self.id=id;self.appID=appID;self.platform=platform;self.installed=installed;self.path=path;self.requiredRenderer=requiredRenderer;self.supportsLaunchArguments=supportsLaunchArguments
    }
}

/// Preferences are inert until a caller explicitly integrates them into a launch.
final class GameSettingsStore {
    let root: URL
    init(root: URL) { self.root = root }
    private func eligible(_ game: GameSettingsContext) -> Bool {
        game.platform.lowercased() == "windows" && game.installed && game.supportsLaunchArguments && !game.appID.isEmpty
    }
    private func sm2(_ game: GameSettingsContext) -> Bool { eligible(game) && game.appID == "2651280" }
    private func safeKey(_ game: GameSettingsContext) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard game.appID.count <= 80, game.appID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !game.platform.isEmpty, game.platform.count <= 30, game.platform.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              game.appID != ".", game.appID != ".." else { throw Issue.invalid("Identifiant de jeu invalide") }
        let identifier=game.appID.isEmpty ? "local-"+SHA256.hash(data:Data(game.id.utf8)).prefix(12).map{String(format:"%02x",$0)}.joined() : game.appID
        return "steam-\(identifier)-\(game.platform.lowercased())"
    }
    private enum Issue: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
    }
    private func defaults() -> [String: Any] {
        ["launchArgs":"", "backend":"auto", "display":["mode":"windowed","screenID":"primary","width":1280,"height":720,"refreshRate":60,"retina":"auto","vsync":false,"hdr":false],
         "graphics":["upscaler":"fsr","quality":"quality","dynamicFPS":0,"frameGeneration":false,"grain":0.0,"sharpness":0.0]]
    }
    private func capabilities(_ game: GameSettingsContext) -> [String: Any] {
        let enabled = eligible(game), special = sm2(game)
        var options: [[String:String]] = [["value":"auto","label":"Automatique"]]
        if special || (enabled && game.requiredRenderer.lowercased() == "d3dmetal") { options.append(["value":"d3dmetal","label":"D3DMetal"]) }
        else if enabled && game.requiredRenderer.lowercased() == "dxmt" { options.append(["value":"dxmt","label":"DXMT"]) }
        var result: [String:Any] = ["launchArgs":enabled,"backends":options,"display":special,"graphics":special]
        if !enabled { result["readOnlyReason"] = "Réglages de lancement indisponibles pour cette plateforme ou ce jeu non installé." }
        return result
    }
    private func keys(_ object: [String:Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw Issue.invalid("Champs manquants ou inconnus") }
    }
    private func number(_ value: Any?, _ min: Double, _ max: Double, integer: Bool = false) throws -> Double {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw Issue.invalid("Nombre invalide") }
        let v=n.doubleValue
        guard v.isFinite, v >= min, v <= max, !integer || v.rounded() == v else { throw Issue.invalid("Nombre hors limites") }
        return v
    }
    private func bool(_ value: Any?) -> Bool? {
        guard let n=value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private func choice(_ value: Any?, _ allowed: [String]) throws -> String {
        guard let v=value as? String, allowed.contains(v) else { throw Issue.invalid("Choix invalide") }; return v
    }
    /// Quotes and backslashes group literal arguments; no expansion or shell is involved.
    static func parseArguments(_ text: String) throws -> [String] {
        guard text.utf8.count <= 2048, !text.unicodeScalars.contains(where: { ($0.properties.generalCategory == .control && $0.value != 9) || $0.properties.generalCategory == .surrogate || $0.properties.generalCategory == .format }) else { throw Issue.invalid("Arguments invalides") }
        let chars=Array(text);var out:[String]=[],word="",quote:Character?=nil,started=false,i=0
        while i<chars.count {
            let c=chars[i]
            if c == "\t" {
                guard quote == nil else { throw Issue.invalid("Tabulation interdite dans un argument") }
                if started { out.append(word);word="";started=false };i+=1;continue
            }
            if c == "\\" && i+1<chars.count && (chars[i+1] == "\"" || chars[i+1] == "'" || chars[i+1] == " ") {
                word.append(chars[i+1]);started=true;i+=2;continue
            }
            if c == "\"" || c == "'" {
                if quote == nil { quote=c;started=true;i+=1;continue }
                if quote == c { quote=nil;i+=1;continue }
            }
            if c == " " && quote == nil { if started { out.append(word);word="";started=false } }
            else { word.append(c);started=true }
            i+=1
        }
        guard quote == nil else { throw Issue.invalid("Guillemets incomplets") }
        if started { out.append(word) }
        guard out.count <= 64, out.allSatisfy({ $0.unicodeScalars.count <= 512 }) else { throw Issue.invalid("Limite d’arguments dépassée") }
        return out
    }
    private func validate(_ raw: [String:Any], game: GameSettingsContext) throws -> [String:Any] {
        guard eligible(game) else { throw Issue.invalid("Jeu non pris en charge") }
        try keys(raw,["launchArgs","backend","display","graphics"])
        guard let args=raw["launchArgs"] as? String else { throw Issue.invalid("Arguments invalides") }; _ = try Self.parseArguments(args)
        let backends=(capabilities(game)["backends"] as? [[String:String]] ?? []).compactMap { $0["value"] }
        let backend=try choice(raw["backend"],backends)
        guard let originalDisplay=raw["display"] as? [String:Any],let graphics=raw["graphics"] as? [String:Any] else { throw Issue.invalid("Groupes invalides") }
        var display=originalDisplay
        if display["screenID"] == nil { display["screenID"]="primary" }
        try keys(display,["mode","screenID","width","height","refreshRate","retina","vsync","hdr"])
        guard let screen=display["screenID"] as? String,screen == "primary" || UUID(uuidString:screen) != nil else { throw Issue.invalid("Écran invalide") }
        try keys(graphics,["upscaler","quality","dynamicFPS","frameGeneration","grain","sharpness"])
        _ = try choice(display["mode"],["exclusive","fullscreen","windowed"])
        _ = try number(display["width"],640,7680,integer:true); _ = try number(display["height"],480,4320,integer:true)
        _ = try number(display["refreshRate"],1,1000,integer:true); _ = try choice(display["retina"],["auto","on","off"])
        guard bool(display["vsync"]) != nil, bool(display["hdr"]) != nil, bool(graphics["frameGeneration"]) != nil else { throw Issue.invalid("Booléen invalide") }
        _ = try choice(graphics["upscaler"],["fsr"]); _ = try choice(graphics["quality"],["quality"])
        let fps=try number(graphics["dynamicFPS"],0,60,integer:true); guard [0.0,30.0,60.0].contains(fps) else { throw Issue.invalid("Cible FPS non prise en charge") }
        _ = try number(graphics["grain"],0,1); _ = try number(graphics["sharpness"],0,1)
        if !sm2(game) {
            let d=defaults()
            guard NSDictionary(dictionary:display).isEqual(to:d["display"] as! [AnyHashable:Any]), NSDictionary(dictionary:graphics).isEqual(to:d["graphics"] as! [AnyHashable:Any]) else { throw Issue.invalid("Réglages graphiques indisponibles") }
        }
        return ["launchArgs":args,"backend":backend,"display":display,"graphics":graphics]
    }
    private func data(_ settings: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:settings,options:[.sortedKeys]) }
    private func ensureSafeRoot() throws {
        guard root.isFileURL,root.path.hasPrefix("/"),!root.pathComponents.contains("..") else { throw Issue.invalid("Chemin de paramètres invalide") }
        var path="/",info=stat()
        for part in root.pathComponents.dropFirst() {
            path=(path as NSString).appendingPathComponent(part)
            if lstat(path,&info) != 0 {
                guard errno==ENOENT,mkdir(path,0o700)==0,lstat(path,&info)==0 else { throw Issue.invalid("Création du dossier impossible") }
            }
            guard (info.st_mode & S_IFMT)==S_IFDIR else { throw Issue.invalid("Lien ou dossier parent invalide : " + path) }
        }
        guard info.st_uid==getuid() else { throw Issue.invalid("Propriétaire du dossier invalide") }
    }
    private func writeAtomic(_ bytes:Data, name:String) throws {
        let final=root.appendingPathComponent(name).path,tmp=root.appendingPathComponent("."+UUID().uuidString+".tmp").path
        var info=stat()
        if lstat(final,&info)==0 {
            guard (info.st_mode & S_IFMT)==S_IFREG,info.st_uid==getuid(),info.st_nlink==1 else { throw Issue.invalid("Fichier de paramètres invalide") }
        } else if errno != ENOENT { throw Issue.invalid("Contrôle du fichier impossible") }
        let fd=open(tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else { throw Issue.invalid("Création temporaire impossible") }
        var success=false
        defer { close(fd);if !success { unlink(tmp) } }
        let ok=bytes.withUnsafeBytes { ptr -> Bool in
            guard let base=ptr.baseAddress else { return bytes.isEmpty }
            var offset=0
            while offset<bytes.count { let n=write(fd,base.advanced(by:offset),bytes.count-offset);if n<=0 { return false };offset+=n }
            return true
        }
        guard ok,fsync(fd)==0,rename(tmp,final)==0 else { throw Issue.invalid("Écriture atomique impossible") }
        success=true
        let dfd=open(root.path,O_RDONLY|O_DIRECTORY);if dfd>=0 { _=fsync(dfd);close(dfd) }
    }
    private func seeded(_ game: GameSettingsContext) -> [String:Any] {
        var value=defaults();guard sm2(game) else { return value }
        let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Runtime/D3DMetal/Games/2651280/prefix/user.reg")
        guard let attr=try? FileManager.default.attributesOfItem(atPath:url.path),attr[.type] as? FileAttributeType == .typeRegular,(attr[.size] as? NSNumber)?.intValue ?? 9_000_000 <= 2_000_000,let content=try? String(contentsOf:url,encoding:.utf8) else { return value }
        var active=false, found:[String:Int]=[:]
        for line in content.components(separatedBy:.newlines) {
            if line.hasPrefix("[") { active=line.hasPrefix("[Software\\\\Insomniac Games\\\\Marvel's Spider-Man 2\\\\Graphics]");continue }
            guard active,let match=line.range(of:#"^"[A-Za-z0-9]+"=dword:[0-9a-fA-F]{8}$"#,options:.regularExpression),match.lowerBound==line.startIndex,let quote=line.dropFirst().firstIndex(of:"\"") else { continue }
            let name=String(line[line.index(after:line.startIndex)..<quote]);if let hex=Int(line.suffix(8),radix:16) { found[name]=hex }
        }
        var display=value["display"] as! [String:Any],graphics=value["graphics"] as! [String:Any]
        if let w=found["FullscreenWidth"],(640...7680).contains(w) { display["width"]=w }
        if let h=found["FullscreenHeight"],(480...4320).contains(h) { display["height"]=h }
        if let r=found["RefreshRate"],(1...1000).contains(r) { display["refreshRate"]=r }
        if found["Fullscreen"] == 0 { display["mode"]="windowed" } else if found["Fullscreen"] == 1 { display["mode"] = found["ExclusiveFullscreen"] == 1 ? "exclusive" : "fullscreen" }
        if let h=found["HDR"],h==0 || h==1 { display["hdr"] = h==1 }
        if let n=found["VSync"],n==0 || n==1 { display["vsync"] = n==1 }
        if let n=found["DynamicResolutionTargetFPS"],[0,30,60].contains(n) { graphics["dynamicFPS"]=n }
        if let n=found["FrameGen"],n==0 || n==1 { graphics["frameGeneration"] = n==1 }
        if let n=found["FilmGrainStrength"],(0...1000).contains(n) { graphics["grain"]=Double(n)/1000 }
        if let n=found["UpscaleSharpness"],(0...1000).contains(n) { graphics["sharpness"]=Double(n)/1000 }
        value["display"]=display;value["graphics"]=graphics;return value
    }
    private func validFields(_ fields:[String], game:GameSettingsContext) throws -> Set<String> {
        let base:Set<String> = ["launchArgs","backend"]
        let display:Set<String> = ["display.mode","display.screenID","display.width","display.height","display.refreshRate","display.retina","display.vsync","display.hdr"]
        let graphics:Set<String> = ["graphics.upscaler","graphics.quality","graphics.dynamicFPS","graphics.frameGeneration","graphics.grain","graphics.sharpness"]
        let permitted = eligible(game) ? base.union(sm2(game) ? display.union(graphics) : []) : []
        let selected=Set(fields)
        guard fields.count<=16,fields.count==selected.count,selected.isSubset(of:permitted) else { throw Issue.invalid("Champs à appliquer inconnus ou indisponibles") }
        return selected
    }
    private func load(_ game: GameSettingsContext) throws -> ([String:Any],String,Set<String>,[String:String]) {
        let key=try safeKey(game),file=root.appendingPathComponent(key+".json")
        guard FileManager.default.fileExists(atPath:file.path) else {
            let initial=seeded(game),hex=SHA256.hash(data:try data(initial)).prefix(16).map { String(format:"%02x",$0) }.joined()
            let rev="\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
            return (initial,rev,[],[:])
        }
        let attr=try FileManager.default.attributesOfItem(atPath:file.path)
        guard attr[.type] as? FileAttributeType == .typeRegular, (attr[.size] as? NSNumber)?.intValue ?? 100_000 <= 64_000 else { throw Issue.invalid("Fichier de paramètres invalide") }
        let bytes=try Data(contentsOf:file);guard let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw Issue.invalid("JSON invalide") }
        if value["schemaVersion"] as? Int == 1 { throw Issue.invalid("Ancien schéma 1 non pris en charge ; aucune préférence appliquée") }
        guard let v=value["schemaVersion"] as? NSNumber,CFGetTypeID(v) != CFBooleanGetTypeID(),v.doubleValue == 2 || v.doubleValue == 3 else { throw Issue.invalid("Version de paramètres inconnue") }
        let version=v.intValue
        let expectedKeys:Set<String> = version == 2 ? ["schemaVersion","gameKey","revision","settings","applyFields"] : ["schemaVersion","gameKey","revision","settings","applyFields","fieldRevisions"]
        guard Set(value.keys)==expectedKeys,let storedKey=value["gameKey"] as? String,storedKey==key,let rev=value["revision"] as? String,let uuid=UUID(uuidString:rev),uuid.uuidString.lowercased()==rev,let settings=value["settings"] as? [String:Any],let fields=value["applyFields"] as? [String] else { throw Issue.invalid("JSON invalide") }
        let applied=try validFields(fields,game:game)
        var fieldRevisions:[String:String]=[:]
        if version == 3 {
            guard let stored=value["fieldRevisions"] as? [String:String],Set(stored.keys)==applied,stored.count<=16 else { throw Issue.invalid("Révisions de champs invalides") }
            for (field,fieldRevision) in stored {
                guard let uuid=UUID(uuidString:fieldRevision),uuid.uuidString.lowercased()==fieldRevision else { throw Issue.invalid("Révision de champ invalide") }
                fieldRevisions[field]=fieldRevision
            }
        } else {
            for field in applied { fieldRevisions[field]=rev }
        }
        return (try validate(settings,game:game),rev,applied,fieldRevisions)
    }
    private func measurements(_ game: GameSettingsContext) -> [String:Any] {
        guard sm2(game) else { return [:] }
        let name=NSUserName();let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Runtime/D3DMetal/Games/2651280/prefix/drive_c/users/\(name)/Documents/Marvel's Spider-Man 2/Marvel's Spider-Man 2.log")
        guard let attr=try? FileManager.default.attributesOfItem(atPath:url.path),attr[.type] as? FileAttributeType == .typeRegular,let size=(attr[.size] as? NSNumber)?.uint64Value,let date=attr[.modificationDate] as? Date,let f=try? FileHandle(forReadingFrom:url) else { return [:] }
        defer { try? f.close() };do { try f.seek(toOffset:size>2_000_000 ? size-2_000_000 : 0) } catch { return [:] }
        guard let bytes=try? f.read(upToCount:2_000_000),let text=String(data:bytes,encoding:.utf8) else { return [:] }
        let parsed=Self.parseLog(text)
        return ["source":"spiderman2-game-log","timestamp":ISO8601DateFormatter().string(from:date),"fpsSamples":parsed.samples,"observedSettings":parsed.latest,"correlation":"preceding-complete-settings-block"]
    }
    static func parseLog(_ text:String) -> (samples:[[String:Any]],latest:[String:String]) {
        guard let pattern=try? NSRegularExpression(pattern:#"^(\d\d:\d\d:\d\d:\d\d\d).*\bfps:\s*([0-9]+(?:\.[0-9]+)?)\s*$"#,options:[.caseInsensitive]) else { return ([],[:]) }
        let labels:[String:String] = ["resolution":"Resolution","dynamic resolution fps target":"Dynamic resolution FPS target","upscale method":"Upscale Method","upscale quality":"Upscale Quality","frame generation":"Frame Generation","vsync":"VSync","window mode":"Window mode"]
        var samples:[[String:Any]]=[],current:[String:String]=[:],latest:[String:String]=[:],inBlock=false
        for line in text.components(separatedBy:.newlines) {
            if let pos=line.range(of:"[Settings] ",options:.caseInsensitive) {
                let v=String(line[pos.upperBound...]).trimmingCharacters(in:.whitespaces)
                if v.lowercased().hasPrefix("directx version:") { current=[:];inBlock=true }
                if inBlock, let colon=v.firstIndex(of:":") {
                    let key=String(v[..<colon]).lowercased()
                    if let canonical=labels[key] { current[canonical]=String(v[v.index(after:colon)...]).trimmingCharacters(in:.whitespaces) }
                }
                if v.lowercased() == "end of settings." && inBlock { latest=current;inBlock=false }
            }
            let ns=line as NSString,range=NSRange(location:0,length:ns.length)
            if let m=pattern.firstMatch(in:line,range:range),let fps=Double(ns.substring(with:m.range(at:2))),fps.isFinite,fps>=0,fps<=1000 {
                samples.append(["timestamp":ns.substring(with:m.range(at:1)),"fps":fps,"observedSettings":latest]);if samples.count>100 { samples.removeFirst() }
            }
        }
        return (samples,latest)
    }
    func snapshot(game: GameSettingsContext, hardware: [String:Any], displays: [[String:Any]]) -> [String:Any] {
        do {
            let (settings,rev,fields,_)=try load(game);let d=settings["display"] as! [String:Any];let g=settings["graphics"] as! [String:Any]
            let width=(d["width"] as! NSNumber).intValue,height=(d["height"] as! NSNumber).intValue,fps=(g["dynamicFPS"] as! NSNumber).intValue
            var caps=capabilities(game)
            let primary=displays.first(where: { ($0["isPrimary"] as? Bool)==true })
            func option(_ screen:[String:Any],value:String) -> [String:Any]? {
                guard let name=screen["name"] as? String,name.count <= 200,let w=(screen["width"] as? NSNumber)?.intValue,let h=(screen["height"] as? NSNumber)?.intValue,w>0,h>0,w<=16384,h<=16384 else { return nil }
                var result:[String:Any]=["value":value,"label":"\(name) — \(w)×\(h)","width":w,"height":h]
                if let hz=screen["refreshRate"] as? NSNumber,hz.doubleValue.isFinite,hz.doubleValue>0,hz.doubleValue<=1000 { result["refreshRate"]=hz }
                return result
            }
            var choices:[[String:Any]]=[primary.flatMap { option($0,value:"primary") } ?? ["value":"primary","label":"Écran principal"]]
            var ids=Set<String>()
            for screen in displays {
                guard let id=screen["id"] as? String,UUID(uuidString:id) != nil,ids.insert(id).inserted,let item=option(screen,value:id) else { continue }
                choices.append(item)
            }
            caps["displays"]=choices
            let selection=d["screenID"] as? String ?? "primary"
            let chosen=displays.first(where: { ($0["id"] as? String)==selection }) ?? primary
            var calc:[String:Any] = [:]
            if sm2(game) {
                calc=["outputPixels":width*height,"fsrQualityScale":2.0/3.0,"estimatedRenderPixels":Int((Double(width)*2/3).rounded())*Int((Double(height)*2/3).rounded()),"basis":"proposed-settings"]
                if fps>0 { calc["frameBudgetMs"]=1000.0/Double(fps) }
                if let chosen=chosen,let id=chosen["id"] as? String,UUID(uuidString:id) != nil { calc["proposedDisplay"]=id }
            }
            let exists=FileManager.default.fileExists(atPath:root.appendingPathComponent(try safeKey(game)+".json").path)
            return ["gameId":game.id,"status":"ready","revision":rev,"settings":settings,"applyFields":fields.sorted(),"capabilities":caps,"measurements":measurements(game),"calculation":calc, "settingsOrigin":exists ? "saved-request" : "partial-registry-and-defaults", "hardware":hardware]
        } catch { return ["gameId":game.id,"status":"error","error":error.localizedDescription,"capabilities":capabilities(game),"measurements":[:],"calculation":[:]] }
    }
    func save(game: GameSettingsContext, payload: [String:Any], expectedRevision: String?, changedFields: [String]) -> [String:Any] {
        do {
            let key=try safeKey(game);let valid=try validate(payload,game:game);let changed=try validFields(changedFields,game:game)
            try ensureSafeRoot()
            var info=stat()
            guard lstat(root.path,&info)==0, (info.st_mode & S_IFMT)==S_IFDIR,info.st_uid==getuid() else { throw Issue.invalid("Dossier de paramètres invalide") }
            let lockPath=root.appendingPathComponent(key+".lock").path;let fd=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw Issue.invalid("Verrou inaccessible") };defer { close(fd) }
            guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,(info.st_mode & 0o077)==0 else { throw Issue.invalid("Verrou invalide") }
            guard flock(fd,LOCK_EX)==0 else { throw Issue.invalid("Verrou impossible") };defer { flock(fd,LOCK_UN) }
            let (previous,current,previousFields,previousFieldRevisions)=try load(game)
            guard let expected=expectedRevision,expected==current else { throw Issue.invalid("Révision modifiée : rechargez les paramètres") }
            var merged=previous
            for field in changed {
                let parts=field.split(separator:".").map(String.init)
                if parts.count==1 { merged[field]=valid[field] }
                else { var group=merged[parts[0]] as! [String:Any];let requested=valid[parts[0]] as! [String:Any];group[parts[1]]=requested[parts[1]];merged[parts[0]]=group }
            }
            let nextRevision=UUID().uuidString.lowercased()
            var fieldRevisions=previousFieldRevisions
            for field in changed { fieldRevisions[field]=nextRevision }
            let document:[String:Any]=["schemaVersion":3,"gameKey":key,"revision":nextRevision,"settings":merged,"applyFields":previousFields.union(changed).sorted(),"fieldRevisions":fieldRevisions];let bytes=try data(document);try writeAtomic(bytes,name:key+".json")
            var result=snapshot(game:game,hardware:[:],displays:[]);result["status"]="saved";return result
        } catch { return ["gameId":game.id,"status":"error","error":error.localizedDescription,"capabilities":capabilities(game),"measurements":[:],"calculation":[:]] }
    }
    func launchArguments(for game: GameSettingsContext) -> [String] { guard eligible(game),let (settings,_,fields,_)=try? load(game),fields.contains("launchArgs"),let text=settings["launchArgs"] as? String else { return [] }; return (try? Self.parseArguments(text)) ?? [] }
    func requestedBackend(for game: GameSettingsContext) -> String { guard eligible(game),let (settings,_,fields,_)=try? load(game),fields.contains("backend") else { return "auto" };return settings["backend"] as? String ?? "auto" }
}
