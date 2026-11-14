import Foundation

/// CPU bookkeeping for Playmelt-owned backing allocations. Does not create a
/// Metal device, reserve RAM/VRAM, change a system quota or control another app.
///
/// Apple describes recommendedMaxWorkingSetSize as an approximate performance
/// threshold, not free memory. currentAllocatedSize is an observed resource total.
/// https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize
/// https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize
///
/// Integration: reserve then beginAllocation before creating a resource;
/// allocationFailed if creation returns no resource, otherwise commit its actual
/// backing size. Count a heap once, not its
/// suballocated textures/views again. requestRetirement does NOT free capacity:
/// confirmReleased is allowed only after GPU work completed and the backing was
/// really released. No Metal operations or completion inference happen here.
final class GraphicsMemoryBudget: @unchecked Sendable {
    enum Pressure: String, Codable { case normal, warning, critical, unknown }
    enum Kind: String, Codable { case buffer, texture, heap, modelWeights, cache, other }
    enum Phase: String, Codable { case reserved, creating, resident, retiring }
    enum Failure: Error, Equatable {
        case invalidPolicy, zeroSize, duplicateAllocation, allocationLimit, arithmeticOverflow
        case admissionClosed, budgetExceeded, unknownReservation, invalidPhase, staleObservation
    }

    struct Inputs: Codable {
        let totalUnifiedBytes: UInt64
        let recommendedWorkingSetBytes: UInt64?
        /// Total own allocation footprint, INCLUDING committed entries in this ledger.
        /// The caller must sample it consistently with ledger mutations, not use a
        /// total for the whole system or another process. No external usage is guessed.
        let observedOwnAllocatedBytes: UInt64?
        let hasUnifiedMemory: Bool
        let renderProtectionEnabled: Bool
        let pressure: Pressure
        /// Monotonically increasing caller sample number. No polling or clock here.
        let observationSequence: UInt64
        init(totalUnifiedBytes: UInt64, recommendedWorkingSetBytes: UInt64?, observedOwnAllocatedBytes: UInt64?,
             hasUnifiedMemory: Bool, renderProtectionEnabled: Bool, pressure: Pressure, observationSequence: UInt64 = 0) {
            self.totalUnifiedBytes = totalUnifiedBytes; self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
            self.observedOwnAllocatedBytes = observedOwnAllocatedBytes; self.hasUnifiedMemory = hasUnifiedMemory
            self.renderProtectionEnabled = renderProtectionEnabled; self.pressure = pressure; self.observationSequence = observationSequence
        }
    }

    struct Policy: Codable {
        /// Product policy, not an Apple guarantee or a dedicated VRAM reservation.
        let maximumBudgetBytes: UInt64
        let unifiedMemoryBasisPoints: UInt64
        let recommendedWorkingSetBasisPoints: UInt64
        let maximumTrackedAllocations: Int
        let enforceRecommendedWorkingSet: Bool
        let reduceBudgetOnWarning: Bool
        // Default: the full physical capacity, with no Playmelt percentage,
        // fixed GiB ceiling or use of Apple's recommendation as a hard quota.
        // This ledger never changes the memory available to an external game.
        init(maximumBudgetBytes: UInt64 = .max, unifiedMemoryBasisPoints: UInt64 = 10_000,
             recommendedWorkingSetBasisPoints: UInt64 = 10_000, maximumTrackedAllocations: Int = .max,
             enforceRecommendedWorkingSet: Bool = false, reduceBudgetOnWarning: Bool = false) {
            self.maximumBudgetBytes = maximumBudgetBytes; self.unifiedMemoryBasisPoints = unifiedMemoryBasisPoints
            self.recommendedWorkingSetBasisPoints = recommendedWorkingSetBasisPoints; self.maximumTrackedAllocations = maximumTrackedAllocations
            self.enforceRecommendedWorkingSet = enforceRecommendedWorkingSet; self.reduceBudgetOnWarning = reduceBudgetOnWarning
        }
        fileprivate var valid: Bool {
            unifiedMemoryBasisPoints <= 10_000 && recommendedWorkingSetBasisPoints <= 10_000 &&
            maximumTrackedAllocations > 0
        }
    }

    struct Reservation: Equatable, Codable {
        let id: UUID
        fileprivate let ticket: UUID
        let reservedBytes: UInt64
    }

