import AppKit
import ImageIO

final class PlayerProfile {
    private let file:URL
    private var value:[String:Any] = ["name":"","avatar":"orbit"]
    static let avatars=["orbit","comet","nova","pixel","astronaut","planet"]
    init(file:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/player-profile.json")) {
        self.file=file
        if let data=try? Data(contentsOf:file),data.count<1_000_000,let saved=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {value=saved}
    }
    func snapshot()->[String:Any] {value}
    func save(name:String?=nil,avatar:String?=nil)throws {
        var next=value
        if let name {let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !trimmed.isEmpty,trimmed.count<=40,!trimmed.unicodeScalars.contains(where: {CharacterSet.controlCharacters.contains($0)}) else {throw NSError(domain:"Playmelt",code:1,userInfo:[NSLocalizedDescriptionKey:"Choisissez un pseudo de 1 à 40 caractères."])};next["name"]=trimmed}
        if let avatar {guard Self.avatars.contains(avatar) else {return};next["avatar"]=avatar;next.removeValue(forKey:"photo")}
        try persist(next)
    }
    func photo(_ url:URL)throws {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]);guard (size.fileSize ?? Int.max)<=10_000_000 else {throw Self.imageError}
        try photo(data:Data(contentsOf:url))
    }
    private static var imageError:NSError {NSError(domain:"Playmelt",code:2,userInfo:[NSLocalizedDescriptionKey:"Choisissez une image PNG, JPEG, HEIC ou WebP de moins de 10 Mo."])}
    func photo(data:Data,name:String?=nil,fit:Bool=false)throws {
        guard data.count<=10_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil),let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary),let context=CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw Self.imageError}
        context.setFillColor(CGColor(red:0.065,green:0.09,blue:0.12,alpha:1));context.fill(CGRect(x:0,y:0,width:256,height:256))
        let w=CGFloat(cg.width),h=CGFloat(cg.height),scale=fit ? 220/max(w,h) : 256/min(w,h)
        context.interpolationQuality = .high
        context.draw(cg,in:CGRect(x:(256-w*scale)/2,y:(256-h*scale)/2,width:w*scale,height:h*scale))
        guard let image=context.makeImage(),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw Self.imageError}
        var next=value
        if let name,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard trimmed.count<=40,!trimmed.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {throw NSError(domain:"Playmelt",code:1,userInfo:[NSLocalizedDescriptionKey:"Choisissez un pseudo de 1 à 40 caractères."])}
            next["name"]=trimmed
        }
        next["photo"]="data:image/png;base64,"+png.base64EncodedString();try persist(next)
    }
    private func persist(_ next:[String:Any])throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:next,options:[.sortedKeys]).write(to:file,options:.atomic)
        value=next
    }
}
