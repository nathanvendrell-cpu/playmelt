import Foundation

// Read-only source of the verified canonical renderer plan for the supervisor.
@main enum PrivatePlan {
    static func main() throws {
        guard CommandLine.arguments.count == 1 else { throw RuntimeSetupError.failed("No arguments accepted.") }
        let base = RuntimeSetup().descriptor()
        let plan = try D3DMetalStore().launchPlan(base: base)
        guard plan.preparationBlockers.isEmpty else { throw RuntimeSetupError.failed(plan.preparationBlockers.joined(separator: "; ")) }
        var hints = GameDisplayMetadata.hints()
        let target=try GameDisplayMetadata.launchTarget(hints["displays"] as? [[String:Any]] ?? [])
        hints["safeLaunchTarget"]=target
        let library=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("libPlaymeltDisplayGuard.dylib")
        let environment=try GameDisplayMetadata.guardedEnvironment(plan.environment,target:target,library:library)
        let value: [String: Any] = ["displayHints": hints,"wine": base.wineURL.path, "server": base.wineserverURL.path,
                                    "environment": environment, "rendererHash": plan.rendererHash,
                                    "engineID": plan.engineID, "engineFingerprint": plan.engineFingerprint]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
    }
}
