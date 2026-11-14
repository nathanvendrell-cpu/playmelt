import AppKit
@main struct Tests {
 static func main()throws {
  let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
  let file=folder.appendingPathComponent("profile.json"),store=PlayerProfile(file:file)
  try store.save(name:"  Nathan  ",avatar:"nova");precondition(store.snapshot()["name"] as? String == "Nathan")
  do {try store.save(name:"bad\nname");fatalError("Controls accepted")}catch{}
  do {try store.save(name:String(repeating:"n",count:41));fatalError("Long name accepted")}catch{}
  try store.save(avatar:"unknown");precondition(store.snapshot()["avatar"] as? String == "nova")
  let fresh=PlayerProfile(file:file);precondition(fresh.snapshot()["name"] as? String == "Nathan")
  let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:20,pixelsHigh:40,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  memset(image.bitmapData!,127,image.bytesPerRow*40)
  let png=image.representation(using:.png,properties:[:])!
  try store.photo(data:png,name:"Nathan")
  let stored=store.snapshot()["photo"] as! String
  let decoded=NSBitmapImageRep(data:Data(base64Encoded:String(stored.dropFirst("data:image/png;base64,".count)))!)!
  precondition(decoded.pixelsWide==256 && decoded.pixelsHigh==256)
  precondition(PlayerProfile(file:file).snapshot()["photo"] as? String == stored)
  do {try store.photo(data:Data("not an image".utf8));fatalError("Invalid image accepted")}catch{}
  do {try store.photo(data:png,name:"bad\nname");fatalError("Invalid name accepted with image")}catch{}
  precondition(store.snapshot()["photo"] as? String == stored)
  print("PlayerProfile: 10 checks passed")
 }
}
