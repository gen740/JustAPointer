import SwiftUI
import Foundation
import CoreFoundation
import CoreBluetooth
import ApplicationServices
import AppKit
import QuartzCore
import CoreVideo

private struct SerialDiagnosticSnapshot {
    let captureID: UUID
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let receiveIntervals: [Double]
    let callbackBatchSizes: [Double]
    let receiveIntervalOverflow: Int
    let callbackBatchSizeOverflow: Int
    let acceptedPackets: Int
    let acceptedCallbacks: Int
    let callbackRequestTotal: Int
    let rejectedCandidatePackets: Int
    let mailboxReplacedPackets: Int
    let sequenceGaps: Int
    let firstReceive: TimeInterval?
    let lastReceive: TimeInterval?
}

private struct SerialDiagnosticAccumulator {
    let captureID: UUID
    let startedAt: TimeInterval
    let deadline: TimeInterval
    var receiveIntervals: [Double] = []
    var callbackBatchSizes: [Double] = []
    var receiveIntervalOverflow = 0
    var callbackBatchSizeOverflow = 0
    var acceptedPackets = 0
    var acceptedCallbacks = 0
    var callbackRequestTotal = 0
    var rejectedCandidatePackets = 0
    var mailboxReplacedPackets = 0
    var sequenceGaps = 0
    var firstReceive: TimeInterval?
    var lastReceive: TimeInterval?
    var lastAcceptedCallback: TimeInterval?

    mutating func recordCallback(at now: TimeInterval, requestCount: Int,
                                 accepted: Int, rejected: Int, replaced: Int, gaps: Int) {
        guard now >= startedAt, now < deadline else { return }
        rejectedCandidatePackets += rejected
        guard accepted > 0 else { return }
        acceptedPackets += accepted; acceptedCallbacks += 1; callbackRequestTotal += requestCount
        mailboxReplacedPackets += replaced; sequenceGaps += gaps
        if firstReceive == nil { firstReceive = now }; lastReceive = now
        if let previous = lastAcceptedCallback {
            Self.append(now - previous, to: &receiveIntervals, overflow: &receiveIntervalOverflow)
        }
        lastAcceptedCallback = now
        Self.append(Double(requestCount), to: &callbackBatchSizes, overflow: &callbackBatchSizeOverflow)
    }

    func snapshot(endedAt: TimeInterval) -> SerialDiagnosticSnapshot {
        SerialDiagnosticSnapshot(captureID: captureID, startedAt: startedAt,
                                 endedAt: max(startedAt, min(endedAt, deadline)),
                                 receiveIntervals: receiveIntervals, callbackBatchSizes: callbackBatchSizes,
                                 receiveIntervalOverflow: receiveIntervalOverflow,
                                 callbackBatchSizeOverflow: callbackBatchSizeOverflow,
                                 acceptedPackets: acceptedPackets, acceptedCallbacks: acceptedCallbacks,
                                 callbackRequestTotal: callbackRequestTotal,
                                 rejectedCandidatePackets: rejectedCandidatePackets,
                                 mailboxReplacedPackets: mailboxReplacedPackets, sequenceGaps: sequenceGaps,
                                 firstReceive: firstReceive, lastReceive: lastReceive)
    }

    private static func append(_ value: Double, to samples: inout [Double], overflow: inout Int) {
        guard value.isFinite, value >= 0 else { return }
        if samples.count < JitterDiagnosticCapture.sampleCapacity { samples.append(value) }
        else { overflow += 1 }
    }
}

private struct JitterDiagnosticCapture {
    static let duration: TimeInterval = 20
    static let sampleCapacity = 16_000

    let captureID: UUID
    let startedAt: TimeInterval
    /// Immutable presentation configuration for an A/B-comparable report.
    let adaptiveSmoothingEnabled: Bool
    /// Capture-start-only decorative configuration; reports never read changing live preferences.
    let effectsLabel: String
    var batchDrainIntervals: [Double] = []
    var batchSizes: [Double] = []
    var handoffAges: [Double] = []
    var renderIntervals: [Double] = []
    var receiveAges: [Double] = []
    var batchDrainIntervalOverflow = 0
    var batchSizeOverflow = 0
    var handoffAgeOverflow = 0
    var renderIntervalOverflow = 0
    var receiveAgeOverflow = 0
    var mappedBatches = 0
    var visibleRenderCallbacks = 0
    var lastBatchDrain: TimeInterval?
    var lastRender: TimeInterval?
    var visibleRenderObservation = 0.0

    mutating func recordBatch(_ batch: MotionBatch, acceptedMappingUptime now: TimeInterval) {
        mappedBatches += 1
        if let previous = lastBatchDrain {
            Self.append(now - previous, to: &batchDrainIntervals, overflow: &batchDrainIntervalOverflow)
        }
        Self.append(Double(batch.rawPacketCount), to: &batchSizes, overflow: &batchSizeOverflow)
        Self.append(now - batch.latestRawReceiveUptime, to: &handoffAges, overflow: &handoffAgeOverflow)
        lastBatchDrain = now
    }

    mutating func recordRender(at now: TimeInterval, startsSegment: Bool, latestReceive: TimeInterval?) {
        visibleRenderCallbacks += 1
        if startsSegment { lastRender = nil }
        if let previous = lastRender {
            let interval = now - previous
            if interval.isFinite, interval > 0 {
                visibleRenderObservation += interval
                Self.append(interval, to: &renderIntervals, overflow: &renderIntervalOverflow)
            }
        }
        lastRender = now
        if let latestReceive {
            let age = now - latestReceive
            if age.isFinite, age >= 0 { Self.append(age, to: &receiveAges, overflow: &receiveAgeOverflow) }
        }
    }

    private static func append(_ value: Double, to samples: inout [Double], overflow: inout Int) {
        guard value.isFinite, value >= 0 else { return }
        if samples.count < Self.sampleCapacity { samples.append(value) }
        else { overflow += 1 }
    }
}

private struct ConnectionIncidentSnapshot {
    let eventID: UUID
    let clearGeneration: UInt64
    let trigger: String
    let triggeringUptime: TimeInterval
    let observationUptime: TimeInterval
    let expectedGeneration: UInt64?
    let observedGeneration: UInt64
    let latestValidCandidateUptime: TimeInterval?
    let outstandingControlCount: Int
    let oldestControlAge: TimeInterval?
    let pendingStatusCount: Int
    let subscribedCount: Int
}

private struct TransportStamp {
    let generation: UInt64
    let ordinal: UInt64
    let rawReceiveUptime: TimeInterval
}

private struct MotionBatch {
    let generation: UInt64
    let session: UInt64
    var firstSequence: UInt32
    var latestSequence: UInt32
    var latestX: Float
    var latestY: Float
    var firstRawReceiveUptime: TimeInterval
    var latestRawReceiveUptime: TimeInterval
    var rawPacketCount: Int
    var rawCallbackCount: Int
    var callbackRequestTotal: Int
    var callbackBatchSizes: [Int]
    var callbackBatchSizeOverflow: Int
    var rawCallbackIntervals: [Double]
    var rawCallbackIntervalOverflow: Int
    var beforeAuthorizationRawCount: Int
    var replacedCount: Int
    var sequenceGaps: Int
    var maximumRawReceiveInterval: Double
    var upperOrdinal: UInt64
}

private struct ControlEnvelope {
    let id: UInt64
    let centralID: UUID
    let message: RemoteMessage
    let stamp: TransportStamp
    /// Motion frozen before this control boundary. Motion after the boundary cannot replace it.
    let precedingMotion: MotionBatch?
}

private struct TransportPolicy {
    let modelGeneration: UInt64
    let receivingEnabled: Bool
    let authorizedCentralID: UUID?
    let pendingCentralID: UUID?
    let activeMotionSession: UInt64?
}

private struct ControlDecision {
    let result: CBATTError.Code
    let policy: TransportPolicy
    let statuses: [RemoteStatus]
}

@MainActor
private protocol MacBLETransportSink: AnyObject {
    func transportStateChanged(_ text: String)
    func transportSubscribed(_ centralID: UUID)
    func transportUnsubscribed(_ centralID: UUID, generation: UInt64)
    func transportReset(generation: UInt64, subscriptionsCleared: Bool)
    func transportExhausted()
    func transportDiagnosticEnded(_ snapshot: SerialDiagnosticSnapshot, reason: String)
    func transportConnectionIncident(_ snapshot: ConnectionIncidentSnapshot)
    func transportReceived(_ envelope: ControlEnvelope)
    func transportAccepted(_ batch: MotionBatch, acceptedMappingUptime: TimeInterval)
}

/// A lock-protected one-slot mailbox containing value types only. It never stores CoreBluetooth
/// or AppKit objects. Locks are released before dispatching or invoking model code.
private final class MotionMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var slot: MotionBatch?
    private var drainEnqueued = false
    private var blockedAtControlOrdinal: UInt64?

    @discardableResult func offer(_ batch: MotionBatch, enqueueDrain: @escaping () -> Void) -> Int {
        var enqueue = false
        var replaced = 0
        lock.lock()
        if var old = slot, old.generation == batch.generation, old.session == batch.session,
           batch.latestSequence > old.latestSequence {
            let interval = batch.latestRawReceiveUptime - old.latestRawReceiveUptime
            old.latestSequence = batch.latestSequence
            old.latestX = batch.latestX; old.latestY = batch.latestY
            old.latestRawReceiveUptime = batch.latestRawReceiveUptime
            old.rawPacketCount += batch.rawPacketCount
            old.rawCallbackCount += batch.rawCallbackCount
            old.callbackRequestTotal += batch.callbackRequestTotal
            for size in batch.callbackBatchSizes {
                if old.callbackBatchSizes.count < 64 { old.callbackBatchSizes.append(size) }
                else { old.callbackBatchSizeOverflow += 1 }
            }
            old.callbackBatchSizeOverflow += batch.callbackBatchSizeOverflow
            for interval in batch.rawCallbackIntervals {
                if old.rawCallbackIntervals.count < 64 { old.rawCallbackIntervals.append(interval) }
                else { old.rawCallbackIntervalOverflow += 1 }
            }
            old.rawCallbackIntervalOverflow += batch.rawCallbackIntervalOverflow
            old.beforeAuthorizationRawCount += batch.beforeAuthorizationRawCount
            old.replacedCount += batch.rawPacketCount
            replaced = batch.rawPacketCount
            old.sequenceGaps += batch.sequenceGaps
            if interval.isFinite, interval >= 0 { old.maximumRawReceiveInterval = max(old.maximumRawReceiveInterval, interval) }
            old.upperOrdinal = batch.upperOrdinal
            slot = old
        } else if slot == nil {
            slot = batch
        }
        if blockedAtControlOrdinal == nil, !drainEnqueued, slot != nil {
            drainEnqueued = true; enqueue = true
        }
        lock.unlock()
        if enqueue { enqueueDrain() }
        return replaced
    }

    func takeForDrain() -> MotionBatch? {
        lock.lock(); defer { lock.unlock() }
        guard blockedAtControlOrdinal == nil else { drainEnqueued = false; return nil }
        let value = slot; slot = nil; drainEnqueued = false
        return value
    }

    func beginBoundary(_ ordinal: UInt64, discard: Bool) -> MotionBatch? {
        lock.lock(); defer { lock.unlock() }
        blockedAtControlOrdinal = ordinal
        let value = discard ? nil : slot
        slot = nil
        return value
    }

    func endBoundary(_ ordinal: UInt64, enqueueDrain: @escaping () -> Void) {
        var enqueue = false
        lock.lock()
        if blockedAtControlOrdinal == ordinal { blockedAtControlOrdinal = nil }
        if blockedAtControlOrdinal == nil, !drainEnqueued, slot != nil { drainEnqueued = true; enqueue = true }
        lock.unlock()
        if enqueue { enqueueDrain() }
    }

    func discardAll() {
        lock.lock(); slot = nil; drainEnqueued = false; blockedAtControlOrdinal = nil; lock.unlock()
    }
}

/// Owns every CoreBluetooth peripheral object and call on one dedicated serial queue. Only immutable
/// protocol/value snapshots cross to the main actor; retained ATT requests never leave this object.
private final class MacBLETransport: NSObject, CBPeripheralManagerDelegate {
    private struct PendingStatus {
        let status: RemoteStatus
        let generation: UInt64
        let ordered: Bool
    }
    private let queue = DispatchQueue(label: "PointerRemote.MacBLETransport")
    private let serviceID = CBUUID(string: "C2F02001-67D2-4FD2-946C-4F0D34A2A101")
    private let controlID = CBUUID(string: "C2F02002-67D2-4FD2-946C-4F0D34A2A101")
    private let statusID = CBUUID(string: "C2F02003-67D2-4FD2-946C-4F0D34A2A101")
    private let motionID = CBUUID(string: "C2F02004-67D2-4FD2-946C-4F0D34A2A101")
    private let mailbox = MotionMailbox()
    private weak var sink: MacBLETransportSink?
    private var manager: CBPeripheralManager!
    private var service: CBMutableService?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var subscribed: [UUID: CBCentral] = [:]
    /// Quarantine is subscription-scoped. A duplicate subscribe callback does not clear it; only a
    /// real unsubscribe (or service/Bluetooth reset) admits that central again.
    private var quarantinedCentralIDs: Set<UUID> = []
    private struct PendingResponse {
        let request: CBATTRequest
        let boundaryOrdinal: UInt64
        let submittedAt: TimeInterval
    }
    private static let maximumOutstandingControls = 16
    private var pendingResponses: [UInt64: PendingResponse] = [:]
    private var outstandingControlCallbacks = 0
    private var diagnostic: SerialDiagnosticAccumulator?
    private var statusLanes: [UUID: [PendingStatus]] = [:]
    private var policy = TransportPolicy(modelGeneration: 0, receivingEnabled: true,
                                         authorizedCentralID: nil, pendingCentralID: nil,
                                         activeMotionSession: nil)
    private var transportGeneration: UInt64 = 1
    private var ordinal: UInt64 = 0
    private var responseID: UInt64 = 0
    private var published = false
    /// Once an ordering/generation counter is exhausted this transport instance never admits
    /// semantic work again, including policy updates queued before main observes the failure.
    private var exhausted = false
    private var lastAcceptedSequence: [UInt64: UInt32] = [:]
    private var lastRawCallbackUptime: TimeInterval?
    private var latestValidCandidateUptime: TimeInterval?
    private var incidentClearGeneration: UInt64 = 0
    private var beforeAuthorizationRawCount = 0

