import Foundation

// Only the connector's value projection is needed here; no Core/application initializers.
struct Game {
    var id:String,appId:String,title:String,store:String,installed:Bool,platform:String,runtimeId:String,runtimeName:String,ownership:String
    var path:URL?,complete:Bool,epicLaunchID:String,supportedPlatforms:[String],customImageURL:String,customPortraitURL:String,lastPlayed:Int64,installSource:String
    var cloudInputMode="",gamePassRecent = -1
}

private final class FixtureProtocol:URLProtocol,@unchecked Sendable {
    static let lock=NSLock()
    static var mode="good",requests=0
    static let cloud="BT5P2X999VH2",pc="9NPKGVXPFRSX"
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock();let mode=Self.mode;Self.requests+=1;Self.lock.unlock()
        guard let url=request.url,let host=url.host else{fatalError("fixture missing URL")}
        var code=200,body:Data
        if host=="catalog.gamepass.com" {
            let sigl=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="id"}!.value!
            var ids=[Self.cloud,Self.pc]
            if sigl==XboxConnector.pcSiglID {ids=[Self.pc]}
            var rows:[[String:Any]]=[["siglId":sigl]]+ids.map{["id":$0]}
            if sigl==XboxConnector.cloudSiglID {
                switch mode {
                case "cloud-http":code=503
                case "cloud-network":client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return
                case "cloud-empty":rows=[["siglId":sigl]]
                case "cloud-wrong-sigl":rows[0]=["siglId":"unrelated-list"]
                case "cloud-invalid-id":rows.append(["id":"bad"])
                default:break
                }
            }
            body=try! JSONSerialization.data(withJSONObject:rows)
            if sigl==XboxConnector.cloudSiglID && mode=="cloud-malformed" {body=Data("{not json".utf8)}
            if sigl==XboxConnector.cloudSiglID && ["cloud-oversized","cloud-stream-oversized"].contains(mode) {body=Data(repeating:65,count:2*1024*1024+1)}
        } else if host=="displaycatalog.mp.microsoft.com" {
            let ids=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name=="bigIds"}!.value!.split(separator:",").map(String.init)
            var products:[[String:Any]]=ids.map{["ProductId":$0,"LocalizedProperties":[["ProductTitle":"Fixture "+$0,"Images":[]]]]}
            if mode=="products-partial" {products.removeLast()}
            if mode=="products-http" {code=502}
            body=try! JSONSerialization.data(withJSONObject:["Products":products])
            if mode=="products-malformed" {body=Data("[]".utf8)}
        } else {fatalError("Test attempted non-catalogue host")}
        let response=HTTPURLResponse(url:url,statusCode:code,httpVersion:"HTTP/1.1",headerFields:mode=="cloud-stream-oversized" ? ["Content-Type":"application/json"] : ["Content-Type":"application/json","Content-Length":String(body.count)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
    }
}

