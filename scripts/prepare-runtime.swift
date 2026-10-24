import Foundation
import Darwin

/// Explicit, opt-in engine preparation. Compile with RuntimeSetup.swift; never invoked
/// by the app/build/test scripts. Does not install Steam or launch a game.
@main
enum PrepareRuntime {
    static func main() {
        guard CommandLine.arguments.dropFirst().isEmpty else {
            fputs("Usage: PlaymeltRuntimeSetup (préparation explicite du moteur Wine/DXMT uniquement)\n", stderr)
            Darwin.exit(64)
        }
        let runner = PreparationRunner()
        runner.start()
        withExtendedLifetime(runner) { dispatchMain() }
    }
}

private final class PreparationRunner {
    private let setup = RuntimeSetup()
    private var signals: [DispatchSourceSignal] = []
    private var finishRequested = false
    private var lastStatus = "", lastBucket = -1
    private var requestedExitCode: Int32?
    private var cleanupNotice: DispatchSourceTimer?

    func start() {
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.interrupted(number) }
            source.resume()
            signals.append(source)
        }
        print("Playmelt — préparation explicite Wine/DXMT. Aucun lancement de Steam ou de jeu.")
        print("Moteur candidat : \(RuntimeSetup.engineID)")
        fflush(stdout)
        setup.start(progress: { [weak self] state in self?.show(state) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let descriptor):
                if descriptor.readyEngine {
                    print("Initialisation du moteur terminée. Compatibilité et performances des jeux non testées.")
                    self.finish(code: 0)
                } else {
                    fputs("La préparation s’est terminée sans moteur prêt.\n", stderr)
                    self.finish(code: 1)
                }
            case .failure(let error):
                fputs("Préparation interrompue : \(Self.safeText(error.localizedDescription))\n", stderr)
                self.finish(code: self.requestedExitCode ?? 1)
            }
        }
    }

    private func show(_ state: [String: Any]) {
        let status = state["status"] as? String ?? "unknown"
        let progress = (state["progress"] as? NSNumber)?.doubleValue
        let bucket = progress.map { Int(($0 * 10).rounded(.down)) } ?? -1
        guard status != lastStatus || bucket != lastBucket else { return }
        lastStatus = status; lastBucket = bucket
        let amount: String
        if status == "downloading", let progress {
            let bytes = (state["bytesDownloaded"] as? NSNumber)?.int64Value ?? 0
            let total = (state["bytesTotal"] as? NSNumber)?.int64Value ?? 0
            amount = " \(Int(progress * 100))% (\(bytes)/\(total) octets)"
        } else { amount = "" }
        print("[\(status)]\(amount) \(Self.safeText(state["message"] as? String ?? ""))")
        fflush(stdout)
    }

    private func interrupted(_ signal: Int32) {
        guard requestedExitCode == nil else { return }
        requestedExitCode = 128 + signal
        fputs("Signal reçu : annulation et nettoyage des ressources de cette préparation.\n", stderr)
        finish(code: 128 + signal)
    }

    private func finish(code: Int32) {
        guard !finishRequested else { return }
        finishRequested = true
        // Do not force exit while setup owns a Wine server. RuntimeSetup bounds download
        // cancellation, subprocess termination and prefix-server cleanup. A slow filesystem
        // can still delay cleanup; report that honestly instead of abandoning children.
        let notice = DispatchSource.makeTimerSource(queue: .main)
        notice.schedule(deadline: .now() + 35)
        notice.setEventHandler {
            fputs("Le nettoyage prend plus de 35 s; le lanceur attend encore sa confirmation avant de quitter.\n", stderr)
        }
        notice.resume(); cleanupNotice = notice
        setup.shutdown { [self] in
            cleanupNotice?.cancel(); cleanupNotice = nil
            signals.forEach { $0.cancel() }; signals.removeAll()
            print("Séquence de nettoyage terminée. Aucun processus n’est volontairement conservé.")
            fflush(stdout); fflush(stderr)
            Darwin.exit(requestedExitCode ?? code)
        }
    }

    private static func safeText(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(600))
    }
}
