import AppKit

/// Extract a restrained readable palette from the actual cover, without a model or upload.
enum GameTheme {
    static let fallback = ["accent":"#e89a69", "background":"#141b22", "surface":"#202a34", "muted":"#b8c4cf"]
    private static let cache = NSCache<NSString, NSDictionary>()
    static func palette(_ data: Data) -> [String:String] {
        guard data.count <= 8_000_000, let source = NSBitmapImageRep(data:data), source.pixelsWide > 0, source.pixelsHigh > 0 else { return fallback }
        var bins: [Int:(Double,Double,Double,Double)] = [:]
        for y in stride(from:0,to:source.pixelsHigh,by:max(1,source.pixelsHigh/40)) {
            for x in stride(from:0,to:source.pixelsWide,by:max(1,source.pixelsWide/40)) {
                guard let c=source.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.8 else { continue }
                let h=Double(c.hueComponent), saturation=Double(c.saturationComponent), brightness=Double(c.brightnessComponent)
                guard saturation > 0.2, brightness > 0.18 else { continue }
                let key=Int(h*24), weight=saturation*brightness
                let old=bins[key] ?? (0,0,0,0)
                bins[key]=(old.0+h*weight,old.1+saturation*weight,old.2+brightness*weight,old.3+weight)
            }
        }
        guard let win=bins.values.max(by:{$0.3 < $1.3}), win.3 > 0 else { return fallback }
        let hue=win.0/win.3
        func hex(_ s:Double,_ v:Double)->String {
            let c=NSColor(hue:hue,saturation:s,brightness:v,alpha:1).usingColorSpace(.deviceRGB)!
            return String(format:"#%02x%02x%02x",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255))
        }
        return ["accent":hex(0.48,0.98),"background":hex(0.35,0.09),"surface":hex(0.24,0.15),"muted":hex(0.12,0.78)]
    }
    static func isArtworkURL(_ url:URL)->Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && ["shared.fastly.steamstatic.com","cdn.cloudflare.steamstatic.com","shared.akamai.steamstatic.com","cdn1.epicgames.com","cdn2.unrealengine.com","images.gog.com","images.gog-statics.com","store-images.s-microsoft.com"].contains(url.host ?? "")
    }
    @discardableResult static func load(_ url: URL, completion:@escaping([String:String])->Void)->URLSessionDataTask? {
        guard isArtworkURL(url) else { completion(fallback);return nil }
        if let hit=cache.object(forKey:url.absoluteString as NSString) as? [String:String] { completion(hit);return nil }
        var request=URLRequest(url:url,cachePolicy:.returnCacheDataElseLoad,timeoutInterval:10)
        request.setValue("Playmelt",forHTTPHeaderField:"User-Agent")
        let task=URLSession.shared.dataTask(with:request){data,response,_ in
            let theme=(response as? HTTPURLResponse)?.statusCode == 200 ? data.map(palette) ?? fallback : fallback
            cache.setObject(theme as NSDictionary,forKey:url.absoluteString as NSString);completion(theme)
        };task.resume();return task
    }
}