    struct Snapshot: Codable {
        let ownership: String, allocationMode: String
        let configuredTargetBytes: UInt64, policyCeilingBytes: UInt64, effectiveAdmissionBytes: UInt64
        let policyMaximumBytes: UInt64, budgetBytes: UInt64
        let observedOwnAllocatedBytes: UInt64?
        let untrackedOwnBytes: UInt64, residentBytes: UInt64, reservedBytes: UInt64, creatingBytes: UInt64, retiringBytes: UInt64
        let accountedUsageBytes: UInt64, availableBudgetBytes: UInt64, overBudgetBytes: UInt64
        let trackedAllocationCount: Int
        let observationSequence: UInt64
        let arithmeticOverflow: Bool, observationBelowTrackedBytes: Bool, observationDeferred: Bool, admissionOpen: Bool
        let reasons: [String]
        var json: [String: Any] {
            guard let data = try? JSONEncoder().encode(self), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return value
        }
    }

    struct CommitResult {
        let reservation: Reservation
        /// If true, do not submit this new resource to GPU work. Release it safely
        /// then confirmReleased. It remains counted until that confirmation.
        let retirementRequired: Bool
        let snapshot: Snapshot
    }

    struct RetirementCandidate: Codable {
        let reservation: Reservation, kind: Kind, phase: Phase, bytes: UInt64
    }
    struct RetirementPlan: Codable {
        let requiredReductionBytes: UInt64
        let candidates: [RetirementCandidate]
        let candidateBytes: UInt64
        let pendingCancellationBytes: UInt64
        let alreadyRetiringBytes: UInt64
        let reductionStillUncoveredBytes: UInt64
        let accountingOnly: Bool
    }

    private struct Entry {
        let reservation: Reservation, kind: Kind, reclaimable: Bool
        var phase: Phase, bytes: UInt64
    }
    private struct Totals { var resident: UInt64 = 0, reserved: UInt64 = 0, creating: UInt64 = 0, retiring: UInt64 = 0; var overflow = false }
    private let lock = NSLock()
    private let policy: Policy
    private var inputs: Inputs
    private var untrackedOwnBytes: UInt64
    private var observationBelowTrackedBytes = false
    private var observationDeferred = false
    private var entries: [UUID: Entry] = [:]
    private var closed = false

    init(inputs: Inputs, policy: Policy = Policy()) throws {
        guard policy.valid else { throw Failure.invalidPolicy }
        self.inputs = inputs; self.policy = policy; untrackedOwnBytes = inputs.observedOwnAllocatedBytes ?? 0
    }

