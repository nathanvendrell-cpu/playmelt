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
    let store: String
    let supportsPerformanceSettings: Bool
    let supportsSpatialUpscaling: Bool
    let performanceReadOnlyReason: String?
    let spatialUpscalingReadOnlyReason: String?
    let resolvedPerformanceBackend: String?
    init(id:String,appID:String,platform:String,installed:Bool,path:String,requiredRenderer:String,supportsLaunchArguments:Bool=true,store:String="steam",supportsPerformanceSettings:Bool=false,supportsSpatialUpscaling:Bool=false,performanceReadOnlyReason:String?=nil,spatialUpscalingReadOnlyReason:String?=nil,resolvedPerformanceBackend:String?=nil) {
        self.id=id;self.appID=appID;self.platform=platform;self.installed=installed;self.path=path;self.requiredRenderer=requiredRenderer;self.supportsLaunchArguments=supportsLaunchArguments
        self.store=store;self.supportsPerformanceSettings=supportsPerformanceSettings;self.supportsSpatialUpscaling=supportsSpatialUpscaling;self.performanceReadOnlyReason=performanceReadOnlyReason;self.spatialUpscalingReadOnlyReason=spatialUpscalingReadOnlyReason
        self.resolvedPerformanceBackend=resolvedPerformanceBackend
    }
}

/// A normalized request for a future launch, never a claim of measured effect.
struct GamePerformanceRequest: Equatable {
    let fpsLimit: Int?
    let metalFXScale: Double
    let outputWidth: Int
    let outputHeight: Int
    let renderWidth: Int
    let renderHeight: Int
    let appliedFields: Set<String>
}

