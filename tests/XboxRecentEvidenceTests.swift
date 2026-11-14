import Foundation
@main enum Tests {
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-xbox-evidence-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("history.json"),id="BT5P2X999VH2",other="9NPKGVXPFRSX"
        let observed=XboxRecentGames.observationsURL(for:url)
        let legacy=Data(("{\""+id+"\":1234,\""+other+"\":1900000000}").utf8)
        try legacy.write(to:url)
        let legacyAttributes=try FileManager.default.attributesOfItem(atPath:url.path)
        let store=XboxRecentGames(url:url)
        var checks=0
        func expect(_ value:@autoclosure()->Bool){checks+=1;precondition(value())}
        expect(store.lastPlayed(id)==0);expect(store.lastPlayed(other)==0)
        expect(store.hasUnverifiedHistory(id));expect(store.hasUnverifiedHistory(other))
        store.record([id,other],at:Date(timeIntervalSince1970:2000),evidence:.recentList)
        store.record([id],at:Date(timeIntervalSince1970:3000))
        expect(store.lastPlayed(id)==0);expect(!FileManager.default.fileExists(atPath:observed.path))
        let unchanged=try Data(contentsOf:url);expect(unchanged==legacy)
        store.record([id],at:Date(timeIntervalSince1970:4000),evidence:.videoPlayback)
        let reopened=XboxRecentGames(url:url)
        expect(store.lastPlayed(id)==4000);expect(reopened.lastPlayed(id)==4000)
        expect(reopened.lastPlayed(other)==0);expect(reopened.hasUnverifiedHistory(other))
        let stillLegacy=try Data(contentsOf:url);expect(stillLegacy==legacy)
        let afterAttributes=try FileManager.default.attributesOfItem(atPath:url.path)
        expect(legacyAttributes[.systemFileNumber] as? NSNumber==afterAttributes[.systemFileNumber] as? NSNumber)
        expect(legacyAttributes[.modificationDate] as? Date==afterAttributes[.modificationDate] as? Date)
        let played=try Data(contentsOf:observed)
        let envelope=try JSONSerialization.jsonObject(with:played) as! [String:Any]
        expect(envelope["schema"] as? Int==1);expect(envelope["evidence"] as? String=="video-playback")
        store.record([id,other],at:Date(timeIntervalSince1970:5000),evidence:.videoPlayback)
        store.record(["invalid"],at:Date(timeIntervalSince1970:5000),evidence:.videoPlayback)
        store.record([id],at:Date(timeIntervalSince1970:Double.nan),evidence:.videoPlayback)
        store.record([id],at:Date(timeIntervalSince1970:2000),evidence:.videoPlayback)
        let afterInvalid=try Data(contentsOf:observed);expect(afterInvalid==played)
        let absent=root.appendingPathComponent("no-history.json"),new=XboxRecentGames(url:absent)
        new.record([id],evidence:.recentList)
        expect(!FileManager.default.fileExists(atPath:absent.path))
        expect(!FileManager.default.fileExists(atPath:XboxRecentGames.observationsURL(for:absent).path))
        let permissions=try FileManager.default.attributesOfItem(atPath:observed.path)[.posixPermissions] as? NSNumber
        expect(permissions?.intValue==0o600)
        // An untyped dictionary in the new location is not a certified observation either.
        try legacy.write(to:observed)
        expect(XboxRecentGames(url:url).lastPlayed(id)==0)
        let finalLegacy=try Data(contentsOf:url);expect(finalLegacy==legacy)
        print("Xbox recent evidence: \(checks) unknown-legacy preservation, explicit-playback and reopen assertions passed; fixture history only")
    }
}
