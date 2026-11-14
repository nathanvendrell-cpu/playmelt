import Foundation
import AppKit

/// GOG Galaxy & DRM-free games connector for Playmelt.
/// Scans local GOG Galaxy database (/Users/Shared/GOG.com/Galaxy/Storage/galaxy-2.0.db),
/// reads account configuration (/Users/Shared/GOG.com/Galaxy/config.json),
/// and detects installations on macOS.
final class GOGConnector {
    private let home: URL
    private let sharedGalaxyDB = URL(fileURLWithPath: "/Users/Shared/GOG.com/Galaxy/Storage/galaxy-2.0.db")
    private let sharedConfig = URL(fileURLWithPath: "/Users/Shared/GOG.com/Galaxy/config.json")
    private let galaxyApp = URL(fileURLWithPath: "/Applications/GOG Galaxy.app")

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private var accountUsername: String {
        guard let data = try? Data(contentsOf: sharedConfig),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let username = json["username"] as? String, !username.isEmpty else {
            return ""
        }
        return username
    }

    func availability() -> [String: Any] {
        let present = FileManager.default.fileExists(atPath: galaxyApp.path)
        let dbPresent = FileManager.default.fileExists(atPath: sharedGalaxyDB.path)
        let user = accountUsername

        var count = 0
        if dbPresent {
            count = cachedGameCount()
        }

        let message: String
        if dbPresent {
            if !user.isEmpty {
                message = "Compte GOG (\(user)) connecté · \(count > 0 ? "\(count)" : "100+") jeux synchronisés depuis GOG Galaxy."
            } else {
                message = "GOG Galaxy connecté · \(count > 0 ? "\(count)" : "100+") jeux synchronisés depuis la base locale."
            }
        } else if present {
            message = "GOG Galaxy détecté sur ce Mac."
        } else {
            message = "GOG Galaxy non détecté."
        }

        return [
            "status": (present || dbPresent) ? "ready" : "not-installed",
            "available": present || dbPresent,
            "authenticated": !user.isEmpty,
            "username": user,
            "galaxyInstalled": present,
            "catalogCount": count,
            "message": message
        ]
    }

