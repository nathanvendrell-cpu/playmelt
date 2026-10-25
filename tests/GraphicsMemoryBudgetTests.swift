import Foundation

@main
enum GraphicsMemoryBudgetTests {
    typealias Budget = GraphicsMemoryBudget
    static func main() throws {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !condition() { fatalError(message) }
        }
        func rejects(_ expected: Budget.Failure, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected rejection: \(expected)") }
            catch let error as Budget.Failure { require(error == expected, "Wrong rejection: \(error), wanted \(expected)") }
            catch { fatalError("Unexpected error: \(error)") }
        }
        let gib: UInt64 = 1_073_741_824
        func inputs(_ own: UInt64? = 0, sequence: UInt64 = 0, pressure: Budget.Pressure = .normal,
                    renders: Bool = false, total: UInt64 = 1000, recommended: UInt64? = 1000, unified: Bool = true) -> Budget.Inputs {
            Budget.Inputs(totalUnifiedBytes: total, recommendedWorkingSetBytes: recommended, observedOwnAllocatedBytes: own,
                          hasUnifiedMemory: unified, renderProtectionEnabled: renders, pressure: pressure, observationSequence: sequence)
        }
        let policy = Budget.Policy(maximumBudgetBytes: 1000, unifiedMemoryBasisPoints: 10_000, recommendedWorkingSetBasisPoints: 10_000)
        let normal = Budget.evaluate(inputs: inputs(2*gib, total: 48*gib, recommended: 36*gib))
        require(normal.configuredTargetBytes == 16*gib && normal.policyCeilingBytes == 16*gib, "16GiB is the configured ceiling, not a reservation")
        require(normal.effectiveAdmissionBytes == 14*gib && normal.accountedUsageBytes == 2*gib, "existing own footprint consumes budget")
        let warning = Budget.evaluate(inputs: inputs(2*gib, pressure: .warning, total: 48*gib, recommended: 36*gib))
        require(warning.budgetBytes == 8*gib && warning.effectiveAdmissionBytes == 6*gib, "warning halves the policy ceiling")
        let protected = Budget.evaluate(inputs: inputs(2*gib, renders: true, total: 48*gib, recommended: 36*gib))
        require(protected.policyCeilingBytes == 16*gib && protected.effectiveAdmissionBytes == 0 && protected.reasons.contains("render-protection"), "render guard closes admission without inventing a physical quota")
        for input in [inputs(pressure: .unknown), inputs(pressure: .critical), inputs(nil), inputs(recommended: nil), inputs(recommended: 0), inputs(total: 0), inputs(unified: false)] {
            require(!Budget.evaluate(inputs: input, policy: policy).admissionOpen, "unknown/unsupported telemetry fails closed")
        }
        require(Budget.evaluate(inputs: inputs(total: 8000, recommended: 6000)).policyCeilingBytes == 4000, "unified memory fraction limits small machines")
        require(Budget.evaluate(inputs: inputs(total: 8000, recommended: 3000)).policyCeilingBytes == 2400, "recommended working set is an independent bound")
        let invalid = Budget.Policy(unifiedMemoryBasisPoints: 10_001)
        require(Budget.evaluate(inputs: inputs(), policy: invalid).budgetBytes == 0, "invalid diagnostics policy fails closed")
        rejects(.invalidPolicy) { _ = try Budget(inputs: inputs(), policy: invalid) }
        let huge = Budget.evaluate(inputs: inputs(total: .max, recommended: .max), policy: Budget.Policy(maximumBudgetBytes: .max, unifiedMemoryBasisPoints: 10_000, recommendedWorkingSetBasisPoints: 10_000))
        require(huge.policyCeilingBytes == UInt64.max && !huge.arithmeticOverflow, "fraction arithmetic cannot overflow")

