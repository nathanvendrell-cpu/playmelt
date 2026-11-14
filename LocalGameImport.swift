import AppKit

/// Publisher-selected Steam entry point, kept separate from local imports.
struct SteamDepotLaunchManifest {
    let executable:String,arguments:[String],workingDirectory:String,renderer:String
    let preparationTasks:[SteamPreparationTask],prerequisiteChecks:[SteamPrerequisiteCheck],steamClientRequired:Bool
    var requiresOfficialSteam:Bool {steamClientRequired || !prerequisiteChecks.isEmpty || preparationTasks.contains(where:{$0.kind == "official-installscript"})}
    /// First-start components and licence validation belong to the official
    /// Windows client. Their pending state must block direct EXE execution,
    /// not prevent that client from doing the work in the first place.
    func officialClientIssue(accountID:String,descriptor supplied:PlaymeltRuntimeDescriptor? = nil)->String? {
        guard renderer != "auto" else{return "Choisis un moteur dans les paramètres du jeu pour tester son premier lancement."}
        let base=RuntimeSetup().descriptor()
        let descriptor=supplied ?? (renderer == "d3dmetal" ? (try? D3DMetalRuntime(store:D3DMetalStore()).descriptor(base:base)):base)
        guard let descriptor,descriptor.readyEngine else{return "Le moteur Windows doit terminer sa préparation."}
        guard descriptor.steamInstalled else{return "Une première installation et connexion à Steam Windows est nécessaire pour ce jeu."}
        let users=TextVDF.read(descriptor.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users")
        guard LibraryModel.validAccountID(accountID),activeSteamAccount(users)==accountID else{return "Connecte le même compte Steam dans l’environnement Windows pour activer ce jeu."}
        return nil
    }
    func preparationIssue(accountID:String,descriptor supplied:PlaymeltRuntimeDescriptor? = nil)->String? {
        if let issue=preparationTasks.first{return issue.message}
        guard renderer != "auto" else{return "Choisis un moteur dans les paramètres du jeu pour tester son premier lancement."}
        let base=RuntimeSetup().descriptor()
        let descriptor=supplied ?? (renderer == "d3dmetal" ? (try? D3DMetalRuntime(store:D3DMetalStore()).descriptor(base:base)) : base)
        guard let descriptor,descriptor.readyEngine else{return "Le moteur \(renderer == "d3dmetal" ? "DirectX 12":"Windows") doit terminer sa préparation."}
        let missing=prerequisiteChecks.filter{!$0.isSatisfied(in:descriptor.prefixURL)}
        if !missing.isEmpty {return "Composants Windows à finaliser dans Steam : " + missing.map(\.name).prefix(4).joined(separator:", ") + "."}
        if steamClientRequired {
            guard descriptor.steamInstalled else{return "Une première installation et connexion à Steam Windows est nécessaire pour ce jeu."}
            let users=TextVDF.read(descriptor.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users")
            guard LibraryModel.validAccountID(accountID),activeSteamAccount(users) == accountID else{return "Connecte le même compte Steam dans l’environnement Windows pour activer ce jeu."}
        }
        return nil
    }
    static func file(_ folder:URL)->URL {folder.appendingPathComponent(".playmelt-steam-launch.json")}
    static func read(_ folder:URL,appID:String)->Self? {
        let file=file(folder)
        guard let values=try? file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]),
              values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? 65537)<=65536,
              let data=try? Data(contentsOf:file),let raw=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              raw["schema"] as? Int == 1,raw["appID"] as? String == appID,
              raw["source"] as? String == "official-steam-console-completion",
              let executable=raw["executable"] as? String,let working=raw["workingDirectory"] as? String,
              let arguments=raw["arguments"] as? [String],arguments.count<=128,
              arguments.allSatisfy({$0.utf8.count<=8192 && !$0.unicodeScalars.contains(where:{$0.value<32})}),
              let renderer=raw["renderer"] as? String,["auto","dxmt","d3dmetal"].contains(renderer) else{return nil}
        guard var tasks=SteamPreparationTask.read(raw["preparationTasks"] ?? []),let checks=SteamPrerequisiteCheck.read(raw["prerequisiteChecks"] ?? []) else{return nil}
        if let override=raw["rendererOverride"],!(override is String) {return nil}
        let selected=raw["rendererOverride"] as? String
        guard selected == nil || ["dxmt","d3dmetal"].contains(selected!) else{return nil}
        if let automatic=raw["automaticRenderer"],!(automatic is String) {return nil}
        let automatic=raw["automaticRenderer"] as? String
        guard automatic == nil || ["dxmt","d3dmetal"].contains(automatic!) else{return nil}
        let effective=selected ?? automatic ?? renderer
        if effective != "auto" {tasks.removeAll{$0.kind == "graphics-api-unknown"}}
        func safe(_ value:String,empty:Bool=false)->Bool {
            (empty && value.isEmpty) || (!value.isEmpty && value.count<=1024 && !value.hasPrefix("/") &&
                !value.contains("\\") && !value.contains(":") && !value.unicodeScalars.contains(where:{$0.value<32}) &&
                !value.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0 == ".." || $0.isEmpty}))
        }
        guard safe(executable),executable.lowercased().hasSuffix(".exe"),safe(working,empty:true) else{return nil}
        let root=folder.appendingPathComponent("Windows").standardizedFileURL
        let target=root.appendingPathComponent(executable)
        guard root.resolvingSymlinksInPath() == root,target.resolvingSymlinksInPath().path.hasPrefix(root.path+"/"),
              let v=try? target.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),v.isRegularFile == true,v.isSymbolicLink != true else{return nil}
        if !working.isEmpty {
            let cwd=root.appendingPathComponent(working)
            guard cwd.resolvingSymlinksInPath().path.hasPrefix(root.path+"/"),(try? cwd.resourceValues(forKeys:[.isDirectoryKey]))?.isDirectory == true else{return nil}
        }
        return .init(executable:executable,arguments:arguments,workingDirectory:working,renderer:effective,preparationTasks:tasks,prerequisiteChecks:checks,steamClientRequired:raw["steamClientRequired"] as? Bool ?? false)
    }
    static func chooseRenderer(_ backend:String,folder:URL,appID:String)throws {
        guard ["auto","dxmt","d3dmetal"].contains(backend),read(folder,appID:appID) != nil else{return}
        let url=file(folder),data=try Data(contentsOf:url)
        guard var raw=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{return}
        // Preserve the publisher's base and tasks. Automatic removes only the
        // user's override, so reopening cannot silently retain a manual engine.
        if backend == "auto" {
            raw.removeValue(forKey:"rendererOverride")
            raw.removeValue(forKey:"automaticRenderer")
            raw.removeValue(forKey:"automaticRendererSource")
        }
        else {raw["rendererOverride"]=backend}
        raw["gameExecutionVerified"]=false
        try JSONSerialization.data(withJSONObject:raw,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }

    /// Select a first route from publisher metadata and bounded file metadata.
    /// This records a candidate, never a successful game execution. An explicit
    /// advanced user override remains authoritative and is never rewritten.
    static func selectAutomaticRenderer(folder:URL,appID:String,preferredRuntimeID:String?=nil)throws->Self? {
        guard let current=read(folder,appID:appID) else{return nil}
        let file=file(folder),before=try Data(contentsOf:file)
        guard file.resolvingSymlinksInPath()==file.standardizedFileURL,
              var raw=try JSONSerialization.jsonObject(with:before) as? [String:Any] else {
            throw RuntimeSetupError.failed("Le plan de lancement doit être vérifié. Les fichiers sont conservés.")
        }
        if raw["rendererOverride"] != nil {return current}
        let required=SteamGameLaunchProfile.requiredRenderer(appID:appID)
        if current.renderer != "auto",required == "auto" || current.renderer == required {return current}
        let preferred:String?
        switch preferredRuntimeID {
        case nil:preferred=nil
        case "playmelt-windows":preferred="dxmt"
        case "playmelt-d3dmetal":preferred="d3dmetal"
        default:throw RuntimeSetupError.failed("Le moteur demandé n’est pas reconnu pour cette installation Windows.")
        }
        let candidate:String,source:String
        if required != "auto" {candidate=required;source="required-renderer"}
        else if let publisher=SteamGameLaunchProfile.publisherCandidate(appID:appID) {candidate=publisher;source="publisher-minimum-requirements"}
        else {
            let windows=folder.appendingPathComponent("Windows"),fm=FileManager.default
            var unity=false,dx12=false,visited=0
            if let entries=fm.enumerator(at:windows,includingPropertiesForKeys:[.isSymbolicLinkKey],options:[.skipsHiddenFiles]) {
                for case let entry as URL in entries {
                    visited+=1
                    if visited>10000 {break}
                    if (try? entry.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true {entries.skipDescendants();continue}
                    let name=entry.lastPathComponent.lowercased(),path=entry.path.lowercased()
                    unity = unity || name=="unityplayer.dll" || name.hasSuffix("_data")
                    dx12 = dx12 || name=="d3d12core.dll" || path.contains("/plugins/nne/")
                }
            }
            if dx12 && !unity {candidate="d3dmetal";source="local-dx12-files"}
            else if unity {candidate="dxmt";source="local-unity-files"}
            else if let preferred {candidate=preferred;source="preferred-route"}
            else {candidate="dxmt";source="default-dx11-candidate"}
        }
        guard ["dxmt","d3dmetal"].contains(candidate),try Data(contentsOf:file)==before else {
            throw RuntimeSetupError.failed("Le plan de lancement a changé. Réessayez sans supprimer les fichiers.")
        }
        raw["automaticRenderer"]=candidate;raw["automaticRendererSource"]=source
        raw["gameExecutionVerified"]=false
        try JSONSerialization.data(withJSONObject:raw,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.atomic)
        return read(folder,appID:appID)
    }
}

/// A single bounded installation intent. Login never consumes the selected game.
struct SteamOfficialPreparation {
    enum Decision:Equatable {case prepareClient,openLogin,waitForLogin,prepareFiles,install(String),cancelled,expired}
    let id=UUID(),gameID:String,appID:String,runtimeID:String,account:String,expiresAt:TimeInterval,installationJobID:UUID?
    var loginOpened=false,requestInFlight=false,reusePrepared=false
    init(gameID:String,appID:String,runtimeID:String,account:String,now:TimeInterval=ProcessInfo.processInfo.systemUptime,installationJobID:UUID?=nil) {
        self.gameID=gameID;self.appID=appID;self.runtimeID=runtimeID;self.account=account;self.expiresAt=now+30*60;self.installationJobID=installationJobID
    }
    func next(selectedAccount:String,steamInstalled:Bool,activeAccount:String?,now:TimeInterval=ProcessInfo.processInfo.systemUptime)->Decision {
        guard selectedAccount == account else{return .cancelled}
        guard now<expiresAt else{return .expired}
        if requestInFlight{return .waitForLogin}
        if !steamInstalled{return .prepareClient}
        if activeAccount != account{return loginOpened ? .waitForLogin:.openLogin}
        if !reusePrepared{return .prepareFiles}
        return .install("steam://install/"+appID)
    }
}

struct SteamPreparationCancellation {
    let preparation:Bool,installationJob:Bool
    static func decide(preparationOnly:Bool,requestedGame:String?,pendingGame:String?,currentJobGame:String?)->Self {
        if preparationOnly{return .init(preparation:pendingGame != nil && requestedGame == pendingGame,installationJob:false)}
        return .init(preparation:pendingGame != nil && currentJobGame == pendingGame,installationJob:true)
    }
}

struct SteamPreparationTask {
    let kind:String,message:String
    static func read(_ raw:Any)->[Self]? {
        guard let rows=raw as? [[String:Any]],rows.count<=64 else{return nil}
        var result:[Self]=[]
        for row in rows {
            guard let kind=row["kind"] as? String,["official-installscript","graphics-api-unknown"].contains(kind),let message=row["message"] as? String,!message.isEmpty,message.count<=1024 else{return nil}
            result.append(.init(kind:kind,message:message))
        }
        return result
    }
}

struct SteamPrerequisiteCheck {
    let key:String,name:String,minimum:UInt32
    static func read(_ raw:Any)->[Self]? {
        guard let rows=raw as? [[String:Any]],rows.count<=128 else{return nil}
        var result:[Self]=[]
        for row in rows {
            guard let key=row["key"] as? String,key.count<=1024,
                  key.range(of:"^HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\(?:Wow6432Node\\\\)?Valve\\\\Steam\\\\Apps\\\\CommonRedist(?:\\\\[^\\r\\n]+)?$",options:[.regularExpression,.caseInsensitive]) != nil,
                  let name=row["name"] as? String,!name.isEmpty,name.count<=200,!name.contains("\n"),!name.contains("\""),
                  let minimum=row["minimum"] as? Int,minimum>0,minimum<=Int(UInt32.max) else{return nil}
            result.append(.init(key:key,name:name,minimum:UInt32(minimum)))
        }
        return result
    }
    func isSatisfied(in prefix:URL)->Bool {
        let file=prefix.appendingPathComponent("system.reg")
        guard let size=try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<16_000_000,
              let text=try? String(contentsOf:file,encoding:.utf8) else{return false}
        let wanted=String(key.dropFirst("HKEY_LOCAL_MACHINE\\".count)).lowercased()
        var matches=false
        for raw in text.split(separator:"\n") {
            let line=String(raw).trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("["),let end=line.firstIndex(of:"]") {
                let section=String(line[line.index(after:line.startIndex)..<end]).replacingOccurrences(of:"\\\\",with:"\\").lowercased()
                matches=section == wanted
            }else if matches,let split=line.range(of:"\"=") {
                let valueName=String(line[..<split.lowerBound]).dropFirst().lowercased()
                let value=String(line[split.upperBound...]).lowercased()
                if valueName == name.lowercased(),value.hasPrefix("dword:"),let number=UInt32(value.dropFirst(6),radix:16),number>=minimum{return true}
            }
        }
        return false
    }
}

struct LocalGameManifest {
    let id:String,title:String,executable:String
    static func read(_ folder:URL)->LocalGameManifest? {
        let file=folder.appendingPathComponent(".playmelt-game.json")
        guard let size=try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8192,
              let data=try? Data(contentsOf:file),let raw=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],raw["schema"] as? Int == 1,
              let id=raw["id"] as? String,UUID(uuidString:id) != nil,
              let title=raw["title"] as? String,!title.isEmpty,title.count<=160,
              let executable=raw["executable"] as? String,!executable.isEmpty,executable.count<=1024,
              !executable.hasPrefix("/"),!executable.contains("\\"),!executable.contains(":"),!executable.split(separator:"/").contains(".."),executable.lowercased().hasSuffix(".exe") else {return nil}
        let root=folder.appendingPathComponent("Windows").resolvingSymlinksInPath(),target=root.appendingPathComponent(executable)
        guard root.path == folder.resolvingSymlinksInPath().appendingPathComponent("Windows").path,target.resolvingSymlinksInPath().path.hasPrefix(root.path+"/"),(try? target.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])).map({$0.isRegularFile == true && $0.isSymbolicLink != true}) == true else {return nil}
        return LocalGameManifest(id:id,title:title,executable:executable)
    }
}