    /// Diagnostics with no ledger and no side effects. Invalid policies fail closed.
    static func evaluate(inputs: Inputs, policy: Policy = Policy()) -> Snapshot {
        makeSnapshot(inputs: inputs, policy: policy, totals: Totals(),
                     untracked: inputs.observedOwnAllocatedBytes ?? 0, count: 0, closed: false, belowTracked: false, deferred: false)
    }

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snapshotLocked() }

    /// A fresh observation includes already tracked resident/retiring resources.
    /// Only its residual is added to the ledger; later commits are counted on top.
    /// The caller serializes sampling with its resource lifecycle; a sequence
    /// number rejects replayed samples but cannot authenticate a device reading.
    @discardableResult func update(inputs next: Inputs) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard next.observationSequence > inputs.observationSequence else { throw Failure.staleObservation }
        let totals = totalsLocked()
        // During creation, device usage may already include some pending objects.
        // Preserve the old residual, block admissions, and require a newer sample
        // after every creating ticket has committed/failed. Never guess inclusion.
        observationDeferred = totals.creating > 0
        if !observationDeferred {
            let observed = next.observedOwnAllocatedBytes ?? 0
            observationBelowTrackedBytes = observed < totals.resident
            untrackedOwnBytes = observed > totals.resident ? observed - totals.resident : 0
        }
        inputs = next
        return snapshotLocked()
    }

    func reserve(id: UUID = UUID(), bytes: UInt64, kind: Kind, reclaimable: Bool = false) throws -> Reservation {
        lock.lock(); defer { lock.unlock() }
        guard bytes > 0 else { throw Failure.zeroSize }
        guard entries[id] == nil else { throw Failure.duplicateAllocation }
        guard entries.count < policy.maximumTrackedAllocations else { throw Failure.allocationLimit }
        let state = snapshotLocked()
        guard state.admissionOpen else { throw Failure.admissionClosed }
        let projected = state.accountedUsageBytes.addingReportingOverflow(bytes)
        guard !projected.overflow else { throw Failure.arithmeticOverflow }
        guard projected.partialValue <= state.budgetBytes else { throw Failure.budgetExceeded }
        let reservation = Reservation(id: id, ticket: UUID(), reservedBytes: bytes)
        entries[id] = Entry(reservation: reservation, kind: kind, reclaimable: reclaimable, phase: .reserved, bytes: bytes)
        return reservation
    }

    /// Call immediately before resource creation on the owning resource queue.
    /// Once creating, cancelReservation cannot discard this bookkeeping entry.
    func beginAllocation(_ reservation: Reservation) throws {
        lock.lock(); defer { lock.unlock() }
        var entry = try entryLocked(reservation)
        guard entry.phase == .reserved else { throw Failure.invalidPhase }
        let state = snapshotLocked()
        guard state.budgetBytes > 0, state.overBudgetBytes == 0, !state.arithmeticOverflow else { throw Failure.admissionClosed }
        entry.phase = .creating; entries[reservation.id] = entry
    }

    /// Only after the allocator returned no resource; otherwise use commit.
    func allocationFailed(_ reservation: Reservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard try entryLocked(reservation).phase == .creating else { throw Failure.invalidPhase }
        entries.removeValue(forKey: reservation.id)
    }

    @discardableResult func commit(_ reservation: Reservation, actualBytes: UInt64) throws -> CommitResult {
        lock.lock(); defer { lock.unlock() }
        guard actualBytes > 0 else { throw Failure.zeroSize }
        var entry = try entryLocked(reservation)
        guard entry.phase == .creating else { throw Failure.invalidPhase }
        // A caller may discover extra alignment/heap overhead after creation, or
        // pressure may change meanwhile. Count the actual allocation even when
        // it exceeds the budget; never pretend a failed commit freed real bytes.
        entry.bytes = actualBytes; entry.phase = .resident; entries[reservation.id] = entry
        let state = snapshotLocked()
        let retire = closed || state.arithmeticOverflow || state.overBudgetBytes > 0 || state.budgetBytes == 0
        if retire { entry.phase = .retiring; entries[reservation.id] = entry }
        return CommitResult(reservation: reservation, retirementRequired: retire, snapshot: snapshotLocked())
    }

    func cancelReservation(_ reservation: Reservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard try entryLocked(reservation).phase == .reserved else { throw Failure.invalidPhase }
        entries.removeValue(forKey: reservation.id)
    }

    func requestRetirement(_ reservation: Reservation) throws {
        lock.lock(); defer { lock.unlock() }
        var entry = try entryLocked(reservation)
        guard entry.phase == .resident else { throw Failure.invalidPhase }
        entry.phase = .retiring; entries[reservation.id] = entry
    }

    /// Caller acknowledgement after actual destruction AND completion of GPU use.
    /// Calling twice/stale tickets cannot release a new allocation with the same ID.
    func confirmReleased(_ reservation: Reservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard try entryLocked(reservation).phase == .retiring else { throw Failure.invalidPhase }
        entries.removeValue(forKey: reservation.id)
    }

    /// Stop new admissions without erasing live resources or pending tickets.
    func close() { lock.lock(); closed = true; lock.unlock() }

    /// Suggestions only: reservations can be cancelled if creation has not begun;
    /// only explicitly reclaimable resident allocations are selected for retirement.
    /// Retiring and nonreclaimable resources stay charged until confirmed released.
    func retirementPlan() -> RetirementPlan {
        lock.lock(); defer { lock.unlock() }
        let state = snapshotLocked()
        let reserved = entries.values.filter { $0.phase == .reserved }.sorted { $0.reservation.id.uuidString < $1.reservation.id.uuidString }
        let residents = entries.values.filter { $0.phase == .resident && $0.reclaimable }.sorted {
            if $0.kind == .cache && $1.kind != .cache { return true }
            if $1.kind == .cache && $0.kind != .cache { return false }
            return $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.reservation.id.uuidString < $1.reservation.id.uuidString
        }
        var candidates: [RetirementCandidate] = [], bytes: UInt64 = 0
        let outstanding = state.overBudgetBytes > state.retiringBytes ? state.overBudgetBytes - state.retiringBytes : 0
        for entry in reserved + residents where bytes < outstanding {
            candidates.append(RetirementCandidate(reservation: entry.reservation, kind: entry.kind, phase: entry.phase, bytes: entry.bytes))
            bytes = Self.saturatedAdd(bytes, entry.bytes).value
        }
        let uncovered = outstanding > bytes ? outstanding - bytes : 0
        return RetirementPlan(requiredReductionBytes: state.overBudgetBytes, candidates: candidates, candidateBytes: bytes,
                              pendingCancellationBytes: state.reservedBytes - state.creatingBytes, alreadyRetiringBytes: state.retiringBytes,
                              reductionStillUncoveredBytes: uncovered, accountingOnly: true)
    }

    private func entryLocked(_ reservation: Reservation) throws -> Entry {
        guard let entry = entries[reservation.id], entry.reservation == reservation else { throw Failure.unknownReservation }
        return entry
    }
    private func totalsLocked() -> Totals {
        var totals = Totals()
        for entry in entries.values {
            if entry.phase == .reserved || entry.phase == .creating {
                let sum = Self.saturatedAdd(totals.reserved, entry.bytes); totals.reserved = sum.value; totals.overflow = totals.overflow || sum.overflow
                if entry.phase == .creating {
                    let sum = Self.saturatedAdd(totals.creating, entry.bytes); totals.creating = sum.value; totals.overflow = totals.overflow || sum.overflow
                }
            } else {
                let sum = Self.saturatedAdd(totals.resident, entry.bytes); totals.resident = sum.value; totals.overflow = totals.overflow || sum.overflow
                if entry.phase == .retiring {
                    let sum = Self.saturatedAdd(totals.retiring, entry.bytes); totals.retiring = sum.value; totals.overflow = totals.overflow || sum.overflow
                }
            }
        }
        return totals
    }
    private func snapshotLocked() -> Snapshot {
        Self.makeSnapshot(inputs: inputs, policy: policy, totals: totalsLocked(), untracked: untrackedOwnBytes,
                          count: entries.count, closed: closed, belowTracked: observationBelowTrackedBytes, deferred: observationDeferred)
    }
    private static func saturatedAdd(_ a: UInt64, _ b: UInt64) -> (value: UInt64, overflow: Bool) {
        let result = a.addingReportingOverflow(b); return (result.overflow ? UInt64.max : result.partialValue, result.overflow)
    }
    private static func fraction(_ value: UInt64, basisPoints: UInt64) -> UInt64 {
        // Quotient/remainder avoids value*10000 overflowing at UInt64.max.
        (value / 10_000) * basisPoints + ((value % 10_000) * basisPoints) / 10_000
    }
    private static func makeSnapshot(inputs: Inputs, policy: Policy, totals: Totals, untracked: UInt64,
                                     count: Int, closed: Bool, belowTracked: Bool, deferred: Bool) -> Snapshot {
        var reasons: [String] = []
        if !policy.valid { reasons.append("invalid-policy") }
        if !inputs.hasUnifiedMemory { reasons.append("unified-memory-required") }
        if inputs.totalUnifiedBytes == 0 || inputs.observedOwnAllocatedBytes == nil ||
            (policy.enforceRecommendedWorkingSet && (inputs.recommendedWorkingSetBytes == nil || inputs.recommendedWorkingSetBytes == 0)) {
            reasons.append("memory-observation-unavailable")
        }
        if inputs.renderProtectionEnabled { reasons.append("render-protection") }
        if inputs.pressure == .critical { reasons.append("critical-memory-pressure") }
        if inputs.pressure == .unknown { reasons.append("memory-pressure-unknown") }
        if closed { reasons.append("closed") }
        if deferred { reasons.append("usage-observation-deferred-during-creation") }
        let ceiling: UInt64
        if policy.valid && inputs.hasUnifiedMemory && inputs.totalUnifiedBytes > 0 {
            let physical = min(policy.maximumBudgetBytes, fraction(inputs.totalUnifiedBytes, basisPoints: policy.unifiedMemoryBasisPoints))
            if policy.enforceRecommendedWorkingSet {
                ceiling = min(physical, fraction(inputs.recommendedWorkingSetBytes ?? 0, basisPoints: policy.recommendedWorkingSetBasisPoints))
            } else { ceiling = physical }
        } else { ceiling = 0 }
        var budget: UInt64 = 0
        if reasons.isEmpty {
            budget = ceiling
            if inputs.pressure == .warning && policy.reduceBudgetOnWarning { budget /= 2; reasons.append("memory-pressure-warning") }
        }
        let tracked = saturatedAdd(totals.resident, totals.reserved)
        let all = saturatedAdd(untracked, tracked.value)
        let overflow = totals.overflow || tracked.overflow || all.overflow
        if overflow { reasons.append("accounting-overflow") }
        if all.value > budget { reasons.append("over-budget") }
        let available = overflow || all.value >= budget ? 0 : budget - all.value
        return Snapshot(ownership: "playmelt-renderer-not-external-game", allocationMode: "accounting-only-no-system-reservation",
                        configuredTargetBytes: policy.maximumBudgetBytes, policyCeilingBytes: ceiling, effectiveAdmissionBytes: available,
                        policyMaximumBytes: policy.maximumBudgetBytes, budgetBytes: budget,
                        observedOwnAllocatedBytes: inputs.observedOwnAllocatedBytes, untrackedOwnBytes: untracked,
                        residentBytes: totals.resident, reservedBytes: totals.reserved, creatingBytes: totals.creating, retiringBytes: totals.retiring,
                        accountedUsageBytes: all.value, availableBudgetBytes: available,
                        overBudgetBytes: all.value > budget ? all.value - budget : 0,
                        trackedAllocationCount: count, observationSequence: inputs.observationSequence,
                        arithmeticOverflow: overflow, observationBelowTrackedBytes: belowTracked, observationDeferred: deferred,
                        admissionOpen: available > 0, reasons: reasons)
    }
}
