import Foundation
@main struct OffersProfileTests {
 static func main() throws {
  var count=0
  func check(_ ok:Bool,_ name:String){precondition(ok,"FAIL "+name);count+=1}
  let file=FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-profile-test-\(UUID()).json")
  defer{try? FileManager.default.removeItem(at:file)}
  let p=ProfileProgression(file:file)
  let factorio:[String:Any] = ["id":"steam:1","title":"Factorio","store":"steam","playtime":Int64(837*3600),"installed":true]
  var duplicate=factorio;duplicate["id"]="gog:1";duplicate["title"]="Factorio™";duplicate["store"]="gog"
  let result=p.snapshot(games:[factorio,duplicate,["title":"Backlog","playtime":0,"installed":false]],account:"test")
  check(result["points"] as? Int == 1168,"Factorio cumulative milestones counted once across platforms")
  check((result["entries"] as? [[String:Any]])?.count == 1,"unplayed uninstalled backlog gives no points")
  let reopened=ProfileProgression(file:file).snapshot(games:[],account:"test")
  check(reopened["points"] as? Int == 1168,"points retained after uninstall and app restart")
  check(p.snapshot(games:[],account:"other")["points"] as? Int == 0,"accounts isolated")
  var downgraded=factorio;downgraded["playtime"]=3600.0
  check(p.snapshot(games:[downgraded],account:"test")["points"] as? Int == 1168,"lower refreshed playtime does not remove acquired points")
  var legend=factorio;legend["playtime"]=1000.0*3600
  check(p.snapshot(games:[legend],account:"test")["points"] as? Int == 11168,"legend awards additional 10000 exactly once")
  check(p.snapshot(games:[legend],account:"test")["points"] as? Int == 11168,"repeat refresh does not award twice")
  let steam=try JSONSerialization.data(withJSONObject:["specials":["items":[["id":1,"type":0,"name":"Game","original_price":2000,"final_price":500,"currency":"EUR","discount_expiration":42],["id":2,"type":0,"name":"No sale","original_price":1000,"final_price":1000,"currency":"EUR"],["id":3,"type":0,"name":"Wrong currency","original_price":2000,"final_price":500,"currency":"USD"]]]])
  let deals=OffersCatalog.steam(steam)
  check(deals.count==1,"only true EUR promotions published")
  check(deals[0]["discount"] as? Int==75 && deals[0]["priceCents"] as? Int==500,"prices and discount kept exactly")
  check(OffersCatalog.gog(Data("{}".utf8)).isEmpty,"malformed GOG payload gives no invented offers")
  check(OffersCatalog.xbox(Data("<html>Error</html>".utf8)).isEmpty,"changed Xbox schema gives no invented offers")
  let body=HubArticle.body("[img]javascript:alert(1)[/img][url=javascript:alert(1)]bad[/url] [url=https://example.com/a?x=1&y=2]Official link[/url]<script>x</script>")
  check(!body.contains("<script>") && !body.contains("href=\"javascript:"),"article rejects active HTML and unsafe links")
  check(body.contains("href=\"https://example.com/a?x=1&amp;y=2\""),"safe links preserved and escaped")
  print("Offers and profile: \(count) PASS")
 }
}