        let ledger = try Budget(inputs: inputs(100), policy: policy)
        let backing = UUID()
        let ticket = try ledger.reserve(id: backing, bytes: 200, kind: .heap)
        require(ledger.snapshot.accountedUsageBytes == 300 && ledger.snapshot.reservedBytes == 200, "reservation is charged before creation")
        rejects(.duplicateAllocation) { _ = try ledger.reserve(id: backing, bytes: 200, kind: .heap) }
        rejects(.invalidPhase) { _ = try ledger.commit(ticket, actualBytes: 220) }
        try ledger.beginAllocation(ticket)
        rejects(.invalidPhase) { try ledger.cancelReservation(ticket) }
        let committed = try ledger.commit(ticket, actualBytes: 220)
        require(!committed.retirementRequired && ledger.snapshot.accountedUsageBytes == 320, "actual aligned size replaces estimate once")
        rejects(.invalidPhase) { _ = try ledger.commit(ticket, actualBytes: 220) }
        let observed = try ledger.update(inputs: inputs(320, sequence: 1))
        require(observed.untrackedOwnBytes == 100 && observed.residentBytes == 220 && observed.accountedUsageBytes == 320, "observed own total is not added twice")
        rejects(.staleObservation) { _ = try ledger.update(inputs: inputs(0, sequence: 1)) }
        require(ledger.snapshot.accountedUsageBytes == 320, "stale sample cannot create fictional capacity")
        rejects(.invalidPhase) { try ledger.confirmReleased(ticket) }
        try ledger.requestRetirement(ticket)
        require(ledger.snapshot.accountedUsageBytes == 320 && ledger.snapshot.retiringBytes == 220, "retirement request is not a free")
        try ledger.confirmReleased(ticket)
        require(ledger.snapshot.accountedUsageBytes == 100, "only confirmed backing release restores capacity")
        rejects(.unknownReservation) { try ledger.confirmReleased(ticket) }
        let replacement = try ledger.reserve(id: backing, bytes: 50, kind: .buffer)
        try ledger.beginAllocation(replacement); _ = try ledger.commit(replacement, actualBytes: 50)
        try ledger.requestRetirement(replacement)
        rejects(.unknownReservation) { try ledger.confirmReleased(ticket) }
        require(ledger.snapshot.residentBytes == 50, "old ticket cannot free a newer resource sharing its identifier")
        try ledger.confirmReleased(replacement)
        rejects(.zeroSize) { _ = try ledger.reserve(bytes: 0, kind: .texture) }
        rejects(.budgetExceeded) { _ = try ledger.reserve(bytes: 901, kind: .texture) }

        let pressured = try Budget(inputs: inputs(), policy: policy)
        let notStarted = try pressured.reserve(bytes: 100, kind: .buffer)
        _ = try pressured.update(inputs: inputs(sequence: 1, pressure: .critical))
        rejects(.admissionClosed) { try pressured.beginAllocation(notStarted) }
        try pressured.cancelReservation(notStarted)
        _ = try pressured.update(inputs: inputs(sequence: 2))
        let creating = try pressured.reserve(bytes: 100, kind: .texture)
        try pressured.beginAllocation(creating)
        let uncertain = try pressured.update(inputs: inputs(150, sequence: 3, renders: true))
        require(uncertain.observationDeferred && uncertain.untrackedOwnBytes == 0 && uncertain.creatingBytes == 100, "in-flight creation cannot be mistaken for observed residual usage")
        let afterPressure = try pressured.commit(creating, actualBytes: 150)
        require(afterPressure.retirementRequired && afterPressure.snapshot.residentBytes == 150 && afterPressure.snapshot.retiringBytes == 150, "real resource survives guard change in bookkeeping")
        rejects(.admissionClosed) { _ = try pressured.reserve(bytes: 1, kind: .cache) }
        try pressured.confirmReleased(creating)
        require(pressured.snapshot.accountedUsageBytes == 0 && !pressured.snapshot.admissionOpen, "release does not authenticate a deferred observation")
        _ = try pressured.update(inputs: inputs(sequence: 4))
        require(pressured.snapshot.admissionOpen && !pressured.snapshot.observationDeferred, "fresh coherent observation restores eligibility")
        let failed = try pressured.reserve(bytes: 100, kind: .texture)
        try pressured.beginAllocation(failed); try pressured.allocationFailed(failed)
        require(pressured.snapshot.trackedAllocationCount == 0, "failed creation without a resource releases reservation")
        rejects(.unknownReservation) { _ = try pressured.commit(failed, actualBytes: 100) }

        let oversized = try Budget(inputs: inputs(), policy: policy)
        let small = try oversized.reserve(bytes: 100, kind: .buffer)
        try oversized.beginAllocation(small)
        let over = try oversized.commit(small, actualBytes: 1200)
        require(over.retirementRequired && over.snapshot.accountedUsageBytes == 1200 && over.snapshot.overBudgetBytes == 200, "oversized physical allocation remains fully charged")
        try oversized.confirmReleased(small)
        require(oversized.snapshot.accountedUsageBytes == 0, "oversize retirement is recoverable")