    init(sink: MacBLETransportSink) {
        self.sink = sink
        super.init()
        queue.async { [weak self] in
            guard let self else { return }
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    func setPolicy(_ value: TransportPolicy) {
        queue.async { [weak self] in guard let self, !self.exhausted else { return }; self.policy = value }
    }

    func setIncidentClearGeneration(_ generation: UInt64) {
        queue.async { [weak self] in self?.incidentClearGeneration = generation }
    }

    func requestConnectionIncident(eventID: UUID, clearGeneration: UInt64, trigger: String,
                                   triggeringUptime: TimeInterval, expectedGeneration: UInt64?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deliverConnectionIncident(eventID: eventID, clearGeneration: clearGeneration,
                                           trigger: trigger, triggeringUptime: triggeringUptime,
                                           expectedGeneration: expectedGeneration)
        }
    }
    func fence(generation: UInt64, policy value: TransportPolicy) {
        queue.async { [weak self] in
            guard let self, !self.exhausted, generation >= self.transportGeneration else { return }
            self.transportGeneration = generation; self.policy = value
            self.mailbox.discardAll(); self.lastAcceptedSequence.removeAll(); self.statusLanes.removeAll()
            self.lastRawCallbackUptime = nil; self.beforeAuthorizationRawCount = 0
            let requests = self.pendingResponses.values; self.pendingResponses.removeAll()
            for pending in requests { self.manager?.respond(to: pending.request, withResult: .insufficientAuthorization) }
        }
    }
    func enqueue(_ status: RemoteStatus, to centralID: UUID, generation: UInt64) {
        queue.async { [weak self] in
            guard let self, !self.exhausted else { return }
            self.queueStatus(status, to: centralID, generation: generation)
        }
    }

    /// Overflow is not Forget All. It revokes the live transport, pauses it through the policy
    /// supplied by main, and quarantines every current subscription until a true unsubscribe.
    func failClosedOverflow() {
        queue.async { [weak self] in
            guard let self, !self.exhausted else { return }
            self.quarantinedCentralIDs.formUnion(self.subscribed.keys)
            self.resetTransport(response: .insufficientAuthorization, incident: "main action queue overflow quarantined subscriptions")
            self.publishState("Too many pending receiver actions. Disconnect and reconnect every subscribed iPhone before continuing.")
        }
    }

    /// Counter exhaustion is sticky for this object and does not depend on finding a next epoch.
    func shutdownForGenerationExhaustion() {
        queue.async { [weak self] in self?.enterExhaustedState() }
    }

    func complete(id: UInt64, decision: ControlDecision) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.outstandingControlCallbacks > 0 { self.outstandingControlCallbacks -= 1 }
            guard let pending = self.pendingResponses.removeValue(forKey: id) else { return }
            guard !self.exhausted else {
                self.manager?.respond(to: pending.request, withResult: .insufficientAuthorization)
                return
            }
            self.policy = decision.policy
            self.manager.respond(to: pending.request, withResult: decision.result)
            if decision.result == .success {
                for status in decision.statuses {
                    self.queueStatus(status, to: pending.request.central.identifier,
                                     generation: decision.policy.modelGeneration)
                }
            }
            self.mailbox.endBoundary(pending.boundaryOrdinal) { [weak self] in self?.enqueueMainDrain() }
        }
    }

    func barrier(discard: Bool, completion: @escaping @MainActor (UInt64, MotionBatch?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.exhausted, self.ordinal < UInt64.max else {
                self.enterExhaustedState()
                DispatchQueue.main.async { completion(UInt64.max, nil) }
                return
            }
            self.ordinal += 1
            let token = self.ordinal
            let batch = self.mailbox.beginBoundary(token, discard: discard)
            DispatchQueue.main.async { completion(token, batch) }
        }
    }

    /// Starts at an authoritative serial-queue boundary after the predecessor mailbox is sealed.
    func startDiagnostic(captureID: UUID, discard: Bool,
                         completion: @escaping @MainActor (UInt64, MotionBatch?, TimeInterval) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.exhausted, self.ordinal < UInt64.max else {
                self.enterExhaustedState()
                let now = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { completion(UInt64.max, nil, now) }
                return
            }
            self.ordinal += 1
            let token = self.ordinal
            let batch = self.mailbox.beginBoundary(token, discard: discard)
            let start = ProcessInfo.processInfo.systemUptime
            self.diagnostic = SerialDiagnosticAccumulator(captureID: captureID, startedAt: start,
                                                          deadline: start + JitterDiagnosticCapture.duration)
            DispatchQueue.main.async { completion(token, batch, start) }
        }
    }

    /// Stop is itself the serial barrier: the accumulator is frozen at the same operation that seals
    /// predecessor motion, not after a round trip through main.
    func stopDiagnostic(discard: Bool,
                        completion: @escaping @MainActor (UInt64, MotionBatch?, SerialDiagnosticSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.exhausted, self.ordinal < UInt64.max else {
                self.enterExhaustedState()
                DispatchQueue.main.async { completion(UInt64.max, nil, nil) }
                return
            }
            self.ordinal += 1
            let token = self.ordinal
            let batch = self.mailbox.beginBoundary(token, discard: discard)
            let snapshot = self.freezeDiagnostic(at: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { completion(token, batch, snapshot) }
        }
    }

    func finishBarrier(_ token: UInt64, policy: TransportPolicy, statuses: [(RemoteStatus, UUID)]) {
        queue.async { [weak self] in
            guard let self, !self.exhausted else { return }
            self.policy = policy
            for item in statuses { self.queueStatus(item.0, to: item.1, generation: policy.modelGeneration) }
            self.mailbox.endBoundary(token) { [weak self] in self?.enqueueMainDrain() }
        }
    }

    func invalidate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetTransport(response: .unlikelyError, subscriptionsCleared: true, incident: "transport invalidated")
            self.manager?.stopAdvertising(); self.manager?.removeAllServices(); self.manager?.delegate = nil
            self.manager = nil
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        guard peripheral.state == .poweredOn else {
            // Freeze before clearing transport state. The value snapshot is immutable and capture-ID
            // correlated, so delayed delivery cannot overwrite a later run or fabricate an empty one.
            if let snapshot = freezeDiagnostic(at: ProcessInfo.processInfo.systemUptime) {
                DispatchQueue.main.async { [weak self] in
                    self?.sink?.transportDiagnosticEnded(snapshot, reason: "Bluetooth stopped")
                }
            }
            peripheral.stopAdvertising(); peripheral.removeAllServices(); published = false
            resetTransport(response: .insufficientAuthorization, subscriptionsCleared: true,
                           incident: "Bluetooth state changed to \(peripheral.state.rawValue); service and subscriptions cleared")
            service = nil; statusCharacteristic = nil; subscribed.removeAll(); quarantinedCentralIDs.removeAll()
            if exhausted {
                publishState("Bluetooth transport counter exhausted. Relaunch Pointer Remote; this transport instance is closed.")
            } else {
                publishReset("Turn on Bluetooth to receive connections.")
            }
            return
        }
        guard !exhausted else {
            peripheral.stopAdvertising()
            publishState("Bluetooth transport counter exhausted. Relaunch Pointer Remote; this transport instance is closed.")
            return
        }
        publishService()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd added: CBService, error: Error?) {
        guard peripheral === manager, !exhausted, peripheral.state == .poweredOn, added === service else { return }
        guard error == nil else {
            let now = ProcessInfo.processInfo.systemUptime
            deliverConnectionIncident(trigger: "Bluetooth service publication failed: \(boundedError(error))",
                                      triggeringUptime: now, expectedGeneration: transportGeneration)
            published = false; publishState("Could not publish the Bluetooth service."); return
        }
        let localName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var advertisement: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [serviceID]]
        if !localName.isEmpty { advertisement[CBAdvertisementDataLocalNameKey] = localName }
        peripheral.startAdvertising(advertisement); publishState("Starting Bluetooth advertising…")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager, !exhausted else { return }
        if let error {
            let now = ProcessInfo.processInfo.systemUptime
            deliverConnectionIncident(trigger: "Bluetooth advertising failed: \(boundedError(error))",
                                      triggeringUptime: now, expectedGeneration: transportGeneration)
        }
        publishState(error == nil ? "Waiting for an iPhone connection." : "Bluetooth advertising failed.")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == statusID else { return }
        let id = central.identifier
        subscribed[id] = central
        peripheral.setDesiredConnectionLatency(.low, for: central)
        if exhausted {
            quarantinedCentralIDs.insert(id)
            publishState("This transport instance is closed. Relaunch Pointer Remote before reconnecting.")
            return
        }
        guard !quarantinedCentralIDs.contains(id) else {
            publishState("This iPhone subscription is quarantined. Disconnect it in iPhone Settings, then reconnect.")
            return
        }
        DispatchQueue.main.async { [weak self] in self?.sink?.transportSubscribed(id) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, characteristic.uuid == statusID else { return }
        let id = central.identifier
        let affectedAuthorization = id == policy.authorizedCentralID || id == policy.pendingCentralID
        if affectedAuthorization {
            resetTransport(response: .insufficientAuthorization, incident: "authorized or pending iPhone unsubscribed")
        }
        subscribed.removeValue(forKey: id); statusLanes.removeValue(forKey: id)
        quarantinedCentralIDs.remove(id)
        let generation = transportGeneration
        DispatchQueue.main.async { [weak self] in self?.sink?.transportUnsubscribed(id, generation: generation) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        for id in Array(statusLanes.keys) { drainStatusLane(id) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager else { return }
        guard !exhausted else {
            for request in requests where request.characteristic.uuid == controlID {
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var accepted = 0, rejected = 0, replaced = 0, gapsTotal = 0
        var recordedAcceptedCallback = false
        for request in requests {
            guard ordinal < UInt64.max else {
                enterExhaustedState()
                if request.characteristic.uuid == controlID { peripheral.respond(to: request, withResult: .unlikelyError) }
                continue
            }
            ordinal += 1
            let centralID = request.central.identifier
            if request.characteristic.uuid == motionID {
                guard let data = request.value, let packet = MotionPacket.decode(data),
                      subscribed[centralID] != nil else { continue }
                guard !quarantinedCentralIDs.contains(centralID),
                      policy.authorizedCentralID == centralID,
                      policy.activeMotionSession == packet.session else {
                    beforeAuthorizationRawCount += 1; rejected += 1
                    continue
                }
                guard lastAcceptedSequence[packet.session].map({ packet.sequence > $0 }) ?? true else {
                    rejected += 1; continue
                }
                let previous = lastAcceptedSequence[packet.session]
                lastAcceptedSequence[packet.session] = packet.sequence
                let gaps = previous.map { Int(packet.sequence - $0 - 1) } ?? 0
                let callbackInterval = recordedAcceptedCallback ? 0 : (lastRawCallbackUptime.map { now - $0 } ?? 0)
                let batch = MotionBatch(generation: transportGeneration, session: packet.session,
                                        firstSequence: packet.sequence, latestSequence: packet.sequence,
                                        latestX: packet.x, latestY: packet.y,
                                        firstRawReceiveUptime: now, latestRawReceiveUptime: now,
                                        rawPacketCount: 1, rawCallbackCount: recordedAcceptedCallback ? 0 : 1,
                                        callbackRequestTotal: recordedAcceptedCallback ? 0 : requests.count,
                                        callbackBatchSizes: recordedAcceptedCallback ? [] : [requests.count],
                                        callbackBatchSizeOverflow: 0,
                                        rawCallbackIntervals: recordedAcceptedCallback || callbackInterval <= 0 ? [] : [callbackInterval],
                                        rawCallbackIntervalOverflow: 0,
                                        beforeAuthorizationRawCount: beforeAuthorizationRawCount,
                                        replacedCount: 0, sequenceGaps: gaps,
                                        maximumRawReceiveInterval: callbackInterval, upperOrdinal: ordinal)
                beforeAuthorizationRawCount = 0
                let replacement = mailbox.offer(batch) { [weak self] in self?.enqueueMainDrain() }
                latestValidCandidateUptime = now
                accepted += 1; replaced += replacement; gapsTotal += gaps; recordedAcceptedCallback = true
                continue
            }
            guard request.characteristic.uuid == controlID, let data = request.value,
                  let message = Wire.decode(data) else {
                peripheral.respond(to: request, withResult: .invalidPdu); continue
            }
            guard subscribed[centralID] != nil, !quarantinedCentralIDs.contains(centralID) else {
                peripheral.respond(to: request, withResult: .insufficientAuthorization); continue
            }
            // Admission precedes request retention, mailbox sealing, and main-closure submission.
            guard outstandingControlCallbacks < Self.maximumOutstandingControls,
                  responseID < UInt64.max else {
                quarantine(centralID, reason: "Control backpressure exceeded its bounded lane. On iPhone, disconnect and reconnect to continue.")
                peripheral.respond(to: request, withResult: .unlikelyError)
                continue
            }
            responseID += 1
            let id = responseID
            outstandingControlCallbacks += 1
            pendingResponses[id] = PendingResponse(request: request, boundaryOrdinal: ordinal, submittedAt: now)
            let preceding = mailbox.beginBoundary(ordinal, discard: false)
            let envelope = ControlEnvelope(id: id, centralID: centralID, message: message,
                                           stamp: TransportStamp(generation: transportGeneration, ordinal: ordinal,
                                                                 rawReceiveUptime: now),
                                           precedingMotion: preceding)
            DispatchQueue.main.async { [weak self] in
                guard let self, let sink = self.sink else { return }
                sink.transportReceived(envelope)
            }
        }
        if accepted > 0 { lastRawCallbackUptime = now }
        diagnostic?.recordCallback(at: now, requestCount: requests.count, accepted: accepted,
                                   rejected: rejected, replaced: replaced, gaps: gapsTotal)
    }

    private func quarantine(_ centralID: UUID, reason: String) {
        guard quarantinedCentralIDs.insert(centralID).inserted else { return }
        statusLanes[centralID] = []
        // Always advance the transport epoch: an unapproved peer may already have hello closures
        // queued on main even though serial policy has not yet learned that it is pending.
        resetTransport(response: .insufficientAuthorization, incident: "subscription quarantined: \(reason)")
        publishState(reason)
    }

    private func enqueueMainDrain() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let batch = self.mailbox.takeForDrain() else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.sink?.transportAccepted(batch, acceptedMappingUptime: now)
            // A packet racing this bounded drain posts one replacement token; there is no main FIFO per packet.
            self.mailbox.endBoundary(UInt64.max) { [weak self] in self?.enqueueMainDrain() }
        }
    }

    private func publishService() {
        guard !exhausted, !published else { return }; published = true
        let control = CBMutableCharacteristic(type: controlID, properties: [.write], value: nil,
                                              permissions: [.writeEncryptionRequired])
        let status = CBMutableCharacteristic(type: statusID, properties: [.notify, .notifyEncryptionRequired],
                                             value: nil, permissions: [.readEncryptionRequired])
        let motion = CBMutableCharacteristic(type: motionID, properties: [.writeWithoutResponse], value: nil,
                                             permissions: [.writeEncryptionRequired])
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [control, status, motion]
        self.service = service; statusCharacteristic = status
        manager.add(service); publishState("Publishing Bluetooth service…")
    }

    private func isOrdered(_ status: RemoteStatus) -> Bool {
        switch status {
        case .recentered, .calibrationReady, .calibrationResult, .calibrationApplied,
             .calibrationCancelled, .calibrationFailed, .stopped, .rejected, .heartbeatTimedOut,
             .presetCatalogPage, .presetSelected, .presetSaved, .presetDeleted,
             .presetConflict, .presetRejected: return true
        default: return false
        }
    }

    private func queueStatus(_ status: RemoteStatus, to centralID: UUID, generation: UInt64) {
        guard generation == policy.modelGeneration, subscribed[centralID] != nil else { return }
        var lane = statusLanes[centralID] ?? []
        let entry = PendingStatus(status: status, generation: generation, ordered: isOrdered(status))
        if !entry.ordered, let index = lane.lastIndex(where: { !$0.ordered }) { lane[index] = entry }
        else { lane.append(entry) }
        guard lane.count <= 16 else {
            quarantine(centralID, reason: "Bluetooth status backpressure exceeded its bounded lane. On iPhone, disconnect and reconnect to continue.")
            return
        }
        statusLanes[centralID] = lane; drainStatusLane(centralID)
    }

    private func drainStatusLane(_ centralID: UUID) {
        guard let central = subscribed[centralID], let characteristic = statusCharacteristic else { return }
        while var lane = statusLanes[centralID], let first = lane.first {
            guard first.generation == policy.modelGeneration else { lane.removeFirst(); statusLanes[centralID] = lane; continue }
            guard let data = Wire.encode(first.status), data.count <= Wire.maximumBytes else { lane.removeFirst(); statusLanes[centralID] = lane; continue }
            guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) else { return }
            lane.removeFirst(); statusLanes[centralID] = lane
        }
    }

    private func freezeDiagnostic(at cutoff: TimeInterval) -> SerialDiagnosticSnapshot? {
        let snapshot = diagnostic?.snapshot(endedAt: cutoff)
        diagnostic = nil
        return snapshot
    }

    private func enterExhaustedState() {
        guard !exhausted else { return }
        exhausted = true
        quarantinedCentralIDs.formUnion(subscribed.keys)
        policy = TransportPolicy(modelGeneration: policy.modelGeneration, receivingEnabled: false,
                                 authorizedCentralID: nil, pendingCentralID: nil,
                                 activeMotionSession: nil)
        mailbox.discardAll(); lastAcceptedSequence.removeAll(); statusLanes.removeAll()
        lastRawCallbackUptime = nil; beforeAuthorizationRawCount = 0
        if let snapshot = freezeDiagnostic(at: ProcessInfo.processInfo.systemUptime) {
            DispatchQueue.main.async { [weak self] in
                self?.sink?.transportDiagnosticEnded(snapshot, reason: "transport ordering was exhausted")
            }
        }
        let requests = pendingResponses.values; pendingResponses.removeAll()
        for pending in requests { manager?.respond(to: pending.request, withResult: .insufficientAuthorization) }
        manager?.stopAdvertising()
        DispatchQueue.main.async { [weak self] in self?.sink?.transportExhausted() }
        publishState("Bluetooth transport counter exhausted. Relaunch Pointer Remote; this transport instance is closed.")
    }

    private func boundedError(_ error: Error?) -> String {
        guard let error else { return "no OS error supplied" }
        let ns = error as NSError
        let domain = String(ns.domain.replacingOccurrences(of: "\n", with: " ").prefix(80))
        let description = String(ns.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(180))
        return "\(domain) code \(ns.code): \(description)"
    }

    private func deliverConnectionIncident(eventID: UUID = UUID(), clearGeneration: UInt64? = nil,
                                           trigger: String, triggeringUptime: TimeInterval,
                                           expectedGeneration: UInt64?) {
        let observed = ProcessInfo.processInfo.systemUptime
        let oldestAge = pendingResponses.values.map { max(0, observed - $0.submittedAt) }.max()
        let snapshot = ConnectionIncidentSnapshot(
            eventID: eventID, clearGeneration: clearGeneration ?? incidentClearGeneration,
            trigger: String(trigger.prefix(240)), triggeringUptime: triggeringUptime,
            observationUptime: observed, expectedGeneration: expectedGeneration,
            observedGeneration: transportGeneration,
            latestValidCandidateUptime: latestValidCandidateUptime,
            outstandingControlCount: outstandingControlCallbacks,
            oldestControlAge: oldestAge,
            pendingStatusCount: statusLanes.values.reduce(0) { $0 + $1.count },
            subscribedCount: subscribed.count)
        DispatchQueue.main.async { [weak self] in self?.sink?.transportConnectionIncident(snapshot) }
    }

    private func resetTransport(response: CBATTError.Code, subscriptionsCleared: Bool = false,
                                incident: String) {
        guard !exhausted else { return }
        let triggerTime = ProcessInfo.processInfo.systemUptime
        // Capture serial-owned counts before reset clears them. Delivery is asynchronous and cannot
        // mutate transport state or resurrect the connection.
        deliverConnectionIncident(trigger: incident, triggeringUptime: triggerTime,
                                  expectedGeneration: transportGeneration)
        guard transportGeneration < UInt64.max else { enterExhaustedState(); return }
        transportGeneration += 1; mailbox.discardAll(); lastAcceptedSequence.removeAll(); statusLanes.removeAll()
        lastRawCallbackUptime = nil; latestValidCandidateUptime = nil; beforeAuthorizationRawCount = 0
        let requests = pendingResponses.values; pendingResponses.removeAll()
        for pending in requests { manager?.respond(to: pending.request, withResult: response) }
        let generation = transportGeneration
        DispatchQueue.main.async { [weak self] in
            self?.sink?.transportReset(generation: generation, subscriptionsCleared: subscriptionsCleared)
        }
    }
    private func publishState(_ text: String) { DispatchQueue.main.async { [weak self] in self?.sink?.transportStateChanged(text) } }
    private func publishReset(_ text: String) { publishState(text) }
}

private struct PresetAppearanceSnapshot: Codable, Equatable {
    let shape: PointerOverlay.Shape
    let red: Double
    let green: Double
    let blue: Double
    let size: Int
    let adaptiveSmoothing: Bool
    let mode: EffectMode
    let lifetime: Double
    let fade: Double
    let scaleDown: Double
    let ropeLength: Double
    let ropeNodes: Int
    let ropeThickness: Double
    let ropeStrands: Int
    let ropeGravity: Double
    let ropeTurbulence: Double
    let gaming: Bool
    let rainbowCycle: Double

    init(shape: PointerOverlay.Shape, red: Double, green: Double, blue: Double, size: Int,
         adaptiveSmoothing: Bool, effects: PointerEffectsConfiguration) {
        self.shape = shape; self.red = red; self.green = green; self.blue = blue; self.size = size
        self.adaptiveSmoothing = adaptiveSmoothing; mode = effects.mode; lifetime = effects.lifetime
        fade = effects.fade; scaleDown = effects.scaleDown; ropeLength = effects.ropeLength
        ropeNodes = effects.ropeNodes; ropeThickness = effects.ropeThickness
        ropeStrands = effects.ropeStrands; ropeGravity = effects.ropeGravity
        ropeTurbulence = effects.ropeTurbulence
        gaming = effects.gaming; rainbowCycle = effects.rainbowCycle
    }

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey {
            case shape, red, green, blue, size, adaptiveSmoothing, mode, lifetime, fade, scaleDown
            case ropeLength, ropeNodes, ropeThickness, ropeStrands, ropeGravity, ropeTurbulence, gaming, rainbowCycle
        }
        let c = try decoder.container(keyedBy: Keys.self)
        shape = try c.decode(PointerOverlay.Shape.self, forKey: .shape)
        red = try c.decode(Double.self, forKey: .red); green = try c.decode(Double.self, forKey: .green)
        blue = try c.decode(Double.self, forKey: .blue); size = try c.decode(Int.self, forKey: .size)
        adaptiveSmoothing = try c.decode(Bool.self, forKey: .adaptiveSmoothing)
        mode = try c.decode(EffectMode.self, forKey: .mode)
        lifetime = try c.decode(Double.self, forKey: .lifetime); fade = try c.decode(Double.self, forKey: .fade)
        scaleDown = try c.decode(Double.self, forKey: .scaleDown); ropeLength = try c.decode(Double.self, forKey: .ropeLength)
        ropeNodes = try c.decode(Int.self, forKey: .ropeNodes); ropeThickness = try c.decode(Double.self, forKey: .ropeThickness)
        ropeStrands = try c.decode(Int.self, forKey: .ropeStrands); ropeGravity = try c.decode(Double.self, forKey: .ropeGravity)
        // Missing is the pre-turbulence preset schema and intentionally migrates to off; a present
        // malformed value still throws so that one bad preset is skipped without dropping others.
        ropeTurbulence = try c.decodeIfPresent(Double.self, forKey: .ropeTurbulence) ?? 0
        gaming = try c.decode(Bool.self, forKey: .gaming); rainbowCycle = try c.decode(Double.self, forKey: .rainbowCycle)
        let finite = [red, green, blue, lifetime, fade, scaleDown, ropeLength, ropeThickness, ropeGravity, ropeTurbulence, rainbowCycle]
        guard finite.allSatisfy(\.isFinite), [red, green, blue].allSatisfy({ (0...1).contains($0) }),
              (16...160).contains(size), (0.1...5).contains(lifetime), (0...lifetime).contains(fade),
              (0...lifetime).contains(scaleDown), (20...600).contains(ropeLength), (1...24).contains(ropeThickness),
              (PointerEffectsConfiguration.minimumRopeStrands...PointerEffectsConfiguration.maximumRopeStrands).contains(ropeStrands),
              (PointerEffectsConfiguration.minimumRopeNodes...PointerEffectsConfiguration.maximumRopeNodes(forStrands: ropeStrands)).contains(ropeNodes),
              (0...2000).contains(ropeGravity), (0...1).contains(ropeTurbulence), (0.2...20).contains(rainbowCycle) else {
            throw DecodingError.dataCorruptedError(forKey: .mode, in: c, debugDescription: "Invalid preset appearance snapshot.")
        }
    }

    var effects: PointerEffectsConfiguration {
        PointerEffectsConfiguration(mode: mode, lifetime: lifetime, fade: fade, scaleDown: scaleDown,
                                    ropeLength: ropeLength, ropeNodes: ropeNodes, ropeThickness: ropeThickness,
                                    ropeStrands: ropeStrands, ropeGravity: ropeGravity, ropeTurbulence: ropeTurbulence, gaming: gaming,
                                    rainbowCycle: rainbowCycle)
    }
}

private struct StoredAppearancePreset: Codable, Equatable, Identifiable {
    let slot: PresetSlot
    var name: PresetName
    var appearance: PresetAppearanceSnapshot
    var id: PresetSlot { slot }
}

private struct LossyStoredPreset: Codable {
    let value: StoredAppearancePreset?
    init(value: StoredAppearancePreset?) { self.value = value }
    init(from decoder: Decoder) throws { value = try? StoredAppearancePreset(from: decoder) }
    func encode(to encoder: Encoder) throws {
        guard let value else { var c = encoder.singleValueContainer(); try c.encodeNil(); return }
        try value.encode(to: encoder)
    }
}

private struct StoredPresetDocument: Codable {
    let schemaVersion: Int
    let revision: UInt64
    let selectedSlot: PresetSlot?
    let entries: [LossyStoredPreset]
}

@main
struct MacReceiverApp: App {
    @StateObject private var receiver = MacReceiverModel()

