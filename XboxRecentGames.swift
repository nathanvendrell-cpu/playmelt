import Foundation

/// Legacy timestamps stay unverified. Only explicit new video observations date a game.
final class XboxRecentGames {
    enum Evidence:String { case videoPlayback = "video-playback", recentList = "recent-list" }
    private struct Observations:Codable {
        let schema:Int
        let evidence:String
        let played:[String:Double]
    }
    private let observedURL:URL
    private let unverifiedIDs:Set<String>
    private let lock=NSLock()
    private var played:[String:Double]=[:]
    init(url:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/xbox-recent.json")) {
        // Keep the original file byte-for-byte: absence of provenance cannot establish a play date.
        observedURL=Self.observationsURL(for:url)
        if let data=try? Data(contentsOf:url,options:.mappedIfSafe),data.count<256*1024,
           let legacy=try? JSONDecoder().decode([String:Double].self,from:data) {
            unverifiedIDs=Set(legacy.keys.filter(Self.validID))
        } else {unverifiedIDs=[]}
        if let data=try? Data(contentsOf:observedURL,options:.mappedIfSafe),data.count<256*1024,
           let observations=try? JSONDecoder().decode(Observations.self,from:data),
           observations.schema==1,observations.evidence==Evidence.videoPlayback.rawValue {
            played=observations.played.filter{Self.validID($0.key) && $0.value.isFinite && $0.value>0 && $0.value<Double(Int64.max)}
        }
    }
    static func observationsURL(for legacy:URL)->URL {
        legacy.deletingLastPathComponent().appendingPathComponent(legacy.deletingPathExtension().lastPathComponent+"-observed.json")
    }
    static func validID(_ id:String)->Bool {id.range(of:"^[A-Z0-9]{12}$",options:.regularExpression) != nil}
    func hasUnverifiedHistory(_ id:String)->Bool {unverifiedIDs.contains(id)}
    func lastPlayed(_ id:String)->Int64 {lock.lock();defer{lock.unlock()};return Int64(played[id] ?? 0)}
    // Legacy callers without provenance fail closed until the native message patch is integrated.
    func record(_ ids:[String],at:Date=Date(),evidence:Evidence?=nil) {
        guard evidence == .videoPlayback,ids.count==1,let id=ids.first,Self.validID(id),
              at.timeIntervalSince1970.isFinite,at.timeIntervalSince1970>0,
              at.timeIntervalSince1970<Double(Int64.max) else{return}
        lock.lock();defer{lock.unlock()}
        let value=at.timeIntervalSince1970
        guard value>(played[id] ?? 0) else{return}
        played[id]=value
        guard let data=try? JSONEncoder().encode(Observations(schema:1,evidence:Evidence.videoPlayback.rawValue,played:played)) else{return}
        try? FileManager.default.createDirectory(at:observedURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? data.write(to:observedURL,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:observedURL.path)
    }
}
