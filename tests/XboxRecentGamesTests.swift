import Foundation
@main enum Tests {
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-xbox-recents-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("recent.json"),store=XboxRecentGames(url:url)
        precondition(store.lastPlayed("BT5P2X999VH2")==0)
        store.record(["BT5P2X999VH2"],at:Date(timeIntervalSince1970:2000),evidence:.videoPlayback)
        store.record(["9NPKGVXPFRSX"],at:Date(timeIntervalSince1970:1999),evidence:.videoPlayback)
        precondition(store.lastPlayed("BT5P2X999VH2")==2000 && store.lastPlayed("9NPKGVXPFRSX")==1999)
        precondition(store.lastPlayed("invalid")==0)
        store.record(["9NPKGVXPFRSX"],at:Date(timeIntervalSince1970:3000),evidence:.videoPlayback)
        precondition(XboxRecentGames(url:url).lastPlayed("9NPKGVXPFRSX")==3000)
        store.record(["BT5P2X999VH2"],at:Date(timeIntervalSince1970:1000),evidence:.videoPlayback)
        precondition(store.lastPlayed("BT5P2X999VH2")==2000)
        let observedURL=XboxRecentGames.observationsURL(for:url)
        let attributes=try FileManager.default.attributesOfItem(atPath:observedURL.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600)
        try Data("{\"BT5P2X999VH2\":1e300}".utf8).write(to:observedURL)
        precondition(XboxRecentGames(url:url).lastPlayed("BT5P2X999VH2")==0)
        print("Xbox recents: 7 persistence, ordering, identity and corrupted-data checks passed; fixture only")
    }
}