    var body: some Scene {
        WindowGroup {
            MacReceiverView().environmentObject(receiver)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class MacReceiverModel: NSObject, ObservableObject, MacBLETransportSink {
    @Published var status = "Preparing Bluetooth…"
    @Published var accessibility = AXIsProcessTrusted()
    @Published var pointerEnabled = false
    @Published private var sensitivityPair: (x: Double, y: Double)
    var sensitivityX: Double { sensitivityPair.x }
    var sensitivityY: Double { sensitivityPair.y }
    @Published private(set) var calibrationSummary: String?
    @Published fileprivate var pointerShape: PointerOverlay.Shape = PointerOverlay.savedShape {
        didSet {
            guard oldValue != pointerShape, !applyingPresetAppearance else { return }
            PointerOverlay.save(pointerShape); overlay.shape = pointerShape
            appearanceWasEdited()
        }
    }
    @Published private var storedPointerColor: Color = PointerOverlay.savedColor
    fileprivate var pointerColor: Color { storedPointerColor }
    @Published private var storedPointerSize: Double = PointerOverlay.savedSize
    fileprivate var pointerSize: Double { storedPointerSize }
    @Published private var storedEffectsConfiguration = PointerEffectsConfiguration()
    fileprivate var effectsConfiguration: PointerEffectsConfiguration { storedEffectsConfiguration }
    @Published fileprivate var adaptiveSmoothingEnabled: Bool {
        didSet {
            guard oldValue != adaptiveSmoothingEnabled, !applyingPresetAppearance else { return }
            UserDefaults.standard.set(adaptiveSmoothingEnabled, forKey: Self.adaptiveSmoothingKey)
            overlay.setAdaptiveSmoothingEnabled(adaptiveSmoothingEnabled)
            appearanceWasEdited()
        }
    }
    @Published private(set) var selectedPresetSlot: PresetSlot?
    @Published private(set) var presetRevision: UInt64 = 1
    private var appearancePresets: [PresetSlot: StoredAppearancePreset] = [:]
    private var applyingPresetAppearance = false
    @Published var pendingApprovalName: String?
    @Published var rememberPendingPhone = false
    @Published var approved = false
    @Published private(set) var receivingEnabled = true
    @Published private(set) var transportActionPending = false
    @Published private(set) var trustedPhoneIDs: [UUID] = []
    @Published private(set) var receivedValidMotionPerSecond = 0
    @Published private(set) var jitterDiagnosticsActive = false
    @Published private(set) var jitterDiagnosticsStatus = "Start a 20-second capture while continuous tracking is available."
    @Published private(set) var jitterDiagnosticsReport: String?
    @Published private(set) var connectionDiagnostics: [String] = []

    private static let trustedPhoneIDsKey = "trustedPhoneCentralIDs"
    private static let connectionDiagnosticsKey = "macConnectionDiagnostics.v1"
    private static let legacySensitivityKey = "macPointerSensitivity"

    private static func normalizedConnectionDiagnostics(_ entries: [String]) -> [String] {
        entries.suffix(16).map { String($0.prefix(2_048)) }
    }
    private static let sensitivityXKey = "macPointerSensitivityX"
    private static let sensitivityYKey = "macPointerSensitivityY"
    private static let sensitivityPairKey = "macPointerSensitivityPair"
    private static let adaptiveSmoothingKey = "macPointerAdaptiveSmoothingEnabled"
    private static let effectsKey = "macPointerEffects.v1"
    private static let appearancePresetsKey = "macPointerAppearancePresets.v1"
    private static func loadEffects() -> PointerEffectsConfiguration {
        let defaults = UserDefaults.standard
        var configuration = PointerEffectsConfiguration()
        configuration.mode = EffectMode(rawValue: defaults.string(forKey: effectsKey + ".mode") ?? "") ?? .off
        func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard let value = defaults.object(forKey: effectsKey + "." + key) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return fallback }
            let candidate = value.doubleValue
            guard candidate.isFinite else { return fallback }
            return min(max(candidate, range.lowerBound), range.upperBound)
        }
        func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
            let bounded = number(key, fallback: Double(fallback),
                                 range: Double(range.lowerBound)...Double(range.upperBound))
            return Int(bounded.rounded()) // Bounded before conversion; corrupt finite values cannot trap.
        }
        func boolean(_ key: String, fallback: Bool) -> Bool {
            guard let value = defaults.object(forKey: effectsKey + "." + key) as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return fallback }
            return value.boolValue
        }
        configuration.lifetime = number("lifetime", fallback: configuration.lifetime, range: 0.1...5)
        configuration.fade = number("fade", fallback: min(configuration.fade, configuration.lifetime), range: 0...configuration.lifetime)
        configuration.scaleDown = number("scale", fallback: min(configuration.scaleDown, configuration.lifetime), range: 0...configuration.lifetime)
        configuration.ropeLength = number("length", fallback: configuration.ropeLength, range: 20...600)
        configuration.ropeNodes = integer("nodes", fallback: configuration.ropeNodes,
                                          range: PointerEffectsConfiguration.minimumRopeNodes...PointerEffectsConfiguration.maximumRopeNodesPerStrand)
        configuration.ropeThickness = number("thickness", fallback: configuration.ropeThickness, range: 1...24)
        configuration.ropeStrands = integer("strands", fallback: configuration.ropeStrands,
                                            range: PointerEffectsConfiguration.minimumRopeStrands...PointerEffectsConfiguration.maximumRopeStrands)
        configuration.ropeGravity = number("gravity", fallback: configuration.ropeGravity, range: 0...2000)
        configuration.ropeTurbulence = number("turbulence", fallback: configuration.ropeTurbulence, range: 0...1)
        configuration.gaming = boolean("gaming", fallback: false)
        configuration.rainbowCycle = number("cycle", fallback: configuration.rainbowCycle, range: 0.2...20)
        return .validated(configuration)
    }
    private static func saveEffects(_ c: PointerEffectsConfiguration) { let d=UserDefaults.standard; d.set(c.mode.rawValue,forKey:effectsKey+".mode"); d.set(c.lifetime,forKey:effectsKey+".lifetime"); d.set(c.fade,forKey:effectsKey+".fade"); d.set(c.scaleDown,forKey:effectsKey+".scale"); d.set(c.ropeLength,forKey:effectsKey+".length"); d.set(c.ropeNodes,forKey:effectsKey+".nodes"); d.set(c.ropeThickness,forKey:effectsKey+".thickness"); d.set(c.ropeStrands,forKey:effectsKey+".strands"); d.set(c.ropeGravity,forKey:effectsKey+".gravity"); d.set(c.ropeTurbulence,forKey:effectsKey+".turbulence"); d.set(c.gaming,forKey:effectsKey+".gaming"); d.set(c.rainbowCycle,forKey:effectsKey+".cycle") }
    private var transport: MacBLETransport!
    private var subscribedCentralIDs: Set<UUID> = []
    private var transportGeneration: UInt64 = 1
    private var transportInstanceExhausted = false
    private var authorizedCentralID: UUID?
    private var pendingCentralID: UUID?
    private var authorizationGeneration: UInt64 = 0
    private var pendingApprovalGeneration: UInt64?
    private var lastHeartbeatUptime: TimeInterval?
    /// Non-nil only while one ordered control is executing. notify() appends here so the serial
    /// transport applies its gate, responds exactly once, then emits statuses in declaration order.
    private var completingControlStatuses: [(RemoteStatus, UUID)]?
    private enum BarrierIntent {
        case approve, reject, stopReceiving, forget(UUID), forgetAll
        case sensitivityX(Double), sensitivityY(Double)
        case startDiagnostics, stopDiagnostics(String)
        case displayTopologyChanged, failClosedOverflow

        var discardPredecessor: Bool {
            switch self {
            case .approve, .reject, .stopReceiving, .forget, .forgetAll, .failClosedOverflow: return true
            default: return false
            }
        }
    }
    private static let maximumPendingBarrierIntents = 32
    private var mainBarrierPending = false
    private var pendingBarrierIntents: [BarrierIntent] = []
    private var heartbeatTimer: Timer?
    private var activePointerSession: UInt64?
    private var lastPointerSession: UInt64?
    private var lastRecenterEpoch: UInt64?
    private var lastMotionSequence: UInt32?
    private var validMotionInRateWindow = 0
    private var rateWindowStarted = ProcessInfo.processInfo.systemUptime
    private var pointerAnchor = CGPoint.zero
    private var pointerDisplayBounds = CGRect.zero
    // Cumulative packets are differenced only against the last accepted packet, then applied to
    // an unbounded logical target. Off-display travel remains real and must be reversed to reenter.
    private var previousAcceptedCumulative = CGSize.zero
    private var effectivePointerTarget = CGPoint.zero
    /// Logical targets survive release independently for each display; overlays remain hidden while idle.
    private var retainedTargetsByDisplay: [CGDirectDisplayID: CGPoint] = [:]
    private var lastPointedDisplayID: CGDirectDisplayID?
    private var trackingStartedAt: TimeInterval?
    private var lastAcceptedMotionReceiveTime: TimeInterval?
    private var lastMainMappingExecutionUptime: TimeInterval?
    private var incidentClearGeneration: UInt64 = 0
    private var pendingIncidentMainContext: [UUID: String] = [:]
    private let trackingStartupGrace: TimeInterval = 5
    private let trackingPacketTimeout: TimeInterval = 5
    private var heldSensitivityX: Double?
    private var heldSensitivityY: Double?
    private var overlayShown = false
    private var holdAcceptedPackets = 0
    private var holdSequenceGaps = 0
    private var holdMaxReceiveGap = 0.0
    private let overlay = PointerOverlay()
    private let calibrationOverlay = CalibrationMarkerOverlay()
    private struct CalibrationRun {
        let session: UInt64
        let displayID: CGDirectDisplayID
        let displayBounds: CGRect
        let targets: [CGPoint]
        var expectedStep: CalibrationStep
        var captures: [CalibrationStep: CGPoint]
        var proposal: (x: Double, y: Double)?
    }
    private var calibrationRun: CalibrationRun?
    private var lastCalibrationSession: UInt64?
    private var terminalCalibrationStatus: RemoteStatus?
    private enum PresetMutationSignature: Equatable {
        case select(PresetSlot)
        case save(PresetSlot, PresetName, Bool)
        case delete(PresetSlot)
    }
    private struct CompletedPresetMutation {
        let signature: PresetMutationSignature
        let result: RemoteStatus
    }
    // This authorization-session cache has one shared, bounded history across all mutation kinds.
    private var completedPresetMutations: [UInt64: CompletedPresetMutation] = [:]
    private var completedPresetMutationOrder: [UInt64] = []
    // Prevent an evicted, delayed request ID from being treated as a new mutation.
    private var highestCompletedPresetMutationRequestID: UInt64?
    private var presetInvalidationWorkItem: DispatchWorkItem?
    private var screenChangeObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var jitterCapture: JitterDiagnosticCapture?
    private var jitterLastPublishedSecond: Int?
    private var jitterFinalizationPending = false
    private var jitterDiagnosticsStartPending = false

    var smoothingControlDisabled: Bool {
        jitterDiagnosticsActive || jitterDiagnosticsStartPending || jitterFinalizationPending
    }

    var effectsControlDisabled: Bool { smoothingControlDisabled }
    var presetControlsDisabled: Bool { calibrationRun != nil || effectsControlDisabled }

    func presetName(for slot: PresetSlot) -> String? { appearancePresets[slot]?.name.value }
    func presetIsOccupied(_ slot: PresetSlot) -> Bool { appearancePresets[slot] != nil }

    func setPointerColor(_ proposed: Color) {
        let normalized = PointerOverlay.opaque(proposed)
        guard !PointerOverlay.colorsEqual(normalized, storedPointerColor) else { return }
        storedPointerColor = normalized
        PointerOverlay.save(normalized)
        overlay.color = normalized
        appearanceWasEdited()
    }

    func setPointerSize(_ proposed: Double) {
        let normalized = PointerOverlay.validatedSize(proposed.rounded())
        guard normalized != storedPointerSize else { return }
        storedPointerSize = normalized
        PointerOverlay.saveSize(normalized)
        overlay.size = normalized
        appearanceWasEdited()
    }

    @discardableResult
    fileprivate func setEffectsConfiguration(_ proposed: PointerEffectsConfiguration) -> Bool {
        // Recheck at application time: a diagnostics capture may have started while the sheet was open.
        guard !effectsControlDisabled else { return false }
        let normalized = PointerEffectsConfiguration.validated(proposed)
        guard normalized != storedEffectsConfiguration else { return true }
        storedEffectsConfiguration = normalized // The sole publication for one complete settings commit.
        Self.saveEffects(normalized)
        overlay.setEffectsConfiguration(normalized)
        appearanceWasEdited()
        return true
    }

    private static func loadPresetDocument() -> (entries: [PresetSlot: StoredAppearancePreset], revision: UInt64, selected: PresetSlot?) {
        guard let data = UserDefaults.standard.data(forKey: appearancePresetsKey),
              let document = try? JSONDecoder().decode(StoredPresetDocument.self, from: data),
              document.schemaVersion == 1, document.revision != 0 else { return ([:], 1, nil) }
        var entries: [PresetSlot: StoredAppearancePreset] = [:]
        for wrapper in document.entries {
            guard let entry = wrapper.value, entries[entry.slot] == nil else { continue }
            entries[entry.slot] = entry
        }
        let selected = document.selectedSlot.flatMap { entries[$0] == nil ? nil : $0 }
        return (entries, document.revision, selected)
    }

    private func currentAppearanceSnapshot() -> PresetAppearanceSnapshot {
        let color = NSColor(PointerOverlay.opaque(storedPointerColor)).usingColorSpace(.sRGB)
        return PresetAppearanceSnapshot(shape: pointerShape,
                                        red: Double(color?.redComponent ?? 0),
                                        green: Double(color?.greenComponent ?? 1),
                                        blue: Double(color?.blueComponent ?? 1),
                                        size: Int(PointerOverlay.validatedSize(storedPointerSize).rounded()),
                                        adaptiveSmoothing: adaptiveSmoothingEnabled,
                                        effects: PointerEffectsConfiguration.validated(storedEffectsConfiguration))
    }

    private func persistPresetDocument() {
        let entries = PresetSlot.allCases.compactMap { appearancePresets[$0] }.map { LossyStoredPreset(value: $0) }
        let document = StoredPresetDocument(schemaVersion: 1, revision: presetRevision,
                                            selectedSlot: selectedPresetSlot, entries: entries)
        if let data = try? JSONEncoder().encode(document) {
            UserDefaults.standard.set(data, forKey: Self.appearancePresetsKey)
        }
    }

    private func advancePresetRevision() -> Bool {
        guard presetRevision < UInt64.max else { return false }
        presetRevision += 1
        return true
    }

    private func publishPresetInvalidation() {
        presetInvalidationWorkItem?.cancel()
        let generation = authorizationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.authorizationGeneration == generation, let id = self.authorizedCentralID else { return }
            self.notify(.presetInvalidated(revision: self.presetRevision,
                                           selectedSlot: self.selectedPresetSlot), to: id)
            self.presetInvalidationWorkItem = nil
        }
        presetInvalidationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func appearanceWasEdited() {
        let snapshot = currentAppearanceSnapshot()
        if let selectedPresetSlot, appearancePresets[selectedPresetSlot]?.appearance == snapshot {
            self.selectedPresetSlot = selectedPresetSlot
        } else {
            selectedPresetSlot = PresetSlot.allCases.first { appearancePresets[$0]?.appearance == snapshot }
        }
        _ = advancePresetRevision()
        persistPresetDocument()
        publishPresetInvalidation()
    }

    @discardableResult
    private func applyPresetAppearance(_ snapshot: PresetAppearanceSnapshot, selecting slot: PresetSlot,
                                       announce: Bool = true) -> Bool {
        guard !presetControlsDisabled, advancePresetRevision() else { return false }
        applyingPresetAppearance = true
        pointerShape = snapshot.shape
        storedPointerColor = Color(.sRGB, red: snapshot.red, green: snapshot.green, blue: snapshot.blue, opacity: 1)
        storedPointerSize = Double(snapshot.size)
        adaptiveSmoothingEnabled = snapshot.adaptiveSmoothing
        storedEffectsConfiguration = snapshot.effects
        applyingPresetAppearance = false
        PointerOverlay.save(pointerShape); PointerOverlay.save(storedPointerColor); PointerOverlay.saveSize(storedPointerSize)
        UserDefaults.standard.set(adaptiveSmoothingEnabled, forKey: Self.adaptiveSmoothingKey)
        Self.saveEffects(storedEffectsConfiguration)
        overlay.shape = pointerShape; overlay.color = storedPointerColor; overlay.size = storedPointerSize
        overlay.setAdaptiveSmoothingEnabled(adaptiveSmoothingEnabled)
        overlay.setEffectsConfiguration(storedEffectsConfiguration)
        selectedPresetSlot = slot
        persistPresetDocument()
        if announce { publishPresetInvalidation() }
        return true
    }

    @discardableResult
    func applyPreset(_ slot: PresetSlot) -> Bool {
        guard let entry = appearancePresets[slot] else { return false }
        return applyPresetAppearance(entry.appearance, selecting: slot)
    }

    @discardableResult
    func saveCurrentPreset(_ slot: PresetSlot, rawName: String, overwrite: Bool) -> Bool {
        guard !presetControlsDisabled, let name = PresetName(rawName),
              (appearancePresets[slot] == nil || overwrite), advancePresetRevision() else { return false }
        appearancePresets[slot] = StoredAppearancePreset(slot: slot, name: name, appearance: currentAppearanceSnapshot())
        selectedPresetSlot = slot
        persistPresetDocument(); publishPresetInvalidation()
        return true
    }

    @discardableResult
    func renamePreset(_ slot: PresetSlot, rawName: String) -> Bool {
        guard !presetControlsDisabled, let name = PresetName(rawName), var entry = appearancePresets[slot],
              advancePresetRevision() else { return false }
        entry.name = name; appearancePresets[slot] = entry
        persistPresetDocument(); publishPresetInvalidation()
        return true
    }

    @discardableResult
    func deletePreset(_ slot: PresetSlot) -> Bool {
        guard !presetControlsDisabled, advancePresetRevision() else { return false }
        appearancePresets.removeValue(forKey: slot)
        if selectedPresetSlot == slot { selectedPresetSlot = nil }
        persistPresetDocument(); publishPresetInvalidation()
        return true
    }

    var canStartJitterDiagnostics: Bool {
        activePointerSession != nil && calibrationRun == nil && authorizedCentralID != nil
    }

    override init() {
        let defaults = UserDefaults.standard
        trustedPhoneIDs = (defaults.stringArray(forKey: Self.trustedPhoneIDsKey) ?? []).compactMap(UUID.init(uuidString:))
        let loaded = Self.loadSensitivities(from: .standard)
        sensitivityPair = loaded
        adaptiveSmoothingEnabled = Self.loadAdaptiveSmoothingEnabled(from: .standard)
        storedEffectsConfiguration = Self.loadEffects()
        let loadedPresets = Self.loadPresetDocument()
        appearancePresets = loadedPresets.entries
        presetRevision = loadedPresets.revision
        selectedPresetSlot = loadedPresets.selected
        let savedDiagnostics = defaults.stringArray(forKey: Self.connectionDiagnosticsKey) ?? []
        let normalizedDiagnostics = Self.normalizedConnectionDiagnostics(savedDiagnostics)
        connectionDiagnostics = normalizedDiagnostics
        super.init()
        if normalizedDiagnostics.isEmpty {
            defaults.removeObject(forKey: Self.connectionDiagnosticsKey)
        } else if savedDiagnostics != normalizedDiagnostics {
            defaults.set(normalizedDiagnostics, forKey: Self.connectionDiagnosticsKey)
        }
        Self.saveSensitivityPair(loaded, to: .standard)
        UserDefaults.standard.set(adaptiveSmoothingEnabled, forKey: Self.adaptiveSmoothingKey)
        overlay.shape = pointerShape
        overlay.color = storedPointerColor
        overlay.size = storedPointerSize
        overlay.setAdaptiveSmoothingEnabled(adaptiveSmoothingEnabled)
        overlay.setEffectsConfiguration(effectsConfiguration)
        if let selectedPresetSlot, appearancePresets[selectedPresetSlot]?.appearance != currentAppearanceSnapshot() {
            self.selectedPresetSlot = nil
            _ = advancePresetRevision()
        }
        persistPresetDocument()
        overlay.onVisibleRenderCallback = { [weak self] now, startsSegment in
            self?.recordVisibleRenderCallback(at: now, startsSegment: startsSegment)
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter promises this observer on OperationQueue.main; make that executor
            // guarantee explicit to strict concurrency rather than merely relying on queue affinity.
            MainActor.assumeIsolated { self?.cancelPointerForDisplayChange() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Termination cleanup must remain synchronous; deferring it to an unstructured Task can
            // lose the final snapshot or leave the delegate live while the process is exiting.
            MainActor.assumeIsolated {
                self?.finalizeJitterDiagnostics(reason: "the app terminated")
                self?.overlay.hide()
                self?.calibrationOverlay.hide()
                self?.transport.invalidate()
            }
        }
        transport = MacBLETransport(sink: self)
        transport.setIncidentClearGeneration(incidentClearGeneration)
        pushTransportPolicy()
        // This @MainActor initializer schedules the timer on the main run loop. Express that
        // synchronous executor invariant explicitly for the Timer's @Sendable callback type.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireAuthorizationIfNeeded() }
        }
    }

    private let exhaustedStatus = "Bluetooth transport counter exhausted. Relaunch Pointer Remote; this transport instance is closed."

    func transportStateChanged(_ text: String) {
        guard !transportInstanceExhausted else { return }
        status = text
    }

    func transportSubscribed(_ centralID: UUID) {
        guard !transportInstanceExhausted else { return }
        subscribedCentralIDs.insert(centralID)
        status = "An iPhone connected. Waiting for its approval request."
    }

    func transportUnsubscribed(_ centralID: UUID, generation: UInt64) {
        subscribedCentralIDs.remove(centralID)
        guard !transportInstanceExhausted else { return }
        if centralID == authorizedCentralID || centralID == pendingCentralID {
            transportGeneration = max(transportGeneration, generation)
            clearAuthorization(notify: nil)
            status = "iPhone disconnected. Waiting for a new connection."
        }
    }

    func transportReset(generation: UInt64, subscriptionsCleared: Bool) {
        // Once closed there is no current authorization to mutate, but a real subscription reset
        // may still discard local bookkeeping. Before exhaustion, stale callbacks are inert.
        if transportInstanceExhausted {
            if subscriptionsCleared { subscribedCentralIDs.removeAll() }
            return
        }
        // An equal epoch remains a legitimate semantic reset and must perform cleanup.
        guard generation >= transportGeneration else { return }
        if subscriptionsCleared { subscribedCentralIDs.removeAll() }
        clearAuthorization(notify: nil, minimumTransportGeneration: generation)
    }

    func transportExhausted() {
        guard !transportInstanceExhausted else { return }
        transportInstanceExhausted = true
        receivingEnabled = false
        approved = false
        authorizedCentralID = nil; pendingCentralID = nil
        pendingApprovalGeneration = nil; pendingApprovalName = nil; rememberPendingPhone = false
        activePointerSession = nil; lastPointerSession = nil; pointerEnabled = false
        clearPointerMappingState(); heldSensitivityX = nil; heldSensitivityY = nil
        calibrationRun = nil; calibrationOverlay.hide(); calibrationSummary = nil
        lastRecenterEpoch = nil; lastCalibrationSession = nil; terminalCalibrationStatus = nil
        lastHeartbeatUptime = nil; pendingBarrierIntents.removeAll()
        mainBarrierPending = false; transportActionPending = false
        jitterDiagnosticsActive = false; jitterDiagnosticsStartPending = false
        jitterFinalizationPending = false; jitterCapture = nil
        hidePointerOverlay()
        status = exhaustedStatus
    }

    fileprivate func transportDiagnosticEnded(_ snapshot: SerialDiagnosticSnapshot, reason: String) {
        guard !transportInstanceExhausted else { return }
        completeJitterDiagnostics(snapshot, reason: reason,
                                  mainEndedAt: ProcessInfo.processInfo.systemUptime)
    }

    private func requestConnectionIncident(_ trigger: String) {
        let eventID = UUID(), now = ProcessInfo.processInfo.systemUptime
        let lease: String
        if activePointerSession == nil { lease = "none" }
        else if let receive = lastAcceptedMotionReceiveTime {
            lease = "steady; latest main-accepted raw age at trigger \(String(format: "%.3fs", max(0, now - receive)))"
        } else if let start = trackingStartedAt {
            lease = "startup; age at trigger \(String(format: "%.3fs", max(0, now - start)))"
        } else { lease = "active; startup timestamp unavailable" }
        let mapping = lastMainMappingExecutionUptime.map { String(format: "%.3fs ago", max(0, now - $0)) } ?? "unavailable"
        pendingIncidentMainContext[eventID] = "lease: \(lease); last main mapping execution: \(mapping); main trigger uptime: \(String(format: "%.3f", now))s"
        appendConnectionDiagnostic("[event \(eventID.uuidString)] awaiting serial snapshot — \(String(trigger.prefix(240)))")
        transport.requestConnectionIncident(eventID: eventID, clearGeneration: incidentClearGeneration,
                                            trigger: trigger, triggeringUptime: now,
                                            expectedGeneration: transportGeneration)
    }

    fileprivate func transportConnectionIncident(_ snapshot: ConnectionIncidentSnapshot) {
        guard snapshot.clearGeneration == incidentClearGeneration else { return }
        let marker = "[event \(snapshot.eventID.uuidString)]"
        let generation = snapshot.expectedGeneration.map {
            $0 == snapshot.observedGeneration ? "\($0)" : "unavailable (expected \($0), observed \(snapshot.observedGeneration))"
        } ?? "observed \(snapshot.observedGeneration)"
        let rawAge = snapshot.latestValidCandidateUptime.map {
            String(format: "%.3fs at serial observation", max(0, snapshot.observationUptime - $0))
        } ?? "unavailable"
        let oldest = snapshot.oldestControlAge.map { String(format: "%.3fs", $0) } ?? "unavailable"
        let pendingMain = pendingIncidentMainContext.removeValue(forKey: snapshot.eventID)
        let main = pendingMain ?? "lease/main mapping: unavailable (serial-originated event)"
        let text = """
        \(marker) \(ISO8601DateFormatter().string(from: Date()))
        trigger: \(snapshot.trigger)
        local trigger uptime: \(String(format: "%.3f", snapshot.triggeringUptime))s; serial snapshot observation uptime: \(String(format: "%.3f", snapshot.observationUptime))s
        transport generation: \(generation)
        latest raw serial valid-candidate age: \(rawAge); \(main)
        outstanding controls: \(snapshot.outstandingControlCount); oldest retained control age: \(oldest); pending status lane entries: \(snapshot.pendingStatusCount); subscriptions: \(snapshot.subscribedCount)
        """
        if let index = connectionDiagnostics.firstIndex(where: { $0.contains(marker) }) {
            connectionDiagnostics[index] = String(text.prefix(2_048))
            persistConnectionDiagnostics()
        } else if pendingMain == nil {
            // Serial-originated events have no placeholder. A late main-requested fill whose bounded
            // placeholder was evicted is discarded rather than appended out of causal order.
            appendConnectionDiagnostic(text)
        }
    }

    private func appendConnectionDiagnostic(_ text: String) {
        connectionDiagnostics.append(String(text.prefix(2_048)))
        if connectionDiagnostics.count > 16 { connectionDiagnostics.removeFirst(connectionDiagnostics.count - 16) }
        persistConnectionDiagnostics()
    }

    private func persistConnectionDiagnostics() {
        UserDefaults.standard.set(connectionDiagnostics, forKey: Self.connectionDiagnosticsKey)
    }

    func copyConnectionDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(connectionDiagnostics.isEmpty ? "Pointer Remote Mac connection diagnostics: no incidents recorded." : connectionDiagnostics.joined(separator: "\n\n---\n\n"), forType: .string)
    }

    func clearConnectionDiagnostics() {
        incidentClearGeneration &+= 1
        pendingIncidentMainContext.removeAll()
        connectionDiagnostics.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.connectionDiagnosticsKey)
        transport.setIncidentClearGeneration(incidentClearGeneration)
    }

    fileprivate func transportReceived(_ envelope: ControlEnvelope) {
        guard !transportInstanceExhausted else {
            transport.complete(id: envelope.id,
                               decision: ControlDecision(result: .insufficientAuthorization,
                                                         policy: transportPolicy(), statuses: []))
            return
        }
        guard envelope.stamp.generation == transportGeneration else {
            transport.complete(id: envelope.id,
                               decision: ControlDecision(result: .insufficientAuthorization,
                                                         policy: transportPolicy(), statuses: []))
            return
        }
        // The transport atomically sealed this pre-control snapshot. Later motion is held in the
        // one-slot mailbox and cannot be mapped with gains/session state created by this control.
        let discardPreceding: Bool
        switch envelope.message {
        case let .tracking(enabled, _): discardPreceding = enabled
        case .recenter, .calibrationStart, .calibrationCapture, .calibrationCancel, .calibrationApply:
            discardPreceding = true
        default: discardPreceding = false
        }
        if !discardPreceding, let batch = envelope.precedingMotion {
            acceptLatestMotion(batch, acceptedMappingUptime: ProcessInfo.processInfo.systemUptime)
        }
        completingControlStatuses = []
        let result = receive(envelope.message, from: envelope.centralID,
                             rawReceiveUptime: envelope.stamp.rawReceiveUptime)
        let orderedStatuses = (completingControlStatuses ?? []).map(\.0)
        completingControlStatuses = nil
        transport.complete(id: envelope.id,
                           decision: ControlDecision(result: result, policy: transportPolicy(),
                                                     statuses: orderedStatuses))
    }

    fileprivate func transportAccepted(_ batch: MotionBatch, acceptedMappingUptime: TimeInterval) {
        guard !transportInstanceExhausted else { return }
        acceptLatestMotion(batch, acceptedMappingUptime: acceptedMappingUptime)
    }

    private func transportPolicy() -> TransportPolicy {
        TransportPolicy(modelGeneration: authorizationGeneration, receivingEnabled: receivingEnabled,
                        authorizedCentralID: authorizedCentralID, pendingCentralID: pendingCentralID,
                        activeMotionSession: activePointerSession)
    }

    private func pushTransportPolicy() { transport?.setPolicy(transportPolicy()) }

    /// A finite typed queue prevents a concurrent main-originated semantic boundary from vanishing.
    /// Gains coalesce to their latest value. On pressure, overflow revocation, diagnostic finalization,
    /// and display topology have a bounded sticky representation. Confirmed Forget persistence is
    /// applied at admission and therefore is not permission inferred from queue pressure.
    private func enqueueBarrierIntent(_ intent: BarrierIntent) {
        switch intent {
        case .sensitivityX:
            pendingBarrierIntents.removeAll { if case .sensitivityX = $0 { return true }; return false }
        case .sensitivityY:
            pendingBarrierIntents.removeAll { if case .sensitivityY = $0 { return true }; return false }
        case .displayTopologyChanged:
            if pendingBarrierIntents.contains(where: { if case .displayTopologyChanged = $0 { return true }; return false }) { return }
        default: break
        }
        guard pendingBarrierIntents.count < Self.maximumPendingBarrierIntents else {
            let combined = pendingBarrierIntents + [intent]
            if combined.contains(where: { if case .startDiagnostics = $0 { return true }; return false }) {
                jitterDiagnosticsStartPending = false
                jitterDiagnosticsStatus = "Capture could not start because the bounded action queue overflowed."
            }
            var collapsed: [BarrierIntent] = [.failClosedOverflow]
            if let stop = combined.first(where: { if case .stopDiagnostics = $0 { return true }; return false }) {
                collapsed.append(stop)
            }
            if combined.contains(where: { if case .displayTopologyChanged = $0 { return true }; return false }) {
                collapsed.append(.displayTopologyChanged)
            }
            pendingBarrierIntents = collapsed
            if !mainBarrierPending { runNextBarrierIntent() }
            return
        }
        pendingBarrierIntents.append(intent)
        if !mainBarrierPending { runNextBarrierIntent() }
    }

    private func runNextBarrierIntent() {
        guard !mainBarrierPending, !pendingBarrierIntents.isEmpty else { return }
        let intent = pendingBarrierIntents.removeFirst()
        mainBarrierPending = true; transportActionPending = true
        if case .startDiagnostics = intent {
            guard canStartJitterDiagnostics, !jitterDiagnosticsActive, !jitterFinalizationPending else {
                jitterDiagnosticsStartPending = false
                mainBarrierPending = false; transportActionPending = !pendingBarrierIntents.isEmpty
                runNextBarrierIntent(); return
            }
            let captureID = UUID()
            transport.startDiagnostic(captureID: captureID, discard: false) { [weak self] token, batch, start in
                guard let self, !self.transportInstanceExhausted else { return }
                guard token != UInt64.max else {
                    self.jitterDiagnosticsStartPending = false
                    self.mainBarrierPending = false; self.transportActionPending = !self.pendingBarrierIntents.isEmpty
                    self.jitterDiagnosticsStatus = "Capture could not start because transport ordering was exhausted."
                    self.runNextBarrierIntent(); return
                }
                if let batch { self.acceptLatestMotion(batch, acceptedMappingUptime: ProcessInfo.processInfo.systemUptime) }
                self.jitterDiagnosticsReport = nil
                self.jitterCapture = JitterDiagnosticCapture(captureID: captureID, startedAt: start,
                                                             adaptiveSmoothingEnabled: self.adaptiveSmoothingEnabled,
                                                             effectsLabel: self.effectsConfiguration.diagnosticsLabel)
                self.jitterDiagnosticsStartPending = false
                self.jitterDiagnosticsActive = true; self.jitterFinalizationPending = false
                self.jitterLastPublishedSecond = nil
                self.jitterDiagnosticsStatus = "Capturing local Mac callback timing for 20 seconds…"
                self.finishBarrierIntent(token: token, statuses: [])
            }
            return
        }
        if case let .stopDiagnostics(reason) = intent {
            if jitterDiagnosticsActive { jitterFinalizationPending = true }
            transport.stopDiagnostic(discard: false) { [weak self] token, batch, snapshot in
                guard let self, !self.transportInstanceExhausted else { return }
                if let batch { self.acceptLatestMotion(batch, acceptedMappingUptime: ProcessInfo.processInfo.systemUptime) }
                self.completeJitterDiagnostics(snapshot, reason: reason,
                                               mainEndedAt: ProcessInfo.processInfo.systemUptime)
                self.finishBarrierIntent(token: token, statuses: [])
            }
            return
        }
        transport.barrier(discard: intent.discardPredecessor) { [weak self] token, batch in
            guard let self, !self.transportInstanceExhausted else { return }
            if let batch { self.acceptLatestMotion(batch, acceptedMappingUptime: ProcessInfo.processInfo.systemUptime) }
            self.completingControlStatuses = []
            self.performBarrierIntent(token == UInt64.max ? .failClosedOverflow : intent)
            let statuses = self.completingControlStatuses ?? []
            self.completingControlStatuses = nil
            self.finishBarrierIntent(token: token, statuses: statuses)
        }
    }

    private func finishBarrierIntent(token: UInt64, statuses: [(RemoteStatus, UUID)]) {
        transport.finishBarrier(token, policy: transportPolicy(), statuses: statuses)
        mainBarrierPending = false
        transportActionPending = !pendingBarrierIntents.isEmpty
        runNextBarrierIntent()
    }

    private func performBarrierIntent(_ intent: BarrierIntent) {
        switch intent {
        case .approve:
            guard receivingEnabled, let id = pendingCentralID,
                  pendingApprovalGeneration == authorizationGeneration, subscribedCentralIDs.contains(id) else {
                clearAuthorization(notify: nil); return
            }
            if rememberPendingPhone { trust(id) }
            authorize(id, message: "This iPhone is approved for this connection.")
        case .reject:
            guard let id = pendingCentralID else { return }
            clearAuthorization(notify: id, status: .rejected); status = "iPhone approval was declined."
        case .stopReceiving:
            receivingEnabled = false
            let id = authorizedCentralID ?? pendingCentralID
            clearAuthorization(notify: id)
            status = "Receiving stopped. Resume Receiving before any iPhone, including remembered phones, can connect."
        case let .forget(id):
            trustedPhoneIDs.removeAll { $0 == id }; saveTrustedPhones(); receivingEnabled = false
            let affected = id == authorizedCentralID || id == pendingCentralID ? id : nil
            clearAuthorization(notify: affected); clearForgottenPointerState()
            status = "Remembered iPhone forgotten. Receiving is paused; Resume Receiving before a fresh approval."
        case .forgetAll:
            let affected = subscribedCentralIDs.union([authorizedCentralID, pendingCentralID].compactMap { $0 })
            // Persistence was removed synchronously when the confirmed action was admitted.
            receivingEnabled = false; clearAuthorization(notify: nil); clearForgottenPointerState()
            for id in affected { notify(.stopped, to: id) }
            status = "Forgot all iPhones in Pointer Remote. Receiving is paused; Resume Receiving for fresh approval."
        case .failClosedOverflow:
            requestConnectionIncident("bounded main action queue overflow revoked authorization")
            receivingEnabled = false; clearAuthorization(notify: nil)
            transport.failClosedOverflow()
            status = "Too many pending receiver actions; authorization was revoked and current subscriptions are quarantined. Remembered iPhones were not deleted."

        case let .sensitivityX(value):
            let x = Self.normalizedSensitivity(value), pair = (x, sensitivityPair.y)
            Self.saveSensitivityPair(pair, to: .standard); sensitivityPair = pair
            if activePointerSession != nil { heldSensitivityX = x }
        case let .sensitivityY(value):
            let y = Self.normalizedSensitivity(value), pair = (sensitivityPair.x, y)
            Self.saveSensitivityPair(pair, to: .standard); sensitivityPair = pair
            if activePointerSession != nil { heldSensitivityY = y }
        case .stopDiagnostics: break
        case .displayTopologyChanged: cancelPointerForDisplayChangeNow()
        case .startDiagnostics: break
        }
    }

    func approvePendingConnection() { enqueueBarrierIntent(.approve) }

    func resumeReceiving() {
        guard !transportInstanceExhausted else {
            receivingEnabled = false
            status = "This Bluetooth transport instance is closed. Relaunch Pointer Remote to receive again."
            return
        }
        receivingEnabled = true; pushTransportPolicy()
        status = "Receiving resumed. Waiting for an iPhone connection."
    }

    func forgetTrustedPhone(_ centralID: UUID) {
        // A confirmed destructive choice is durable before asynchronous revocation. Advancing the
        // authorization fence now prevents an older in-flight Approve from recreating this trust.
        trustedPhoneIDs.removeAll { $0 == centralID }; saveTrustedPhones()
        let affected = centralID == authorizedCentralID || centralID == pendingCentralID ? centralID : nil
        receivingEnabled = false; clearAuthorization(notify: affected); clearForgottenPointerState()
        enqueueBarrierIntent(.forget(centralID))
    }

    func forgetAllTrustedPhones() {
        trustedPhoneIDs.removeAll(); UserDefaults.standard.removeObject(forKey: Self.trustedPhoneIDsKey)
        receivingEnabled = false; clearAuthorization(notify: nil); clearForgottenPointerState()
        enqueueBarrierIntent(.forgetAll)
    }

    private func trust(_ centralID: UUID) {
        guard pendingApprovalGeneration == authorizationGeneration else { return }
        guard !trustedPhoneIDs.contains(centralID) else { return }
        trustedPhoneIDs.append(centralID)
        saveTrustedPhones()
    }

    private func saveTrustedPhones() {
        UserDefaults.standard.set(trustedPhoneIDs.map(\.uuidString), forKey: Self.trustedPhoneIDsKey)
    }

    private func authorize(_ centralID: UUID, message: String) {
        completedPresetMutations.removeAll(); completedPresetMutationOrder.removeAll()
        highestCompletedPresetMutationRequestID = nil
        authorizedCentralID = centralID
        pendingCentralID = nil
        pendingApprovalGeneration = nil
        pendingApprovalName = nil
        rememberPendingPhone = false
        approved = true
        lastHeartbeatUptime = ProcessInfo.processInfo.systemUptime
        status = message
        notify(.approved, to: centralID)
    }

    func rejectPendingConnection() { enqueueBarrierIntent(.reject) }

    func stopReceiving() { enqueueBarrierIntent(.stopReceiving) }

    func setSensitivityX(_ value: Double) {
        if activePointerSession == nil { performBarrierIntent(.sensitivityX(value)) }
        else { enqueueBarrierIntent(.sensitivityX(value)) }
    }

    func setSensitivityY(_ value: Double) {
        if activePointerSession == nil { performBarrierIntent(.sensitivityY(value)) }
        else { enqueueBarrierIntent(.sensitivityY(value)) }
    }

    private static func validSensitivity(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, PointerSensitivity.minimum), PointerSensitivity.maximum)
    }

    private static func normalizedSensitivity(_ value: Double?) -> Double {
        (validSensitivity(value) ?? PointerSensitivity.referenceGain).rounded()
    }

    private static func numericPreference(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// The pair record is authoritative. Only when it is absent do the older independent keys migrate.
    private static func loadAdaptiveSmoothingEnabled(from defaults: UserDefaults) -> Bool {
        // An absent key means the requested default-on behavior; an existing NSNumber is UserDefaults' Bool.
        (defaults.object(forKey: adaptiveSmoothingKey) as? NSNumber)?.boolValue ?? true
    }

    private static func loadSensitivities(from defaults: UserDefaults) -> (x: Double, y: Double) {
        if let pairObject = defaults.object(forKey: sensitivityPairKey) {
            guard let pair = pairObject as? [String: Any] else {
                return (normalizedSensitivity(nil), normalizedSensitivity(nil))
            }
            // A malformed present pair is normalized on its own; old axis keys cannot supplement it.
            return (normalizedSensitivity(numericPreference(pair["x"])),
                    normalizedSensitivity(numericPreference(pair["y"])))
        }
        let legacy = validSensitivity(numericPreference(defaults.object(forKey: legacySensitivityKey)))
        func migratedAxis(_ key: String) -> Double {
            if let object = defaults.object(forKey: key) {
                return normalizedSensitivity(numericPreference(object))
            }
            return normalizedSensitivity(legacy)
        }
        return (migratedAxis(sensitivityXKey), migratedAxis(sensitivityYKey))
    }

    private static func saveSensitivityPair(_ pair: (x: Double, y: Double), to defaults: UserDefaults) {
        defaults.set(["x": pair.x, "y": pair.y], forKey: sensitivityPairKey)
    }

    func refreshAccessibility() {
        // Accessibility is only needed for arrow-key injection. The visual pointer remains usable without it.
        accessibility = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refreshAccessibility()
    }

    func startJitterDiagnostics() {
        guard !jitterDiagnosticsActive, !jitterDiagnosticsStartPending, !jitterFinalizationPending else { return }
        guard canStartJitterDiagnostics else {
            jitterDiagnosticsStatus = "Continuous tracking is unavailable. Connect and approve the iPhone, then wait for tracking to start; no zero-valued capture was created."
            return
        }
        jitterDiagnosticsStartPending = true
        enqueueBarrierIntent(.startDiagnostics)
    }

    // Queue even when Start has not reached its serial boundary yet; ordered Start→Stop clicks must
    // not collapse into a missing Stop merely because the published active flag is still false.
    func stopJitterDiagnostics() {
        if jitterDiagnosticsActive {
            finalizeJitterDiagnosticsAtTransportBoundary(reason: "stopped by the user")
        } else {
            enqueueBarrierIntent(.stopDiagnostics("stopped by the user"))
        }
    }

    private func finalizeJitterDiagnosticsAtTransportBoundary(reason: String) {
        guard jitterDiagnosticsActive, !jitterFinalizationPending else { return }
        jitterFinalizationPending = true
        enqueueBarrierIntent(.stopDiagnostics(reason))
    }

    func copyJitterDiagnosticsReport() {
        guard let jitterDiagnosticsReport else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jitterDiagnosticsReport, forType: .string)
    }

    private func recordVisibleRenderCallback(at now: TimeInterval, startsSegment: Bool) {
        guard jitterDiagnosticsActive, let startedAt = jitterCapture?.startedAt,
              now - startedAt < JitterDiagnosticCapture.duration else { return }
        jitterCapture?.recordRender(at: now, startsSegment: startsSegment,
                                    latestReceive: lastAcceptedMotionReceiveTime)
    }

    private func tickJitterDiagnostics(at now: TimeInterval) {
        guard jitterDiagnosticsActive, let capture = jitterCapture else { return }
        let elapsed = max(0, now - capture.startedAt)
        if elapsed >= JitterDiagnosticCapture.duration {
            finalizeJitterDiagnosticsAtTransportBoundary(reason: "the 20-second limit was reached")
            return
        }
        let seconds = Int(elapsed)
        if seconds != jitterLastPublishedSecond {
            jitterLastPublishedSecond = seconds
            jitterDiagnosticsStatus = "Capturing… \(Int(ceil(JitterDiagnosticCapture.duration - elapsed))) seconds remaining."
        }
    }

    private func finalizeJitterDiagnostics(reason: String) {
        finalizeJitterDiagnosticsAtTransportBoundary(reason: reason)
    }

    private func completeJitterDiagnostics(_ serial: SerialDiagnosticSnapshot?, reason: String,
                                           mainEndedAt: TimeInterval) {
        guard let serial else {
            if jitterDiagnosticsActive {
                jitterDiagnosticsActive = false; jitterCapture = nil; jitterLastPublishedSecond = nil
                jitterFinalizationPending = false
                jitterDiagnosticsStatus = "Capture ended without a serial snapshot; no empty report was created."
            }
            return
        }
        guard let capture = jitterCapture, capture.captureID == serial.captureID else { return }
        // Main/render attribution stops when main receives the serial boundary payload. Its own
        // timestamp is reported separately; it is never presented as the serial cutoff.
        jitterDiagnosticsActive = false; jitterCapture = nil; jitterLastPublishedSecond = nil
        jitterFinalizationPending = false
        jitterDiagnosticsReport = makeJitterDiagnosticsReport(capture, serial: serial, reason: reason,
                                                               mainEndedAt: mainEndedAt)
        jitterDiagnosticsStatus = "Capture finished because \(reason). The report remains available until the next capture."
    }

    private func makeJitterDiagnosticsReport(_ capture: JitterDiagnosticCapture,
                                             serial: SerialDiagnosticSnapshot,
                                             reason: String,
                                             mainEndedAt: TimeInterval) -> String {
        struct Statistics {
            let median: Double
            let p95: Double
            let p99: Double
            let maximum: Double
        }
        func statistics(_ samples: [Double]) -> Statistics? {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            func nearestRank(_ percentile: Double) -> Double {
                let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
                return sorted[min(rank - 1, sorted.count - 1)]
            }
            return Statistics(median: nearestRank(0.50), p95: nearestRank(0.95),
                              p99: nearestRank(0.99), maximum: sorted[sorted.count - 1])
        }
        func ms(_ value: Double) -> String { String(format: "%.2f", value * 1_000) }
        func line(_ name: String, samples: [Double], count: Int, observation: Double, overflow: Int) -> String {
            guard let result = statistics(samples) else {
                return "\(name): count \(count); interval/sample count 0; observation \(String(format: "%.2f", observation)) s; median n/a, p95 n/a, p99 n/a, max n/a; overflow \(overflow)."
            }
            return "\(name): count \(count); interval/sample count \(samples.count); observation \(String(format: "%.2f", observation)) s; median \(ms(result.median)) ms, p95 \(ms(result.p95)) ms, p99 \(ms(result.p99)) ms, max \(ms(result.maximum)) ms; overflow \(overflow)."
        }
        let elapsed = max(0, serial.endedAt - serial.startedAt)
        let mainElapsed = max(0, min(mainEndedAt, capture.startedAt + JitterDiagnosticCapture.duration) - capture.startedAt)
        let receiveObservation = serial.firstReceive.flatMap { first in serial.lastReceive.map { max(0, $0 - first) } } ?? 0
        let receive = line("Serial accepted-candidate receive callback intervals (continuous, including hidden)",
                           samples: serial.receiveIntervals, count: serial.acceptedPackets,
                           observation: receiveObservation, overflow: serial.receiveIntervalOverflow)
        let drainObservation = capture.batchDrainIntervals.reduce(0, +)
        let drain = line("Accepted mailbox batch main-drain intervals",
                         samples: capture.batchDrainIntervals, count: capture.mappedBatches,
                         observation: drainObservation, overflow: capture.batchDrainIntervalOverflow)
        let handoff = line("Optional serial receive-to-main acceptance handoff age",
                           samples: capture.handoffAges, count: capture.mappedBatches,
                           observation: drainObservation, overflow: capture.handoffAgeOverflow)
        let batchSizeStats = statistics(serial.callbackBatchSizes)
        let batchSizes: String
        if let batchSizeStats {
            batchSizes = "Serial callback batches containing accepted candidates: callbacks \(serial.acceptedCallbacks); request total \(serial.callbackRequestTotal); accepted candidate packets \(serial.acceptedPackets); rejected/unauthorized/duplicate decoded motion candidates \(serial.rejectedCandidatePackets); mailbox replacements \(serial.mailboxReplacedPackets); callback request-count median \(String(format: "%.0f", batchSizeStats.median)), p95 \(String(format: "%.0f", batchSizeStats.p95)), p99 \(String(format: "%.0f", batchSizeStats.p99)), max \(String(format: "%.0f", batchSizeStats.maximum)); overflow \(serial.callbackBatchSizeOverflow)."
        } else {
            batchSizes = "Serial callback batches containing accepted candidates: callbacks 0; accepted candidates 0; rejected decoded motion candidates \(serial.rejectedCandidatePackets); no callback-size observations; overflow \(serial.callbackBatchSizeOverflow)."
        }
        let render = line("Actual presented-geometry callback execution intervals",
                          samples: capture.renderIntervals, count: capture.visibleRenderCallbacks,
                          observation: capture.visibleRenderObservation, overflow: capture.renderIntervalOverflow)
        let age = line("Latest accepted motion receive age at presented-geometry callback",
                       samples: capture.receiveAges, count: capture.visibleRenderCallbacks,
                       observation: capture.visibleRenderObservation, overflow: capture.receiveAgeOverflow)
        let summary: String
        if serial.receiveIntervals.isEmpty && capture.renderIntervals.isEmpty {
            summary = "Plain-English summary: there were not enough serial accepted-candidate receive intervals or presented-geometry callback intervals to characterize jitter."
        } else {
            let receiveMedian = statistics(serial.receiveIntervals).map { "\(ms($0.median)) ms" } ?? "n/a"
            let renderMedian = statistics(capture.renderIntervals).map { "\(ms($0.median)) ms" } ?? "n/a"
            summary = "Plain-English summary: the typical accepted receive interval was \(receiveMedian), and the typical actual presented-geometry callback interval was \(renderMedian). Compare the p95/p99/max values with the medians to spot bursts or main-thread scheduling stalls."
        }
        return """
        Pointer Remote — Jitter Diagnostics
        Finalized: \(reason).
        Adaptive visual smoothing at capture start: \(capture.adaptiveSmoothingEnabled ? "enabled" : "disabled"). \(capture.adaptiveSmoothingEnabled ? "One Euro 2D shared-speed cutoff: min 12 Hz, derivative 10 Hz, beta 0.025 Hz per (Mac point/sec)." : "Direct latest-only presentation.") This immutable capture label is not read from the live switch.
        \(capture.effectsLabel)
        Serial capture observation: \(String(format: "%.2f", elapsed)) s (half-open admission ended at the serial stop/loss boundary, capped by the fixed 20-second deadline).
        Main/render attribution observation: \(String(format: "%.2f", mainElapsed)) s (stopped separately when main received that frozen boundary payload).
        \(summary)

        \(receive)
        The receive distribution is owned by the serial diagnostic epoch and includes only callbacks in [start, cutoff); its first interval baseline is necessarily inside that window. It describes transport-accepted candidates, not later main mapping/display acceptance. Rejected candidates are labelled separately.
        \(batchSizes)
        \(drain)
        \(handoff)
        Handoff age is local scheduling time from the latest known-accepted serial callback to main mapping; it is not BLE PHY delay or cross-device age.
        Sequence gaps during serial accepted candidates: \(serial.sequenceGaps). These are unexplained unseen sequence numbers after accounting separately for local mailbox replacement; radio loss is not proven.
        \(render)
        Render intervals use ProcessInfo.systemUptime at a main callback that produced selected-viewport-intersecting geometry, not CADisplayLink targetTimestamp or a CV predicted/output time. Equal-target presented callbacks are included. Permission-active all-outside and stopped/restarted segments do not share an interval baseline.
        \(age)
        Trail live-sample hard-guard overflow during the current hold: \(overlay.trailOverflowCount). Existing live Trail samples are not evicted or decimated; rejected changed samples resume as a separate path segment when capacity expires.

        Percentiles use nearest rank: sort only when finalizing, then select rank ceil(p × n). With no samples the value is n/a, never zero. Storage is capped at \(JitterDiagnosticCapture.sampleCapacity) samples per metric; overflow is reported above while total callback/packet counts continue. Receive observation is first-to-last accepted serial callback; render observation is the sum of recorded presented-geometry within-segment callback intervals.

        Scope: these are local Mac receive and main callback scheduling observations. They cannot prove photons-on-screen timing, drawing cadence, CPU/GPU cost, BLE connection interval, radio loss, or cross-device/end-to-end latency. The existing predicted maximumRenderFrameGap diagnostic is separate from these actual callback execution intervals.
        """
    }

    private func receive(_ message: RemoteMessage, from centralID: UUID,
                         rawReceiveUptime: TimeInterval) -> CBATTError.Code {
        switch message {
        case .hello:
            guard receivingEnabled else { notify(.stopped, to: centralID); return .insufficientAuthorization }
            if authorizedCentralID == centralID {
                lastHeartbeatUptime = rawReceiveUptime
                return .success
            }
            guard authorizedCentralID == nil, pendingCentralID == nil || pendingCentralID == centralID else {
                return .insufficientAuthorization
            }
            if trustedPhoneIDs.contains(centralID) {
                // This is the OS-local CBCentral identifier saved after explicit approval, not caller data.
                authorize(centralID, message: "Remembered iPhone reconnected. Pointer remains idle until held.")
                lastHeartbeatUptime = rawReceiveUptime
                return .success
            }
            if pendingCentralID != centralID { rememberPendingPhone = false }
            pendingCentralID = centralID; pendingApprovalGeneration = authorizationGeneration
            pendingApprovalName = centralID.uuidString
            status = "Approval requested by iPhone \(centralID.uuidString.prefix(8))."
            notify(.waitingForApproval, to: centralID)
            return .success
        default:
            guard authorizedCentralID == centralID else { return .insufficientAuthorization }
            lastHeartbeatUptime = rawReceiveUptime
            return handle(message)
        }
    }

    private func handle(_ message: RemoteMessage) -> CBATTError.Code {
        switch message {
        case let .tracking(enabled, session):
            guard session != 0 else { return .invalidPdu }
            if enabled {
                guard calibrationRun == nil else { return .unlikelyError }
                if activePointerSession == session { return .success }
                guard lastPointerSession.map({ session > $0 }) ?? true else { return .unlikelyError }
                lastPointerSession = session
                let selected: (id: CGDirectDisplayID, bounds: CGRect)
                if let id = lastPointedDisplayID, !CGDisplayBounds(id).isEmpty {
                    selected = (id, CGDisplayBounds(id))
                } else {
                    selected = display(containing: CGEvent(source: nil)?.location ?? .zero)
                }
                guard !selected.bounds.isEmpty else { return .unlikelyError }
                finalizeJitterDiagnostics(reason: "the tracking session changed")
                pointerDisplayBounds = selected.bounds
                let fallback = CGPoint(x: selected.bounds.midX, y: selected.bounds.midY)
                effectivePointerTarget = retainedTargetsByDisplay[selected.id] ?? fallback
                if !effectivePointerTarget.x.isFinite || !effectivePointerTarget.y.isFinite {
                    effectivePointerTarget = fallback
                }
                pointerAnchor = effectivePointerTarget
                retainedTargetsByDisplay[selected.id] = effectivePointerTarget; lastPointedDisplayID = selected.id
                previousAcceptedCumulative = .zero
                activePointerSession = session; lastMotionSequence = nil; lastAcceptedMotionReceiveTime = nil
                trackingStartedAt = ProcessInfo.processInfo.systemUptime
                holdAcceptedPackets = 0; holdSequenceGaps = 0; holdMaxReceiveGap = 0
                heldSensitivityX = sensitivityX; heldSensitivityY = sensitivityY
                pointerEnabled = false
                hidePointerOverlay()
            } else if activePointerSession == Optional(session) {
                finalizeJitterDiagnostics(reason: "tracking stopped")
                finishHoldDiagnostics(); pointerEnabled = false; activePointerSession = nil; lastMotionSequence = nil
                previousAcceptedCumulative = .zero; lastAcceptedMotionReceiveTime = nil; trackingStartedAt = nil
                heldSensitivityX = nil; heldSensitivityY = nil; hidePointerOverlay()
            }
            return .success
        case let .visibility(visible, session):
            // Stale visibility around tracking stop/Recenter is acknowledged but inert.
            guard activePointerSession == Optional(session), calibrationRun == nil else { return .success }
            pointerEnabled = visible
            if visible, !reconcilePointerVisibility() {
                pointerEnabled = false
                status = "Display synchronization is unavailable. Release and hold again after checking the display."
                return .unlikelyError
            }
            if !visible { hidePointerOverlay() }
            return .success
        case let .recenter(epoch):
            guard calibrationRun == nil else { return .unlikelyError }
            if let last = lastRecenterEpoch {
                guard epoch >= last else { return .unlikelyError }
                if epoch == last { if let id = authorizedCentralID { notify(.recentered(epoch: epoch), to: id) }; return .success }
            }
            finalizeJitterDiagnostics(reason: "Recenter ended the tracking session")
            if activePointerSession != nil { finishHoldDiagnostics() }
            pointerEnabled = false; activePointerSession = nil; lastMotionSequence = nil; trackingStartedAt = nil
            previousAcceptedCumulative = .zero; heldSensitivityX = nil; heldSensitivityY = nil; hidePointerOverlay()
            let selected: (id: CGDirectDisplayID, bounds: CGRect)
            if let displayID = lastPointedDisplayID, !CGDisplayBounds(displayID).isEmpty {
                selected = (id: displayID, bounds: CGDisplayBounds(displayID))
            } else {
                selected = display(containing: CGEvent(source: nil)?.location ?? .zero)
            }
            guard !selected.bounds.isEmpty else { return .unlikelyError }
            let centre = CGPoint(x: selected.bounds.midX, y: selected.bounds.midY)
            retainedTargetsByDisplay[selected.id] = centre; lastPointedDisplayID = selected.id
            pointerDisplayBounds = selected.bounds; effectivePointerTarget = centre; pointerAnchor = centre
            lastRecenterEpoch = epoch
            if let id = authorizedCentralID { notify(.recentered(epoch: epoch), to: id) }
            status = "Pointer recentered. Continuous tracking will renew; hold to show it."
            return .success
        case let .key(key):
            if calibrationRun == nil, AXIsProcessTrusted() { press(key) }
            return .success
        case let .calibrationStart(session): return startCalibration(session: session)
        case let .calibrationCapture(session, step, x, y): return captureCalibration(session: session, step: step, snapshot: CGPoint(x: x, y: y))
        case let .calibrationCancel(session): return cancelCalibration(session: session, notifyPhone: true)
        case let .calibrationApply(session): return applyCalibration(session: session)
        case let .presetCatalogPage(requestID, _, slot):
            if let id = authorizedCentralID {
                notify(.presetCatalogPage(requestID: requestID, revision: presetRevision, slot: slot,
                                          name: appearancePresets[slot]?.name, selectedSlot: selectedPresetSlot), to: id)
            }
            return .success
        case let .presetSelect(requestID, slot):
            let signature = PresetMutationSignature.select(slot)
            if replayPresetMutation(requestID: requestID, signature: signature) { return .success }
            guard calibrationRun == nil, !effectsControlDisabled else {
                rejectPreset(requestID, signature, .unavailable); return .success
            }
            guard let appearance = appearancePresets[slot]?.appearance else {
                rejectPreset(requestID, signature, .missingSlot); return .success
            }
            guard applyPresetAppearance(appearance, selecting: slot, announce: false) else {
                rejectPreset(requestID, signature, .counterExhausted); return .success
            }
            finishPresetMutation(requestID, signature,
                                 .presetSelected(requestID: requestID, revision: presetRevision, selectedSlot: slot))
            return .success
        case let .presetSave(requestID, slot, name, overwrite):
            let signature = PresetMutationSignature.save(slot, name, overwrite)
            if replayPresetMutation(requestID: requestID, signature: signature) { return .success }
            guard calibrationRun == nil, !effectsControlDisabled else {
                rejectPreset(requestID, signature, .unavailable); return .success
            }
            if let existing = appearancePresets[slot], !overwrite {
                finishPresetMutation(requestID, signature,
                                     .presetConflict(requestID: requestID, revision: presetRevision, slot: slot,
                                                     existingName: existing.name))
                return .success
            }
            guard advancePresetRevision() else { rejectPreset(requestID, signature, .counterExhausted); return .success }
            appearancePresets[slot] = StoredAppearancePreset(slot: slot, name: name,
                                                             appearance: currentAppearanceSnapshot())
            selectedPresetSlot = slot; persistPresetDocument()
            finishPresetMutation(requestID, signature,
                                 .presetSaved(requestID: requestID, revision: presetRevision, slot: slot,
                                              name: name, selectedSlot: slot))
            return .success
        case let .presetDelete(requestID, slot):
            let signature = PresetMutationSignature.delete(slot)
            if replayPresetMutation(requestID: requestID, signature: signature) { return .success }
            guard calibrationRun == nil, !effectsControlDisabled else {
                rejectPreset(requestID, signature, .unavailable); return .success
            }
            if appearancePresets[slot] != nil {
                guard advancePresetRevision() else { rejectPreset(requestID, signature, .counterExhausted); return .success }
                appearancePresets.removeValue(forKey: slot)
                if selectedPresetSlot == slot { selectedPresetSlot = nil }
                persistPresetDocument()
            }
            finishPresetMutation(requestID, signature,
                                 .presetDeleted(requestID: requestID, revision: presetRevision,
                                                slot: slot, selectedSlot: selectedPresetSlot))
            return .success
        case .timer, .hello: return .success
        }
    }

    // handle(_:) is called only after the central-authorization gate, so no other peer can query this cache.
    private func replayPresetMutation(requestID: UInt64, signature: PresetMutationSignature) -> Bool {
        if let completed = completedPresetMutations[requestID] {
            if let id = authorizedCentralID {
                if completed.signature == signature {
                    notify(completed.result, to: id)
                } else {
                    // Preserve the original result: a changed payload or mutation kind never replaces it.
                    notify(.presetRejected(requestID: requestID, revision: presetRevision, reason: .invalidRequest), to: id)
                }
            }
            return true
        }
        // Phone request IDs are monotonic and one mutation is in flight. Once a bounded-cache entry
        // is evicted, a delayed older write is rejected rather than allowed to resnapshot or mutate.
        if requestID <= (highestCompletedPresetMutationRequestID ?? 0) {
            if let id = authorizedCentralID {
                notify(.presetRejected(requestID: requestID, revision: presetRevision, reason: .invalidRequest), to: id)
            }
            return true
        }
        return false
    }

    private func rejectPreset(_ requestID: UInt64, _ signature: PresetMutationSignature, _ reason: PresetRejection) {
        finishPresetMutation(requestID, signature,
                             .presetRejected(requestID: requestID, revision: presetRevision, reason: reason))
    }

    private func finishPresetMutation(_ requestID: UInt64, _ signature: PresetMutationSignature, _ result: RemoteStatus) {
        completedPresetMutations[requestID] = CompletedPresetMutation(signature: signature, result: result)
        highestCompletedPresetMutationRequestID = max(highestCompletedPresetMutationRequestID ?? 0, requestID)
        completedPresetMutationOrder.append(requestID)
        if completedPresetMutationOrder.count > 16 {
            completedPresetMutations.removeValue(forKey: completedPresetMutationOrder.removeFirst())
        }
        if let id = authorizedCentralID { notify(result, to: id) }
    }

    private func startCalibration(session: UInt64) -> CBATTError.Code {
        if notifyTerminalCalibrationIfMatching(session) { return .success }
        guard activePointerSession == nil else { return .unlikelyError }
        if let run = calibrationRun, run.session == session {
            notifyCalibrationState(run); return .success
        }
        guard calibrationRun == nil, lastCalibrationSession.map({ session > $0 }) ?? true else { return .unlikelyError }
        let current = CGEvent(source: nil)?.location ?? .zero
        let selected = display(containing: current)
        let b = selected.bounds
        guard b.width >= 240, b.height >= 240 else { return .unlikelyError }
        finalizeJitterDiagnostics(reason: "calibration started")
        overlay.resetAdaptiveSmoothing()
        let inset = min(90.0, max(50.0, min(b.width, b.height) * 0.08))
        let targets = [CGPoint(x: b.midX, y: b.midY), CGPoint(x: b.minX + inset, y: b.minY + inset),
                       CGPoint(x: b.maxX - inset, y: b.minY + inset), CGPoint(x: b.maxX - inset, y: b.maxY - inset),
                       CGPoint(x: b.minX + inset, y: b.maxY - inset)]
        lastCalibrationSession = session
        calibrationRun = CalibrationRun(session: session, displayID: selected.id, displayBounds: b, targets: targets,
                                        expectedStep: .centre, captures: [:], proposal: nil)
        calibrationSummary = "Calibration in progress: Centre"
        calibrationOverlay.show(at: targets[0], label: CalibrationStep.centre.title)
        if let authorizedCentralID { notify(.calibrationReady(session: session, step: .centre), to: authorizedCentralID) }
        return .success
    }

    private func captureCalibration(session: UInt64, step: CalibrationStep, snapshot: CGPoint) -> CBATTError.Code {
        if notifyTerminalCalibrationIfMatching(session) { return .success }
        guard var run = calibrationRun, run.session == session else { return .unlikelyError }
        if let storedSnapshot = run.captures[step] {
            guard storedSnapshot == snapshot else { return .unlikelyError }
            // A retry of any accepted step, including final Lower Left after its proposal exists,
            // only repeats the current Ready/Result status; it never captures, fits, or saves again.
            notifyCalibrationState(run); return .success
        }
        guard step == run.expectedStep, run.proposal == nil else { return .unlikelyError }
        run.captures[step] = snapshot
        if let next = step.next {
            run.expectedStep = next; calibrationRun = run
            calibrationSummary = "Calibration in progress: \(next.title)"
            calibrationOverlay.show(at: run.targets[next.rawValue], label: next.title)
            if let authorizedCentralID { notify(.calibrationReady(session: session, step: next), to: authorizedCentralID) }
            return .success
        }
        let proposal: (x: Double, y: Double)
        switch calibrationProposal(run) {
        case let .success(value): proposal = value
        case let .failure(failure):
            calibrationOverlay.hide(); calibrationRun = nil
            calibrationSummary = "Calibration rejected: \(failure.message) Previous sensitivities unchanged."
            let failed = RemoteStatus.calibrationFailed(session: session, message: failure.message)
            terminalCalibrationStatus = failed
            if let authorizedCentralID { notify(failed, to: authorizedCentralID) }
            return .success
        }
        run.proposal = proposal; calibrationRun = run; calibrationOverlay.hide()
        calibrationSummary = "Proposed X \(Int(proposal.x.rounded())), Y \(Int(proposal.y.rounded())). Awaiting Apply or Cancel."
        if let authorizedCentralID { notify(.calibrationResult(session: session, xGain: proposal.x, yGain: proposal.y), to: authorizedCentralID) }
        return .success
    }

    private struct CalibrationFitFailure: Error {
        let message: String
    }

    private func calibrationProposal(_ run: CalibrationRun) -> Result<(x: Double, y: Double), CalibrationFitFailure> {
        guard let centre = run.captures[.centre], run.captures.count == CalibrationStep.allCases.count else {
            return .failure(CalibrationFitFailure(message: "Incomplete calibration samples."))
        }
        var rx = [Double](), ry = [Double](), tx = [Double](), ty = [Double]()
        for step in CalibrationStep.allCases where step != .centre {
            guard let capture = run.captures[step] else {
                return .failure(CalibrationFitFailure(message: "Incomplete calibration samples."))
            }
            rx.append(Double(capture.x - centre.x) / PointerSensitivity.referenceGain)
            ry.append(Double(capture.y - centre.y) / PointerSensitivity.referenceGain)
            tx.append(Double(run.targets[step.rawValue].x - run.targets[0].x))
            ty.append(Double(run.targets[step.rawValue].y - run.targets[0].y))
        }
        // This conservative low-motion gate is 0.0001 rad² (four corners at RMS 0.005 rad,
        // about 0.286°, meet it). It only rejects ill-conditioned fits; it is not a promise
        // that larger motion is free of sensor noise or calibration error.
        func fit(axis: String, reference: [Double], target: [Double]) -> Result<Double, CalibrationFitFailure> {
            let denominator = zip(reference, reference).reduce(0) { $0 + $1.0 * $1.1 }
            let targetEnergy = zip(target, target).reduce(0) { $0 + $1.0 * $1.1 }
            guard denominator.isFinite, denominator >= 0.0001, targetEnergy.isFinite, targetEnergy > 0 else {
                return .failure(CalibrationFitFailure(message: "Insufficient \(axis) rotation; use larger deliberate motion."))
            }
            let gain = zip(reference, target).reduce(0) { $0 + $1.0 * $1.1 } / denominator
            guard gain.isFinite else {
                return .failure(CalibrationFitFailure(message: "\(axis) estimated gain is not finite."))
            }
            guard gain > 0 else {
                return .failure(CalibrationFitFailure(message: "Opposite direction \(axis); reverse the calibration motion."))
            }
            guard gain >= PointerSensitivity.minimum else {
                return .failure(CalibrationFitFailure(message: "\(axis) estimated gain \(boundedGainText(gain)) is below minimum \(Int(PointerSensitivity.minimum))."))
            }
            guard gain <= PointerSensitivity.maximum else {
                return .failure(CalibrationFitFailure(message: "\(axis) estimated gain \(boundedGainText(gain)) exceeds maximum \(Int(PointerSensitivity.maximum))."))
            }
            let residual = zip(reference, target).reduce(0) { $0 + pow($1.1 - gain * $1.0, 2) }
            let residualRatio = sqrt(residual / targetEnergy)
            guard residual.isFinite, residualRatio.isFinite, residualRatio <= 0.25 else {
                return .failure(CalibrationFitFailure(message: "Inconsistent \(axis) samples; residual ratio \(boundedGainText(residualRatio))."))
            }
            return .success(gain.rounded())
        }
        switch fit(axis: "X", reference: rx, target: tx) {
        case let .failure(failure): return .failure(failure)
        case let .success(x):
            switch fit(axis: "Y", reference: ry, target: ty) {
            case let .failure(failure): return .failure(failure)
            case let .success(y): return .success((x, y))
            }
        }
    }

    /// Never convert a potentially non-finite or unbounded fit estimate to Int for UI/protocol text.
    private func boundedGainText(_ value: Double) -> String {
        guard value.isFinite else { return "non-finite" }
        return abs(value) >= 100_000_000 ? String(format: "%.3e", value) : String(format: "%.3f", value)
    }

    private func notifyCalibrationState(_ run: CalibrationRun) {
        guard let centralID = authorizedCentralID else { return }
        if let proposal = run.proposal { notify(.calibrationResult(session: run.session, xGain: proposal.x, yGain: proposal.y), to: centralID) }
        else { notify(.calibrationReady(session: run.session, step: run.expectedStep), to: centralID) }
    }

    private func notifyTerminalCalibrationIfMatching(_ session: UInt64) -> Bool {
        guard let terminalCalibrationStatus else { return false }
        let matches: Bool
        switch terminalCalibrationStatus {
        case let .calibrationApplied(value), let .calibrationCancelled(value): matches = value == session
        case let .calibrationFailed(value, _): matches = value == session
        default: matches = false
        }
        if matches, let centralID = authorizedCentralID { notify(terminalCalibrationStatus, to: centralID) }
        return matches
    }

    @discardableResult private func cancelCalibration(session: UInt64, notifyPhone: Bool) -> CBATTError.Code {
        if notifyTerminalCalibrationIfMatching(session) { return .success }
        guard calibrationRun?.session == session else { return .success }
        calibrationRun = nil; calibrationOverlay.hide(); overlay.resetAdaptiveSmoothing(); calibrationSummary = "Calibration cancelled; previous sensitivities unchanged."
        let cancelled = RemoteStatus.calibrationCancelled(session: session); terminalCalibrationStatus = cancelled
        if notifyPhone, let centralID = authorizedCentralID { notify(cancelled, to: centralID) }
        return .success
    }

    private func applyCalibration(session: UInt64) -> CBATTError.Code {
        if notifyTerminalCalibrationIfMatching(session) { return .success }
        guard let run = calibrationRun, run.session == session, let proposal = run.proposal else { return .unlikelyError }
        // Persist the validated pair in one authoritative record before publishing it in memory.
        // This avoids independent axis updates, without claiming a disk transaction or fsync guarantee.
        Self.saveSensitivityPair(proposal, to: .standard)
        sensitivityPair = proposal
        calibrationRun = nil; calibrationOverlay.hide(); overlay.resetAdaptiveSmoothing()
        calibrationSummary = "Applied X \(Int(proposal.x)), Y \(Int(proposal.y))."
        let applied = RemoteStatus.calibrationApplied(session: session); terminalCalibrationStatus = applied
        if let centralID = authorizedCentralID { notify(applied, to: centralID) }
        return .success
    }

    private func acceptLatestMotion(_ batch: MotionBatch, acceptedMappingUptime now: TimeInterval) {
        guard batch.generation == transportGeneration,
              activePointerSession == Optional(batch.session), calibrationRun == nil else { return }
        if let lastMotionSequence, batch.latestSequence <= lastMotionSequence { return }
        holdSequenceGaps += batch.sequenceGaps
        if let previousReceive = lastAcceptedMotionReceiveTime {
            holdMaxReceiveGap = max(holdMaxReceiveGap,
                                    max(batch.firstRawReceiveUptime - previousReceive,
                                        batch.maximumRawReceiveInterval))
        }
        lastMotionSequence = batch.latestSequence
        // The lease is renewed only after generation/session acceptance, but retains the honest serial
        // callback uptime. It is not a display time, PHY delay, or cross-device packet age.
        lastAcceptedMotionReceiveTime = batch.latestRawReceiveUptime
        lastHeartbeatUptime = batch.latestRawReceiveUptime
        validMotionInRateWindow += batch.rawPacketCount
        holdAcceptedPackets += batch.rawPacketCount
        lastMainMappingExecutionUptime = now
        guard moveCumulative(x: Double(batch.latestX), y: Double(batch.latestY)) else {
            requestConnectionIncident("finite-coordinate validation failure cleared authorization")
            clearAuthorization(notify: authorizedCentralID)
            status = "Pointer motion exceeded finite coordinate bounds. Reconnect to continue."
            return
        }
        // Main acceptance is a separate timeline from serial candidate admission. Attribute a
        // coalesced coordinate batch only by its main acceptance instant, never by mixed raw prefix.
        if jitterDiagnosticsActive, let startedAt = jitterCapture?.startedAt,
           now >= startedAt, now < startedAt + JitterDiagnosticCapture.duration {
            jitterCapture?.recordBatch(batch, acceptedMappingUptime: now)
        }
    }

    private func expireAuthorizationIfNeeded() {
        refreshAccessibility()
        let now = ProcessInfo.processInfo.systemUptime
        tickJitterDiagnostics(at: now)
        if now - rateWindowStarted >= 1 {
            receivedValidMotionPerSecond = Int((Double(validMotionInRateWindow) / (now - rateWindowStarted)).rounded())
            validMotionInRateWindow = 0
            rateWindowStarted = now
        }
        if activePointerSession != nil {
            let trackingExpired: Bool
            if let lastAcceptedMotionReceiveTime {
                trackingExpired = now - lastAcceptedMotionReceiveTime > trackingPacketTimeout
            } else if let trackingStartedAt {
                trackingExpired = now - trackingStartedAt > trackingStartupGrace
            } else {
                trackingExpired = false
            }
            if trackingExpired {
                requestConnectionIncident("tracking authorization cleared by 5-second \(lastAcceptedMotionReceiveTime == nil ? "startup" : "steady-state") watchdog")
                clearAuthorization(notify: authorizedCentralID)
                status = "Continuous tracking stopped after no motion packets for 5 seconds. Reconnect manually."
                return
            }
        }
        guard authorizedCentralID != nil,
              lastHeartbeatUptime.map({ now - $0 > 30 }) ?? false else { return }
        requestConnectionIncident("authorization cleared by 30-second heartbeat watchdog")
        clearAuthorization(notify: authorizedCentralID, status: .heartbeatTimedOut)
        self.status = "Remote session timed out."
    }

    private func clearAuthorization(notify centralID: UUID?, status notification: RemoteStatus = .stopped,
                                    minimumTransportGeneration: UInt64? = nil) {
        finalizeJitterDiagnostics(reason: "the connection or Bluetooth session ended")
        guard authorizationGeneration < UInt64.max else {
            receivingEnabled = false; approved = false; authorizedCentralID = nil; pendingCentralID = nil
            pendingApprovalGeneration = nil; pendingApprovalName = nil; rememberPendingPhone = false
            activePointerSession = nil; pointerEnabled = false; hidePointerOverlay(); calibrationOverlay.hide()
            transportInstanceExhausted = true
            transport.shutdownForGenerationExhaustion()
            status = "Authorization counter exhausted. Relaunch Pointer Remote before receiving again."
            return
        }
        authorizationGeneration += 1
        let floor = max(transportGeneration, minimumTransportGeneration ?? transportGeneration)
        guard floor < UInt64.max else {
            receivingEnabled = false; approved = false; authorizedCentralID = nil; pendingCentralID = nil
            pendingApprovalGeneration = nil; pendingApprovalName = nil; rememberPendingPhone = false
            activePointerSession = nil; pointerEnabled = false; hidePointerOverlay(); calibrationOverlay.hide()
            transportInstanceExhausted = true
            transport.shutdownForGenerationExhaustion()
            status = "Bluetooth session counter exhausted. Relaunch Pointer Remote; this transport instance is closed."
            return
        }
        transportGeneration = floor + 1
        if activePointerSession != nil { finishHoldDiagnostics() }
        pointerEnabled = false
        activePointerSession = nil
        lastMotionSequence = nil
        trackingStartedAt = nil
        clearPointerMappingState()
        heldSensitivityX = nil; heldSensitivityY = nil
        hidePointerOverlay()
        calibrationRun = nil; calibrationOverlay.hide(); calibrationSummary = nil
        lastPointerSession = nil
        lastRecenterEpoch = nil
        lastCalibrationSession = nil
        terminalCalibrationStatus = nil
        presetInvalidationWorkItem?.cancel(); presetInvalidationWorkItem = nil
        completedPresetMutations.removeAll(); completedPresetMutationOrder.removeAll()
        highestCompletedPresetMutationRequestID = nil
        approved = false
        authorizedCentralID = nil
        pendingCentralID = nil
        pendingApprovalGeneration = nil
        pendingApprovalName = nil
        rememberPendingPhone = false
        lastHeartbeatUptime = nil
        transport.fence(generation: transportGeneration, policy: transportPolicy())
        if let centralID { notify(notification, to: centralID) }
    }

    private func notify(_ remoteStatus: RemoteStatus, to centralID: UUID, generation: UInt64? = nil) {
        let notificationGeneration = generation ?? authorizationGeneration
        guard notificationGeneration == authorizationGeneration else { return }
        if completingControlStatuses != nil {
            completingControlStatuses?.append((remoteStatus, centralID))
        } else {
            transport.enqueue(remoteStatus, to: centralID, generation: notificationGeneration)
        }
    }

    private func display(containing point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect) {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)
        let id = displayIDs.prefix(Int(count)).first(where: { CGDisplayBounds($0).contains(point) }) ?? CGMainDisplayID()
        return (id, CGDisplayBounds(id))
    }

    // Logical mapping remains raw latest-coordinate acceptance: visual filtering occurs later only
    // in PointerOverlay's permission-active selected-screen callback, never in packet mapping or this state.
    @discardableResult private func moveCumulative(x: Double, y: Double) -> Bool {
        guard !pointerDisplayBounds.isEmpty, x.isFinite, y.isFinite,
              let heldSensitivityX, let heldSensitivityY else { return false }
        let xGain = heldSensitivityX / PointerSensitivity.referenceGain
        let yGain = heldSensitivityY / PointerSensitivity.referenceGain
        // A coalesced packet contributes its missing cumulative delta exactly once. The logical
        // result is deliberately not clamped: offscreen overshoot remains as reverse dead travel.
        let deltaX = x - previousAcceptedCumulative.width
        let deltaY = y - previousAcceptedCumulative.height
        let next = CGPoint(x: effectivePointerTarget.x + deltaX * xGain,
                           y: effectivePointerTarget.y + deltaY * yGain)
        guard deltaX.isFinite, deltaY.isFinite, next.x.isFinite, next.y.isFinite else { return false }
        previousAcceptedCumulative = CGSize(width: x, height: y)
        effectivePointerTarget = next
        if let displayID = lastPointedDisplayID { retainedTargetsByDisplay[displayID] = next }
        return reconcilePointerVisibility()
    }

    private func reconcilePointerVisibility() -> Bool {
        guard pointerEnabled else { hidePointerOverlay(); return true }
        guard let displayID = lastPointedDisplayID, !pointerDisplayBounds.isEmpty else {
            hidePointerOverlay()
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if overlayShown {
            let updated = overlay.updateTarget(effectivePointerTarget, on: displayID,
                                               viewport: pointerDisplayBounds, timestamp: now)
            if !updated { overlayShown = false }
            return updated
        }
        guard overlay.begin(at: effectivePointerTarget, on: displayID,
                            viewport: pointerDisplayBounds, timestamp: now) else { return false }
        overlayShown = true
        return true
    }

    private func hidePointerOverlay() {
        // Explicit permission/lifecycle boundaries reset visual state. Ordinary viewport exit does not.
        overlay.resetAdaptiveSmoothing()
        guard overlayShown else { return }
        overlayShown = false
        overlay.hide()
    }

    private func clearPointerMappingState() {
        previousAcceptedCumulative = .zero
        lastAcceptedMotionReceiveTime = nil
    }

    private func clearForgottenPointerState() {
        retainedTargetsByDisplay.removeAll()
        lastPointedDisplayID = nil
        pointerDisplayBounds = .zero
        pointerAnchor = .zero
        effectivePointerTarget = .zero
    }

    private func finishHoldDiagnostics() {
        print(String(format: "Pointer tracking diagnostics — accepted packets %d; sequence gaps %d; max receive gap %.3fs; max presented-geometry display callback gap %.3fs; trail hard-guard overflow %llu. Hidden packets are included; render gaps exclude all-outside intervals, and receive/render times are local Mac scheduling observations, not cross-device latency.", holdAcceptedPackets, holdSequenceGaps, holdMaxReceiveGap, overlay.maximumRenderFrameGap, overlay.trailOverflowCount))
    }

    private func cancelPointerForDisplayChange() { enqueueBarrierIntent(.displayTopologyChanged) }

    private func cancelPointerForDisplayChangeNow() {
        finalizeJitterDiagnostics(reason: "the display configuration changed")
        if let calibrationSession = calibrationRun?.session {
            calibrationRun = nil; calibrationOverlay.hide(); calibrationSummary = nil
            if let authorizedCentralID {
                let cancelled = RemoteStatus.calibrationCancelled(session: calibrationSession)
                terminalCalibrationStatus = cancelled; notify(cancelled, to: authorizedCentralID)
            }
        }
        guard activePointerSession != nil else { return }
        if let id = lastPointedDisplayID, !CGDisplayBounds(id).isEmpty {
            pointerDisplayBounds = CGDisplayBounds(id)
            _ = reconcilePointerVisibility()
            status = "Display configuration changed; the selected display and logical target were retained."
            return
        }
        let selected = display(containing: CGEvent(source: nil)?.location ?? .zero)
        guard !selected.bounds.isEmpty else {
            requestConnectionIncident("display topology had no valid display; authorization cleared")
            clearAuthorization(notify: authorizedCentralID)
            status = "No valid display remains. Reconnect to continue."
            return
        }
        hidePointerOverlay()
        let centre = CGPoint(x: selected.bounds.midX, y: selected.bounds.midY)
        lastPointedDisplayID = selected.id; pointerDisplayBounds = selected.bounds
        effectivePointerTarget = centre; pointerAnchor = centre
        retainedTargetsByDisplay[selected.id] = centre
        _ = reconcilePointerVisibility()
        status = "The selected display was removed; tracking moved to the current display centre."
    }

    private func press(_ key: RemoteMessage.RemoteKey) {
        let code: CGKeyCode = key == .left ? 123 : 124
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

@MainActor
private final class CalibrationMarkerOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 150, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        panel.hasShadow = true; panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        label.alignment = .center; label.textColor = .white; label.font = .boldSystemFont(ofSize: 15)
        label.maximumNumberOfLines = 2; label.frame = CGRect(x: 8, y: 8, width: 134, height: 48)
        panel.contentView = label
    }

    func show(at cgPoint: CGPoint, label text: String) {
        label.stringValue = "Aim here\n\(text)"
        // Core Graphics screen y grows downward; AppKit global y grows upward from the primary display bottom.
        let primaryTop = CGDisplayBounds(CGMainDisplayID()).maxY
        panel.setFrameOrigin(CGPoint(x: cgPoint.x - panel.frame.width / 2, y: primaryTop - cgPoint.y - panel.frame.height / 2))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// Constant-memory 2D One Euro display filter. It low-passes the derivative first, then uses
/// `cutoff = minCutoff + beta * speed` and `alpha = 1 / (1 + tau / dt)`, where
/// `tau = 1 / (2π cutoff)`. Speed is the magnitude of the filtered XY derivative in Mac
/// points/sec, so both axes share one cutoff. These conservative low-lag constants (12 Hz,
/// 10 Hz, 0.025 Hz per point/sec) are empirically untuned; they are not a measured latency claim.
private struct OneEuroDisplayFilter2D {
    static let minCutoffHz = 12.0
    static let derivativeCutoffHz = 10.0
    static let betaHzPerPointPerSecond = 0.025
    static let longGap: TimeInterval = 0.25

    private var point: CGPoint?
    private var lastTarget: CGPoint?
    private var derivative = CGVector.zero
    private var lastUptime: TimeInterval?

    mutating func reset(to latest: CGPoint? = nil, at uptime: TimeInterval? = nil) {
        point = latest
        lastTarget = latest
        derivative = .zero
        lastUptime = uptime
    }

    mutating func filter(latest: CGPoint, at uptime: TimeInterval) -> CGPoint {
        guard latest.x.isFinite, latest.y.isFinite, uptime.isFinite else {
            reset()
            return latest
        }
        guard let prior = point, let priorTarget = lastTarget, let priorUptime = lastUptime else {
            reset(to: latest, at: uptime)
            return latest
        }
        let dt = uptime - priorUptime
        guard dt.isFinite, dt > 0, dt < Self.longGap else {
            reset(to: latest, at: uptime)
            return latest
        }
        func alpha(cutoff: Double) -> Double {
            let tau = 1 / (2 * Double.pi * cutoff)
            return 1 / (1 + tau / dt)
        }
        let rawDerivative = CGVector(dx: (latest.x - priorTarget.x) / CGFloat(dt), dy: (latest.y - priorTarget.y) / CGFloat(dt))
        guard rawDerivative.dx.isFinite, rawDerivative.dy.isFinite else {
            reset(to: latest, at: uptime)
            return latest
        }
        let derivativeAlpha = CGFloat(alpha(cutoff: Self.derivativeCutoffHz))
        derivative = CGVector(dx: derivative.dx + derivativeAlpha * (rawDerivative.dx - derivative.dx),
                              dy: derivative.dy + derivativeAlpha * (rawDerivative.dy - derivative.dy))
        let speed = hypot(Double(derivative.dx), Double(derivative.dy))
        guard derivative.dx.isFinite, derivative.dy.isFinite, speed.isFinite else {
            reset(to: latest, at: uptime)
            return latest
        }
        let positionAlpha = CGFloat(alpha(cutoff: Self.minCutoffHz + Self.betaHzPerPointPerSecond * speed))
        let filtered = CGPoint(x: prior.x + positionAlpha * (latest.x - prior.x),
                               y: prior.y + positionAlpha * (latest.y - prior.y))
        point = filtered
        lastTarget = latest
        lastUptime = uptime // Stationary callbacks intentionally advance this clock too.
        return filtered
    }
}

private enum EffectMode: String, Codable, CaseIterable, Identifiable {
    case off, trail, rope
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct PointerEffectsConfiguration: Equatable {
    static let minimumRopeNodes = 4
    static let maximumRopeNodesPerStrand = 128
    static let minimumRopeStrands = 1
    static let maximumRopeStrands = 8
    static let maximumRopeNodesTotal = 1_024
    static func maximumRopeNodes(forStrands strands: Int) -> Int {
        min(maximumRopeNodesPerStrand, maximumRopeNodesTotal / max(strands, minimumRopeStrands))
    }

    var mode: EffectMode = .off
    var lifetime = 1.0
    var fade = 0.6
    var scaleDown = 0.6
    var ropeLength = 160.0
    var ropeNodes = 12
    var ropeThickness = 5.0
    var ropeStrands = 2
    var ropeGravity = 600.0
    /// Motion-gated decorative noise strength; zero preserves the pre-turbulence rope behavior.
    var ropeTurbulence = 0.0
    var gaming = false
    var rainbowCycle = 3.0
    static func validated(_ c: PointerEffectsConfiguration) -> PointerEffectsConfiguration {
        var v = c
        v.lifetime = c.lifetime.isFinite ? min(max(c.lifetime, 0.1), 5) : 1
        v.fade = c.fade.isFinite ? min(max(c.fade, 0), v.lifetime) : min(0.6, v.lifetime)
        v.scaleDown = c.scaleDown.isFinite ? min(max(c.scaleDown, 0), v.lifetime) : min(0.6, v.lifetime)
        v.ropeLength = c.ropeLength.isFinite ? min(max(c.ropeLength, 20), 600) : 160
        v.ropeStrands = min(max(c.ropeStrands, minimumRopeStrands), maximumRopeStrands)
        v.ropeNodes = min(max(c.ropeNodes, minimumRopeNodes), maximumRopeNodes(forStrands: v.ropeStrands))
        v.ropeThickness = c.ropeThickness.isFinite ? min(max(c.ropeThickness, 1), 24) : 5
        v.ropeGravity = c.ropeGravity.isFinite ? min(max(c.ropeGravity, 0), 2000) : 600
        v.ropeTurbulence = c.ropeTurbulence.isFinite ? min(max(c.ropeTurbulence, 0), 1) : 0
        v.rainbowCycle = c.rainbowCycle.isFinite ? min(max(c.rainbowCycle, 0.2), 20) : 3
        return v
    }
    var diagnosticsLabel: String {
        let gamingLabel = gaming ? "on" : "off"
        return "effects capture-start configuration: mode=\(mode.title), trail lifetime=\(lifetime)s fade=\(fade)s scale-down=\(scaleDown)s; rope length=\(ropeLength)pt nodes/strand=\(ropeNodes) thickness=\(ropeThickness)pt strands=\(ropeStrands) gravity=\(ropeGravity)pt/s² turbulence=\(ropeTurbulence) (\(ropeNodes * ropeStrands)/\(Self.maximumRopeNodesTotal) total nodes), solver=XPBD-gentle-v4(compact-roots, midpoint-quadratic-rope, max4x5-passes, mass-floor-0.025, axial-damping-x10/y4, deterministic-noise-v3-normalized-arc); gaming rainbow=\(gamingLabel) cycle=\(rainbowCycle)s. Decorative settings only; not proof of rendered performance or gentleness."
    }
}

private enum EffectStrokePathKind {
    case threePointQuadratic
    case midpointQuadraticChain
}
private struct EffectStroke {
    let points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    let pathKind: EffectStrokePathKind
}
private struct VisualSample {
    let point: CGPoint
    let uptime: TimeInterval
    let segment: UInt64
}
private struct RopeChain {
    var points: [CGPoint]
    var velocities: [CGVector]
    /// Per-segment XPBD multipliers. They are restarted for each integration step because the
    /// kinematic head moves; retaining stale tension would inject energy after a direction change.
    var lambdas: [CGFloat]
}

@MainActor
private final class PointerOverlay {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case circle, pointOutline, pointFilled, triangleOutline, triangleFilled, arrowheadOutline, arrowheadFilled, plus
        var id: String { rawValue }
        var title: String {
            switch self {
            case .circle: return "Circle"
            case .pointOutline: return "Point Outline"
            case .pointFilled: return "Point Filled"
            case .triangleOutline: return "Triangle Outline"
            case .triangleFilled: return "Triangle Filled"
            case .arrowheadOutline: return "Arrowhead Outline"
            case .arrowheadFilled: return "Arrowhead Filled"
            case .plus: return "Plus"
            }
        }
    }

    static let defaultsKey = "pointerOverlayShape"
    static let colorDefaultsKey = "pointerOverlayColor"
    static let sizeDefaultsKey = "pointerOverlaySize"
    static let sizeRange = 16.0...160.0
    static var savedShape: Shape {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        // The former `triangle` was outlined; preserve that appearance across upgrades.
        let shape: Shape = raw == "triangle" ? .triangleOutline : (Shape(rawValue: raw) ?? .circle)
        if raw == "triangle" { save(shape) }
        return shape
    }
    static func save(_ shape: Shape) { UserDefaults.standard.set(shape.rawValue, forKey: defaultsKey) }

    static var savedColor: Color {
        let raw = UserDefaults.standard.array(forKey: colorDefaultsKey) ?? []
        let values = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard values.count == 4, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return Color(.sRGB, red: 0, green: 1, blue: 1)
        }
        UserDefaults.standard.set([values[0], values[1], values[2], 1.0], forKey: colorDefaultsKey)
        return Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: 1)
    }
    static func opaque(_ color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return Color(.sRGB, red: 0, green: 1, blue: 1) }
        return Color(.sRGB, red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, opacity: 1)
    }
    static func colorsEqual(_ lhs: Color, _ rhs: Color) -> Bool {
        guard let a = NSColor(opaque(lhs)).usingColorSpace(.sRGB),
              let b = NSColor(opaque(rhs)).usingColorSpace(.sRGB) else { return false }
        return a.redComponent == b.redComponent && a.greenComponent == b.greenComponent &&
               a.blueComponent == b.blueComponent && a.alphaComponent == b.alphaComponent
    }
    static func save(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, 1.0]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        UserDefaults.standard.set(values, forKey: colorDefaultsKey)
    }
    static var savedSize: Double {
        let raw = (UserDefaults.standard.object(forKey: sizeDefaultsKey) as? NSNumber)?.doubleValue ?? 54
        let value = validatedSize(raw)
        UserDefaults.standard.set(value, forKey: sizeDefaultsKey)
        return value
    }
    static func validatedSize(_ value: Double) -> Double {
        guard value.isFinite else { return 54 }
        return min(max(value, sizeRange.lowerBound), sizeRange.upperBound)
    }
    static func saveSize(_ size: Double) { UserDefaults.standard.set(validatedSize(size), forKey: sizeDefaultsKey) }

    var shape: Shape = .circle { didSet { view.shape = shape; resetRopeAnchorsIfNeeded() } }
    var color: Color = Color(.sRGB, red: 0, green: 1, blue: 1) { didSet { view.color = NSColor(Self.opaque(color)) } }
    var size: Double {
        get { storedSize }
        set {
            let value = Self.validatedSize(newValue)
            guard value != storedSize else { return }
            storedSize = value
            view.pointerSize = CGFloat(value)
            resetRopeAnchorsIfNeeded()
            resizePanel()
        }
    }

    private var storedSize = 54.0
    private let view = PointerOverlayView(frame: .zero)
    private let panel: PointerOverlayPanel
    // Keep the macOS-14-only concrete type behind guarded accesses.
    private var modernLink: AnyObject?
    private var cvLink: CVDisplayLink?
    private var cvBridge: PointerDisplayLinkBridge?
    private var generation: UInt64 = 0
    private var isVisible = false
    private var panelOrdered = false
    private var selectedDisplayID: CGDirectDisplayID?
    private var viewport = CGRect.zero
    private var target = CGPoint.zero
    private var displayed = CGPoint.zero
    private var adaptiveSmoothingEnabled = true
    private var smoothing = OneEuroDisplayFilter2D()
    private var lastRenderTimestamp: TimeInterval?
    private var hasDeliveredRenderCallback = false
    var onVisibleRenderCallback: (@MainActor (TimeInterval, Bool) -> Void)?
    private(set) var maximumRenderFrameGap = 0.0
    private var effects = PointerEffectsConfiguration()
    private var samples: [VisualSample] = []
    private var sampleStartIndex = 0
    private var trailSegment: UInt64 = 0
    private var trailNeedsGap = false
    private(set) var trailOverflowCount: UInt64 = 0
    private static let maximumLiveTrailSamples = 8_192
    private var ropes: [RopeChain] = []
    private var currentStrokes: [EffectStroke] = []
    private var lastEffectsUptime: TimeInterval?
    /// The preceding displayed sample is used only to move the decorative anchor through this
    /// callback's bounded substeps. The rendered head itself is always the current displayed point.
    private var previousRopeHead: CGPoint?
    // Cached offsets make each strand's kinematic anchor persistent for its current configuration.
    // They are decorative only: the glyph always uses the unmodified displayed head.
    private var strandAnchorOffsets: [CGFloat] = []
    // A head-speed envelope gates deterministic turbulence and decays to zero while stationary.
    private var ropeTurbulenceEnvelope: CGFloat = 0
    // Rope simulation is validated inside this head-relative safety radius. Trail history is
    // intentionally exempt and remains lifetime-bounded; viewport intersection bounds the panel.
    // The real head is always retained at its unmodified global coordinate.
    private static let maximumDecorationRadius: CGFloat = 1_024

    init() {
        panel = PointerOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Intentionally always-high for presentation windows; not a security or lock-screen guarantee.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = view
        view.color = NSColor(color)
        view.pointerSize = CGFloat(storedSize)
        resizePanel()
    }

    deinit {
        if #available(macOS 14.0, *) { (modernLink as? CADisplayLink)?.invalidate() }
        cvBridge?.deactivate()
        if let cvLink { CVDisplayLinkStop(cvLink) }
    }

    func begin(at point: CGPoint, on displayID: CGDirectDisplayID,
               viewport proposedViewport: CGRect, timestamp: TimeInterval) -> Bool {
        stopDisplayLink()
        generation &+= 1
        guard configureViewport(displayID: displayID, bounds: proposedViewport),
              point.x.isFinite, point.y.isFinite else { return false }
        target = point
        displayed = point
        smoothing.reset(to: point, at: timestamp)
        lastRenderTimestamp = nil
        hasDeliveredRenderCallback = false
        maximumRenderFrameGap = 0
        trailOverflowCount = 0
        isVisible = true
        clearVisualEffects()
        layoutPanel(head: point, strokes: [])
        guard startDisplayLink(on: displayID) else {
            hide()
            return false
        }
        return true
    }

    func updateTarget(_ point: CGPoint, on displayID: CGDirectDisplayID,
                      viewport proposedViewport: CGRect, timestamp: TimeInterval) -> Bool {
        guard isVisible, point.x.isFinite, point.y.isFinite else { return false }
        if selectedDisplayID != displayID || viewport != proposedViewport {
            stopDisplayLink()
            generation &+= 1
            guard configureViewport(displayID: displayID, bounds: proposedViewport),
                  startDisplayLink(on: displayID) else {
                hide()
                return false
            }
            hasDeliveredRenderCallback = false
            lastRenderTimestamp = nil
            layoutPanel(head: displayed, strokes: currentStrokes)
        }
        target = point
        return true
    }

    func setEffectsConfiguration(_ configuration: PointerEffectsConfiguration) {
        let old = effects
        effects = .validated(configuration)
        let ropeChanged = old.ropeLength != effects.ropeLength || old.ropeNodes != effects.ropeNodes ||
            old.ropeStrands != effects.ropeStrands || old.ropeThickness != effects.ropeThickness ||
            old.ropeGravity != effects.ropeGravity || old.ropeTurbulence != effects.ropeTurbulence
        if old.mode != effects.mode || ropeChanged { clearVisualEffects() }
    }
    func clearVisualEffects() {
        samples.removeAll(keepingCapacity: true)
        sampleStartIndex = 0
        trailSegment = 0
        trailNeedsGap = false
        ropes.removeAll(keepingCapacity: true)
        currentStrokes.removeAll(keepingCapacity: true)
        lastEffectsUptime = nil
        previousRopeHead = nil
        strandAnchorOffsets.removeAll(keepingCapacity: true)
        ropeTurbulenceEnvelope = 0
        if !view.effectStrokes.isEmpty { view.effectStrokes = [] }
        if view.headColor != nil { view.headColor = nil }
        layoutPanel(head: displayed, strokes: [])
    }

    func setAdaptiveSmoothingEnabled(_ enabled: Bool) {
        adaptiveSmoothingEnabled = enabled
        smoothing.reset(to: displayed)
    }

    func resetAdaptiveSmoothing() { smoothing.reset(to: target); clearVisualEffects() }

    func hide() {
        generation &+= 1
        isVisible = false
        smoothing.reset()
        clearVisualEffects()
        stopDisplayLink()
        lastRenderTimestamp = nil
        hasDeliveredRenderCallback = false
        selectedDisplayID = nil
        viewport = .zero
        if panelOrdered { panel.orderOut(nil) }
        panelOrdered = false
    }

    private func configureViewport(displayID: CGDirectDisplayID, bounds: CGRect) -> Bool {
        let actual = CGDisplayBounds(displayID)
        guard !actual.isEmpty, !actual.isNull, !actual.isInfinite,
              actual.origin.x.isFinite, actual.origin.y.isFinite,
              actual.width.isFinite, actual.height.isFinite, actual == bounds else { return false }
        selectedDisplayID = displayID
        viewport = actual
        return true
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID && CGDisplayBounds(displayID) == viewport
        }
    }

    private func startDisplayLink(on displayID: CGDirectDisplayID) -> Bool {
        stopDisplayLink()
        if #available(macOS 14.0, *) {
            guard let screen = screen(for: displayID) else { return false }
            let proxy = PointerModernDisplayLinkProxy(owner: self, generation: generation)
            let link = screen.displayLink(target: proxy, selector: #selector(PointerModernDisplayLinkProxy.tick(_:)))
            modernLink = link
            link.add(to: .main, forMode: .common)
            return true
        }

        var candidate: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &candidate) == kCVReturnSuccess, let candidate else { return false }
        let bridge = PointerDisplayLinkBridge(owner: self, generation: generation)
        // The registered block owns the bridge; no raw user-context pointer is freed on stop.
        // The bridge holds its owner weakly and never retains the display link.
        let callbackResult = CVDisplayLinkSetOutputHandler(candidate) { [bridge] _, now, output, _, _ in
            let stamp = output.pointee.hostTime != 0 ? output.pointee : now.pointee
            let seconds = stamp.hostTime == 0 ? ProcessInfo.processInfo.systemUptime : Double(stamp.hostTime) / CVGetHostClockFrequency()
            bridge.requestFrame(timestamp: seconds)
            return kCVReturnSuccess
        }
        guard callbackResult == kCVReturnSuccess, CVDisplayLinkStart(candidate) == kCVReturnSuccess else {
            bridge.deactivate()
            return false
        }
        cvLink = candidate
        cvBridge = bridge
        return true
    }

    private func stopDisplayLink() {
        if #available(macOS 14.0, *) { (modernLink as? CADisplayLink)?.invalidate() }
        modernLink = nil
        cvBridge?.deactivate()
        if let cvLink { CVDisplayLinkStop(cvLink) }
        cvLink = nil
        cvBridge = nil
    }

    @available(macOS 14.0, *)
    fileprivate func displayLinkFired(_ link: CADisplayLink, generation callbackGeneration: UInt64,
                                      actualCallbackUptime callbackUptime: TimeInterval) {
        guard link === modernLink else { return }
        renderFrame(timestamp: link.targetTimestamp, actualCallbackUptime: callbackUptime,
                    generation: callbackGeneration)
    }

    fileprivate func renderFrame(timestamp: TimeInterval, actualCallbackUptime callbackUptime: TimeInterval,
                                 generation callbackGeneration: UInt64) {
        // Actual uptime comes from main callback entry. The supplied timestamp remains only for the
        // older predicted/display-clock max-gap diagnostic and its existing dt guards.
        guard isVisible, callbackGeneration == generation else { return }
        // Presentation timing uses actual main callback uptime, never targetTimestamp or packet time.
        // Disabling is the exact former latest-only path on this very callback, with no filter tail.
        let presentation = adaptiveSmoothingEnabled
            ? smoothing.filter(latest: target, at: callbackUptime)
            : target
        // Effects and Trail history advance from actual displayed positions even while all geometry is
        // outside. The selected-screen link remains active so unbounded reversal can naturally reenter.
        if presentation != displayed { displayed = presentation }
        renderEffects(head: displayed, uptime: callbackUptime)

        // Diagnostics count only callbacks that produced geometry intersecting the selected viewport.
        guard panelOrdered else {
            hasDeliveredRenderCallback = false
            lastRenderTimestamp = nil
            return
        }
        let startsSegment = !hasDeliveredRenderCallback
        hasDeliveredRenderCallback = true
        onVisibleRenderCallback?(callbackUptime, startsSegment)
        // Keep the older display-clock max-gap metric separate and segment it across all-outside time.
        if timestamp.isFinite {
            if let previous = lastRenderTimestamp {
                let dt = timestamp - previous
                if dt.isFinite, dt > 0 { maximumRenderFrameGap = max(maximumRenderFrameGap, dt) }
            }
            lastRenderTimestamp = timestamp
        }
    }

    private func desiredStrandAnchorOffsets() -> [CGFloat] {
        let count = effects.ropeStrands
        guard count > 1 else { return [0] }
        let totalSpan = min(CGFloat(12), CGFloat(storedSize) * 0.12)
        let actualSpacing = totalSpan / CGFloat(count - 1)
        return (0..<count).map { CGFloat($0) * actualSpacing - totalSpan / 2 }
    }

    private func resetRopeAnchorsIfNeeded() {
        let expected = desiredStrandAnchorOffsets()
        guard !strandAnchorOffsets.isEmpty, strandAnchorOffsets != expected else { return }
        // Changing the physical roots cannot retain old-chain position/velocity history safely.
        clearVisualEffects()
    }

    private func renderEffects(head: CGPoint, uptime: TimeInterval) {
        guard uptime.isFinite, head.x.isFinite, head.y.isFinite else { clearVisualEffects(); return }
        let previous = lastEffectsUptime
        let elapsed = previous.map { uptime - $0 }
        let discontinuity = elapsed.map { !$0.isFinite || $0 <= 0 || $0 > 0.25 } ?? false
        if discontinuity {
            samples.removeAll(keepingCapacity: true)
            sampleStartIndex = 0
            if trailSegment < UInt64.max { trailSegment += 1 }
            trailNeedsGap = false
            ropes.removeAll(keepingCapacity: true)
            previousRopeHead = nil
            strandAnchorOffsets.removeAll(keepingCapacity: true)
            ropeTurbulenceEnvelope = 0
        }
        lastEffectsUptime = uptime

        if effects.mode == .off && !effects.gaming {
            if !currentStrokes.isEmpty { currentStrokes.removeAll(keepingCapacity: true); view.effectStrokes = [] }
            if view.headColor != nil { view.headColor = nil }
            layoutPanel(head: head, strokes: [])
            return
        }

        func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
        func decorationAllowed(_ point: CGPoint) -> Bool {
            finite(point) && abs(point.x - head.x) <= Self.maximumDecorationRadius &&
                abs(point.y - head.y) <= Self.maximumDecorationRadius
        }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        var strokes: [EffectStroke] = []

        if effects.mode == .trail {
            // Expiry advances an index instead of repeatedly copying with removeFirst. Samples are
            // never dropped for viewport/head distance and retain their original callback uptimes.
            while sampleStartIndex < samples.count {
                let sample = samples[sampleStartIndex]
                if finite(sample.point), uptime >= sample.uptime,
                   uptime - sample.uptime < effects.lifetime { break }
                sampleStartIndex += 1
            }
            let liveCount = samples.count - sampleStartIndex
            let last = liveCount > 0 ? samples.last : nil
            if last?.point != head {
                if liveCount < Self.maximumLiveTrailSamples {
                    if trailNeedsGap {
                        if trailSegment < UInt64.max { trailSegment += 1 }
                        trailNeedsGap = false
                    }
                    samples.append(VisualSample(point: head, uptime: uptime, segment: trailSegment))
                } else {
                    // Never evict or decimate live history. A later admitted sample begins a new
                    // segment so overflow cannot fabricate one long straight connection.
                    if trailOverflowCount < UInt64.max { trailOverflowCount += 1 }
                    trailNeedsGap = true
                }
            }
            // Amortized compaction bounds backing storage without changing the live time window.
            if sampleStartIndex > 0 &&
                (samples.count >= Self.maximumLiveTrailSamples || sampleStartIndex >= 1_024) {
                samples = Array(samples[sampleStartIndex...])
                sampleStartIndex = 0
            }
            if samples.count - sampleStartIndex > 1 {
                for index in sampleStartIndex..<samples.count {
                    let sample = samples[index]
                    let hasPrevious = index > sampleStartIndex && samples[index - 1].segment == sample.segment
                    let hasNext = index + 1 < samples.count && samples[index + 1].segment == sample.segment
                    guard hasPrevious || hasNext else { continue }
                    let start = hasPrevious ? midpoint(samples[index - 1].point, sample.point) : sample.point
                    let end = hasNext ? midpoint(sample.point, samples[index + 1].point) : sample.point
                    let age = max(0, uptime - sample.uptime)
                    let fadeStart = effects.lifetime - effects.fade
                    let scaleStart = effects.lifetime - effects.scaleDown
                    let alpha = effects.fade > 0 && age >= fadeStart ? max(0, 1 - (age - fadeStart) / effects.fade) : 1
                    let scale = effects.scaleDown > 0 && age >= scaleStart ? max(0, 1 - (age - scaleStart) / effects.scaleDown) : 1
                    let width = max(1, CGFloat(storedSize * 0.12 * scale))
                    if finite(start), finite(end), width.isFinite {
                        strokes.append(EffectStroke(points: [start, sample.point, end],
                                                    color: effectColor(uptime: sample.uptime, alpha: CGFloat(alpha)),
                                                    width: width, pathKind: .threePointQuadratic))
                    }
                }
            }
        } else if effects.mode == .rope {
            let nodeCount = effects.ropeNodes
            let strandCount = effects.ropeStrands
            let rest = CGFloat(effects.ropeLength / Double(nodeCount - 1))
            let expectedOffsets = desiredStrandAnchorOffsets()
            if strandAnchorOffsets != expectedOffsets {
                ropes.removeAll(keepingCapacity: true)
                previousRopeHead = nil
                ropeTurbulenceEnvelope = 0
                strandAnchorOffsets = expectedOffsets
            }
            func strandAnchor(_ baseHead: CGPoint, _ strand: Int) -> CGPoint {
                CGPoint(x: baseHead.x + strandAnchorOffsets[strand], y: baseHead.y)
            }
            func initializedRopes() -> [RopeChain] {
                (0..<strandCount).map { strand in
                    let anchor = strandAnchor(head, strand)
                    let centeredOffset = strandAnchorOffsets[strand]
                    let fan = centeredOffset / max(CGFloat(effects.ropeLength), 1) * 0.18
                    let direction = CGVector(dx: fan, dy: CGFloat(sqrt(Double(max(0, 1 - fan * fan)))))
                    return RopeChain(points: (0..<nodeCount).map { index in
                        CGPoint(x: anchor.x + CGFloat(index) * rest * direction.dx,
                                y: anchor.y + CGFloat(index) * rest * direction.dy)
                    }, velocities: Array(repeating: .zero, count: nodeCount),
                       lambdas: Array(repeating: 0, count: nodeCount - 1))
                }
            }
            if discontinuity || ropes.count != strandCount || ropes.contains(where: {
                $0.points.count != nodeCount || $0.velocities.count != nodeCount ||
                    $0.lambdas.count != nodeCount - 1
            }) {
                ropes = initializedRopes()
                previousRopeHead = head
            }

            // At most 1/30 s is simulated and divided into <=1/120 s steps. A longer-but-valid
            // callback gap discards stale elapsed time rather than replaying an old trajectory.
            // Anchor interpolation uses only the preceding and current displayed samples; the final
            // anchor and rendered head are exact, with no prediction, clamp, or added head latency.
            let rawDT = discontinuity ? 0 : (elapsed ?? 0)
            let dt = min(1.0 / 30.0, max(0, rawDT))
            let anchorStart = previousRopeHead ?? head
            let headSpeed: CGFloat
            if rawDT.isFinite, rawDT > 0, rawDT <= 0.25, finite(anchorStart) {
                headSpeed = min(2_400, hypot(head.x - anchorStart.x, head.y - anchorStart.y) / CGFloat(rawDT))
            } else {
                headSpeed = 0
            }
            // Reach useful activation during ordinary pointer motion rather than reserving most of
            // the control for very fast sweeps. Actual callback dt is admitted only by the guard
            // above; the bounded simulation interval also bounds envelope attack/decay work.
            let targetTurbulenceEnvelope = min(1, headSpeed / 200)
            let envelopeRate: CGFloat = targetTurbulenceEnvelope > ropeTurbulenceEnvelope ? 12 : 4
            ropeTurbulenceEnvelope += (targetTurbulenceEnvelope - ropeTurbulenceEnvelope) *
                (1 - CGFloat(exp(-Double(envelopeRate) * dt)))
            let anchorOffsetBudget = strandAnchorOffsets.map { abs($0) }.max() ?? 0
            var invalid = !rest.isFinite || rest <= 0 || !finite(anchorStart) ||
                !ropeTurbulenceEnvelope.isFinite || anchorOffsetBudget >= Self.maximumDecorationRadius
            if dt > 0 && !invalid {
                let substeps = min(4, max(1, Int(ceil(dt / (1.0 / 120.0)))))
                let step = CGFloat(dt / Double(substeps))
                // Unit line density is normalized to one mass per 16 pt. The 0.025 floor keeps
                // inverse mass finite for the shortest 20/128 geometry: rest is 20/127 ≈ 0.157 pt,
                // so floor density is bounded to about 2.54x nominal rather than clamping geometry
                // or turning a dense chain into a rigid exact-projection whip. Segment compliance is
                // 8e-5 + 2e-6*rest s²/mass (the discrete analogue of axial compliance L/EA).
                let nodeMass = max(rest / 16, 0.025)
                let inverseMass = 1 / nodeMass
                let compliance = CGFloat(0.00008) + CGFloat(0.000002) * rest
                let alpha = compliance / (step * step)
                // Post-projection damping covers constraint-created motion in this same step.
                // Horizontal damping remains strong; lower (but nonzero) vertical damping makes
                // screen-down gravity visibly settle instead of immediately erasing it.
                let postDampingX = CGFloat(exp(-10 * Double(step)))
                let postDampingY = CGFloat(exp(-4 * Double(step)))
                // At full strength/envelope, 1,200 pt/s² is still finite and velocity/radius capped.
                // Against 10/s horizontal damping its force scale is responsive without restoring
                // the former unconstrained strong horizontal impulse behavior.
                let maximumTurbulenceAcceleration: CGFloat = 1_200
                // The decorative budget scales with configured geometry and is intentionally far
                // below the former blind 4,000 pt/s cap.
                let maximumVelocity = max(CGFloat(180), min(CGFloat(1_400),
                    CGFloat(effects.ropeLength) * 2 + rest * 4))
                let maximumSegment = rest * 1.8
                let maximumRadius = min(Self.maximumDecorationRadius - anchorOffsetBudget,
                    CGFloat(effects.ropeLength) * 1.8 + CGFloat(storedSize) + 64)

                for substep in 0..<substeps where !invalid {
                    let fraction = CGFloat(substep + 1) / CGFloat(substeps)
                    let substepHead = CGPoint(x: anchorStart.x + (head.x - anchorStart.x) * fraction,
                                              y: anchorStart.y + (head.y - anchorStart.y) * fraction)
                    guard finite(substepHead) else { invalid = true; break }
                    for strand in ropes.indices {
                        let substepAnchor = strandAnchor(substepHead, strand)
                        guard finite(substepAnchor) else { invalid = true; break }
                        let oldPoints = ropes[strand].points
                        ropes[strand].points[0] = substepAnchor
                        ropes[strand].velocities[0] = .zero
                        ropes[strand].lambdas = Array(repeating: 0, count: nodeCount - 1)
                        for index in 1..<nodeCount {
                            var velocity = ropes[strand].velocities[index]
                            let u = CGFloat(index) / CGFloat(nodeCount - 1)
                            // Normalized arc position fixes spatial frequency as node density changes.
                            // Strand offsets decorrelate chains; two low-ish smooth harmonics remain
                            // deterministic and bounded by their weights' sum.
                            let arcPhase = Double(u) * 2 * Double.pi
                            let strandPhase = Double(strand) * 1.618033988749895
                            let noise = 0.64 * sin(uptime * 3.7 + arcPhase + strandPhase) +
                                0.36 * sin(uptime * 5.3 - arcPhase * 0.55 + strandPhase * 1.37)
                            let tipWeight = u * u
                            let turbulence = CGFloat(noise) * effects.ropeTurbulence * ropeTurbulenceEnvelope *
                                maximumTurbulenceAcceleration * tipWeight
                            // The deterministic, continuous force is non-head-only and motion-gated.
                            velocity.dx += turbulence * step
                            velocity.dy += turbulence * 0.35 * step
                            velocity.dy += CGFloat(effects.ropeGravity) * step
                            let candidate = CGPoint(x: ropes[strand].points[index].x + velocity.dx * step,
                                                    y: ropes[strand].points[index].y + velocity.dy * step)
                            guard finite(candidate), velocity.dx.isFinite, velocity.dy.isFinite else {
                                invalid = true; break
                            }
                            ropes[strand].points[index] = candidate
                        }

                        // Compliant XPBD distance constraints replace the former repeated exact
                        // forward projection. Equal free-node masses and a zero-mass kinematic head
                        // distribute corrections in both directions without feeding force to head.
                        for _ in 0..<5 where !invalid {
                            ropes[strand].points[0] = substepAnchor
                            for index in 1..<nodeCount {
                                var dx = ropes[strand].points[index].x - ropes[strand].points[index - 1].x
                                var dy = ropes[strand].points[index].y - ropes[strand].points[index - 1].y
                                var distance = hypot(dx, dy)
                                guard dx.isFinite, dy.isFinite, distance.isFinite else { invalid = true; break }
                                if distance < 0.0001 {
                                    let angle = Double(strand * nodeCount + index) * 2.399963229728653
                                    dx = CGFloat(cos(angle)); dy = CGFloat(sin(angle)); distance = 1
                                }
                                let weightA: CGFloat = index == 1 ? 0 : inverseMass
                                let denominator = weightA + inverseMass + alpha
                                guard denominator.isFinite, denominator > 0 else { invalid = true; break }
                                let deltaLambda = (-(distance - rest) - alpha * ropes[strand].lambdas[index - 1]) /
                                    denominator
                                guard deltaLambda.isFinite else { invalid = true; break }
                                ropes[strand].lambdas[index - 1] += deltaLambda
                                let nx = dx / distance, ny = dy / distance
                                if weightA > 0 {
                                    ropes[strand].points[index - 1].x -= weightA * deltaLambda * nx
                                    ropes[strand].points[index - 1].y -= weightA * deltaLambda * ny
                                }
                                ropes[strand].points[index].x += inverseMass * deltaLambda * nx
                                ropes[strand].points[index].y += inverseMass * deltaLambda * ny
                            }
                        }
                        if invalid { break }

                        // One forward safety pass bounds pathological stretch; ordinary motion is
                        // governed by the compliant solve above, not repeated hard projection.
                        ropes[strand].points[0] = substepAnchor
                        for index in 1..<nodeCount {
                            let anchor = ropes[strand].points[index - 1]
                            let dx = ropes[strand].points[index].x - anchor.x
                            let dy = ropes[strand].points[index].y - anchor.y
                            let distance = hypot(dx, dy)
                            guard distance.isFinite, finite(ropes[strand].points[index]) else {
                                invalid = true; break
                            }
                            if distance > maximumSegment {
                                ropes[strand].points[index] = CGPoint(x: anchor.x + dx / distance * maximumSegment,
                                                                     y: anchor.y + dy / distance * maximumSegment)
                            }
                            let radius = hypot(ropes[strand].points[index].x - substepAnchor.x,
                                               ropes[strand].points[index].y - substepAnchor.y)
                            guard radius.isFinite, radius <= maximumRadius else { invalid = true; break }
                        }
                        if invalid { break }

                        for index in 1..<nodeCount {
                            var velocity = CGVector(
                                dx: (ropes[strand].points[index].x - oldPoints[index].x) / step * postDampingX,
                                dy: (ropes[strand].points[index].y - oldPoints[index].y) / step * postDampingY)
                            let speed = hypot(velocity.dx, velocity.dy)
                            guard speed.isFinite else { invalid = true; break }
                            if speed > maximumVelocity {
                                let ratio = maximumVelocity / speed
                                velocity.dx *= ratio; velocity.dy *= ratio
                            }
                            ropes[strand].velocities[index] = velocity
                        }
                    }
                }
            }
            previousRopeHead = head
            for strand in ropes.indices {
                ropes[strand].points[0] = strandAnchor(head, strand)
                ropes[strand].velocities[0] = .zero
            }
            if invalid {
                ropes = initializedRopes()
                previousRopeHead = head
            }
            for chain in ropes where chain.points.allSatisfy(decorationAllowed) {
                strokes.append(EffectStroke(points: chain.points, color: effectColor(uptime: uptime, alpha: 0.85),
                                            width: CGFloat(effects.ropeThickness), pathKind: .midpointQuadraticChain))
            }
        }

        currentStrokes = strokes
        view.effectStrokes = strokes
        view.headColor = effects.gaming ? effectColor(uptime: uptime, alpha: 1) : nil
        layoutPanel(head: head, strokes: strokes)
    }
    private func effectColor(uptime: TimeInterval, alpha: CGFloat) -> NSColor {
        guard effects.gaming else { return NSColor(Self.opaque(color)).withAlphaComponent(alpha) }
        let hue = (uptime/effects.rainbowCycle).truncatingRemainder(dividingBy: 1)
        return NSColor(calibratedHue: hue < 0 ? hue+1 : hue, saturation: 0.9, brightness: 1, alpha: alpha)
    }

    private func resizePanel() {
        layoutPanel(head: displayed, strokes: currentStrokes)
    }

    private func layoutPanel(head: CGPoint, strokes: [EffectStroke]) {
        guard isVisible else {
            if panelOrdered { panel.orderOut(nil) }
            panelOrdered = false
            return
        }
        guard head.x.isFinite, head.y.isFinite, !viewport.isEmpty else { return }
        let pointerSize = CGFloat(storedSize)
        let headStroke = max(2, min(8, pointerSize * 0.1))
        // Includes the longest glyph miter plus antialiasing. The head remains at its true coordinate.
        let headMargin = max(12, pointerSize * 0.16, headStroke * 2.4 + 6)
        let headRadius = pointerSize / 2 + headMargin
        let headBounds = CGRect(x: head.x - headRadius, y: head.y - headRadius,
                                width: headRadius * 2, height: headRadius * 2)
        guard !headBounds.isNull, !headBounds.isInfinite else { return }
        var intersectingBounds: CGRect? = headBounds.intersects(viewport) ? headBounds : nil
        for stroke in strokes where stroke.width.isFinite && stroke.width > 0 && stroke.points.count > 1 {
            let margin = stroke.width / 2 + 3
            guard stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            // Every actual quadratic endpoint/control participates. A quadratic lies inside its
            // control hull, so this is conservative even when both endpoints are outside.
            var strokeBounds = CGRect(x: stroke.points[0].x - margin,
                                      y: stroke.points[0].y - margin,
                                      width: margin * 2, height: margin * 2)
            for point in stroke.points.dropFirst() {
                strokeBounds = strokeBounds.union(CGRect(x: point.x - margin, y: point.y - margin,
                                                         width: margin * 2, height: margin * 2))
            }
            if !strokeBounds.isNull, !strokeBounds.isInfinite, strokeBounds.intersects(viewport) {
                intersectingBounds = intersectingBounds.map { $0.union(strokeBounds) } ?? strokeBounds
            }
        }
        view.globalHead = head
        guard let drawableBounds = intersectingBounds else {
            if panelOrdered { panel.orderOut(nil) }
            panelOrdered = false
            return
        }
        let clippedBounds = drawableBounds.integral.intersection(viewport)
        guard !clippedBounds.isNull, !clippedBounds.isEmpty, !clippedBounds.isInfinite,
              clippedBounds.width.isFinite, clippedBounds.height.isFinite else {
            if panelOrdered { panel.orderOut(nil) }
            panelOrdered = false
            return
        }
        let primaryTop = CGDisplayBounds(CGMainDisplayID()).maxY
        let appKitFrame = CGRect(x: clippedBounds.minX, y: primaryTop - clippedBounds.maxY,
                                 width: clippedBounds.width, height: clippedBounds.height)
        view.globalBounds = clippedBounds
        if view.frame.size != clippedBounds.size { view.frame = CGRect(origin: .zero, size: clippedBounds.size) }
        if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: false) }
        if !panelOrdered {
            panel.orderFrontRegardless()
            panelOrdered = true
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class PointerModernDisplayLinkProxy: NSObject {
    private weak var owner: PointerOverlay?
    private let generation: UInt64

    init(owner: PointerOverlay, generation: UInt64) {
        self.owner = owner
        self.generation = generation
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        owner?.displayLinkFired(link, generation: generation, actualCallbackUptime: callbackUptime)
    }
}

private final class PointerDisplayLinkBridge: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: PointerOverlay?
    private let generation: UInt64
    private var active = true
    private var frameEnqueued = false

    init(owner: PointerOverlay, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    func requestFrame(timestamp: TimeInterval) {
        lock.lock()
        guard active, !frameEnqueued else { lock.unlock(); return }
        frameEnqueued = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.deliver(timestamp: timestamp) }
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    @MainActor private func deliver(timestamp: TimeInterval) {
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        frameEnqueued = false
        let shouldDeliver = active
        lock.unlock()
        if shouldDeliver {
            owner?.renderFrame(timestamp: timestamp, actualCallbackUptime: callbackUptime,
                               generation: generation)
        }
    }
}

private final class PointerOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PointerOverlayView: NSView {
    var shape: PointerOverlay.Shape = .circle { didSet { if oldValue != shape { needsDisplay = true } } }
    var color: NSColor = .systemCyan { didSet { if !oldValue.isEqual(color) { needsDisplay = true } } }
    var pointerSize: CGFloat = 54 { didSet { if oldValue != pointerSize { needsDisplay = true } } }
    var globalHead = CGPoint.zero { didSet { if oldValue != globalHead { needsDisplay = true } } }
    var globalBounds = CGRect.zero { didSet { if oldValue != globalBounds { needsDisplay = true } } }
    var centersHeadInBounds = false { didSet { if oldValue != centersHeadInBounds { needsDisplay = true } } }
    var headColor: NSColor? { didSet { needsDisplay = true } }
    var effectStrokes: [EffectStroke] = [] { didSet { needsDisplay = true } }

    override func layout() {
        super.layout()
        if centersHeadInBounds { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Transparent backing stores retain pixels: clear the dirty area before any effect or head paint.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        // The panel is only the drawable/selected-viewport intersection; this is the final explicit
        // paint clip for partially visible glyphs and curves.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.clip(to: bounds)

        let stroke = max(2, min(8, pointerSize * 0.1))
        // CG global y is screen-down; AppKit local y is up, including displays with negative origins.
        let local: (CGPoint) -> CGPoint = { point in
            CGPoint(x: point.x - self.globalBounds.minX, y: self.globalBounds.maxY - point.y)
        }
        let localHead = centersHeadInBounds
            ? CGPoint(x: bounds.midX, y: bounds.midY)
            : local(globalHead)
        // The glyph remains centered on the true unbounded head; clipping never relocates it.
        let glyphRect = CGRect(x: localHead.x - pointerSize / 2, y: localHead.y - pointerSize / 2,
                               width: pointerSize, height: pointerSize)
        func intersectsPanel(_ effect: EffectStroke) -> Bool {
            guard effect.points.count > 1, effect.width.isFinite, effect.width > 0,
                  effect.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            let margin = effect.width / 2 + 3
            var result = CGRect(x: effect.points[0].x - margin, y: effect.points[0].y - margin,
                                width: margin * 2, height: margin * 2)
            for point in effect.points.dropFirst() {
                result = result.union(CGRect(x: point.x - margin, y: point.y - margin,
                                             width: margin * 2, height: margin * 2))
            }
            return !result.isNull && !result.isInfinite && result.intersects(globalBounds)
        }
        // Cull whole paths only. Never remove outside control nodes and splice a different curve.
        for effect in effectStrokes where intersectsPanel(effect) {
            NSGraphicsContext.saveGraphicsState()
            let line = NSBezierPath()
            func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            func appendQuadratic(from start: CGPoint, control: CGPoint, to end: CGPoint) {
                let control1 = CGPoint(x: start.x + (control.x - start.x) * 2 / 3,
                                       y: start.y + (control.y - start.y) * 2 / 3)
                let control2 = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                       y: end.y + (control.y - end.y) * 2 / 3)
                line.curve(to: end, controlPoint1: control1, controlPoint2: control2)
            }
            switch effect.pathKind {
            case .threePointQuadratic:
                let start = local(effect.points[0]), control = local(effect.points[1]), end = local(effect.points[2])
                line.move(to: start)
                appendQuadratic(from: start, control: control, to: end)
            case .midpointQuadraticChain:
                let first = local(effect.points[0])
                line.move(to: first)
                if effect.points.count == 2 {
                    line.line(to: local(effect.points[1]))
                } else {
                    var segmentStart = first
                    for index in 1..<(effect.points.count - 1) {
                        let control = local(effect.points[index])
                        let end = index == effect.points.count - 2
                            ? local(effect.points[effect.points.count - 1])
                            : midpoint(control, local(effect.points[index + 1]))
                        appendQuadratic(from: segmentStart, control: control, to: end)
                        segmentStart = end
                    }
                }
            }
            effect.color.setStroke()
            line.lineWidth = effect.width
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            line.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        let path: NSBezierPath
        let filled: Bool
        switch shape {
        case .circle:
            path = NSBezierPath(ovalIn: glyphRect)
            filled = false
        case .pointOutline, .pointFilled:
            let diameter = pointerSize * 0.35
            path = NSBezierPath(ovalIn: CGRect(x: localHead.x - diameter / 2, y: localHead.y - diameter / 2, width: diameter, height: diameter))
            filled = shape == .pointFilled
        case .triangleOutline, .triangleFilled:
            path = trianglePath(in: glyphRect)
            filled = shape == .triangleFilled
        case .arrowheadOutline, .arrowheadFilled:
            path = arrowheadPath(in: glyphRect)
            filled = shape == .arrowheadFilled
        case .plus:
            path = NSBezierPath()
            path.move(to: CGPoint(x: glyphRect.midX, y: glyphRect.minY))
            path.line(to: CGPoint(x: glyphRect.midX, y: glyphRect.maxY))
            path.move(to: CGPoint(x: glyphRect.minX, y: glyphRect.midY))
            path.line(to: CGPoint(x: glyphRect.maxX, y: glyphRect.midY))
            filled = false
        }

        // Head paint has its own state so tail alpha, width, joins, and stroke color cannot leak.
        NSGraphicsContext.saveGraphicsState()
        let sharp = shape == .triangleOutline || shape == .triangleFilled ||
                    shape == .arrowheadOutline || shape == .arrowheadFilled
        path.lineCapStyle = sharp ? .butt : .round
        path.lineJoinStyle = sharp ? .miter : .round
        path.miterLimit = sharp ? 14 : 10
        let chosenColor = (headColor ?? color).withAlphaComponent(1)
        if filled {
            chosenColor.setFill()
            path.fill()
        } else {
            chosenColor.setStroke()
            path.lineWidth = stroke
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func trianglePath(in rect: CGRect) -> NSBezierPath {
        // Deliberately narrow, sharp, diagonal isosceles silhouette with a slightly longer 22° apex.
        let halfWidthRatio = tan(CGFloat(11 * Double.pi / 180))
        let axisLength = rect.width * sqrt(2) / (1 + 2 * halfWidthRatio)
        let (u, v) = diagonalAxes()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let tip = offset(centre, along: u, by: axisLength / 2)
        let base = offset(centre, along: u, by: -axisLength / 2)
        let halfWidth = axisLength * halfWidthRatio
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: offset(base, along: v, by: halfWidth))
        path.line(to: offset(base, along: v, by: -halfWidth))
        path.close()
        return path
    }

    private func arrowheadPath(in rect: CGRect) -> NSBezierPath {
        // A shaftless four-corner arrowhead. The forward rear notch makes this concave and
        // visibly different from the plain triangular silhouette.
        let axisLength = rect.width * 0.76
        let halfWidth = rect.width * 0.23
        let (u, v) = diagonalAxes()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let tip = offset(centre, along: u, by: axisLength * 0.54)
        let rear = offset(centre, along: u, by: -axisLength * 0.46)
        let notch = offset(centre, along: u, by: -axisLength * 0.08)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: offset(rear, along: v, by: halfWidth))
        path.line(to: notch)
        path.line(to: offset(rear, along: v, by: -halfWidth))
        path.close()
        return path
    }

    private func diagonalAxes() -> (CGVector, CGVector) {
        (CGVector(dx: -1 / sqrt(2), dy: 1 / sqrt(2)),
         CGVector(dx: 1 / sqrt(2), dy: 1 / sqrt(2)))
    }

    private func offset(_ point: CGPoint, along vector: CGVector, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + vector.dx * distance, y: point.y + vector.dy * distance)
    }
}

private struct PointerOverlayReference: NSViewRepresentable {
    let shape: PointerOverlay.Shape
    let color: Color
    let size: Double

    func makeNSView(context: Context) -> PointerOverlayView {
        let view = PointerOverlayView(frame: .zero)
        view.centersHeadInBounds = true
        return view
    }
    func updateNSView(_ view: PointerOverlayView, context: Context) {
        if view.shape != shape { view.shape = shape }
        let normalizedColor = NSColor(PointerOverlay.opaque(color))
        if !view.color.isEqual(normalizedColor) { view.color = normalizedColor }
        let normalizedSize = CGFloat(PointerOverlay.validatedSize(size))
        if view.pointerSize != normalizedSize { view.pointerSize = normalizedSize }
    }
}

private enum ReceiverTheme {
    static let canvas = Color(red: 0.035, green: 0.06, blue: 0.11)
    static let surface = Color(red: 0.08, green: 0.12, blue: 0.19)
    static let teal = Color(red: 0.18, green: 0.80, blue: 0.72)
    static let violet = Color(red: 0.62, green: 0.48, blue: 0.93)
}

struct MacReceiverView: View {
    @EnvironmentObject private var model: MacReceiverModel
    @State private var forgetAllConfirmationPresented = false
    @State private var jitterDiagnosticsPresented = false
    @State private var connectionDiagnosticsPresented = false
    @State private var effectsPresented = false
    @State private var presetsPresented = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Pointer Remote Receiver").font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Label(model.approved ? "Approved" : "Idle", systemImage: model.approved ? "checkmark.shield.fill" : "circle")
                    .foregroundStyle(model.approved ? ReceiverTheme.teal : .white.opacity(0.7))
            }
            // Explicit clearance protects the native traffic lights in the hidden-titlebar window.
            .padding(.top, 32)
            Text(model.status).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.white.opacity(0.84))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(ReceiverTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Pointer Sensitivity") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("X").frame(width: 16)
                                Slider(value: Binding(get: { model.sensitivityX }, set: { model.setSensitivityX($0) }), in: PointerSensitivity.minimum...PointerSensitivity.maximum)
                                Text("\(Int(model.sensitivityX))").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                            HStack {
                                Text("Y").frame(width: 16)
                                Slider(value: Binding(get: { model.sensitivityY }, set: { model.setSensitivityY($0) }), in: PointerSensitivity.minimum...PointerSensitivity.maximum)
                                Text("\(Int(model.sensitivityY))").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                            Text("Saved independently on this Mac. Changes adopt at the next accepted cumulative sample without moving the current logical target or rescaling historical displacement. Raising the maximum does not guarantee a drift/stutter cure.")
                                .font(.footnote).foregroundStyle(.white.opacity(0.7))
                            if let summary = model.calibrationSummary { Text(summary).font(.footnote).foregroundStyle(ReceiverTheme.teal) }
                        }.padding(4)
                    }
                    .disabled(model.transportActionPending)
                    GroupBox("Pointer Appearance") {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("Shape", selection: $model.pointerShape) {
                                    ForEach(PointerOverlay.Shape.allCases) { Text($0.title).tag($0) }
                                }.pickerStyle(.menu)
                                ColorPicker("Color", selection: Binding(get: { model.pointerColor }, set: { model.setPointerColor($0) }), supportsOpacity: false)
                                HStack {
                                    Text("Size")
                                    Slider(value: Binding(get: { model.pointerSize }, set: { model.setPointerSize($0) }), in: 16...160)
                                    Text("\(Int(model.pointerSize)) pt").monospacedDigit().frame(width: 52)
                                }
                                Toggle("Adaptive smoothing", isOn: $model.adaptiveSmoothingEnabled)
                                    .disabled(model.smoothingControlDisabled)
                                HStack {
                                    Button("Effects…") { effectsPresented = true }.controlSize(.small)
                                    Button("Presets…") { presetsPresented = true }.controlSize(.small)
                                }
                                Text("Reduces jitter; may add tracking lag. No prediction or buffered playback.")
                                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                            }
                            VStack(spacing: 4) {
                                PointerOverlayReference(shape: model.pointerShape, color: model.pointerColor, size: model.pointerSize)
                                    .frame(width: 220, height: 220)
                                    .background(ReceiverTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                                Text("Head preview (actual size; effects shown on pointer)").font(.caption).foregroundStyle(.white.opacity(0.75))
                            }
                        }.padding(4).frame(maxHeight: .infinity, alignment: .center)
                    }.frame(maxHeight: .infinity, alignment: .center)
                    HStack {
                        Image(systemName: model.accessibility ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        Text(model.accessibility ? "Accessibility allowed" : "Accessibility not allowed")
                        Spacer()
                        Button("Refresh") { model.refreshAccessibility() }
                        Button("Allow") { model.requestAccessibility() }
                    }.foregroundStyle(model.accessibility ? ReceiverTheme.teal : .orange)
                        .padding(.vertical, 4)
                    Text("The head-only preview uses the AppKit head renderer at 1:1 points. Tail, Rope, and Gaming animation appear only on the remote pointer; the preview never shows, focuses, or reorders that overlay.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 10) {
                    GroupBox("Connection") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Received valid motion: \(model.receivedValidMotionPerSecond)/s").monospacedDigit()
                            Button("Jitter Diagnostics…") { jitterDiagnosticsPresented = true }
                                .controlSize(.small)
                            Button("Connection Diagnostics…") { connectionDiagnosticsPresented = true }
                                .controlSize(.small)
                            Button(model.receivingEnabled ? "Stop Receiving" : "Resume Receiving") { model.receivingEnabled ? model.stopReceiving() : model.resumeReceiving() }
                                .buttonStyle(MaterialReceiverButtonStyle(accent: model.receivingEnabled ? .red : ReceiverTheme.teal))
                            if let name = model.pendingApprovalName {
                                Text("Approve iPhone \(name.prefix(8))?")
                                Toggle("Remember this iPhone", isOn: $model.rememberPendingPhone)
                                HStack { Button("Approve") { model.approvePendingConnection() }; Button("Reject") { model.rejectPendingConnection() } }
                                    .buttonStyle(MaterialReceiverButtonStyle(accent: ReceiverTheme.teal, foreground: ReceiverTheme.canvas))
                            }
                        }.padding(4)
                    }
                    .disabled(model.transportActionPending)
                    GroupBox("Trusted iPhones") {
                        VStack(alignment: .leading, spacing: 7) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    if model.trustedPhoneIDs.isEmpty { Text("No remembered iPhones.").foregroundStyle(.secondary) }
                                    ForEach(model.trustedPhoneIDs, id: \.self) { id in
                                        HStack { Text(id.uuidString.prefix(8)); Spacer(); Button("Forget") { model.forgetTrustedPhone(id) } }
                                    }
                                }
                            }.frame(minHeight: 84, maxHeight: .infinity)
                            Button("Forget All iPhones…", role: .destructive) { forgetAllConfirmationPresented = true }
                                .buttonStyle(MaterialReceiverButtonStyle(accent: .red))
                            Text("Removes app approvals only, hides the pointer, and pauses receiving. Sensitivity and appearance remain saved.")
                                .font(.footnote).foregroundStyle(.white.opacity(0.7))
                        }
                    }.frame(maxHeight: .infinity, alignment: .top)
                        .disabled(model.transportActionPending)
                    Text("Bluetooth pairing and approval are separate. The overlay needs no Accessibility; arrow keys do.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 4)
                }
                .frame(width: 270)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 20).padding(.bottom, 18)
        .frame(width: 880, height: 660, alignment: .top)
        .background(ReceiverTheme.canvas)
        .preferredColorScheme(.dark)
        .alert("Forget all iPhones?", isPresented: $forgetAllConfirmationPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Forget All iPhones", role: .destructive) { model.forgetAllTrustedPhones() }
        } message: {
            Text("This permanently removes Pointer Remote's remembered iPhone approvals, ends the current session, hides the pointer, and pauses receiving. Resume Receiving allows a fresh explicit approval. System Bluetooth pairing and pointer settings are unchanged.")
        }
        .sheet(isPresented: $jitterDiagnosticsPresented) {
            JitterDiagnosticsSheet().environmentObject(model)
        }
        .sheet(isPresented: $connectionDiagnosticsPresented) {
            ConnectionDiagnosticsSheet().environmentObject(model)
        }
        .sheet(isPresented: $effectsPresented) { EffectsSheet(initial: model.effectsConfiguration).environmentObject(model) }
        .sheet(isPresented: $presetsPresented) { AppearancePresetsSheet().environmentObject(model) }
        .onAppear { model.refreshAccessibility() }
    }
}

