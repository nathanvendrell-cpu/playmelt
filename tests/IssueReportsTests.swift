import Foundation
@main struct Tests {
 static func main()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let store=IssueReports(directory:root)
  let report=try store.create(gameID:"test-game",title:"Test",store:"local",category:"launch",message:"Le jeu se ferme au lancement.",diagnostics:["version":"2.2.0","chip":"Apple M3","token":"secret","path":"/private/user/game","launchArgs":"secret"])
  let diagnostic=report["diagnostics"] as! [String:Any];precondition(diagnostic.count==2);precondition(store.all().count==1)
  let id=report["clientId"] as! String
  try store.update(id:id,serverID:"remote-1",status:"investigating");precondition(store.all()[0]["status"] as? String=="investigating")
  try store.update(id:id,serverID:"remote-1",status:"invented");precondition(store.all()[0]["status"] as? String=="investigating")
  do{_ = try store.create(gameID:"test",title:"Test",store:"local",category:"bad",message:"Test report",diagnostics:[:]);fatalError("Bad category accepted")}catch{}
  do{_ = try store.create(gameID:"test",title:"Test",store:"local",category:"launch",message:"",diagnostics:[:]);fatalError("Empty report accepted")}catch{}
  precondition(IssueReports(directory:root).all().count==1)
  print("IssueReports: 7 privacy, persistence and status checks passed")
 }
}
