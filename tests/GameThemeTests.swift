import AppKit
@main struct Tests {
 static func main() {
  func bitmap(_ color:NSColor)->Data {let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;for y in 0..<16{for x in 0..<16{let c=color.usingColorSpace(.deviceRGB)!;let offset=y*image.bytesPerRow+x*4;image.bitmapData![offset]=UInt8(c.redComponent*255);image.bitmapData![offset+1]=UInt8(c.greenComponent*255);image.bitmapData![offset+2]=UInt8(c.blueComponent*255);image.bitmapData![offset+3]=255}};return image.representation(using:.png,properties:[:])!}
  func luminance(_ hex:String)->Double {let n=Int(hex.dropFirst(),radix:16)!;let channels=[(n>>16)&255,(n>>8)&255,n&255].map { value -> Double in let x=Double(value)/255;return x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) };return channels[0]*0.2126+channels[1]*0.7152+channels[2]*0.0722}
  var checks=0
  for color in [NSColor.orange,NSColor.blue,NSColor.red,NSColor.green,NSColor.purple] {
   let p=GameTheme.palette(bitmap(color));let bg=luminance(p["surface"]!);
   for key in ["accent","muted"] {precondition((luminance(p[key]!)+0.05)/(bg+0.05)>4.5);checks+=1}
  }
  precondition(GameTheme.palette(Data())==GameTheme.fallback);checks+=1
  precondition(GameTheme.palette(bitmap(.orange)) != GameTheme.palette(bitmap(.blue)));checks+=1
  print("GameTheme: \(checks) checks passed")
 }
}