/// Preferences are inert until a caller explicitly integrates them into a launch.
final class GameSettingsStore {
    let root: URL
    /// Injected by the app so this file stays compilable alone in tests and
    /// fails closed (no option) when the caller does not provide a probe.
    private let nvidiaBridgeAvailable: () -> Bool
    private let homeDirectory: URL
    init(root: URL, nvidiaBridgeAvailable: (() -> Bool)? = nil, homeDirectory: URL? = nil) {
        self.root = root
        self.nvidiaBridgeAvailable = nvidiaBridgeAvailable ?? { false }
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }
    private func eligible(_ game: GameSettingsContext) -> Bool {
        game.platform.lowercased() == "windows" && game.installed && game.supportsLaunchArguments && !game.appID.isEmpty
    }
    private func sm2(_ game: GameSettingsContext) -> Bool { eligible(game) && game.appID == "2651280" }
    private func performanceReadable(_ game: GameSettingsContext) -> Bool {
        game.platform.lowercased()=="windows" && game.installed && game.appID != "2651280" &&
            ["steam","epic","gog","local"].contains(game.store.lowercased()) &&
            (game.store.lowercased()=="local" ? !game.id.isEmpty && game.id.utf8.count<=512 : !game.appID.isEmpty)
    }
    private func performanceEditable(_ game: GameSettingsContext) -> Bool { performanceReadable(game) && game.supportsPerformanceSettings }
    private let performanceFields:Set<String> = ["performance.fpsLimit","performance.metalFXScale","performance.outputWidth","performance.outputHeight"]
    private func performanceDefaults() -> [String:Any] { ["fpsLimit":0,"metalFXScale":1.0,"outputWidth":1280,"outputHeight":720] }
    private func safeKey(_ game: GameSettingsContext) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard game.appID.count <= 80, game.appID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !game.platform.isEmpty, game.platform.count <= 30, game.platform.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              game.appID != ".", game.appID != ".." else { throw Issue.invalid("Identifiant de jeu invalide") }
        let store=game.store.lowercased()
        guard !store.isEmpty,store.count<=30,store.unicodeScalars.allSatisfy({ allowed.contains($0) }),store != ".",store != ".." else { throw Issue.invalid("Plateforme de vente invalide") }
        let identifier=game.appID.isEmpty ? "local-"+SHA256.hash(data:Data(game.id.utf8)).prefix(12).map{String(format:"%02x",$0)}.joined() : game.appID
        // Imported local titles historically share their Steam appID settings;
        // changing this namespace would silently orphan their saved requests.
        let namespace=store=="local" ? "steam" : store
        return "\(namespace)-\(identifier)-\(game.platform.lowercased())"
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
        else if enabled {options += [["value":"dxmt","label":"Wine · DirectX 10/11 (DXMT)"],["value":"d3dmetal","label":"DirectX 12 (D3DMetal)"]]}
        if options.contains(where: { $0["value"] == "d3dmetal" }), nvidiaBridgeAvailable() {
            // Honest label: the game still asks for DLSS; Apple translates it.
            options.append(["value":"d3dmetal-nv","label":"D3DMetal · DLSS → MetalFX (pont NVIDIA)"])
            // Ray tracing DX12 (DXR) traduit par D3DMetal ; requis pour que le jeu
            // propose le Ray Reconstruction (DLSSD → débruiteur MetalFX).
            options.append(["value":"d3dmetal-nv-rt","label":"D3DMetal · DLSS → MetalFX + ray tracing (DXR)"])
        }
        var result: [String:Any] = ["launchArgs":enabled,"backends":options,"display":special,"graphics":special]
        let editable=performanceEditable(game)
        let reason=game.platform.lowercased() != "windows" ? "Les jeux Mac natifs et cloud ne passent pas par ces réglages Wine." : game.appID=="2651280" ? "Spider-Man 2 conserve son profil verrouillé ; ces nouveaux réglages ne s’y appliquent pas." : !game.installed ? "Ces réglages nécessitent un jeu Windows installé." : game.performanceReadOnlyReason ?? "Cette route de lancement ne transmet pas ces réglages. Les demandes enregistrées restent inactives."
        result["performance"]=["fpsLimit":editable,"spatialUpscaling":editable && game.supportsSpatialUpscaling,"visible":game.appID != "2651280","renderer":game.resolvedPerformanceBackend ?? game.requiredRenderer.lowercased(),"fpsBackends":["dxmt","d3dmetal","d3dmetal-nv","d3dmetal-nv-rt"],"reason":editable ? "Limite FPS : DXMT ou D3DMetal 4 qualifié. Demandes pour le prochain lancement, effet non mesuré." : reason,"spatialReason":game.spatialUpscalingReadOnlyReason ?? "Le rendu doit pouvoir être fixé par une route Unity ou Unreal qualifiée ; aucun effet spatial n’est promis pour un exécutable inconnu."]
        if options.contains(where: { $0["value"] == "d3dmetal-nv" }) { result["resolutionGuide"] = Self.resolutionGuide }
        if !enabled { result["readOnlyReason"] = "Réglages de lancement indisponibles pour cette plateforme ou ce jeu non installé." }
        return result
    }
    /// Mode DLSS conseillé (à choisir dans le jeu) pour une sortie 2K ou 4K.
    /// Coûts mesurés le 12/11/2026 sur M3 Max, macOS 27.0.1, MetalFX seul
    /// (`probes/metalfx-2k-4k-cost.swift`, médiane GPU de 30 images) : ce n'est
    /// pas le coût du jeu, seulement celui de la traduction DLSS → MetalFX.
    static let resolutionGuide: [String:Any] = [
        "source": "MetalFX seul, M3 Max, 12/11/2026 — le rendu du jeu s'ajoute",
        "rows": [
            ["output":"2K · 2560×1440","rayTracing":false,"dlssMode":"Qualité","render":"1707×960","metalFXMs":0.60],
            ["output":"2K · 2560×1440","rayTracing":true,"dlssMode":"Performance","render":"1280×720","metalFXMs":4.51],
            ["output":"4K · 3840×2160","rayTracing":false,"dlssMode":"Performance","render":"1920×1080","metalFXMs":1.06],
            ["output":"4K · 3840×2160","rayTracing":true,"dlssMode":"Ultra performance","render":"1280×720","metalFXMs":5.48],
        ] as [[String:Any]],
        "note": "Avec ray tracing, le débruiteur (Ray Reconstruction) coûte 6,8 ms en 2K Qualité et 15,2 ms en 4K Qualité : un mode plus bas garde la fluidité.",
    ]
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
    private func validate(_ raw: [String:Any], game: GameSettingsContext, readingSaved: Bool = false) throws -> [String:Any] {
        guard eligible(game) || performanceReadable(game) else { throw Issue.invalid("Jeu non pris en charge") }
        var normalized=raw
        if game.appID != "2651280", normalized["performance"] == nil { normalized["performance"]=performanceDefaults() }
        try keys(normalized,game.appID == "2651280" ? ["launchArgs","backend","display","graphics"] : ["launchArgs","backend","display","graphics","performance"])
        guard let args=raw["launchArgs"] as? String else { throw Issue.invalid("Arguments invalides") }; _ = try Self.parseArguments(args)
        let backends=(capabilities(game)["backends"] as? [[String:String]] ?? []).compactMap { $0["value"] }
        // A temporarily unavailable component must not make saved preferences
        // unreadable: the user still needs to open them and choose another engine.
        let knownBackends = ["auto", "dxmt", "d3dmetal", "d3dmetal-nv", "d3dmetal-nv-rt"]
        let backend=try choice(raw["backend"],readingSaved ? knownBackends : backends)
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
        _ = try choice(graphics["upscaler"],readingSaved ? ["fsr", "dlss"] : ["fsr"]); _ = try choice(graphics["quality"],["quality"])
        let fps=try number(graphics["dynamicFPS"],0,60,integer:true); guard [0.0,30.0,60.0].contains(fps) else { throw Issue.invalid("Cible FPS non prise en charge") }
        _ = try number(graphics["grain"],0,1); _ = try number(graphics["sharpness"],0,1)
        if !sm2(game) {
            let d=defaults()
            guard NSDictionary(dictionary:display).isEqual(to:d["display"] as! [AnyHashable:Any]), NSDictionary(dictionary:graphics).isEqual(to:d["graphics"] as! [AnyHashable:Any]) else { throw Issue.invalid("Réglages graphiques indisponibles") }
        }
        var result:[String:Any] = ["launchArgs":args,"backend":backend,"display":display,"graphics":graphics]
        if game.appID != "2651280" {
            guard let performance=normalized["performance"] as? [String:Any] else { throw Issue.invalid("Réglages de performance invalides") }
            try keys(performance,["fpsLimit","metalFXScale","outputWidth","outputHeight"])
            let limit=try number(performance["fpsLimit"],0,120,integer:true)
            guard [0.0,30,40,45,60,90,120].contains(limit) else { throw Issue.invalid("Limite FPS non prise en charge") }
            let scale=try number(performance["metalFXScale"],1,2)
            guard [1.0,1.5,2.0].contains(scale) else { throw Issue.invalid("Facteur MetalFX non pris en charge") }
            _ = try number(performance["outputWidth"],640,7680,integer:true)
            _ = try number(performance["outputHeight"],480,4320,integer:true)
            result["performance"]=performance
        }
        return result
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
        var value=defaults();guard sm2(game) else { if game.appID != "2651280" { value["performance"]=performanceDefaults() };return value }
        let url=homeDirectory.appendingPathComponent("Library/Application Support/Playmelt/Runtime/D3DMetal/Games/2651280/prefix/user.reg")
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
    private func validFields(_ fields:[String], game:GameSettingsContext, readingSaved:Bool=false, clearingFields:Set<String>=[]) throws -> Set<String> {
        let base:Set<String> = ["launchArgs","backend"]
        let display:Set<String> = ["display.mode","display.screenID","display.width","display.height","display.refreshRate","display.retina","display.vsync","display.hdr"]
        let graphics:Set<String> = ["graphics.upscaler","graphics.quality","graphics.dynamicFPS","graphics.frameGeneration","graphics.grain","graphics.sharpness"]
        var permitted:Set<String> = eligible(game) ? base.union(sm2(game) ? display.union(graphics) : []) : []
        if readingSaved ? performanceReadable(game) : performanceEditable(game) { permitted.formUnion(performanceFields) }
        if !readingSaved && !game.supportsSpatialUpscaling { permitted.subtract(["performance.metalFXScale","performance.outputWidth","performance.outputHeight"]) }
        if readingSaved && performanceReadable(game) { permitted.formUnion(base) }
        if performanceReadable(game) { permitted.formUnion(clearingFields.intersection(["performance.fpsLimit","performance.metalFXScale","backend"])) }
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
        let applied=try validFields(fields,game:game,readingSaved:true)
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
        return (try validate(settings,game:game,readingSaved:true),rev,applied,fieldRevisions)
    }
    private func measurements(_ game: GameSettingsContext) -> [String:Any] {
        guard sm2(game) else { return [:] }
        let name=NSUserName();let url=homeDirectory.appendingPathComponent("Library/Application Support/Playmelt/Runtime/D3DMetal/Games/2651280/prefix/drive_c/users/\(name)/Documents/Marvel's Spider-Man 2/Marvel's Spider-Man 2.log")
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
    private func performanceRequest(settings:[String:Any], fields:Set<String>, game:GameSettingsContext, resolvedBackend:String) throws -> GamePerformanceRequest? {
        guard game.appID != "2651280",let group=settings["performance"] as? [String:Any] else { return nil }
        let selected=fields.intersection(performanceFields)
        guard !selected.intersection(["performance.fpsLimit","performance.metalFXScale"]).isEmpty else { return nil }
        let fps=selected.contains("performance.fpsLimit") ? (group["fpsLimit"] as? NSNumber)?.intValue ?? 0 : 0
        let scale=selected.contains("performance.metalFXScale") ? (group["metalFXScale"] as? NSNumber)?.doubleValue ?? 1 : 1
        if fps>0 || scale>1 {
            guard performanceEditable(game) else { throw Issue.invalid(game.performanceReadOnlyReason ?? "La demande de performance enregistrée n’est pas applicable à cette route de lancement. Désactivez-la dans les paramètres.") }
            guard ["dxmt","d3dmetal","d3dmetal-nv","d3dmetal-nv-rt"].contains(resolvedBackend) else { throw Issue.invalid("Le moteur de la demande de performance n’est pas résolu ou pris en charge. Aucun réglage n’a été appliqué.") }
        }
        if scale>1 {
            guard resolvedBackend=="dxmt" else { throw Issue.invalid("L’upscaling MetalFX spatial demandé nécessite DirectX 11/DXMT. Désactivez-le pour ce moteur.") }
            guard game.supportsSpatialUpscaling else { throw Issue.invalid(game.spatialUpscalingReadOnlyReason ?? "Le jeu ne possède pas de route qualifiée pour fixer sa résolution de rendu. Désactivez la demande MetalFX spatiale.") }
        }
        let width=(group["outputWidth"] as! NSNumber).intValue,height=(group["outputHeight"] as! NSNumber).intValue
        func render(_ value:Int) -> Int { scale==1 ? value : Int((Double(value)/scale).rounded(.down))/2*2 }
        let renderWidth=render(width),renderHeight=render(height)
        // Scale×even input is integral for both approved factors. Report the
        // realizable output rather than an incompatible desired odd size.
        return GamePerformanceRequest(fpsLimit:fps>0 ? fps : nil,metalFXScale:scale,outputWidth:scale==1 ? width : Int(Double(renderWidth)*scale),outputHeight:scale==1 ? height : Int(Double(renderHeight)*scale),renderWidth:renderWidth,renderHeight:renderHeight,appliedFields:selected)
    }
    /// The caller must qualify the actual launch route and D3DMetal version, then
    /// pass its resolved backend. This function never edits a game or runtime.
    func performanceRequest(for game:GameSettingsContext,resolvedBackend:String) throws -> GamePerformanceRequest? {
        guard game.platform.lowercased()=="windows",game.installed,game.appID != "2651280" else { return nil }
        let (settings,_,fields,_)=try load(game)
        return try performanceRequest(settings:settings,fields:fields,game:game,resolvedBackend:resolvedBackend)
    }
    func snapshot(game: GameSettingsContext, hardware: [String:Any], displays: [[String:Any]]) -> [String:Any] {
        do {
            let (settings,rev,fields,_)=try load(game);let d=settings["display"] as! [String:Any];let g=settings["graphics"] as! [String:Any]
            let width=(d["width"] as! NSNumber).intValue,height=(d["height"] as! NSNumber).intValue,fps=(g["dynamicFPS"] as! NSNumber).intValue
            var caps=capabilities(game)
            let backend = settings["backend"] as? String ?? "auto"
            let activeBackend = eligible(game) && fields.contains("backend") ? backend : "auto"
            var launchIssue = ""
            if !(caps["backends"] as? [[String:String]] ?? []).contains(where: { $0["value"] == activeBackend }) {
                launchIssue = activeBackend.hasPrefix("d3dmetal-nv")
                    ? "Le pont NVIDIA sélectionné n’est pas installé. Choisissez Automatique ou D3DMetal."
                    : "Le moteur sélectionné n’est pas disponible pour ce jeu. Choisissez Automatique."
                var options = caps["backends"] as? [[String:String]] ?? []
                options.append(["value":backend,"label":backend + " · indisponible"])
                caps["backends"] = options
            }
            if fields.contains("backend"), !(caps["backends"] as? [[String:String]] ?? []).contains(where: { $0["value"]==backend }) {
                var options=caps["backends"] as? [[String:String]] ?? []
                options.append(["value":backend,"label":backend+" · demande inactive"]);caps["backends"]=options
            }
            if fields.contains("graphics.upscaler"), g["upscaler"] as? String == "dlss", !nvidiaBridgeAvailable() {
                launchIssue = "Le pont NVIDIA requis par DLSS n’est pas installé. Choisissez Automatique et appliquez FSR Qualité."
            }
            let performanceBackend=activeBackend=="auto" ? game.resolvedPerformanceBackend ?? game.requiredRenderer.lowercased() : activeBackend
            // "auto" is unresolved here; the runtime must call the throwing API
            // again after resolving the engine, before it starts any process.
            do { _ = try performanceRequest(settings:settings,fields:fields,game:game,resolvedBackend:performanceBackend) }
            catch { if launchIssue.isEmpty { launchIssue=error.localizedDescription } }
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
            return ["gameId":game.id,"status":"ready","revision":rev,"settings":settings,"applyFields":fields.sorted(),"capabilities":caps,"measurements":measurements(game),"calculation":calc, "settingsOrigin":exists ? "saved-request" : "partial-registry-and-defaults", "hardware":hardware,"launchBlockReason":launchIssue]
        } catch { return ["gameId":game.id,"status":"error","error":error.localizedDescription,"capabilities":capabilities(game),"measurements":[:],"calculation":[:]] }
    }
    func save(game: GameSettingsContext, payload: [String:Any], expectedRevision: String?, changedFields: [String]) -> [String:Any] {
        do {
            let key=try safeKey(game);let valid=try validate(payload,game:game,readingSaved:true)
            var clearing=Set<String>()
            if valid["backend"] as? String == "auto" { clearing.insert("backend") }
            if let group=valid["performance"] as? [String:Any] {
                if (group["fpsLimit"] as? NSNumber)?.intValue==0 { clearing.insert("performance.fpsLimit") }
                if (group["metalFXScale"] as? NSNumber)?.doubleValue==1 { clearing.insert("performance.metalFXScale") }
            }
            let changed=try validFields(changedFields,game:game,clearingFields:clearing)
            try ensureSafeRoot()
            var info=stat()
            guard lstat(root.path,&info)==0, (info.st_mode & S_IFMT)==S_IFDIR,info.st_uid==getuid() else { throw Issue.invalid("Dossier de paramètres invalide") }
            let lockPath=root.appendingPathComponent(key+".lock").path;let fd=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw Issue.invalid("Verrou inaccessible") };defer { close(fd) }
            guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,(info.st_mode & 0o077)==0 else { throw Issue.invalid("Verrou invalide") }
            guard flock(fd,LOCK_EX)==0 else { throw Issue.invalid("Verrou impossible") };defer { flock(fd,LOCK_UN) }
            let (previous,current,previousFields,previousFieldRevisions)=try load(game)
            guard let expected=expectedRevision,expected==current else { throw Issue.invalid("Révision modifiée : rechargez les paramètres") }
            if changed.contains("backend") {
                _ = try choice(valid["backend"],(capabilities(game)["backends"] as? [[String:String]] ?? []).compactMap { $0["value"] })
            }
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
    func launchBlockReason(for game: GameSettingsContext) -> String? {
        guard eligible(game) || performanceReadable(game) else { return nil }
        do {
            let (settings,_,fields,_) = try load(game)
            let backend = eligible(game) && fields.contains("backend") ? settings["backend"] as? String ?? "auto" : "auto"
            let options = capabilities(game)["backends"] as? [[String:String]] ?? []
            if !options.contains(where: { $0["value"] == backend }) {
                return "Le moteur sélectionné est indisponible. Ouvrez les paramètres et choisissez Automatique."
            }
            if fields.contains("graphics.upscaler"), (settings["graphics"] as? [String:Any])?["upscaler"] as? String == "dlss", !nvidiaBridgeAvailable() {
                return "Le pont NVIDIA requis par DLSS n’est pas installé. Appliquez FSR Qualité dans les paramètres."
            }
            let renderer=backend=="auto" ? game.resolvedPerformanceBackend ?? game.requiredRenderer.lowercased() : backend
            _ = try performanceRequest(settings:settings,fields:fields,game:game,resolvedBackend:renderer)
            return nil
        } catch { return "Paramètres de lancement invalides : " + error.localizedDescription }
    }
    func launchArguments(for game: GameSettingsContext) -> [String] { guard eligible(game),let (settings,_,fields,_)=try? load(game),fields.contains("launchArgs"),let text=settings["launchArgs"] as? String else { return [] }; return (try? Self.parseArguments(text)) ?? [] }
    func requestedBackend(for game: GameSettingsContext) -> String { guard eligible(game),let (settings,_,fields,_)=try? load(game),fields.contains("backend") else { return "auto" };return settings["backend"] as? String ?? "auto" }
}
