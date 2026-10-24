import AppKit
import WebKit

class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else { return }
        
        switch action {
        case "launchGame":
            if let path = dict["path"] as? String, let type = dict["type"] as? String {
                launchTarget(path: path, type: type)
            }
        case "openSteamWindows":
            let steamApp = ("~/Applications/CrossOver/Steam/Steam.app" as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: steamApp) {
                NSWorkspace.shared.open(URL(fileURLWithPath: steamApp))
            } else {
                let crossOver = "/Applications/CrossOver.app"
                if FileManager.default.fileExists(atPath: crossOver) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: crossOver))
                }
            }
        case "openSteamMac":
            let nativeSteam = "/Applications/Steam.app"
            if FileManager.default.fileExists(atPath: nativeSteam) {
                NSWorkspace.shared.open(URL(fileURLWithPath: nativeSteam))
            }
        case "openHighball":
            let highball = "/Applications/Highball.app"
            if FileManager.default.fileExists(atPath: highball) {
                NSWorkspace.shared.open(URL(fileURLWithPath: highball))
            }
        case "applyMaxBoost":
            applyBoost()
            notifyWeb(functionName: "onBoostApplied", data: ["status": "ok"])
        case "installSteamGame":
            if let appId = dict["appId"] as? String {
                if let url = URL(string: "steam://install/\(appId)") {
                    NSWorkspace.shared.open(url)
                }
            }
        default:
            break
        }
    }
    
    private func launchTarget(path: String, type: String) {
        if type == "native_mac" {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if type == "crossover_steam" {
            // Launch via CrossOver Steam
            let steamApp = ("~/Applications/CrossOver/Steam/Steam.app" as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: steamApp) {
                NSWorkspace.shared.open(URL(fileURLWithPath: steamApp))
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/CrossOver.app"))
            }
        } else if type == "native_steam" {
            let nativeSteam = "/Applications/Steam.app"
            if FileManager.default.fileExists(atPath: nativeSteam) {
                NSWorkspace.shared.open(URL(fileURLWithPath: nativeSteam))
            }
        }
    }
    
    private func applyBoost() {
        let confPath = ("~/Library/Application Support/CrossOver/Bottles/Steam/cxbottle.conf" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: confPath),
              var content = try? String(contentsOfFile: confPath, encoding: .utf8) else { return }
        
        content = content.replacingOccurrences(of: "\"WINEMSYNC\" = \"0\"", with: "\"WINEMSYNC\" = \"1\"")
        content = content.replacingOccurrences(of: "\"CX_GRAPHICS_BACKEND\" = \"\"", with: "\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\"")
        content = content.replacingOccurrences(of: "\"D3DM_ENABLE_METALFX\" = \"0\"", with: "\"D3DM_ENABLE_METALFX\" = \"1\"")
        content = content.replacingOccurrences(of: "\"DXMT_ENABLE_NVEXT\" = \"0\"", with: "\"DXMT_ENABLE_NVEXT\" = \"1\"")
        
        try? content.write(toFile: confPath, atomically: true, encoding: .utf8)
    }
    
    private func notifyWeb(functionName: String, data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let js = "\(functionName)(\(jsonString))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    let scriptHandler = ScriptHandler()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentConfig = WKUserContentController()
        contentConfig.add(scriptHandler, name: "metalmax")
        
        let webConfig = WKWebViewConfiguration()
        webConfig.userContentController = contentConfig
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let windowWidth: CGFloat = min(1440, screenRect.width - 60)
        let windowHeight: CGFloat = min(920, screenRect.height - 60)
        let initialRect = NSRect(x: (screenRect.width - windowWidth) / 2 + screenRect.origin.x,
                                 y: (screenRect.height - windowHeight) / 2 + screenRect.origin.y,
                                 width: windowWidth,
                                 height: windowHeight)
        
        window = NSWindow(contentRect: initialRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
        window.center()
        window.title = "MetalMax Gaming Hub — Apple M3 Max Edition"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 10/255.0, green: 13/255.0, blue: 22/255.0, alpha: 1.0)
        
        webView = WKWebView(frame: initialRect, configuration: webConfig)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        scriptHandler.webView = webView
        
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        
        // Load embedded html
        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
