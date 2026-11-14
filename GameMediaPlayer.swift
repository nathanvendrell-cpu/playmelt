import AppKit
import WebKit

/// A remote video never runs inside the privileged library web view. Closing
/// this surface destroys the player and stops its audio rather than hiding it.
final class GameMediaPlayer: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var panel: NSView?
    private var player: WKWebView?
    private var documentURL: URL?
    private var acceptedDocument = false
    private let status = NSTextField(labelWithString: "")
    private static let sessionID = UUID(uuidString: "EBEAA147-91F6-48EB-B055-937DC8CE8769")!

    func open(video: [String: Any], over library: WKWebView) {
        guard let html = Self.page(video), let parent = library.superview else { return }
        close()
        let panel = NSView()
        panel.wantsLayer = true; panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 1).cgColor
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 52),
            panel.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.sessionID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let player = WKWebView(frame: .zero, configuration: configuration)
        player.navigationDelegate = self; player.uiDelegate = self
        let back = NSButton(title: "Retour au jeu", target: self, action: #selector(close))
        back.bezelStyle = .rounded; back.keyEquivalent = "\u{1b}"
        status.stringValue = video["title"] as? String ?? "Vidéo du jeu"
        status.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [back, status])
        bar.spacing = 18; bar.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        for view in [bar, player] { view.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: panel.topAnchor), bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 56),
            player.topAnchor.constraint(equalTo: bar.bottomAnchor), player.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: panel.trailingAnchor), player.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        self.panel = panel; self.player = player
        // YouTube requires a Referer identifying an embedded desktop app. This
        // base URL follows its documented bundle-identifier identity format.
        let bundle = (Bundle.main.bundleIdentifier ?? "com.robtech.metalmaxgaminghub").lowercased()
        documentURL = URL(string: "https://" + bundle + "/")
        acceptedDocument = false
        player.loadHTMLString(html, baseURL: documentURL)
    }

    @objc func close() {
        player?.stopLoading(); player?.navigationDelegate = nil; player?.uiDelegate = nil
        player?.removeFromSuperview(); panel?.removeFromSuperview()
        player = nil; panel = nil
        documentURL = nil; acceptedDocument = false
    }

    static func youtubeID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func steamVideoURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(),
              ["steamstatic.com", "steamcontent.com", "akamaihd.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              ["mp4", "webm", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func page(_ video: [String: Any]) -> String? {
        let body: String
        if video["provider"] as? String == "youtube", let id = video["youtubeId"] as? String, youtubeID(id) {
            body = "<iframe title=\"\(escape(video["title"] as? String ?? "Vidéo du jeu"))\" src=\"https://www.youtube.com/embed/\(id)?autoplay=1&amp;playsinline=1&amp;rel=0\" allow=\"autoplay; encrypted-media; picture-in-picture; fullscreen\" referrerpolicy=\"strict-origin-when-cross-origin\" allowfullscreen></iframe>"
        } else if video["provider"] as? String == "steam", let raw = video["url"] as? String, let url = steamVideoURL(raw) {
            body = "<video controls autoplay playsinline src=\"\(escape(url.absoluteString))\"></video>"
        } else { return nil }
        return """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="referrer" content="strict-origin-when-cross-origin"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;width:100%;height:100%;background:#08090b;color:#fff}iframe,video{display:block;border:0;width:100%;height:100%;object-fit:contain}</style></head><body>\(body)</body></html>
        """
    }
    private static func permits(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host?.lowercased() else { return false }
        return ["youtube.com", "youtube-nocookie.com", "googlevideo.com", "ytimg.com", "steamstatic.com", "steamcontent.com", "akamaihd.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !acceptedDocument, action.targetFrame?.isMainFrame != false, action.navigationType == .other,
           action.request.url == documentURL || action.request.url?.absoluteString == "about:blank" {
            acceptedDocument = true; decisionHandler(.allow); return
        }
        guard Self.permits(action.request.url) else { decisionHandler(.cancel); return }
        // Links and requested pop-ups stay inside this isolated surface.
        if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.permits(action.request.url) { webView.load(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = "Lecture indisponible. Revenez à la fiche et réessayez." }
    }
}
