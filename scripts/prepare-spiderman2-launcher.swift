import Foundation

// Explicit, single-purpose helper: generation only; it never launches a game.
@main enum PrepareSpiderMan2Launcher {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
    static func main() {
        guard CommandLine.arguments.count == 1 else { fail("No path or options accepted.") }
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games/MarvelsSpiderMan2", isDirectory: true).standardizedFileURL
        guard folder.resolvingSymlinksInPath() == folder,
              let folderValues = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
            fail("Expected game folder is absent, not a directory, or contains a symbolic link.")
        }
        guard !fm.fileExists(atPath: folder.appendingPathComponent("Windows").path),
              let files = try? fm.contentsOfDirectory(atPath: folder.path),
              localGameExecutable(appID: "2651280", files: files) == "Spider-Man2.exe" else {
            fail("Expected unambiguous root Spider-Man2.exe not found, or conflicting Windows folder exists.")
        }
        let executable = folder.appendingPathComponent("Spider-Man2.exe")
        guard let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: executable) else {
            fail("Game executable is absent, is not a regular file, or is a symbolic link.")
        }
        let magic = try? handle.read(upToCount: 2)
        try? handle.close()
        guard magic == Data([0x4d, 0x5a]) else { fail("Game executable has no MZ header.") }
        let game = Game(id: "2651280", appId: "2651280", title: "Marvel's Spider-Man 2", store: "steam", installed: true,
                        platform: "windows", runtimeId: "playmelt-d3dmetal", runtimeName: "D3DMetal", ownership: "installed-only",
                        path: folder, complete: true, installSource: "local")
        guard let script = ensureLaunchScript(for: game) else { fail("Launcher generation refused; verify the game and prepared runtime.") }
        print(script.path)
    }
}