private struct AppearancePresetsSheet: View {
    @EnvironmentObject private var model: MacReceiverModel
    @Environment(\.dismiss) private var dismiss
    @State private var editorPresented = false
    @State private var overwritePresented = false
    @State private var deletePresented = false
    @State private var editingSlot = PresetSlot.allCases[0]
    @State private var editingName = ""
    @State private var renaming = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Appearance Presets").font(.title2.bold())
                Spacer()
                Text(selectionLabel).foregroundStyle(ReceiverTheme.teal)
                Button("Done") { dismiss() }
            }
            Text("Six fixed slots are saved only on this Mac. Applying a preset changes appearance without recentering or restarting tracking.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(PresetSlot.allCases) { slot in
                HStack {
                    Text("\(slot.displayNumber)").monospacedDigit().frame(width: 20)
                    Text(model.presetName(for: slot) ?? "Empty").frame(maxWidth: .infinity, alignment: .leading)
                    if model.selectedPresetSlot == slot { Image(systemName: "checkmark.circle.fill").foregroundStyle(ReceiverTheme.teal) }
                    Button("Apply") { _ = model.applyPreset(slot) }
                        .disabled(!model.presetIsOccupied(slot) || model.presetControlsDisabled)
                    Button("Save Current…") { beginEditor(slot: slot, rename: false) }
                        .disabled(model.presetControlsDisabled)
                    Button("Rename…") { beginEditor(slot: slot, rename: true) }
                        .disabled(!model.presetIsOccupied(slot) || model.presetControlsDisabled)
                    Button("Delete…", role: .destructive) { editingSlot = slot; deletePresented = true }
                        .disabled(!model.presetIsOccupied(slot) || model.presetControlsDisabled)
                }
                Divider()
            }
            if let validationMessage { Text(validationMessage).font(.footnote).foregroundStyle(.orange) }
            if model.presetControlsDisabled {
                Text("Preset changes are unavailable during calibration or while diagnostics is starting, active, or finalizing.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(18).frame(width: 720, height: 440).preferredColorScheme(.dark)
        .alert(renaming ? "Rename Preset" : "Save Current Appearance", isPresented: $editorPresented) {
            TextField("Preset name", text: $editingName)
            Button("Cancel", role: .cancel) { }
            Button(renaming ? "Rename" : "Continue") { submitEditor() }
        } message: {
            Text("Names use at most 32 Unicode characters and 96 UTF-8 bytes, with no line breaks or control characters.")
        }
        .alert("Overwrite slot \(editingSlot.displayNumber)?", isPresented: $overwritePresented) {
            Button("Cancel", role: .cancel) { }
            Button("Overwrite", role: .destructive) {
                _ = model.saveCurrentPreset(editingSlot, rawName: editingName, overwrite: true)
            }
        } message: {
            Text("Replace \(model.presetName(for: editingSlot) ?? "this preset") with the current Mac appearance named \(editingName)?")
        }
        .alert("Delete preset?", isPresented: $deletePresented) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { _ = model.deletePreset(editingSlot) }
        } message: {
            Text("Delete \(model.presetName(for: editingSlot) ?? "this preset") from slot \(editingSlot.displayNumber)? Appearance settings remain unchanged.")
        }
    }

    private var selectionLabel: String {
        guard let slot = model.selectedPresetSlot, let name = model.presetName(for: slot) else { return "Custom" }
        return name
    }

    private func beginEditor(slot: PresetSlot, rename: Bool) {
        editingSlot = slot; renaming = rename
        editingName = model.presetName(for: slot) ?? ""
        validationMessage = nil; editorPresented = true
    }

    private func submitEditor() {
        guard let canonical = PresetName(editingName) else {
            validationMessage = "Enter a valid bounded single-line name."
            return
        }
        editingName = canonical.value
        if renaming {
            if !model.renamePreset(editingSlot, rawName: canonical.value) { validationMessage = "Rename was not applied." }
        } else if model.presetIsOccupied(editingSlot) {
            overwritePresented = true
        } else if !model.saveCurrentPreset(editingSlot, rawName: canonical.value, overwrite: false) {
            validationMessage = "Preset was not saved."
        }
    }
}