        let overflow = try Budget(inputs: inputs(), policy: policy)
        let a = try overflow.reserve(bytes: 1, kind: .buffer), b = try overflow.reserve(bytes: 1, kind: .buffer)
        try overflow.beginAllocation(a); try overflow.beginAllocation(b)
        _ = try overflow.commit(a, actualBytes: .max); _ = try overflow.commit(b, actualBytes: 1)
        require(overflow.snapshot.arithmeticOverflow && overflow.snapshot.accountedUsageBytes == .max && !overflow.snapshot.admissionOpen, "overflow saturates diagnostics and blocks admission without dropping entries")
        try overflow.confirmReleased(a)
        require(!overflow.snapshot.arithmeticOverflow && overflow.snapshot.residentBytes == 1, "recomputing after release recovers exact accounting")
        try overflow.confirmReleased(b)

        let reclaim = try Budget(inputs: inputs(50), policy: policy)
        func resident(_ bytes: UInt64, _ kind: Budget.Kind, _ reclaimable: Bool) throws -> Budget.Reservation {
            let r = try reclaim.reserve(bytes: bytes, kind: kind, reclaimable: reclaimable)
            try reclaim.beginAllocation(r); _ = try reclaim.commit(r, actualBytes: bytes); return r
        }
        let cache = try resident(300, .cache, true)
        let texture = try resident(200, .texture, true)
        let retained = try resident(200, .modelWeights, false)
        let pending = try reclaim.reserve(bytes: 30, kind: .buffer)
        _ = try reclaim.update(inputs: inputs(750, sequence: 1, pressure: .warning))
        let plan = reclaim.retirementPlan()
        require(plan.requiredReductionBytes == 280 && plan.candidates.map(\.reservation) == [pending, cache], "reclamation cancels unused reservations then chooses an explicit cache")
        require(plan.reductionStillUncoveredBytes == 0 && reclaim.snapshot.accountedUsageBytes == 780, "planning does not free allocations")
        try reclaim.cancelReservation(pending); try reclaim.requestRetirement(cache)
        require(reclaim.snapshot.accountedUsageBytes == 750, "pending cancellation and retirement remain distinct")
        try reclaim.confirmReleased(cache)
        require(reclaim.snapshot.accountedUsageBytes == 450 && reclaim.snapshot.availableBudgetBytes == 50, "confirmed reclamation restores only the true accounting delta")
        _ = try reclaim.update(inputs: inputs(450, sequence: 2, pressure: .critical))
        let criticalPlan = reclaim.retirementPlan()
        require(criticalPlan.candidates.map(\.reservation) == [texture] && criticalPlan.reductionStillUncoveredBytes == 250, "nonreclaimable and untracked resources cannot be promised free")
        try reclaim.requestRetirement(texture); try reclaim.confirmReleased(texture)
        try reclaim.requestRetirement(retained); try reclaim.confirmReleased(retained)

        let bounded = try Budget(inputs: inputs(), policy: Budget.Policy(maximumBudgetBytes: 1000, unifiedMemoryBasisPoints: 10_000, recommendedWorkingSetBasisPoints: 10_000, maximumTrackedAllocations: 1))
        let only = try bounded.reserve(bytes: 1, kind: .other)
        rejects(.allocationLimit) { _ = try bounded.reserve(bytes: 1, kind: .other) }
        bounded.close()
        require(bounded.snapshot.reservedBytes == 1 && bounded.snapshot.effectiveAdmissionBytes == 0, "close keeps outstanding tickets visible")
        rejects(.admissionClosed) { try bounded.beginAllocation(only) }
        try bounded.cancelReservation(only)

        final class Results: @unchecked Sendable {
            let lock = NSLock(); var admitted = 0
            func increment() { lock.lock(); admitted += 1; lock.unlock() }
        }
        let concurrent = try Budget(inputs: inputs(), policy: policy), unique = UUID(), results = Results()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if (try? concurrent.reserve(id: unique, bytes: 100, kind: .heap)) != nil { results.increment() }
        }
        require(results.admitted == 1 && concurrent.snapshot.reservedBytes == 100 && concurrent.snapshot.trackedAllocationCount == 1, "concurrent reservations cannot double-count or over-admit one backing")
        concurrent.close()
        let json = protected.json
        require(json["ownership"] as? String == "playmelt-renderer-not-external-game", "diagnostic scope excludes external games")
        require((json["configuredTargetBytes"] as? NSNumber)?.uint64Value == 16*gib && (json["effectiveAdmissionBytes"] as? NSNumber)?.uint64Value == 0, "diagnostics expose target separately from admissible bytes")
        let roundTrip = try JSONDecoder().decode(Budget.Snapshot.self, from: JSONEncoder().encode(protected))
        require(roundTrip.configuredTargetBytes == protected.configuredTargetBytes, "snapshot is Codable")
        print("GraphicsMemoryBudget: \(checks) CPU checks passed. No Metal import/device/resource, system quota, game or background process.")
    }
}
