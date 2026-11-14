import Foundation

@main enum GameMediaPlayerTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { checks += 1; precondition(value, reason) }
        check(GameMediaPlayer.youtubeID("C_Gp_ZHwaUQ"), "Publisher YouTube ID is accepted")
        for value in ["", "abcdefghij", "abcdefghijkx", "../abcdefgh", "abc<script>", "abcdefghijé"] {
            check(!GameMediaPlayer.youtubeID(value), "Reject malformed YouTube ID")
        }
        let youtube: [String:Any] = ["provider":"youtube", "youtubeId":"C_Gp_ZHwaUQ", "title":"\"><script>bad()</script>"]
        let html = GameMediaPlayer.page(youtube)!
        check(html.contains("https://www.youtube.com/embed/C_Gp_ZHwaUQ"), "Use official in-app embed")
        check(html.contains("strict-origin-when-cross-origin"), "Identify the app to the embedded player")
        check(!html.contains("<script>bad()"), "Escape publisher text in the player")
        check(html.contains("allowfullscreen"), "Keep native full-screen player support")
        check(GameMediaPlayer.steamVideoURL("https://video.akamai.steamstatic.com/steam/apps/1/movie_max.m3u8") != nil, "Current official HLS format")
        check(GameMediaPlayer.steamVideoURL("https://cdn.akamai.steamstatic.com/steam/apps/1/movie.mp4") != nil, "Official MP4 format")
        for value in ["http://video.akamai.steamstatic.com/movie.mp4", "file:///tmp/movie.mp4", "javascript:alert(1)", "https://steamstatic.com.evil.example/movie.mp4", "https://user:password@video.akamai.steamstatic.com/movie.mp4", "https://video.akamai.steamstatic.com:443/movie.mp4", "https://video.akamai.steamstatic.com/index.html"] {
            check(GameMediaPlayer.steamVideoURL(value) == nil, "Reject an untrusted video source")
        }
        check(GameMediaPlayer.page(["provider":"youtube", "youtubeId":"invalid"]) == nil, "No invalid player is generated")
        check(GameMediaPlayer.page(["provider":"other", "url":"https://example.com/movie.mp4"]) == nil, "No unsupported provider is opened")
        let steam = GameMediaPlayer.page(["provider":"steam", "url":"https://video.akamai.steamstatic.com/movie.m3u8"])!
        check(steam.contains("<video controls autoplay playsinline"), "Steam media uses embedded native controls")
        print("GameMediaPlayer: \(checks) checks passed")
    }
}