private struct EffectsSheet: View {
    @EnvironmentObject private var model: MacReceiverModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PointerEffectsConfiguration
    @State private var applyRejected = false

    init(initial: PointerEffectsConfiguration) {
        _draft = State(initialValue: PointerEffectsConfiguration.validated(initial))
    }

    private func binding<T>(_ key: WritableKeyPath<PointerEffectsConfiguration, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: key] }, set: { value in
            var changed = draft
            changed[keyPath: key] = value
            draft = PointerEffectsConfiguration.validated(changed)
            applyRejected = false
        })
    }
    private func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
    var body: some View {
        let c = draft
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Effects").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    if model.setEffectsConfiguration(draft) { dismiss() } else { applyRejected = true }
                }.keyboardShortcut(.defaultAction).disabled(model.effectsControlDisabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Tail mode", selection: binding(\.mode)) { ForEach(EffectMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    if c.mode == .trail { trailControls(c) }
                    if c.mode == .rope { ropeControls(c) }
                    GroupBox("Gaming") { VStack(alignment: .leading) {
                        Toggle("Rainbow head and effect colors", isOn: binding(\.gaming))
                        Slider(value: binding(\.rainbowCycle), in: 0.2...20)
                        Text("Rainbow cycle duration (lower is faster): " + decimal(c.rainbowCycle) + " seconds")
                    } }
                    Text("Decorative bounded displayed-head history only; it never replays or changes the pointer head. Off has no tail/rope, but Gaming can still animate the head.").font(.footnote).foregroundStyle(.secondary)
                    if model.effectsControlDisabled || applyRejected {
                        Text("Effects cannot be applied while diagnostics are starting, active, or finalizing. Your local draft is retained.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
        }.padding(18).frame(width: 540, height: 520).preferredColorScheme(.dark)
    }
    @ViewBuilder private func trailControls(_ c: PointerEffectsConfiguration) -> some View {
        GroupBox("Trail") { VStack(alignment: .leading) {
            Slider(value: binding(\.lifetime), in: 0.1...5); Text("Vanish lifetime: " + decimal(c.lifetime) + " seconds")
            Slider(value: binding(\.fade), in: 0...c.lifetime); Text("Fade duration: final " + decimal(c.fade) + " seconds of lifetime")
            Slider(value: binding(\.scaleDown), in: 0...c.lifetime); Text("Scale-down duration: final " + decimal(c.scaleDown) + " seconds (zero steps at vanish)")
        } }
    }
    @ViewBuilder private func ropeControls(_ c: PointerEffectsConfiguration) -> some View {
        GroupBox("Rope") { VStack(alignment: .leading) {
            Slider(value: binding(\.ropeLength), in: 20...600); Text("Length " + String(Int(c.ropeLength)) + " pt; segment " + decimal(c.ropeLength / Double(max(1, c.ropeNodes - 1))) + " pt")
            Stepper("Nodes per strand: " + String(c.ropeNodes), value: binding(\.ropeNodes),
                    in: PointerEffectsConfiguration.minimumRopeNodes...PointerEffectsConfiguration.maximumRopeNodes(forStrands: c.ropeStrands))
            Slider(value: binding(\.ropeThickness), in: 1...24); Text("Thickness " + decimal(c.ropeThickness) + " pt")
            Stepper("Strands: " + String(c.ropeStrands), value: binding(\.ropeStrands),
                    in: PointerEffectsConfiguration.minimumRopeStrands...PointerEffectsConfiguration.maximumRopeStrands)
            Slider(value: binding(\.ropeGravity), in: 0...2000); Text("Screen-down gravity " + String(Int(c.ropeGravity)) + " pt/s² — " + String(c.ropeNodes*c.ropeStrands) + "/" + String(PointerEffectsConfiguration.maximumRopeNodesTotal) + " total-node budget")
            Slider(value: binding(\.ropeTurbulence), in: 0...1)
            Text("Turbulence strength: " + String(Int((c.ropeTurbulence * 100).rounded())) + "% (0 off, 100 strongest). Changes take effect only when you choose Apply.")
        } }
    }
}

