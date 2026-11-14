import Foundation

/// User-authored reports with a small explicit diagnostic allowlist; no logs, paths or account secrets.
final class IssueReports {
    private let directory:URL
    init(directory:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Reports",isDirectory:true)){self.directory=directory}
    static let categories=["launch","crash","graphics","performance","installation","other"]
    static let statuses=["received","investigating","fixed","verified","closed"]
    func create(gameID:String,title:String,store:String,category:String,message:String,diagnostics:[String:Any])throws->[String:Any] {
        let text=message.trimmingCharacters(in:.whitespacesAndNewlines)
        guard Self.categories.contains(category),text.count>=5,text.count<=4000,!gameID.isEmpty else {throw NSError(domain:"Playmelt",code:1,userInfo:[NSLocalizedDescriptionKey:"Décrivez le problème en 5 à 4 000 caractères."])}
        let safe=diagnostics.filter{["version","macOS","chip","memoryGB","gpuName","renderer","graphicsAPI","installed","launchBlocked"].contains($0.key)}
        let report:[String:Any]=["clientId":UUID().uuidString.lowercased(),"gameId":gameID,"gameTitle":String(title.prefix(200)),"store":store,"category":category,"message":text,"diagnostics":safe,"createdAt":Date().timeIntervalSince1970,"status":"queued"]
        try save(report);return report
    }
    func all()->[[String:Any]] {
        let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
        return files.filter{$0.pathExtension=="json"}.compactMap {url in guard let data=try? Data(contentsOf:url),data.count<32000,let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return nil};return row}.sorted{($0["createdAt"] as? Double ?? 0)>($1["createdAt"] as? Double ?? 0)}
    }
    func update(id:String,serverID:String,status:String)throws {
        guard UUID(uuidString:id) != nil,!serverID.isEmpty,serverID.count<=128,Self.statuses.contains(status),var report=all().first(where:{$0["clientId"] as? String==id}) else{return}
        report["serverId"]=serverID;report["status"]=status;report["updatedAt"]=Date().timeIntervalSince1970;try save(report)
    }
    private func save(_ report:[String:Any])throws {
        guard let id=report["clientId"] as? String,UUID(uuidString:id) != nil else{return}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:directory.appendingPathComponent(id+".json"),options:.atomic)
    }
}
