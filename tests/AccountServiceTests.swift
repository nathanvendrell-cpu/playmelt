import Foundation
import CryptoKit
@main struct Tests {
 static func main()throws {
  let secret=Curve25519.Signing.PrivateKey(),key=secret.publicKey.rawRepresentation
  let base:[String:Any]=["aud":"playmelt-desktop","sub":"user-1","device":"device-1","iat":1000,"exp":1900,"plan":"monthly","phase":"trialing","capabilities":["launch","runtime.download"]]
  func b64(_ d:Data)->String{d.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
  func sign(_ claims:[String:Any])throws->String {let payload=b64(try JSONSerialization.data(withJSONObject:claims,options:[.sortedKeys]));return payload+"."+b64(try secret.signature(for:Data(payload.utf8)))}
  let ticket=try sign(base)
  func accepts(_ value:String,user:String="user-1",device:String="device-1",now:Double=1100,last:Double=1000)->Bool {LaunchTicket.verify(value,key:key,user:user,device:device,now:now,lastSeen:last) != nil}
  precondition(accepts(ticket));precondition(!accepts(ticket,user:"other"));precondition(!accepts(ticket,device:"other"));precondition(!accepts(ticket,now:1900));precondition(!accepts(ticket,now:900));precondition(!accepts(ticket,last:1200));precondition(!accepts(ticket+"x"));precondition(!accepts("unsigned"));precondition(!accepts(ticket,now:.infinity))
  for (field,value) in [("aud","another-app" as Any),("exp",1901 as Any),("phase","cancelled" as Any),("capabilities",["runtime.download"] as Any)] {var changed=base;changed[field]=value;let modified=try sign(changed);precondition(!accepts(modified))}
  precondition(LaunchTicket.verify(ticket,key:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,user:"user-1",device:"device-1",now:1100,lastSeen:1000)==nil)
  precondition(!AccountConfiguration(info:["PlaymeltCommercialAccessEnabled":true]).complete)
  precondition(!AccountConfiguration(info:["PlaymeltAccountURL":"http://example.com","PlaymeltLicensePublicKey":key.base64EncodedString()]).complete)
  precondition(AccountConfiguration(info:["PlaymeltAccountURL":"https://example.com/account/","PlaymeltLicensePublicKey":key.base64EncodedString()]).complete)
  let web=AccountConfiguration(info:["PlaymeltAccountServiceAvailable":true,"PlaymeltAccountURL":"https://example.com/Playmelt/compte","PlaymeltLicensePublicKey":key.base64EncodedString()])
  precondition(web.accountPage(plan:"annual")?.absoluteString=="https://example.com/Playmelt/compte?plan=annual")
  precondition(web.accountPage(activateCode:true)?.fragment=="activation-code")
  precondition(web.accountPage(plan:"//other.example") == nil)
  precondition(web.accountPage(mode:"signup")?.absoluteString=="https://example.com/Playmelt/compte/?mode=signup")
  precondition(web.accountPage(mode:"forgot")?.absoluteString=="https://example.com/Playmelt/compte/?mode=forgot")
  precondition(web.accountPage(mode:"//other.example") == nil)
  precondition(AccountConfiguration(info:["PlaymeltAccountURL":"https://example.com/Playmelt/compte","PlaymeltLicensePublicKey":key.base64EncodedString()]).accountPage()==nil)
  print("AccountService: 24 signature, expiry, binding, account-link and configuration checks passed")
 }
}
