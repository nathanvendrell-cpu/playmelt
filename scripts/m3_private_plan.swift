import Foundation

// Read-only source of the verified canonical renderer plan for the supervisor.
@main enum PrivatePlan {
    static func main() throws {
        guard CommandLine.arguments.count == 1 else { throw RuntimeSetupError.failed("No arguments accepted.") }
        let base = RuntimeSetup().descriptor()
        let plan = try D3DMetalStore().launchPlan(base: base)
        guard plan.preparationBlockers.isEmpty else { throw RuntimeSetupError.failed(plan.preparationBlockers.joined(separator: "; ")) }
        let hints = GameDisplayMetadata.hints()
        let value: [String: Any] = ["displayHints": hints,"wine": base.wineURL.path, "server": base.wineserverURL.path,
                                    "environment": plan.environment, "rendererHash": plan.rendererHash,
                                    "engineID": plan.engineID, "engineFingerprint": plan.engineFingerprint]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
    }
}