final class LocalGameImport {
    private var source:URL?
    private var token:OwnedOperationToken?
    private let group=DispatchGroup(),queue=DispatchQueue(label:"playmelt.local-import",qos:.utility)
    private(set) var state:[String:Any]=["status":"idle"]
    var onChange:(()->Void)?
    func choose(in window:NSWindow) {
        guard token == nil else {return}
        let picker=NSOpenPanel();picker.title="Ajouter un jeu local";picker.message="Choisissez un dossier de jeu, une archive ZIP ou un installateur Windows.";picker.prompt="Analyser";picker.canChooseDirectories=true;picker.canChooseFiles=true;picker.allowsMultipleSelection=false
        picker.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .OK,let url=picker.url else {return}
            self.source=url;self.state=["status":"checking","name":url.lastPathComponent];self.onChange?()
            if ["exe","msi","iso"].contains(url.pathExtension.lowercased()) {
                self.state=["status":"needsVM","name":url.lastPathComponent,"utmInstalled":FileManager.default.fileExists(atPath:"/Applications/UTM.app"),"message":"Cet installateur nécessite une VM Windows configurée et un profil d’installation validé. Aucune VM n’est associée à Playmelt pour le moment."];self.onChange?();return
            }
            self.run(arguments:["inspect","--source",url.path]) { value in self.state=value.merging(["status":value["error"] == nil ? "review":"error","name":url.deletingPathExtension().lastPathComponent]){_,latest in latest};self.onChange?() }
        }
    }
    func install(title:String,executable:String) {
        guard token == nil,state["status"] as? String == "review",let source,let candidates=state["executables"] as? [String],candidates.contains(executable),!title.isEmpty,title.count<=160 else {return}
        state["status"]="installing";onChange?()
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games")
        run(arguments:["install","--source",source.path,"--root",root.path,"--title",title,"--executable",executable]) { value in self.state=value;self.onChange?() }
    }
    private func run(arguments:[String],completion:@escaping([String:Any])->Void) {
        guard let script=PortablePythonRuntime.resource(named:"local_game_import.py"),let python=PortablePythonRuntime.resolve() else {state=["status":"error","error":"Outil d’import indisponible."];onChange?();return}
        let token=OwnedOperationToken();self.token=token;group.enter()
        queue.async { [self] in
            var request=OwnedProcessRequest(executable:python.pythonURL,arguments:[script.path]+arguments,environment:python.environment(merging:ProcessInfo.processInfo.environment))
            request.timeout=arguments.first == "install" ? 7200:120;request.outputLimit=64000
            let value:[String:Any]
            do {let result=try OwnedProcessRunner().run(request,cancelled:{token.isCancelled});value=(try? JSONSerialization.jsonObject(with:result.output)) as? [String:Any] ?? ["status":"error","error":"Réponse d’import invalide."]} catch {value=["status":"error","error":error.localizedDescription]}
            DispatchQueue.main.async {self.token=nil;completion(value);self.group.leave()}
        }
    }
    func cancel() {token?.cancel()}
    func shutdown(_ completion:@escaping()->Void) {cancel();group.notify(queue:.main,execute:completion)}
}