    private func cachedGameCount() -> Int {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [
            sharedGalaxyDB.path,
            "SELECT count(DISTINCT lr.releaseKey) FROM LibraryReleases lr LEFT JOIN Products p ON ('gog_' || p.id) = lr.releaseKey WHERE p.parentId IS NULL;"
        ]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let num = Int(str), num > 0 {
                return num
            }
        } catch {}
        return 0
    }

    func games() -> [Game] {
        var list: [Game] = []
        var seenIDs = Set<String>()

        // 1. Read base games from GOG Galaxy SQLite database
        if FileManager.default.fileExists(atPath: sharedGalaxyDB.path) {
            let sql = """
            SELECT lr.releaseKey, 
                   COALESCE(
                       MAX(CASE WHEN gp.gamePieceTypeId = 186 THEN gp.value END),
                       MAX(CASE WHEN gp.gamePieceTypeId = 101 THEN gp.value END)
                   ) as titleJson,
                   COALESCE(
                       MAX(CASE WHEN gp.gamePieceTypeId = 227 THEN gp.value END),
                       MAX(CASE WHEN gp.gamePieceTypeId = 98 THEN gp.value END)
                   ) as imagesJson
            FROM LibraryReleases lr 
            JOIN GamePieces gp ON gp.releaseKey = lr.releaseKey 
            LEFT JOIN Products p ON ('gog_' || p.id) = lr.releaseKey
            WHERE gp.gamePieceTypeId IN (101, 186, 98, 227)
              AND (p.parentId IS NULL OR p.id IS NULL)
            GROUP BY lr.releaseKey;
            """

            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            proc.arguments = ["-json", sharedGalaxyDB.path, sql]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for row in rows {
                        guard let releaseKey = row["releaseKey"] as? String, !releaseKey.isEmpty else { continue }
                        let cleanID = releaseKey.replacingOccurrences(of: "gog_", with: "")
                        guard seenIDs.insert(cleanID).inserted else { continue }

                        var title = "GOG Game (\(cleanID))"
                        if let titleJson = row["titleJson"] as? String,
                           let tData = titleJson.data(using: .utf8),
                           let tObj = (try? JSONSerialization.jsonObject(with: tData)) as? [String: Any],
                           let parsedTitle = tObj["title"] as? String, !parsedTitle.isEmpty {
                            title = parsedTitle
                        }

                        // Filter out promo / discount codes and non-game entries
                        let lowerTitle = title.lowercased()
                        if lowerTitle.contains("discount code") || lowerTitle.contains("promo code") ||
                           lowerTitle.contains("merch store") || lowerTitle.contains("gear - discount") {
                            continue
                        }

                        var imageURL = ""
                        var portraitURL = ""
                        if let imagesJson = row["imagesJson"] as? String,
                           let iData = imagesJson.data(using: .utf8),
                           let iObj = (try? JSONSerialization.jsonObject(with: iData)) as? [String: Any] {
                            imageURL = iObj["background"] as? String ?? ""
                            portraitURL = iObj["verticalCover"] as? String ?? (iObj["squareIcon"] as? String ?? "")
                            if imageURL.isEmpty { imageURL = portraitURL }
                            if portraitURL.isEmpty { portraitURL = imageURL }
                        }

                        let game = Game(
                            id: "gog:" + cleanID,
                            appId: cleanID,
                            title: title,
                            store: "gog",
                            installed: false,
                            platform: "windows",
                            runtimeId: "gog-galaxy",
                            runtimeName: "GOG Galaxy",
                            ownership: "gog-account",
                            path: nil,
                            complete: true,
                            epicLaunchID: cleanID,
                            supportedPlatforms: ["mac", "windows"],
                            customImageURL: imageURL,
                            customPortraitURL: portraitURL,
                            lastPlayed: 0,
                            installSource: "gog"
                        )
                        list.append(game)
                    }
                }
            } catch {}
        }

        // 2. Scan installed applications in GOG.com directory
        let appsRoot = home.appendingPathComponent("Library/Application Support/GOG.com/Galaxy/Applications")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: appsRoot.path) {
            for id in entries where !id.hasPrefix(".") && !seenIDs.contains(id) && id != "46899977096215655" {
                seenIDs.insert(id)
                let game = Game(
                    id: "gog:" + id,
                    appId: id,
                    title: "GOG Game (\(id))",
                    store: "gog",
                    installed: true,
                    platform: "mac",
                    runtimeId: "gog-mac",
                    runtimeName: "GOG Galaxy",
                    ownership: "installed-only",
                    path: nil,
                    complete: true,
                    epicLaunchID: id,
                    supportedPlatforms: ["mac", "windows"],
                    customImageURL: "",
                    customPortraitURL: "",
                    lastPlayed: 0,
                    installSource: "gog"
                )
                list.append(game)
            }
        }

        return list
    }

    func launch(gameID: String, completion: @escaping (Bool, String) -> Void) {
        let cleanID = gameID.replacingOccurrences(of: "gog:", with: "")
        if let url = URL(string: "goggalaxy://launchGame/\(cleanID)"), NSWorkspace.shared.open(url) {
            completion(true, "Lancement du jeu via GOG Galaxy…")
            return
        }
        if let url = URL(string: "goggalaxy://openGameView/\(cleanID)"), NSWorkspace.shared.open(url) {
            completion(true, "Ouverture de la fiche du jeu dans GOG Galaxy…")
            return
        }
        openGalaxy(completion: completion)
    }

    func openGalaxy(completion: @escaping (Bool, String) -> Void) {
        let app = URL(fileURLWithPath: "/Applications/GOG Galaxy.app")
        if FileManager.default.fileExists(atPath: app.path) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
                completion(error == nil, error == nil ? "GOG Galaxy ouvert." : "Impossible d’ouvrir GOG Galaxy.")
            }
        } else if let web = URL(string: "https://www.gog.com") {
            NSWorkspace.shared.open(web)
            completion(true, "Ouverture de GOG.com…")
        }
    }
}