@main enum Tests {
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-xbox-catalogue-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        var checks=0,clock=Date(timeIntervalSince1970:1900000000)
        func expect(_ value:@autoclosure()->Bool,_ label:String){checks+=1;precondition(value(),label)}
        func fixture(_ home:URL)->XboxConnector {
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FixtureProtocol.self]
            return XboxConnector(home:home,catalogConfiguration:config,now:{clock},observeSession:false)
        }
        func refresh(_ connector:XboxConnector,_ mode:String,force:Bool=true) {
            FixtureProtocol.lock.lock();FixtureProtocol.mode=mode;FixtureProtocol.lock.unlock()
            connector.refreshCatalog(force:force)
            let until=Date().addingTimeInterval(5)
            while connector.availability()["busy"] as? Bool == true && Date()<until {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
            expect(connector.availability()["busy"] as? Bool == false,"bounded fake transport finished")
        }
        let home=root.appendingPathComponent("warm"),connector=fixture(home)
        let cache=home.appendingPathComponent("Library/Application Support/Playmelt/.xbox_cloud_catalog.json")
        refresh(connector,"good")
        let original=try Data(contentsOf:cache),goodDate=connector.availability()["updatedAt"] as! String
        expect(connector.games().count==2,"complete catalogue loaded")
        expect(connector.availability()["cloudCount"] as? Int==2,"both cloud capabilities loaded")
        expect(connector.availability()["catalogError"] as? String=="","good response has no error")
        clock=clock.addingTimeInterval(7*60*60)
        for mode in ["cloud-http","cloud-network","cloud-empty","cloud-wrong-sigl","cloud-invalid-id","cloud-malformed","cloud-oversized","cloud-stream-oversized","products-partial","products-http","products-malformed"] {
            refresh(connector,mode)
            let current=try Data(contentsOf:cache)
            expect(current==original,"failed response must not replace cached bytes: "+mode)
            expect(connector.games().count==2,"failed response preserves games: "+mode)
            expect(connector.availability()["cloudCount"] as? Int==2,"Cloud stays present while PC feed succeeds: "+mode)
            expect(connector.availability()["updatedAt"] as? String==goodDate,"last success date stays unchanged: "+mode)
            expect(!(connector.availability()["catalogError"] as! String).isEmpty,"failure is exposed with warm cache: "+mode)
            expect(connector.availability()["catalogStale"] as? Bool==true,"failed refresh does not claim fresh catalogue: "+mode)
            expect((connector.availability()["message"] as! String).contains(goodDate),"last good date is in visible message: "+mode)
        }
        func requestCount()->Int {FixtureProtocol.lock.lock();defer{FixtureProtocol.lock.unlock()};return FixtureProtocol.requests}
        let warmFailureRequests=requestCount()
        for _ in 0..<8 {connector.refreshCatalog()}
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        expect(requestCount()==warmFailureRequests,"stale warm cache cannot bypass automatic retry backoff")
        let reopened=fixture(home)
        expect(reopened.games().count==2,"last good catalogue reopens from disk")
        expect(reopened.availability()["updatedAt"] as? String==goodDate,"reopen preserves successful fetch date")
        refresh(connector,"good")
        expect(connector.availability()["catalogError"] as? String=="","a successful retry clears the error")
        expect(connector.availability()["updatedAt"] as? String != goodDate,"successful retry advances catalogue date")
        let cold=fixture(root.appendingPathComponent("cold"))
        refresh(cold,"cloud-http")
        expect(cold.games().isEmpty,"partial response cannot publish PC-only first catalogue")
        expect(cold.availability()["updatedAt"] as? String=="","partial first fetch has no success date")
        let coldFailureRequests=requestCount()
        for _ in 0..<8 {cold.refreshCatalog()}
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        expect(requestCount()==coldFailureRequests,"empty cold cache cannot bypass automatic retry backoff")
        clock=clock.addingTimeInterval(899)
        refresh(cold,"good",force:false)
        expect(requestCount()==coldFailureRequests,"automatic retry stays blocked before fifteen minutes")
        clock=clock.addingTimeInterval(1)
        refresh(cold,"good",force:false)
        expect(requestCount()>coldFailureRequests,"automatic retry is permitted at the backoff boundary")
        expect(cold.games().count==2,"cold failure can recover")
        refresh(cold,"cloud-http")
        let explicitRequests=requestCount()
        refresh(cold,"good")
        expect(requestCount()>explicitRequests,"explicit force refresh remains available during backoff")
        // A consumer refreshing from onUpdate must not create a request feedback loop.
        let feedback=fixture(root.appendingPathComponent("feedback"))
        var updates=0
        feedback.onUpdate={updates+=1;if updates<6 {feedback.refreshCatalog()}}
        let beforeFeedback=requestCount()
        refresh(feedback,"cloud-http")
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        expect(requestCount()-beforeFeedback==5,"onUpdate failure feedback starts only one catalogue fetch")
        print("Xbox catalogue: \(checks) fake-transport assertions passed; HTTP/malformed/oversized/partial recovery and persistence; no real network or cookies")
    }
}