private struct ConnectionDiagnosticsSheet: View {
    @EnvironmentObject private var model: MacReceiverModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection Diagnostics").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("The newest 16 low-frequency incidents are retained across resets and relaunches. Each is bounded to 2,048 characters (not a byte guarantee). Central identifiers, names, payloads, and NSError userInfo are not stored.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Copy Diagnostics") { model.copyConnectionDiagnostics() }
                Button("Clear", role: .destructive) { model.clearConnectionDiagnostics() }
                Spacer()
            }
            ScrollView {
                Text(model.connectionDiagnostics.isEmpty
                     ? "No connection incidents recorded."
                     : model.connectionDiagnostics.reversed().joined(separator: "\n\n—\n\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(ReceiverTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(width: 700, height: 540)
        .preferredColorScheme(.dark)
    }
}

private struct JitterDiagnosticsSheet: View {
    @EnvironmentObject private var model: MacReceiverModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jitter Diagnostics").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(model.jitterDiagnosticsStatus)
                .foregroundStyle(model.jitterDiagnosticsActive ? ReceiverTheme.teal : .secondary)
            Text("Receive timing continues while permission is off or geometry is outside. Render timing and receive age are sampled only at display-link callbacks with selected-viewport-intersecting geometry.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                if model.jitterDiagnosticsActive {
                    Button("Stop and Finalize") { model.stopJitterDiagnostics() }
                        .buttonStyle(MaterialReceiverButtonStyle(accent: .red))
                } else {
                    Button("Start 20-Second Capture") { model.startJitterDiagnostics() }
                        .buttonStyle(MaterialReceiverButtonStyle(accent: ReceiverTheme.teal, foreground: ReceiverTheme.canvas))
                        .disabled(!model.canStartJitterDiagnostics)
                }
                Button("Copy Report") { model.copyJitterDiagnosticsReport() }
                    .disabled(model.jitterDiagnosticsReport == nil)
                Spacer()
            }
            if !model.canStartJitterDiagnostics && !model.jitterDiagnosticsActive {
                Text("Tracking is not currently available. Connect and approve the iPhone and wait for continuous tracking before starting; diagnostics will not create fake zero samples.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ScrollView {
                Text(model.jitterDiagnosticsReport ?? "A finalized report will appear here. It remains until the next capture starts.")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(ReceiverTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(width: 680, height: 520)
        .preferredColorScheme(.dark)
    }
}

struct MaterialReceiverButtonStyle: ButtonStyle {
    let accent: Color
    var foreground: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.fontWeight(.semibold).foregroundStyle(foreground).padding(.horizontal, 14).padding(.vertical, 9).background(accent.opacity(configuration.isPressed ? 0.62 : 0.9), in: RoundedRectangle(cornerRadius: 10)).scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
