import SwiftUI
import Foundation
import CoreBluetooth
import CoreMotion
import UIKit
import CoreHaptics

// Local cue position: the BLE protocol does not report the presentation's slide number.
struct SpeakerScript {
    static let slides: [String] = [
        "Welcome. Today I will introduce the topic and explain what we will cover.",
        "Here is the background and why this topic matters.",
        "This slide describes the main problem we want to solve.",
        "Our goal is to make the problem clear and define a useful outcome.",
        "This is an overview of the approach and its main steps.",
        "Here is a simple example that illustrates the approach.",
        "These are the key observations from the example.",
        "This slide explains the limitations and open questions.",
        "The next steps are to review the results and improve the approach.",
        "Thank you for listening. I welcome your questions.",
    ]
    private(set) var index = 0
    mutating func move(forward: Bool) {
        index = min(max(index + (forward ? 1 : -1), 0), Self.slides.count - 1)
    }
    mutating func select(_ index: Int) {
        self.index = min(max(index, 0), Self.slides.count - 1)
    }
}

@main
struct PhoneRemoteApp: App {
    var body: some Scene { WindowGroup { PhoneRemoteView() } }
}

@MainActor
fileprivate final class AttemptPeripheralDelegateProxy: NSObject, CBPeripheralDelegate {
    weak var owner: PhoneRemoteModel?
    let generation: UInt64
    private(set) var isValid = true

    init(owner: PhoneRemoteModel, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    func invalidate() { isValid = false; owner = nil }
    private var currentOwner: PhoneRemoteModel? {
        guard isValid, let owner, owner.acceptsPeripheralCallbacks(from: self, generation: generation) else { return nil }
        return owner
    }

    // CBPeripheral callbacks use the central manager's explicitly configured .main queue.
    // Enter the actor synchronously so callback ordering and CoreBluetooth object ownership stay intact.
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { currentOwner?.peripheral(peripheral, didDiscoverServices: error) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { currentOwner?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { currentOwner?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { currentOwner?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { currentOwner?.peripheral(peripheral, didWriteValueFor: characteristic, error: error) }
    }
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { currentOwner?.peripheralIsReady(toSendWriteWithoutResponse: peripheral) }
    }
}

@MainActor
final class PhoneRemoteModel: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct DiscoveredMac: Identifiable {
        let peripheral: CBPeripheral
        let name: String
        fileprivate let centralRealm: UInt64
        var id: UUID { peripheral.identifier }
    }
    struct AppearancePresetItem: Identifiable, Equatable {
        let slot: PresetSlot
        let name: String
        var id: PresetSlot { slot }
    }

    private static let lastMacIDKey = "lastExplicitMacPeripheralID"
    private static let lastMacNameKey = "lastExplicitMacName"
    private static let reconnectKey = "reconnectAutomatically"
    private static let samplingRateKey = "requestedMotionSamplingRate"
    private static let timerModeKey = "presentationTimerMode"
    private static let timerTotalMinutesKey = "presentationTimerTotalMinutes"
    private static let timerWarningEnabledKey = "presentationTimerWarningEnabled"
    private static let timerWarningElapsedMinutesKey = "presentationTimerWarningElapsedMinutes"
    private static let connectionDiagnosticsKey = "phoneConnectionDiagnostics.v1"
    private static let supportedSamplingRates = [60, 100, 200]

    private static func normalizedConnectionDiagnostics(_ entries: [String]) -> [String] {
        entries.suffix(16).map { String($0.prefix(2_048)) }
    }
    private static let timerMinutesRange = 1...180

    enum TimerMode: String, CaseIterable, Identifiable {
        case countUp
        case countDown
        var id: String { rawValue }
        var title: String { self == .countUp ? "Count Up" : "Count Down" }
    }
    @Published var status = "Preparing Bluetooth…"
    @Published var discoveredMacs: [DiscoveredMac] = []
    @Published var selectedMacID: UUID?
    @Published var reconnectAutomatically = false
    @Published private(set) var bluetoothReady = false
    @Published var isApproved = false
    /// Physical gesture and ephemeral latch remain separate; pointerEnabled is their effective visibility intent.
    @Published private(set) var physicalPointerHold = false
    @Published private(set) var holdLockEnabled = false
    @Published private(set) var pointerEnabled = false
    @Published private(set) var speakerScript = SpeakerScript()

    func selectScriptSlide(_ index: Int) { speakerScript.select(index) }

    @Published var elapsed = 0
    @Published var timerRunning = false
    @Published private(set) var timerMode: TimerMode
    @Published private(set) var timerTotalMinutes: Int
    @Published private(set) var timerWarningEnabled: Bool
    @Published private(set) var timerWarningElapsedMinutes: Int
    @Published private(set) var timerMilestoneText: String?
    @Published private(set) var measuredSamplesPerSecond = 0
    @Published private(set) var submittedMotionPacketsPerSecond = 0
    @Published private(set) var requestedSamplingRate: Int
    /// Updated only when a tracking session ends; Settings is not a high-rate diagnostic surface.
    @Published private(set) var lastHoldDiagnostics = "No completed tracking session yet."
    @Published private(set) var connectionDiagnostics: [String] = []
    @Published var calibrationPresented = false
    @Published private(set) var calibrationStep: CalibrationStep = .centre
    @Published private(set) var calibrationMessage = ""
    @Published private(set) var calibrationProposal: (x: Double, y: Double)?
    @Published private(set) var calibrationWaiting = false
    @Published private(set) var calibrationFailed = false
    @Published private(set) var appearancePresetItems: [AppearancePresetItem] = []
    @Published private(set) var selectedAppearancePreset: PresetSlot?
    @Published private(set) var appearancePresetState = "Appearance presets unavailable"
    @Published private(set) var presetRequestPending = false
    @Published private(set) var presetConflictDescription: String?

    private let serviceID = CBUUID(string: "C2F02001-67D2-4FD2-946C-4F0D34A2A101")
    private let controlID = CBUUID(string: "C2F02002-67D2-4FD2-946C-4F0D34A2A101")
    private let statusID = CBUUID(string: "C2F02003-67D2-4FD2-946C-4F0D34A2A101")
    private let motionID = CBUUID(string: "C2F02004-67D2-4FD2-946C-4F0D34A2A101")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var motionCharacteristic: CBCharacteristic?
    private var writeInFlight = false
    private var inFlightMessage: RemoteMessage?
    /// Set immediately before the with-response CoreBluetooth submission and cleared on callback/reset.
    private var inFlightControlSubmittedAt: TimeInterval?
    private var lastMotionSubmittedAt: TimeInterval?
    private var writeRetryCount = 0
    private var orderedMessages: [RemoteMessage] = []
    // This is the only motion backlog. It is replaced, never appended or retried.
    private var pendingMotion: MotionPacket?
    private let motion = CMMotionManager()
    private var activePointerSession: UInt64?
    private var acknowledgedPointerSession: UInt64?
    /// Monotonic for this model lifetime; reconnects do not reuse a pointer-session identifier.
    private var nextPointerSession: UInt64 = 0
    private var nextCalibrationSession: UInt64 = 0
    private var activeCalibrationSession: UInt64?
    private var calibrationStartAcknowledged = false
    private var nextMotionSequence: UInt32 = 0
    private var motionGeneration: UInt64 = 0
    private var attitudeTracker = PointerAttitudeTracker()
    private var currentAngles: (x: Double, y: Double)?
    private var holdAngleBaseline: (x: Double, y: Double)?
    private var cumulativeOffset = CGSize.zero
    private var nextRecenterEpoch: UInt64 = 0
    private var pendingRecenterEpoch: UInt64?
    private var recenterNeedsSample = false
    private var motionNeedsRecenter = false
    private var holdSampleCount = 0
    private var holdAcceptedDTCount = 0
    private var holdRejectedDTCount = 0
    private var holdMaxTimestampGap = 0.0
    private var holdAngleXSum = 0.0
    private var holdAngleYSum = 0.0
    private var lastMotionTimestamp: TimeInterval?
    private var holdPendingOverwriteCount = 0
    private var holdSubmittedCount = 0
    // This display-only name belongs only to the selected/connecting peripheral.
    private var currentMacID: UUID?
    private var currentMacName: String?
    private var sampledInRateWindow = 0
    private var submittedInRateWindow = 0
    private var rateWindowStarted = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var heartbeatTimer: Timer?
    private var subscribed = false
    private var disconnecting = false
    private var accumulatedTime: TimeInterval = 0
    private var timerStartedAt: TimeInterval?
    private var warningDelivered = false
    private var expiryDelivered = false
    private var hapticGeneration = 0
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticPatternPlayer?
    @Published private(set) var timerHapticsAvailable = true
    private var lastMacID: UUID?
    private var lastMacName: String?
    private var wantsConnection = false
    private var appIsActive = false
    private enum DisconnectDisposition: Equatable { case none, boundedRetry, resumeIfRequested }
    private var cancellationPendingID: UUID?
    private var cancellationPendingGeneration: UInt64?
    private var cancellationDisposition: DisconnectDisposition = .none
    private var connectionGeneration: UInt64 = 0
    private var nextAttemptGeneration: UInt64 = 0
    private var currentAttemptGeneration: UInt64?
    private var currentAttemptIsAutomatic = false
    private var peripheralDelegateProxy: AttemptPeripheralDelegateProxy?
    private var scanActive = false
    private var scanIsAutomatic = false
    private var manualConnectionRequired = false
    private var retryCount = 0
    private var retryWorkItem: DispatchWorkItem?
    private var stableConnectionWorkItem: DispatchWorkItem?
    private var scanDeadlineWorkItem: DispatchWorkItem?
    private var setupDeadlineWorkItem: DispatchWorkItem?
    private var cancellationWatchdogWorkItem: DispatchWorkItem?
    private var pendingRealmDisposition: DisconnectDisposition?
    private var preserveStatusOnNextPowerOn = false
    private var centralRealm: UInt64 = 1
    private var lastConnectionFailure: String?
    private enum ConnectionPhase: String {
        case connecting = "connect"
        case services = "service discovery"
        case characteristics = "characteristic discovery"
        case subscription = "status subscription"
        case ready = "established connection"
    }
    private var connectionPhase: ConnectionPhase = .connecting
    private let maximumReconnectAttempts = 4
    private let scanDeadline: TimeInterval = 8
    private let setupDeadline: TimeInterval = 15
    private let cancellationDeadline: TimeInterval = 5

    private enum PresetRequestKind {
        case catalog(PresetSlot)
        case select(PresetSlot)
        case save(PresetSlot, PresetName, Bool)
        case delete(PresetSlot)
    }
    private struct PendingPresetRequest {
        let id: UInt64
        let generation: UInt64
        let message: RemoteMessage
        let kind: PresetRequestKind
        var semanticRetryCount: Int
    }
    private var nextPresetRequestID: UInt64 = 0
    private var presetSyncGeneration: UInt64 = 0
    private var pendingPresetRequest: PendingPresetRequest?
    private var presetRequestTimeout: DispatchWorkItem?
    private var presetCatalogRevision: UInt64?
    private var pagingRevision: UInt64?
    private var pagingSelectedSlot: PresetSlot?
    private var pagingSelectionEstablished = false
    private var pagingNames: [PresetSlot: PresetName] = [:]
    private var presetPagingRestarts = 0
    private var refreshPresetsAfterRequest = false
    private var conflictingSave: (slot: PresetSlot, name: PresetName)?

    override init() {
        let savedRate = UserDefaults.standard.object(forKey: Self.samplingRateKey) as? Int
        requestedSamplingRate = Self.supportedSamplingRates.contains(savedRate ?? 0) ? savedRate! : 100
        let defaults = UserDefaults.standard
        timerMode = TimerMode(rawValue: defaults.string(forKey: Self.timerModeKey) ?? "") ?? .countUp
        let savedTotal = defaults.object(forKey: Self.timerTotalMinutesKey) as? Int
        let validatedTotal = Self.validTimerMinutes(savedTotal) ?? 10
        timerTotalMinutes = validatedTotal
        let savedWarning = defaults.object(forKey: Self.timerWarningElapsedMinutesKey) as? Int
        timerWarningElapsedMinutes = Self.validWarningMinutes(savedWarning, total: validatedTotal) ?? max(validatedTotal - 2, 0)
        timerWarningEnabled = validatedTotal >= 2 && (defaults.object(forKey: Self.timerWarningEnabledKey) as? Bool ?? true)
        timerMilestoneText = nil
        let savedDiagnostics = defaults.stringArray(forKey: Self.connectionDiagnosticsKey) ?? []
        let normalizedDiagnostics = Self.normalizedConnectionDiagnostics(savedDiagnostics)
        super.init()
        timerHapticsAvailable = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        UserDefaults.standard.set(requestedSamplingRate, forKey: Self.samplingRateKey)
        persistTimerSettings()
        lastMacID = UserDefaults.standard.string(forKey: Self.lastMacIDKey).flatMap(UUID.init(uuidString:))
        lastMacName = UserDefaults.standard.string(forKey: Self.lastMacNameKey)
        reconnectAutomatically = UserDefaults.standard.bool(forKey: Self.reconnectKey)
        connectionDiagnostics = normalizedDiagnostics
        if normalizedDiagnostics.isEmpty {
            defaults.removeObject(forKey: Self.connectionDiagnosticsKey)
        } else if savedDiagnostics != normalizedDiagnostics {
            defaults.set(normalizedDiagnostics, forKey: Self.connectionDiagnosticsKey)
        }
        wantsConnection = reconnectAutomatically && lastMacID != nil
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // This timer is installed on the main actor's run loop; do not enqueue this work.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.timerRunning { self.updateTimer(emitHaptics: self.appIsActive) }
                let now = ProcessInfo.processInfo.systemUptime
                let duration = max(now - self.rateWindowStarted, 0.001)
                self.measuredSamplesPerSecond = Int((Double(self.sampledInRateWindow) / duration).rounded())
                self.submittedMotionPacketsPerSecond = Int((Double(self.submittedInRateWindow) / duration).rounded())
                self.sampledInRateWindow = 0
                self.submittedInRateWindow = 0
                self.rateWindowStarted = now
            }
        }
    }

    var canSearchForMacs: Bool {
        appIsActive && bluetoothReady && peripheral == nil && cancellationPendingID == nil
    }
    var canConnectSelectedMac: Bool {
        canSearchForMacs && selectedMacID != nil && discoveredMacs.contains {
            $0.id == selectedMacID && $0.centralRealm == centralRealm
        }
    }
    var canDisconnect: Bool { peripheral != nil || cancellationPendingID != nil || scanActive }

    var canStartCalibration: Bool {
        appIsActive && isApproved && !disconnecting && activeCalibrationSession == nil && pendingPresetRequest == nil && pendingRecenterEpoch == nil && !motionNeedsRecenter && currentAngles != nil && motion.isDeviceMotionAvailable
    }
    var canRecordCalibration: Bool { activeCalibrationSession != nil && calibrationStartAcknowledged && currentAngles != nil && !calibrationWaiting && !calibrationFailed && calibrationProposal == nil }
    var canRecenter: Bool { appIsActive && isApproved && !disconnecting && activeCalibrationSession == nil && pendingRecenterEpoch == nil && motion.isDeviceMotionAvailable }
    var canBeginPointerHold: Bool { isApproved && !disconnecting && activeCalibrationSession == nil && pendingRecenterEpoch == nil && !motionNeedsRecenter }
    private var canEnableHoldLock: Bool {
        guard appIsActive, subscribed, isApproved, !disconnecting,
              activeCalibrationSession == nil, pendingRecenterEpoch == nil, !motionNeedsRecenter,
              currentAngles != nil, peripheral?.state == .connected,
              let session = activePointerSession else { return false }
        return acknowledgedPointerSession == session
    }
    var canToggleHoldLock: Bool { holdLockEnabled || canEnableHoldLock }
    var canChangeSamplingRate: Bool { !disconnecting && !pointerEnabled && activeCalibrationSession == nil && pendingRecenterEpoch == nil && !motionNeedsRecenter }
    var canUseAppearancePresets: Bool {
        isApproved && subscribed && !disconnecting && activeCalibrationSession == nil &&
        presetCatalogRevision != nil && pendingPresetRequest == nil
    }
    var selectedAppearancePresetName: String {
        guard let selectedAppearancePreset,
              let item = appearancePresetItems.first(where: { $0.slot == selectedAppearancePreset }) else { return "Custom" }
        return item.name
    }

    func retryAppearancePresetSync() {
        guard isApproved, pendingPresetRequest == nil else { return }
        beginAppearancePresetSync(clearPublishedCatalog: true)
    }

    func selectAppearancePreset(_ slot: PresetSlot) {
        guard canUseAppearancePresets, appearancePresetItems.contains(where: { $0.slot == slot }) else { return }
        issuePresetRequest(.select(slot)) { .presetSelect(requestID: $0, slot: slot) }
    }

    func saveCurrentMacAppearance(slot: PresetSlot, rawName: String, overwrite: Bool) -> Bool {
        guard canUseAppearancePresets, let name = PresetName(rawName) else { return false }
        issuePresetRequest(.save(slot, name, overwrite)) {
            .presetSave(requestID: $0, slot: slot, name: name, overwrite: overwrite)
        }
        return true
    }

    func confirmConflictingPresetOverwrite() {
        guard let intent = conflictingSave else { return }
        conflictingSave = nil; presetConflictDescription = nil
        guard canUseAppearancePresets else { return }
        issuePresetRequest(.save(intent.slot, intent.name, true)) {
            .presetSave(requestID: $0, slot: intent.slot, name: intent.name, overwrite: true)
        }
    }

    func dismissPresetConflict() {
        conflictingSave = nil; presetConflictDescription = nil
    }

    /// Explicit Recenter hides an active hold and renews the continuously running tracking epoch.
    /// The command is queued only after a fresh valid attitude/gravity sample establishes the basis.
    func recenter() {
        guard canRecenter, nextRecenterEpoch != UInt64.max else { return }
        endPointerHold()
        stopTracking()
        nextRecenterEpoch += 1
        pendingRecenterEpoch = nextRecenterEpoch; recenterNeedsSample = true
        motionNeedsRecenter = false
        attitudeTracker.resetBasis(); currentAngles = nil
        status = "Aim the phone top edge forward and hold steady to recenter…"
        ensureMotionStream()
    }

    func startCalibration() {
        guard canStartCalibration, nextCalibrationSession != UInt64.max else { return }
        endPointerHold()
        stopTracking()
        nextCalibrationSession += 1
        let session = nextCalibrationSession
        activeCalibrationSession = session; calibrationStartAcknowledged = false
        calibrationStep = .centre; calibrationProposal = nil; calibrationWaiting = true; calibrationFailed = false
        calibrationMessage = "Preparing the Centre marker on the Mac…"
        cumulativeOffset = .zero
        calibrationPresented = true
        enqueue(.calibrationStart(session: session))
    }

    func recordCalibrationPoint() {
        guard canRecordCalibration, let session = activeCalibrationSession, let angles = currentAngles else { return }
        let x = angles.x * PointerSensitivity.referenceGain
        let y = angles.y * PointerSensitivity.referenceGain
        guard x.isFinite, y.isFinite else { cancelCalibration(); return }
        calibrationWaiting = true
        calibrationMessage = "Sending the exact \(calibrationStep.title) snapshot…"
        enqueue(.calibrationCapture(session: session, step: calibrationStep, x: x, y: y))
    }

    func applyCalibration() {
        guard let session = activeCalibrationSession, calibrationProposal != nil, !calibrationWaiting else { return }
        calibrationWaiting = true; calibrationMessage = "Applying both values on the Mac…"
        enqueue(.calibrationApply(session: session))
    }

    func cancelCalibration() {
        guard let session = activeCalibrationSession else { calibrationPresented = false; return }
        let startMayHaveReachedMac = calibrationStartAcknowledged || {
            if case let .calibrationStart(inFlight)? = inFlightMessage { return inFlight == session }
            return false
        }()
        orderedMessages.removeAll { $0.calibrationSession == session }
        activeCalibrationSession = nil; calibrationStartAcknowledged = false; calibrationWaiting = false; calibrationFailed = false
        calibrationProposal = nil; calibrationPresented = false
        cumulativeOffset = .zero
        if startMayHaveReachedMac {
            guard orderedMessages.count < 64 else { forceDisconnectForQueueFull(); return }
            orderedMessages.insert(.calibrationCancel(session: session), at: 0); drainWrites()
        }
    }

    var motionAvailabilityDescription: String {
        motion.isDeviceMotionAvailable
            ? "Processed three-axis attitude is available. An approved foreground tracking session transmits while hidden; holding controls visibility only."
            : "Device motion is unavailable on this iPhone. Pointer motion cannot start."
    }

    func setRequestedSamplingRate(_ rate: Int) {
        guard canChangeSamplingRate, Self.supportedSamplingRates.contains(rate) else { return }
        requestedSamplingRate = rate
        UserDefaults.standard.set(rate, forKey: Self.samplingRateKey)
        if motion.isDeviceMotionActive {
            stopTracking(); stopMotionStream(); ensureMotionStream()
            status = "Sampling changed; tracking will resume from a safe angle baseline without moving the hidden pointer."
        }
    }

    private static func validTimerMinutes(_ value: Int?) -> Int? {
        guard let value, timerMinutesRange.contains(value) else { return nil }
        return value
    }

    private static func validWarningMinutes(_ value: Int?, total: Int) -> Int? {
        guard let value, value >= 0, value < total else { return nil }
        return value
    }

    private static func displayName(advertised: String?, peripheralName: String?, id: UUID) -> String {
        for candidate in [advertised, peripheralName] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Mac \(id.uuidString.prefix(8))"
    }

    private func bindCurrentMac(_ peripheral: CBPeripheral, name: String) {
        currentMacID = peripheral.identifier
        currentMacName = name
    }

    private var connectedMacName: String {
        guard let currentMacID, currentMacID == peripheral?.identifier else { return "Mac" }
        return currentMacName ?? "Mac \(currentMacID.uuidString.prefix(8))"
    }

    // CBCentralManager is created with queue: .main in init; preserve its synchronous callback order.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { self.centralManagerDidUpdateStateOnMain(central) }
    }

    private func centralManagerDidUpdateStateOnMain(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn:
            bluetoothReady = true
            if let disposition = pendingRealmDisposition {
                pendingRealmDisposition = nil
                preserveStatusOnNextPowerOn = false
                if disposition == .boundedRetry { scheduleReconnect(); return }
                if disposition == .resumeIfRequested, appIsActive, wantsConnection,
                   reconnectAutomatically, !manualConnectionRequired { reconnectKnownMac(); return }
            }
            if preserveStatusOnNextPowerOn { preserveStatusOnNextPowerOn = false; return }
            if appIsActive, wantsConnection, reconnectAutomatically, !manualConnectionRequired { reconnectKnownMac() }
            else { status = lastMacID == nil ? "Choose a Mac, then connect." : "Choose the saved Mac or tap Search."
            }
        case .unknown:
            handleTransientlyUnavailableBluetooth(message: nil)
        case .resetting:
            appendConnectionIncident("CoreBluetooth central entered resetting")
            handleTransientlyUnavailableBluetooth(message: "Bluetooth is resetting. Search will be available when it is ready.")
        case .poweredOff:
            appendConnectionIncident("CoreBluetooth central powered off")
            handleUnavailableBluetooth(message: "Bluetooth is off. Turn it on to search for a Mac.")
        case .unauthorized:
            appendConnectionIncident("CoreBluetooth authorization unavailable")
            handleUnavailableBluetooth(message: "Bluetooth access is not authorized for Pointer Remote.")
        case .unsupported:
            handleUnavailableBluetooth(message: "Bluetooth Low Energy is not supported on this device.")
        @unknown default:
            handleUnavailableBluetooth(message: "Bluetooth is unavailable. Search will be available if it becomes ready.")
        }
    }

    private func handleTransientlyUnavailableBluetooth(message: String?) {
        let hadPendingDisposition = pendingRealmDisposition != nil
        bluetoothReady = false
        let shouldResume = reconnectAutomatically && wantsConnection && !manualConnectionRequired
        if pendingRealmDisposition == nil {
            if cancellationPendingID != nil, cancellationDisposition != .none {
                pendingRealmDisposition = cancellationDisposition
            } else if shouldResume {
                pendingRealmDisposition = .resumeIfRequested
            }
        }
        // Fence local callbacks before stopping sensing, which can otherwise enqueue a tracking stop.
        disconnecting = true; isApproved = false
        stopScanLocallyAndIfAllowed()
        invalidateConnectionIntent(resetRetryEpisode: false)
        cancellationPendingID = nil; cancellationPendingGeneration = nil; cancellationDisposition = .none
        resetConnection()
        clearManagerBoundDiscoveries()
        if let message {
            if !preserveStatusOnNextPowerOn { status = message }
        } else if !preserveStatusOnNextPowerOn && !hadPendingDisposition {
            status = "Bluetooth is initializing…"
        }
    }

    private func handleUnavailableBluetooth(message: String) {
        handleTransientlyUnavailableBluetooth(message: message)
        preserveStatusOnNextPowerOn = false
        status = message
    }

    private func clearManagerBoundDiscoveries() {
        discoveredMacs.removeAll()
        selectedMacID = nil
    }

    @discardableResult
    private func stopScanLocallyAndIfAllowed(on manager: CBCentralManager? = nil) -> Bool {
        let manager = manager ?? central!
        let allowed = manager.state == .poweredOn
        if allowed { manager.stopScan() }
        scanDeadlineWorkItem?.cancel(); scanDeadlineWorkItem = nil
        scanActive = false
        return allowed
    }

    @discardableResult
    private func cancelPeripheralLocallyAndIfAllowed(_ candidate: CBPeripheral, on manager: CBCentralManager? = nil) -> Bool {
        let manager = manager ?? central!
        guard manager.state == .poweredOn, candidate.state != .disconnected else { return false }
        manager.cancelPeripheralConnection(candidate)
        return true
    }

    private func requireManualConnection() {
        manualConnectionRequired = true
        wantsConnection = false
        reconnectAutomatically = false
        UserDefaults.standard.set(false, forKey: Self.reconnectKey)
        cancelScheduledRetry(resetEpisode: false)
        pendingRealmDisposition = nil
    }

    private func boundedError(_ error: Error?) -> String {
        guard let error else { return "No system error detail was provided." }
        let ns = error as NSError
        func clean(_ value: String, limit: Int) -> String {
            let singleLine = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return String(singleLine.prefix(limit))
        }
        // Intentionally excludes userInfo, peer identifiers, and device names.
        return "\(clean(ns.domain, limit: 80)) code \(ns.code): \(clean(ns.localizedDescription, limit: 180))"
    }

    private func resetAppearancePresetSync(clearPublishedCatalog: Bool) {
        if presetSyncGeneration < UInt64.max { presetSyncGeneration += 1 }
        presetRequestTimeout?.cancel(); presetRequestTimeout = nil
        if let id = pendingPresetRequest?.id {
            orderedMessages.removeAll { $0.presetRequestID == id }
        } else {
            orderedMessages.removeAll { $0.presetRequestID != nil }
        }
        pendingPresetRequest = nil; presetRequestPending = false
        presetCatalogRevision = nil; pagingRevision = nil; pagingSelectedSlot = nil
        pagingSelectionEstablished = false; pagingNames.removeAll(); presetPagingRestarts = 0
        refreshPresetsAfterRequest = false; conflictingSave = nil; presetConflictDescription = nil
        if clearPublishedCatalog {
            appearancePresetItems.removeAll(); selectedAppearancePreset = nil
            appearancePresetState = isApproved ? "Loading appearance presets…" : "Appearance presets unavailable"
        }
    }

    private func beginAppearancePresetSync(clearPublishedCatalog: Bool) {
        guard isApproved, subscribed, !disconnecting else { return }
        resetAppearancePresetSync(clearPublishedCatalog: clearPublishedCatalog)
        appearancePresetState = "Loading appearance presets…"
        requestAppearancePresetPage(PresetSlot.allCases[0])
    }

    private func requestAppearancePresetPage(_ slot: PresetSlot) {
        let known = presetCatalogRevision ?? 0
        issuePresetRequest(.catalog(slot)) { .presetCatalogPage(requestID: $0, knownRevision: known, slot: slot) }
    }

    private func issuePresetRequest(_ kind: PresetRequestKind,
                                    message: (UInt64) -> RemoteMessage) {
        guard pendingPresetRequest == nil, nextPresetRequestID < UInt64.max else {
            if nextPresetRequestID == UInt64.max { appearancePresetState = "Preset request counter exhausted. Relaunch to continue." }
            return
        }
        nextPresetRequestID += 1
        let request = PendingPresetRequest(id: nextPresetRequestID, generation: presetSyncGeneration,
                                           message: message(nextPresetRequestID), kind: kind,
                                           semanticRetryCount: 0)
        pendingPresetRequest = request; presetRequestPending = true
        enqueue(request.message); schedulePresetRequestTimeout()
    }

    private func schedulePresetRequestTimeout() {
        presetRequestTimeout?.cancel()
        guard let request = pendingPresetRequest else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, var current = self.pendingPresetRequest,
                  current.id == request.id, current.generation == request.generation,
                  current.generation == self.presetSyncGeneration else { return }
            if current.semanticRetryCount == 0 {
                current.semanticRetryCount = 1; self.pendingPresetRequest = current
                self.enqueue(current.message); self.schedulePresetRequestTimeout()
            } else {
                self.pendingPresetRequest = nil; self.presetRequestPending = false
                self.presetCatalogRevision = nil
                self.appearancePresetState = "Appearance preset was not confirmed. Retry sync."
            }
        }
        presetRequestTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func completePresetRequest(_ requestID: UInt64) -> PendingPresetRequest? {
        guard let request = pendingPresetRequest, request.id == requestID,
              request.generation == presetSyncGeneration else { return nil }
        presetRequestTimeout?.cancel(); presetRequestTimeout = nil
        orderedMessages.removeAll { $0.presetRequestID == requestID }
        pendingPresetRequest = nil; presetRequestPending = false
        return request
    }

    private func restartPresetPaging() {
        guard presetPagingRestarts < 2 else {
            appearancePresetState = "Appearance preset sync unavailable. Tap Retry."
            presetCatalogRevision = nil
            return
        }
        presetPagingRestarts += 1; pagingRevision = nil; pagingSelectedSlot = nil
        pagingSelectionEstablished = false; pagingNames.removeAll()
        requestAppearancePresetPage(PresetSlot.allCases[0])
    }

    private func controlCaseName(_ message: RemoteMessage?) -> String {
        guard let message else { return "none" }
        switch message {
        case .tracking: return "tracking"
        case .visibility: return "visibility"
        case .recenter: return "recenter"
        case .key: return "key"
        case .timer: return "timer"
        case .calibrationStart: return "calibrationStart"
        case .calibrationCapture: return "calibrationCapture"
        case .calibrationCancel: return "calibrationCancel"
        case .calibrationApply: return "calibrationApply"
        case .presetCatalogPage: return "presetCatalogPage"
        case .presetSelect: return "presetSelect"
        case .presetSave: return "presetSave"
        case .presetDelete: return "presetDelete"
        case .hello: return "hello"
        }
    }

    private func appendConnectionIncident(_ trigger: String, error: Error? = nil,
                                          recognizedCancellation: Bool? = nil,
                                          cancellationReason: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let controlAge = inFlightControlSubmittedAt.map { String(format: "%.3fs", max(0, now - $0)) } ?? "unavailable"
        let motionAge = lastMotionSubmittedAt.map { String(format: "%.3fs", max(0, now - $0)) } ?? "unavailable"
        let cancellation = recognizedCancellation.map { $0 ? "yes" : "no" } ?? "not-applicable"
        let reason = cancellationReason.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(240)) } ?? "none"
        let errorText = error.map { boundedError($0) } ?? "none"
        let entry = """
        \(ISO8601DateFormatter().string(from: Date())) | local uptime \(String(format: "%.3f", now))s
        trigger: \(String(trigger.prefix(240)))
        phase: \(connectionPhase.rawValue); OS error: \(errorText)
        recognized local cancellation: \(cancellation); reason captured before cleanup: \(reason)
        in-flight control: \(controlCaseName(inFlightMessage)); response age since actual submission: \(controlAge); queued controls: \(orderedMessages.count)
        tracking acknowledgement: \(acknowledgedPointerSession == nil ? "pending/unavailable" : "acknowledged"); last motion submission age: \(motionAge)
        """
        connectionDiagnostics.append(String(entry.prefix(2_048)))
        if connectionDiagnostics.count > 16 { connectionDiagnostics.removeFirst(connectionDiagnostics.count - 16) }
        UserDefaults.standard.set(connectionDiagnostics, forKey: Self.connectionDiagnosticsKey)
    }

    func copyConnectionDiagnostics() {
        UIPasteboard.general.string = connectionDiagnostics.isEmpty
            ? "Pointer Remote iPhone connection diagnostics: no incidents recorded."
            : connectionDiagnostics.joined(separator: "\n\n---\n\n")
    }

    func clearConnectionDiagnostics() {
        connectionDiagnostics.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.connectionDiagnosticsKey)
    }

    func scanForMacs() {
        guard canSearchForMacs else {
            if central.state == .unknown || central.state == .resetting { status = "Bluetooth is initializing. Search will be available when it is ready." }
            return
        }
        stopScanLocallyAndIfAllowed()
        manualConnectionRequired = true; wantsConnection = false
        beginNewConnectionEpisode()
        discoveredMacs.removeAll()
        startScan(automatic: false, message: "Searching for Macs…")
    }

    func connectSelectedMac() {
        guard central.state == .poweredOn else {
            status = central.state == .unknown || central.state == .resetting
                ? "Bluetooth is initializing. Connect will be available when it is ready."
                : "Bluetooth is unavailable."
            return
        }
        guard peripheral == nil, cancellationPendingID == nil else { status = "A connection cancellation is still pending."; return }
        guard let selectedMacID, let choice = discoveredMacs.first(where: { $0.id == selectedMacID && $0.centralRealm == centralRealm }) else { status = "Search again and select a Mac before connecting."; return }
        lastMacID = choice.id; lastMacName = choice.name
        UserDefaults.standard.set(choice.id.uuidString, forKey: Self.lastMacIDKey)
        UserDefaults.standard.set(choice.name, forKey: Self.lastMacNameKey)
        manualConnectionRequired = false; wantsConnection = true
        beginNewConnectionEpisode()
        reconnectAutomatically = true
        UserDefaults.standard.set(true, forKey: Self.reconnectKey)
        connect(to: choice.peripheral, name: choice.name, automatic: false)
    }

    func setReconnectAutomatically(_ enabled: Bool) {
        reconnectAutomatically = enabled
        UserDefaults.standard.set(enabled, forKey: Self.reconnectKey)
        if enabled, lastMacID != nil, !manualConnectionRequired { wantsConnection = true; if appIsActive { reconnectKnownMac() } }
        if !enabled { cancelScheduledRetry(resetEpisode: false) }
    }

    func disconnect() {
        requireManualConnection(); stopScanLocallyAndIfAllowed()
        invalidateConnectionIntent(resetRetryEpisode: true)
        cancelCalibration(); endPointerHold(); stopTracking()
        cancelCurrentConnection(status: "Disconnected.", disposition: .none)
    }

    /// Removes only this app's remembered peer records. It does not alter system Bluetooth pairing.
    func forgetAllMacs() {
        requireManualConnection()
        invalidateConnectionIntent(resetRetryEpisode: true)
        cancelAllConnectionWork(); stopScanLocallyAndIfAllowed()
        clearManagerBoundDiscoveries()
        lastMacID = nil; lastMacName = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastMacIDKey)
        defaults.removeObject(forKey: Self.lastMacNameKey)
        defaults.removeObject(forKey: Self.reconnectKey)

        let current = peripheral
        if current != nil {
            appendConnectionIncident("application forgot saved Macs and cancelled the live connection",
                                     recognizedCancellation: true,
                                     cancellationReason: "Forgot all Macs in Pointer Remote.")
        }
        disconnecting = true; isApproved = false
        peripheralDelegateProxy?.invalidate(); peripheralDelegateProxy = nil
        controlCharacteristic = nil; statusCharacteristic = nil; motionCharacteristic = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        orderedMessages.removeAll(); pendingMotion = nil; inFlightMessage = nil; writeInFlight = false
        inFlightControlSubmittedAt = nil
        if let current { current.delegate = nil; _ = cancelPeripheralLocallyAndIfAllowed(current) }
        cancellationPendingID = nil; cancellationPendingGeneration = nil; cancellationDisposition = .none
        resetConnection()
        status = "Forgot all Macs in Pointer Remote. Search and explicitly connect to use one again."
    }

    func appBecameActive() {
        appIsActive = true
        updateTimer(emitHaptics: true)
        if let current = peripheral, cancellationPendingID == current.identifier {
            startCancellationWatchdog(for: current, generation: cancellationPendingGeneration, manager: central)
            return
        }
        if reconnectAutomatically, wantsConnection { reconnectKnownMac() }
    }

    private func suspendForInactive() {
        appIsActive = false; stopScanLocallyAndIfAllowed(); cancelAllConnectionWork(); cancelScheduledRetry(resetEpisode: false)
        cancelCalibration(); endPointerHold(); stopTracking()
        cancelCurrentConnection(status: "Paused while iPhone is inactive.", disposition: .resumeIfRequested)
    }

    private func startScan(automatic: Bool, message: String) {
        guard central.state == .poweredOn else { status = "Bluetooth is not ready to search."; return }
        scanDeadlineWorkItem?.cancel()
        scanActive = true; scanIsAutomatic = automatic
        let manager = central!, episode = connectionGeneration
        manager.scanForPeripherals(withServices: [serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        status = message
        let work = DispatchWorkItem { [weak self, weak manager] in
            guard let self, let manager, manager === self.central, self.connectionGeneration == episode,
                  self.scanActive, self.scanIsAutomatic == automatic else { return }
            self.stopScanLocallyAndIfAllowed(on: manager); self.scanDeadlineWorkItem = nil
            if automatic {
                self.status = "Saved Mac was not found within 8 seconds. Automatic retry is bounded."
                self.scheduleReconnect()
            } else {
                self.status = "Search ended after 8 seconds. Tap Search to scan again."
            }
        }
        scanDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scanDeadline, execute: work)
    }

    private func connect(to candidate: CBPeripheral, name: String, automatic: Bool) {
        guard peripheral == nil, cancellationPendingID == nil, central.state == .poweredOn, appIsActive,
              candidate.state == .disconnected else { return }
        stopScanLocallyAndIfAllowed(); scanDeadlineWorkItem?.cancel(); scanDeadlineWorkItem = nil
        disconnecting = false; peripheral = candidate
        connectionPhase = .connecting
        lastConnectionFailure = nil
        nextAttemptGeneration &+= 1
        let attempt = nextAttemptGeneration
        currentAttemptGeneration = attempt; currentAttemptIsAutomatic = automatic
        let proxy = AttemptPeripheralDelegateProxy(owner: self, generation: attempt)
        peripheralDelegateProxy = proxy; candidate.delegate = proxy
        bindCurrentMac(candidate, name: name)
        status = "Connecting to \(name)…"; central.connect(candidate)
        startSetupDeadline(for: candidate, generation: attempt, automatic: automatic)
    }

    private func reconnectKnownMac() {
        guard appIsActive, reconnectAutomatically, wantsConnection, !manualConnectionRequired,
              peripheral == nil, cancellationPendingID == nil, !scanActive, retryWorkItem == nil,
              central.state == .poweredOn, let lastMacID else { return }
        let restored = central.retrievePeripherals(withIdentifiers: [lastMacID])
        if let candidate = restored.first(where: { $0.identifier == lastMacID }) {
            let liveName = Self.displayName(advertised: nil, peripheralName: candidate.name, id: candidate.identifier)
            let peripheralName = candidate.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let savedName = lastMacName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = !peripheralName.isEmpty ? liveName : (savedName.isEmpty ? liveName : savedName)
            lastMacName = name
            UserDefaults.standard.set(name, forKey: Self.lastMacNameKey)
            connect(to: candidate, name: name, automatic: true)
        } else {
            let label = retryCount == 0 ? "initial attempt" : "retry \(retryCount) of \(maximumReconnectAttempts)"
            startScan(automatic: true, message: "Searching for saved Mac (\(label))…")
        }
    }

    private func startSetupDeadline(for candidate: CBPeripheral, generation: UInt64, automatic: Bool) {
        setupDeadlineWorkItem?.cancel()
        let manager = central!
        let work = DispatchWorkItem { [weak self, weak manager, weak candidate] in
            guard let self, let manager, let candidate, manager === self.central,
                  self.currentAttemptGeneration == generation, self.peripheral === candidate,
                  !self.subscribed, !self.disconnecting else { return }
            self.setupDeadlineWorkItem = nil
            let reason = automatic
                ? "Connection setup (\(self.connectionPhase.rawValue)) did not complete within 15 seconds. Automatic retry is bounded."
                : "Connection setup (\(self.connectionPhase.rawValue)) did not complete within 15 seconds. Tap Search and Connect to try again."
            if !automatic { self.requireManualConnection() }
            self.lastConnectionFailure = reason
            self.appendConnectionIncident("connection setup watchdog", cancellationReason: reason)
            self.cancelCurrentConnection(status: reason, disposition: automatic ? .boundedRetry : .none)
        }
        setupDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + setupDeadline, execute: work)
    }

    private func cancelCurrentConnection(status newStatus: String, disposition: DisconnectDisposition = .none) {
        guard let current = peripheral else { status = newStatus; return }
        // Capture the application reason and live control state before teardown overwrites them.
        appendConnectionIncident("application requested connection cancellation", recognizedCancellation: true,
                                 cancellationReason: newStatus)
        disconnecting = true; isApproved = false; subscribed = false
        setupDeadlineWorkItem?.cancel(); setupDeadlineWorkItem = nil
        peripheralDelegateProxy?.invalidate(); peripheralDelegateProxy = nil; current.delegate = nil
        controlCharacteristic = nil; statusCharacteristic = nil; motionCharacteristic = nil
        cancelCalibration(); endPointerHold(); stopTracking(); stopMotionStream()
        orderedMessages.removeAll(); pendingMotion = nil; inFlightMessage = nil
        writeInFlight = false; inFlightControlSubmittedAt = nil; writeRetryCount = 0
        cancelScheduledRetry(resetEpisode: false)
        cancellationPendingID = current.identifier
        cancellationPendingGeneration = currentAttemptGeneration
        cancellationDisposition = disposition
        let cancellationIssued = cancelPeripheralLocallyAndIfAllowed(current)
        status = newStatus
        if cancellationIssued, appIsActive {
            startCancellationWatchdog(for: current, generation: cancellationPendingGeneration, manager: central)
        } else if !cancellationIssued {
            let deferred = disposition
            cancellationPendingID = nil; cancellationPendingGeneration = nil; cancellationDisposition = .none
            resetConnection()
            if deferred != .none { pendingRealmDisposition = deferred }
        }
    }

    private func startCancellationWatchdog(for candidate: CBPeripheral, generation: UInt64?, manager: CBCentralManager) {
        cancellationWatchdogWorkItem?.cancel()
        let episode = connectionGeneration
        let work = DispatchWorkItem { [weak self, weak candidate, weak manager] in
            guard let self, let candidate, let manager, manager === self.central,
                  self.connectionGeneration == episode, self.peripheral === candidate,
                  self.cancellationPendingID == candidate.identifier,
                  self.cancellationPendingGeneration == generation else { return }
            self.cancellationWatchdogWorkItem = nil
            self.appendConnectionIncident("connection cancellation watchdog", recognizedCancellation: true,
                                          cancellationReason: self.status)
            self.requireManualConnection()
            self.status = "Bluetooth did not finish cancelling within 5 seconds. Tap Search to recover; automatic reconnect is disabled."
            self.lastConnectionFailure = self.status
            self.retireCentralRealm(after: .none, preserveStatus: true)
        }
        cancellationWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cancellationDeadline, execute: work)
    }

    private func retireCentralRealm(after disposition: DisconnectDisposition, preserveStatus: Bool) {
        // resetConnection stops tracking, so fence it before that local work can enqueue a stop.
        disconnecting = true; isApproved = false
        let old = central!
        stopScanLocallyAndIfAllowed(on: old); old.delegate = nil
        peripheralDelegateProxy?.invalidate(); peripheralDelegateProxy = nil; peripheral?.delegate = nil
        cancelAllConnectionWork(); cancelScheduledRetry(resetEpisode: false); resetConnection()
        cancellationPendingID = nil; cancellationPendingGeneration = nil; cancellationDisposition = .none
        pendingRealmDisposition = disposition == .none ? nil : disposition
        preserveStatusOnNextPowerOn = preserveStatus
        clearManagerBoundDiscoveries()
        bluetoothReady = false
        centralRealm &+= 1
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func beginNewConnectionEpisode() {
        connectionGeneration &+= 1
        pendingRealmDisposition = nil; preserveStatusOnNextPowerOn = false
        cancelAllConnectionWork(); cancelScheduledRetry(resetEpisode: true)
    }

    private func invalidateConnectionIntent(resetRetryEpisode: Bool) {
        connectionGeneration &+= 1
        peripheralDelegateProxy?.invalidate()
        cancelAllConnectionWork(); cancelScheduledRetry(resetEpisode: resetRetryEpisode)
    }

    private func cancelAllConnectionWork() {
        scanDeadlineWorkItem?.cancel(); scanDeadlineWorkItem = nil
        setupDeadlineWorkItem?.cancel(); setupDeadlineWorkItem = nil
        cancellationWatchdogWorkItem?.cancel(); cancellationWatchdogWorkItem = nil
    }

    private func scheduleReconnect() {
        guard appIsActive, wantsConnection, reconnectAutomatically, !manualConnectionRequired else { return }
        guard retryCount < maximumReconnectAttempts else { stopAutomaticReconnect(); return }
        retryCount += 1
        let generation = connectionGeneration
        let delay = min(pow(2, Double(retryCount - 1)), 8)
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == generation, self.wantsConnection,
                  !self.manualConnectionRequired else { return }
            self.retryWorkItem = nil
            self.reconnectKnownMac()
        }
        retryWorkItem = work
        let prefix = lastConnectionFailure.map { "\($0) " } ?? ""
        status = "\(prefix)Waiting to retry saved Mac (retry \(retryCount) of \(maximumReconnectAttempts))…"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopAutomaticReconnect() {
        requireManualConnection()
        let prefix = lastConnectionFailure.map { "Last failure: \($0) " } ?? ""
        status = "\(prefix)Automatic reconnect stopped after \(maximumReconnectAttempts) retries. Search, select the saved Mac, and tap Connect to try again."
    }

    private func cancelScheduledRetry(resetEpisode: Bool) {
        retryWorkItem?.cancel(); retryWorkItem = nil
        stableConnectionWorkItem?.cancel(); stableConnectionWorkItem = nil
        if resetEpisode { retryCount = 0 }
    }

    private func markConnectionStableSoon() {
        stableConnectionWorkItem?.cancel()
        let episode = connectionGeneration, attempt = currentAttemptGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectionGeneration == episode,
                  self.currentAttemptGeneration == attempt, self.isApproved,
                  self.peripheral?.state == .connected else { return }
            self.retryCount = 0
            self.stableConnectionWorkItem = nil
        }
        stableConnectionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    fileprivate func acceptsPeripheralCallbacks(from proxy: AttemptPeripheralDelegateProxy, generation: UInt64) -> Bool {
        peripheralDelegateProxy === proxy && currentAttemptGeneration == generation && !disconnecting
    }

    private func failCurrentAttempt(_ reason: String, terminal: Bool) {
        let displayedReason = !currentAttemptIsAutomatic
            ? reason.replacingOccurrences(of: "Automatic retry is bounded.", with: "Tap Search and Connect to try again.")
            : reason
        lastConnectionFailure = displayedReason
        if terminal || !currentAttemptIsAutomatic {
            requireManualConnection()
            invalidateConnectionIntent(resetRetryEpisode: false)
            cancelCurrentConnection(status: displayedReason, disposition: .none)
        } else {
            cancelCurrentConnection(status: displayedReason, disposition: .boundedRetry)
        }
    }

    /// Called only by the long-press recognizer after its 0.2 second threshold. Tracking is unchanged.
    func beginPointerHold() {
        guard canBeginPointerHold, !physicalPointerHold else { return }
        physicalPointerHold = true
        reconcilePointerVisibilityIntent()
    }

    /// Release drops only the physical gesture. A lock remains visible until explicitly unlocked.
    func endPointerHold() {
        guard physicalPointerHold else { return }
        physicalPointerHold = false
        reconcilePointerVisibilityIntent()
    }

    /// Hold Lock is an ephemeral visibility latch. It never starts or renews tracking.
    func toggleHoldLock() {
        if holdLockEnabled {
            holdLockEnabled = false
            reconcilePointerVisibilityIntent()
        } else {
            guard canEnableHoldLock else { return }
            holdLockEnabled = true
            reconcilePointerVisibilityIntent()
        }
    }

    /// Lifecycle/recovery cleanup clears both inputs even if a recognizer ends later.
    func forceClearPointerVisibility() {
        physicalPointerHold = false
        holdLockEnabled = false
        reconcilePointerVisibilityIntent(forceHide: true)
    }

    private func reconcilePointerVisibilityIntent(forceHide: Bool = false) {
        let wantsVisible = !forceHide && (physicalPointerHold || holdLockEnabled)
        guard forceHide || wantsVisible != pointerEnabled else { return }
        pointerEnabled = wantsVisible
        guard let session = activePointerSession else { return }
        orderedMessages.removeAll { message in
            if case let .visibility(_, queuedSession) = message { return queuedSession == session }
            return false
        }
        if wantsVisible {
            // A lock is enabled only after this ACK. A physical hold may wait for the existing start ACK.
            if acknowledgedPointerSession == session { enqueue(.visibility(visible: true, session: session)) }
            return
        }
        let visibleInFlight: Bool
        if case let .visibility(visible, inFlightSession)? = inFlightMessage {
            visibleInFlight = visible && inFlightSession == session
        } else { visibleInFlight = false }
        if acknowledgedPointerSession == session || visibleInFlight {
            guard orderedMessages.count < 64 else { forceDisconnectForQueueFull(); return }
            orderedMessages.insert(.visibility(visible: false, session: session), at: 0)
            drainWrites()
        }
    }

    /// Establishes one acknowledged motion session for the approved foreground connection.
    private func beginTrackingIfPossible() {
        guard appIsActive, isApproved, !disconnecting, activeCalibrationSession == nil,
              pendingRecenterEpoch == nil, !motionNeedsRecenter, currentAngles != nil,
              activePointerSession == nil else { return }
        guard nextPointerSession != UInt64.max else {
            disconnect(); status = "Tracking session sequence completed. Reconnect to continue."; return
        }
        nextPointerSession += 1
        activePointerSession = nextPointerSession; acknowledgedPointerSession = nil
        nextMotionSequence = 0; cumulativeOffset = .zero; pendingMotion = nil
        resetHoldDiagnostics(); lastMotionTimestamp = nil
        enqueue(.tracking(enabled: true, session: nextPointerSession))
    }

    /// Ends transmission for lifecycle, calibration, Recenter, or transport teardown; ordinary release never calls this.
    private func stopTracking() {
        forceClearPointerVisibility()
        guard let session = activePointerSession else { return }
        let wasAcknowledged = acknowledgedPointerSession == session
        activePointerSession = nil; acknowledgedPointerSession = nil
        holdAngleBaseline = nil; lastMotionTimestamp = nil; nextMotionSequence = 0; pendingMotion = nil
        finishHoldDiagnostics()
        enqueueTrackingStop(for: session, wasAcknowledged: wasAcknowledged)
    }

    private func resetHoldDiagnostics() {
        holdSampleCount = 0; holdAcceptedDTCount = 0; holdRejectedDTCount = 0
        holdMaxTimestampGap = 0; holdAngleXSum = 0; holdAngleYSum = 0
        holdPendingOverwriteCount = 0; holdSubmittedCount = 0
    }

    private func finishHoldDiagnostics() {
        let meanX = holdAcceptedDTCount > 0 ? holdAngleXSum / Double(holdAcceptedDTCount) : 0
        let meanY = holdAcceptedDTCount > 0 ? holdAngleYSum / Double(holdAcceptedDTCount) : 0
        lastHoldDiagnostics = String(format: "Last tracking session — attitude samples %d; max sensor timestamp gap %.3fs; rejected samples %d; mean cumulative angle x %.4f, y %.4f rad; pending overwrites %d; submitted %d. Visibility holds do not reset these counters or the motion baseline.", holdSampleCount, holdMaxTimestampGap, holdRejectedDTCount, meanX, meanY, holdPendingOverwriteCount, holdSubmittedCount)
    }

    private let slideFeedback = UIImpactFeedbackGenerator(style: .light)

    func sendKey(_ key: RemoteMessage.RemoteKey) {
        guard appIsActive, central.state == .poweredOn, subscribed, !disconnecting, isApproved, activeCalibrationSession == nil,
              peripheral?.state == .connected else { return }
        guard orderedMessages.count < 64 else { forceDisconnectForQueueFull(); return }
        enqueue(.key(key))
        switch key {
        case .left: speakerScript.move(forward: false)
        case .right: speakerScript.move(forward: true)
        }
        // Local tap feedback, not confirmation that the Mac changed slides.
        slideFeedback.impactOccurred()
        slideFeedback.prepare()
    }

    var canResetTimer: Bool { timerRunning || accumulatedTime > 0 }
    var canConfigureTimer: Bool { !timerRunning && accumulatedTime == 0 }
    var countdownRemainingSeconds: Int {
        max(0, Int(ceil(Double(timerTotalMinutes * 60) - currentTimerElapsed)))
    }
    var timerDisplaySeconds: Int { timerMode == .countDown ? countdownRemainingSeconds : elapsed }
    var timerAccessibilityLabel: String {
        let seconds = timerDisplaySeconds
        let prefix = timerMode == .countDown ? "Countdown remaining" : "Count up"
        return "\(prefix) \(seconds / 60) minutes \(seconds % 60) seconds"
    }
    var warningIsAvailable: Bool { timerTotalMinutes >= 2 }

    func setTimerMode(_ mode: TimerMode) {
        guard canConfigureTimer else { return }
        timerMode = mode; persistTimerSettings(); resetTimer()
    }

    func setTimerTotalMinutes(_ minutes: Int) {
        guard canConfigureTimer, let valid = Self.validTimerMinutes(minutes) else { return }
        timerTotalMinutes = valid
        if !warningIsAvailable { timerWarningEnabled = false; timerWarningElapsedMinutes = 0 }
        else { timerWarningElapsedMinutes = min(max(timerWarningElapsedMinutes, 0), valid - 1) }
        persistTimerSettings(); resetTimer()
    }

    func setTimerWarningEnabled(_ enabled: Bool) {
        guard canConfigureTimer else { return }
        cancelTimerHaptics(); timerWarningEnabled = warningIsAvailable && enabled; persistTimerSettings()
    }

    func setTimerWarningElapsedMinutes(_ minutes: Int) {
        guard canConfigureTimer, let valid = Self.validWarningMinutes(minutes, total: timerTotalMinutes) else { return }
        cancelTimerHaptics(); timerWarningElapsedMinutes = valid; persistTimerSettings()
    }

    private func persistTimerSettings() {
        let defaults = UserDefaults.standard
        defaults.set(timerMode.rawValue, forKey: Self.timerModeKey)
        defaults.set(timerTotalMinutes, forKey: Self.timerTotalMinutesKey)
        defaults.set(timerWarningEnabled && warningIsAvailable, forKey: Self.timerWarningEnabledKey)
        defaults.set(timerWarningElapsedMinutes, forKey: Self.timerWarningElapsedMinutesKey)
    }

    func resetTimer() {
        cancelTimerHaptics()
        timerStartedAt = nil; accumulatedTime = 0; timerRunning = false; elapsed = 0
        warningDelivered = false; expiryDelivered = false; timerMilestoneText = nil
    }

    func toggleTimer() {
        let now = ProcessInfo.processInfo.systemUptime
        if let started = timerStartedAt {
            accumulatedTime += max(0, now - started); timerStartedAt = nil; timerRunning = false
            cancelTimerHaptics(); updateTimer(emitHaptics: false)
        } else {
            if timerMode == .countDown && currentTimerElapsed >= TimeInterval(timerTotalMinutes * 60) { resetTimer() }
            if accumulatedTime == 0 { warningDelivered = false; expiryDelivered = false; timerMilestoneText = nil }
            timerStartedAt = now; timerRunning = true; updateTimer(emitHaptics: appIsActive)
        }
    }

    private var currentTimerElapsed: TimeInterval {
        max(0, accumulatedTime + (timerStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0))
    }

    private func updateTimer(emitHaptics: Bool) {
        let elapsedTime = currentTimerElapsed
        elapsed = Int(elapsedTime)
        guard timerMode == .countDown else { return }
        let total = TimeInterval(timerTotalMinutes * 60)
        if elapsedTime >= total {
            accumulatedTime = total; timerStartedAt = nil; timerRunning = false; elapsed = Int(total)
            timerMilestoneText = "Time is up"
            if !expiryDelivered && emitHaptics { expiryDelivered = true; warningDelivered = true; playTimerHaptic(.expiry) }
            return
        }
        let warningAt = TimeInterval(timerWarningElapsedMinutes * 60)
        if timerWarningEnabled && !warningDelivered && elapsedTime >= warningAt {
            timerMilestoneText = "Warning: \(countdownRemainingSeconds / 60) min remaining"
            if emitHaptics { warningDelivered = true; playTimerHaptic(.warning) }
        }
    }

    private enum TimerHaptic { case warning, expiry }
    private func playTimerHaptic(_ haptic: TimerHaptic) {
        guard appIsActive else { return }
        cancelTimerHaptics()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            timerHapticsAvailable = false; return
        }
        do {
            let engine: CHHapticEngine
            if let existing = hapticEngine { engine = existing }
            else {
                engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.resetHandler = { [weak self] in
                    // A reset never resumes an old timer pattern.
                    self?.hapticPlayer = nil
                }
                hapticEngine = engine
            }
            try engine.start()
            let generation = hapticGeneration
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: haptic == .warning ? 0.55 : 1.0)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: haptic == .warning ? 0.45 : 1.0)
            let events: [CHHapticEvent]
            switch haptic {
            case .warning:
                events = [CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 0.3),
                          CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0.5, duration: 0.3)]
            case .expiry:
                events = [CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 3)]
            }
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            guard appIsActive, hapticGeneration == generation else { return }
            hapticPlayer = player; try player.start(atTime: 0); timerHapticsAvailable = true
        } catch {
            hapticPlayer = nil; timerHapticsAvailable = false
        }
    }

    private func cancelTimerHaptics() {
        hapticGeneration &+= 1
        try? hapticPlayer?.stop(atTime: 0); hapticPlayer = nil
    }

    func appBecameInactive() { cancelTimerHaptics(); suspendForInactive() }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { self.centralManagerOnMain(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI) }
    }

    private func centralManagerOnMain(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, central.state == .poweredOn, scanActive, appIsActive else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = Self.displayName(advertised: advertisedName, peripheralName: peripheral.name, id: peripheral.identifier)
        if scanIsAutomatic, wantsConnection, reconnectAutomatically, peripheral.identifier == lastMacID {
            let savedName = lastMacName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasFreshName = [advertisedName, peripheral.name].contains {
                !($0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            }
            let resolvedName = hasFreshName || savedName.isEmpty ? name : savedName
            lastMacName = resolvedName
            UserDefaults.standard.set(resolvedName, forKey: Self.lastMacNameKey)
            connect(to: peripheral, name: resolvedName, automatic: true)
            return
        }
        guard !discoveredMacs.contains(where: { $0.id == peripheral.identifier }) else { return }
        discoveredMacs.append(DiscoveredMac(peripheral: peripheral, name: name, centralRealm: centralRealm))
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.centralManagerOnMain(central, didConnect: peripheral) }
    }

    private func centralManagerOnMain(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let current = self.peripheral, central === self.central, peripheral === current, !disconnecting,
              currentAttemptGeneration != nil else { return }
        // didConnect is only transport progress. The setup deadline and retry budget remain active
        // until notification setup succeeds and approval is later stable.
        guard central.state == .poweredOn, peripheral.state == .connected else { return }
        connectionPhase = .services
        status = "Discovering services…"
        peripheral.discoverServices([serviceID])
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.centralManagerOnMain(central, didFailToConnect: peripheral, error: error) }
    }

    private func centralManagerOnMain(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleTerminalCallback(from: central, peripheral: peripheral, kind: "Failed during \(connectionPhase.rawValue)", error: error)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.centralManagerOnMain(central, didDisconnectPeripheral: peripheral, error: error) }
    }

    private func centralManagerOnMain(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleTerminalCallback(from: central, peripheral: peripheral, kind: "Unexpected disconnect during \(connectionPhase.rawValue)", error: error)
    }

    private func handleTerminalCallback(from manager: CBCentralManager, peripheral callbackPeripheral: CBPeripheral,
                                        kind: String, error: Error?) {
        guard manager === central, let current = peripheral, callbackPeripheral === current,
              callbackPeripheral.state == .disconnected, let attempt = currentAttemptGeneration else { return }
        let wasCancellation = cancellationPendingID == callbackPeripheral.identifier && cancellationPendingGeneration == attempt
        guard cancellationPendingID == nil || wasCancellation else { return }
        let capturedReason = wasCancellation ? status : nil
        appendConnectionIncident(kind, error: error, recognizedCancellation: wasCancellation,
                                 cancellationReason: capturedReason)
        let disposition: DisconnectDisposition
        if wasCancellation {
            disposition = cancellationDisposition
            if let error {
                let detail = "\(status) System callback: \(boundedError(error))"
                lastConnectionFailure = detail
                status = detail
            }
        } else {
            let detail = "\(kind). \(boundedError(error))"
            lastConnectionFailure = detail
            status = detail
            if !currentAttemptIsAutomatic { requireManualConnection() }
            disposition = currentAttemptIsAutomatic ? .boundedRetry : .none
        }
        cancellationWatchdogWorkItem?.cancel(); cancellationWatchdogWorkItem = nil
        // A terminal attempt retires its manager realm before another attempt can reuse a cached
        // CBPeripheral. Consequently callbacks from this manager cannot reset the replacement realm.
        retireCentralRealm(after: disposition, preserveStatus: true)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard central.state == .poweredOn, let current = self.peripheral, peripheral === current,
              peripheral.state == .connected, !disconnecting, currentAttemptGeneration != nil else { return }
        guard error == nil, peripheral.services?.contains(where: { $0.uuid == serviceID }) == true else {
            failCurrentAttempt("Could not discover the Pointer Remote service. Automatic retry is bounded.", terminal: false); return
        }
        connectionPhase = .characteristics
        peripheral.services?.filter { $0.uuid == serviceID }.forEach { peripheral.discoverCharacteristics([controlID, statusID, motionID], for: $0) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard central.state == .poweredOn, let current = self.peripheral, peripheral === current,
              peripheral.state == .connected, !disconnecting, currentAttemptGeneration != nil else { return }
        guard error == nil else {
            failCurrentAttempt("Could not discover Pointer Remote characteristics. Automatic retry is bounded.", terminal: false); return
        }
        controlCharacteristic = service.characteristics?.first { $0.uuid == controlID }
        statusCharacteristic = service.characteristics?.first { $0.uuid == statusID }
        motionCharacteristic = service.characteristics?.first { $0.uuid == motionID }
        guard let controlCharacteristic, let statusCharacteristic, let motionCharacteristic else {
            failCurrentAttempt("Protocol mismatch: rebuild and install BOTH the iPhone and Mac apps, then connect manually.", terminal: true)
            return
        }
        guard controlCharacteristic.properties.contains(.write),
              statusCharacteristic.properties.contains(.notify),
              motionCharacteristic.properties.contains(.writeWithoutResponse) else {
            failCurrentAttempt("Protocol mismatch: Mac Bluetooth characteristic capabilities do not match. Rebuild BOTH apps, then connect manually.", terminal: true)
            return
        }
        connectionPhase = .subscription
        peripheral.setNotifyValue(true, for: statusCharacteristic)
        status = "Connected to \(connectedMacName). Enabling status updates…"
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard central.state == .poweredOn, let current = self.peripheral, let currentStatus = statusCharacteristic,
              peripheral === current, peripheral.state == .connected, characteristic === currentStatus,
              currentAttemptGeneration != nil, !disconnecting else { return }
        guard error == nil, characteristic.isNotifying else {
            appendConnectionIncident("status notification enablement failed", error: error)
            let reason: String
            if let error {
                reason = "Could not subscribe to Mac status (phase: \(connectionPhase.rawValue)). \(boundedError(error)) Automatic retry is bounded."
            } else {
                reason = "Could not subscribe to Mac status (phase: \(connectionPhase.rawValue)): notification enablement not confirmed (no OS error supplied). Automatic retry is bounded."
            }
            failCurrentAttempt(reason, terminal: false); return
        }
        setupDeadlineWorkItem?.cancel(); setupDeadlineWorkItem = nil
        // Once explicit setup succeeds, later transport loss follows the saved-peer bounded policy.
        currentAttemptIsAutomatic = reconnectAutomatically && wantsConnection && !manualConnectionRequired
        connectionPhase = .ready
        status = "Connected to \(connectedMacName). Awaiting approval."
        subscribed = true; heartbeatTimer?.invalidate()
        // Human approval is intentionally not timed out. The setup deadline ends once notifications work.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            // Installed while main-actor isolated; enqueue synchronously to retain heartbeat order.
            MainActor.assumeIsolated { self?.enqueue(.hello) }
        }; enqueue(.hello)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard central.state == .poweredOn, let current = self.peripheral, let currentStatus = statusCharacteristic,
              peripheral === current, peripheral.state == .connected, characteristic === currentStatus,
              currentAttemptGeneration != nil, !disconnecting else { return }
        guard error == nil else {
            appendConnectionIncident("status notification callback failed", error: error)
            failCurrentAttempt("Mac status notification failed. Reconnect to continue.", terminal: true)
            return
        }
        guard let data = characteristic.value, let remoteStatus = Wire.decodeStatus(data) else {
            failCurrentAttempt("Mac status used an invalid protocol. Rebuild BOTH apps, then reconnect.", terminal: true)
            return
        }
        switch remoteStatus {
        case .waitingForApproval:
            isApproved = false; resetAppearancePresetSync(clearPublishedCatalog: true)
            abandonCalibrationLocally(); endPointerHold(); stopTracking(); cancelUnsentRecenterRequest(); stopMotionStream()
            guard pendingRecenterEpoch != nil else {
                status = "Connected to \(connectedMacName). Awaiting approval."
                break
            }
            cancelCurrentConnection(status: "Mac approval was withdrawn while Recenter was pending. Reconnect to continue.")
        case .approved:
            let newlyApproved = !isApproved
            isApproved = true
            markConnectionStableSoon()
            if newlyApproved {
                motionNeedsRecenter = false
                beginAppearancePresetSync(clearPublishedCatalog: true)
            }
            if !motionNeedsRecenter {
                status = "Connected to \(connectedMacName). Ready."
                ensureMotionStream()
            }
        case .rejected:
            isApproved = false; resetAppearancePresetSync(clearPublishedCatalog: true)
            abandonCalibrationLocally(); endPointerHold(); stopTracking(); stopMotionStream(); status = "Mac approval was declined."
        case .stopped:
            isApproved = false; resetAppearancePresetSync(clearPublishedCatalog: true)
            abandonCalibrationLocally(); endPointerHold(); stopTracking(); stopMotionStream(); status = "Remote control was stopped on the Mac."
        case .heartbeatTimedOut:
            isApproved = false; resetAppearancePresetSync(clearPublishedCatalog: true)
            abandonCalibrationLocally(); endPointerHold(); stopTracking(); stopMotionStream(); status = "Mac session timed out. Reconnect to continue."
        case let .recentered(epoch):
            guard epoch == pendingRecenterEpoch else { return }
            pendingRecenterEpoch = nil; recenterNeedsSample = false
            status = motionNeedsRecenter
                ? "Recenter acknowledgement received, but attitude updates remain unavailable. Resolve the sensor issue, then use Recenter to restart."
                : "Recentered. Continuous tracking resumed; hold to show the pointer."
            if !motionNeedsRecenter { beginTrackingIfPossible() }
        case let .calibrationReady(session, step):
            guard activeCalibrationSession == session else { return }
            calibrationStep = step; calibrationWaiting = false
            calibrationMessage = "Aim the iPhone at the \(step.title) marker, then tap Record."
        case let .calibrationResult(session, xGain, yGain):
            guard activeCalibrationSession == session, xGain.isFinite, yGain.isFinite,
                  (PointerSensitivity.minimum...PointerSensitivity.maximum).contains(xGain),
                  (PointerSensitivity.minimum...PointerSensitivity.maximum).contains(yGain) else { return }
            calibrationProposal = (xGain, yGain); calibrationWaiting = false
            calibrationMessage = "Review the proposed independent values. Nothing changes until Apply."
        case let .calibrationFailed(session, message):
            guard activeCalibrationSession == session else { return }
            calibrationWaiting = false; calibrationFailed = true; calibrationMessage = message
        case let .calibrationApplied(session):
            guard activeCalibrationSession == session else { return }
            finishCalibrationLocally(message: "Calibration applied on the Mac.")
        case let .calibrationCancelled(session):
            guard activeCalibrationSession == session else { return }
            finishCalibrationLocally(message: "Calibration cancelled.")
        case let .presetCatalogPage(requestID, revision, slot, name, selected):
            guard let request = completePresetRequest(requestID), case let .catalog(expected) = request.kind,
                  expected == slot else { return }
            if refreshPresetsAfterRequest {
                refreshPresetsAfterRequest = false; restartPresetPaging(); return
            }
            if pagingRevision == nil {
                pagingRevision = revision; pagingSelectedSlot = selected; pagingSelectionEstablished = true
            } else if pagingRevision != revision || !pagingSelectionEstablished || pagingSelectedSlot != selected {
                restartPresetPaging(); return
            }
            if let name { pagingNames[slot] = name } else { pagingNames.removeValue(forKey: slot) }
            if slot.rawValue + 1 < UInt8(PresetSlot.capacity), let next = PresetSlot(rawValue: slot.rawValue + 1) {
                requestAppearancePresetPage(next)
            } else {
                presetCatalogRevision = revision
                appearancePresetItems = PresetSlot.allCases.compactMap { current in
                    pagingNames[current].map { AppearancePresetItem(slot: current, name: $0.value) }
                }
                selectedAppearancePreset = selected
                appearancePresetState = "Appearance: \(selectedAppearancePresetName)"
                presetPagingRestarts = 0
            }
        case let .presetSelected(requestID, revision, selected):
            guard let request = completePresetRequest(requestID), case let .select(expected) = request.kind,
                  expected == selected else { return }
            presetCatalogRevision = revision; selectedAppearancePreset = selected
            appearancePresetState = "Appearance: \(selectedAppearancePresetName)"
            if refreshPresetsAfterRequest { refreshPresetsAfterRequest = false; beginAppearancePresetSync(clearPublishedCatalog: true) }
        case let .presetSaved(requestID, revision, slot, name, selected):
            guard let request = completePresetRequest(requestID), case let .save(expectedSlot, expectedName, _) = request.kind,
                  expectedSlot == slot, expectedName == name, selected == slot else { return }
            presetCatalogRevision = revision
            appearancePresetItems.removeAll { $0.slot == slot }
            appearancePresetItems.append(AppearancePresetItem(slot: slot, name: name.value))
            appearancePresetItems.sort { $0.slot.rawValue < $1.slot.rawValue }
            selectedAppearancePreset = selected; appearancePresetState = "Appearance: \(name.value)"
            if refreshPresetsAfterRequest { refreshPresetsAfterRequest = false; beginAppearancePresetSync(clearPublishedCatalog: true) }
        case let .presetDeleted(requestID, revision, slot, selected):
            guard let request = completePresetRequest(requestID), case let .delete(expected) = request.kind,
                  expected == slot else { return }
            presetCatalogRevision = revision; appearancePresetItems.removeAll { $0.slot == slot }
            selectedAppearancePreset = selected; appearancePresetState = "Appearance: \(selectedAppearancePresetName)"
            if refreshPresetsAfterRequest { refreshPresetsAfterRequest = false; beginAppearancePresetSync(clearPublishedCatalog: true) }
        case let .presetConflict(requestID, revision, slot, existingName):
            guard let request = completePresetRequest(requestID), case let .save(expectedSlot, requestedName, overwrite) = request.kind,
                  expectedSlot == slot, !overwrite else { return }
            presetCatalogRevision = revision
            conflictingSave = (slot, requestedName)
            presetConflictDescription = "Slot \(slot.displayNumber) now contains \(existingName.value). Overwrite it with \(requestedName.value)?"
        case let .presetRejected(requestID, revision, reason):
            guard completePresetRequest(requestID) != nil else { return }
            presetCatalogRevision = revision
            appearancePresetState = reason == .missingSlot
                ? "Preset changed on the Mac. Resync required."
                : "Preset request was unavailable. Retry sync."
            if reason == .missingSlot { beginAppearancePresetSync(clearPublishedCatalog: true) }
        case .presetInvalidated:
            guard isApproved else { return }
            if pendingPresetRequest != nil {
                refreshPresetsAfterRequest = true
            } else {
                // Every authenticated invalidation is authoritative, even at counter exhaustion.
                beginAppearancePresetSync(clearPublishedCatalog: true)
            }
        }
        if case .rejected = remoteStatus { let reason = status; disconnect(); status = reason }
        if case .stopped = remoteStatus { let reason = status; disconnect(); status = reason }
        if case .heartbeatTimedOut = remoteStatus { let reason = status; disconnect(); status = reason }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard central.state == .poweredOn, let current = self.peripheral, let currentControl = controlCharacteristic,
              peripheral === current, peripheral.state == .connected, characteristic === currentControl,
              currentAttemptGeneration != nil, !disconnecting else { return }
        let sent = inFlightMessage
        if let error { appendConnectionIncident("ATT control write callback failed", error: error) }
        inFlightMessage = nil
        writeInFlight = false
        inFlightControlSubmittedAt = nil
        if error != nil, let sent {
            // A failed/rejected tracking start is never retried: an ATT rejection stays rejected,
            // and local teardown must never put that obsolete start back on wire.
            if case let .tracking(enabled: true, failedSession) = sent {
                // Only the current start may tear down this connection. A late obsolete failure
                // must not cancel a newer active session.
                if activePointerSession == failedSession {
                    failCurrentAttempt("Continuous tracking was not accepted. Rebuild BOTH apps if versions differ, then tap Connect to retry.", terminal: true)
                }
            } else if case let .recenter(epoch) = sent,
                      pendingRecenterEpoch != epoch {
                // A matching status can arrive before its ATT callback; never revive that epoch.
                writeRetryCount = 0
            } else if let calibrationSession = sent.calibrationSession,
                      activeCalibrationSession != calibrationSession {
                writeRetryCount = 0 // A cancelled/stale calibration command must never be revived.
            } else if writeRetryCount < 3 {
                guard orderedMessages.count < 64 else { forceDisconnectForQueueFull(); return }
                writeRetryCount += 1
                orderedMessages.insert(sent, at: 0)
                status = "Retrying a control command…"
            } else {
                disconnect(); status = "Control delivery failed. Reconnect to continue."; return
            }
        } else {
            writeRetryCount = 0
            if case let .tracking(enabled, session)? = sent, enabled,
               activePointerSession == Optional(session) {
                guard let angles = currentAngles else {
                    stopTracking(); status = "No valid attitude yet. Aim the phone top edge forward and use Recenter."
                    drainWrites(); return
                }
                acknowledgedPointerSession = session
                holdAngleBaseline = angles
                cumulativeOffset = .zero
                lastMotionTimestamp = nil
                if pointerEnabled { enqueue(.visibility(visible: true, session: session)) }
            } else if case let .calibrationStart(session)? = sent,
                      activeCalibrationSession == session, !calibrationStartAcknowledged {
                calibrationStartAcknowledged = true
                ensureMotionStream()
            }
        }
        drainWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let current = self.peripheral, peripheral === current, currentAttemptGeneration != nil, !disconnecting else { return }
        drainMotion()
    }

    private func enqueue(_ message: RemoteMessage) {
        guard central.state == .poweredOn, subscribed, !disconnecting, peripheral?.state == .connected else { return }
        if case .hello = message { if case .hello? = inFlightMessage { return }; if orderedMessages.contains(where: { if case .hello = $0 { return true }; return false }) { return } }
        else { guard isApproved else { return } }
        guard orderedMessages.count < 64 else { forceDisconnectForQueueFull(); return }
        orderedMessages.append(message)
        drainWrites()
    }
    /// Removes an unsent tracking start. If it already left the queue, its stop goes next.
    private func enqueueTrackingStop(for session: UInt64, wasAcknowledged: Bool) {
        let hadQueuedStart = orderedMessages.contains { message in
            if case let .tracking(enabled, queuedSession) = message { return enabled && queuedSession == session }
            return false
        }
        orderedMessages.removeAll { message in
            switch message {
            case let .tracking(_, queuedSession), let .visibility(_, queuedSession): return queuedSession == session
            default: return false
            }
        }
        let startInFlight: Bool
        if case let .tracking(enabled, inFlightSession)? = inFlightMessage {
            startInFlight = enabled && inFlightSession == session
        } else { startInFlight = false }
        guard !hadQueuedStart, (startInFlight || wasAcknowledged) else { return }
        guard orderedMessages.count < 64 else { forceDisconnectForQueueFull(); return }
        orderedMessages.insert(.tracking(enabled: false, session: session), at: 0)
        drainWrites()
    }

    private func forceDisconnectForQueueFull() {
        // Do not recurse through enqueue/endPointerHold while the ordered queue is saturated.
        appendConnectionIncident("bounded control queue full", cancellationReason: "Control queue full. Reconnect to continue.")
        let current = peripheral
        disconnecting = true
        if activePointerSession != nil { finishHoldDiagnostics() }
        activePointerSession = nil
        acknowledgedPointerSession = nil
        activeCalibrationSession = nil; calibrationStartAcknowledged = false
        calibrationWaiting = false; calibrationFailed = false; calibrationProposal = nil; calibrationPresented = false
        physicalPointerHold = false
        holdLockEnabled = false
        pointerEnabled = false
        stopMotionStream()
        nextMotionSequence = 0
        pendingMotion = nil
        orderedMessages.removeAll()
        status = "Control queue full. Reconnect to continue."
        guard let current else { resetConnection(); return }
        cancellationPendingID = current.identifier
        cancellationPendingGeneration = currentAttemptGeneration
        cancellationDisposition = .none
        if cancelPeripheralLocallyAndIfAllowed(current) {
            if appIsActive { startCancellationWatchdog(for: current, generation: cancellationPendingGeneration, manager: central) }
        } else {
            cancellationPendingID = nil; cancellationPendingGeneration = nil; cancellationDisposition = .none
            resetConnection()
        }
    }

    private func drainWrites() {
        guard central.state == .poweredOn, !writeInFlight, let peripheral,
              peripheral.state == .connected, let controlCharacteristic else { return }
        guard !orderedMessages.isEmpty else { return }
        let message = orderedMessages.removeFirst()
        guard let data = Wire.encode(message) else {
            if let requestID = message.presetRequestID, pendingPresetRequest?.id == requestID {
                _ = completePresetRequest(requestID); presetCatalogRevision = nil
                appearancePresetState = "Preset command is unavailable at this Bluetooth packet size."
                return
            }
            forceDisconnectForQueueFull(); status = "A control command could not be encoded. Reconnect to continue."
            return
        }
        guard data.count <= Wire.maximumBytes, data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            if let requestID = message.presetRequestID, pendingPresetRequest?.id == requestID {
                _ = completePresetRequest(requestID); presetCatalogRevision = nil
                appearancePresetState = "Preset command is unavailable at this Bluetooth packet size."
                return
            }
            forceDisconnectForQueueFull(); status = "A command exceeded the Bluetooth packet limit. Reconnect to continue."
            return
        }
        inFlightMessage = message; writeInFlight = true
        inFlightControlSubmittedAt = ProcessInfo.processInfo.systemUptime
        peripheral.writeValue(data, for: controlCharacteristic, type: .withResponse)
    }

    private func abandonCalibrationLocally() {
        if let session = activeCalibrationSession { orderedMessages.removeAll { $0.calibrationSession == session } }
        activeCalibrationSession = nil; calibrationStartAcknowledged = false; calibrationWaiting = false; calibrationFailed = false
        calibrationProposal = nil; calibrationPresented = false
        cumulativeOffset = .zero
    }

    private func finishCalibrationLocally(message: String) {
        activeCalibrationSession = nil; calibrationStartAcknowledged = false; calibrationWaiting = false; calibrationFailed = false
        cumulativeOffset = .zero
        calibrationMessage = message; calibrationPresented = false; calibrationProposal = nil
    }

    private func submitLatestMotion(session: UInt64) {
        guard activePointerSession == Optional(session), acknowledgedPointerSession == Optional(session) else { return }
        guard nextMotionSequence != UInt32.max else {
            endPointerHold(); stopTracking(); status = "Motion sequence completed. Reconnect to continue."; return
        }
        nextMotionSequence += 1
        guard let packet = MotionPacket(session: session, sequence: nextMotionSequence,
                                        x: Float(cumulativeOffset.width), y: Float(cumulativeOffset.height)) else {
            endPointerHold(); stopTracking(); status = "Motion value was unsafe; tracking stopped."; return
        }
        if pendingMotion != nil { holdPendingOverwriteCount += 1 }
        pendingMotion = packet
        drainMotion()
    }

    private func drainMotion() {
        guard central.state == .poweredOn, let peripheral, peripheral.state == .connected,
              let motionCharacteristic, peripheral.canSendWriteWithoutResponse,
              let packet = pendingMotion,
              activePointerSession == Optional(packet.session),
              acknowledgedPointerSession == Optional(packet.session) else { return }
        let data = packet.encoded()
        guard data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            pendingMotion = nil
            endPointerHold(); stopTracking()
            status = "The negotiated Bluetooth packet size is too small for motion."
            return
        }
        pendingMotion = nil
        peripheral.writeValue(data, for: motionCharacteristic, type: .withoutResponse)
        lastMotionSubmittedAt = ProcessInfo.processInfo.systemUptime
        submittedInRateWindow += 1 // Submitted to CoreBluetooth, not confirmed delivered.
        holdSubmittedCount += 1
    }

    /// One xArbitraryZVertical stream spans idle time, holds, and calibration while this approved
    /// foreground connection lives. Quaternions are therefore never compared across Core Motion runs.
    private func ensureMotionStream() {
        guard appIsActive, isApproved, !disconnecting, !motionNeedsRecenter,
              motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motionGeneration &+= 1
        let generation = motionGeneration
        attitudeTracker = PointerAttitudeTracker(); currentAngles = nil; holdAngleBaseline = nil
        motion.deviceMotionUpdateInterval = 1.0 / Double(requestedSamplingRate)
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] update, error in
            // Core Motion delivers this stream on the requested .main queue.
            MainActor.assumeIsolated {
                guard let self, self.motionGeneration == generation, self.appIsActive, self.isApproved else { return }
            guard error == nil, let update else {
                self.motionNeedsRecenter = true
                let cancelledCalibration = self.activeCalibrationSession != nil
                self.cancelCalibration()
                self.endPointerHold(); self.stopTracking()
                self.cancelUnsentRecenterRequest()
                self.stopMotionStream()
                self.status = cancelledCalibration
                    ? "Attitude updates stopped and calibration was cancelled. Tilt the phone if asked, then use Recenter to restart."
                    : "Attitude updates stopped. Tilt the phone if asked, then use Recenter to restart tracking."
                return
            }
            self.sampledInRateWindow += 1
            let q = update.attitude.quaternion, m = update.attitude.rotationMatrix, g = update.gravity
            let sample = PointerAttitudeSample(
                quaternion: (q.x, q.y, q.z, q.w),
                matrix: (m.m11, m.m12, m.m13, m.m21, m.m22, m.m23, m.m31, m.m32, m.m33),
                gravity: .init(x: g.x, y: g.y, z: g.z))

            let result: Result<(x: Double, y: Double), PointerAttitudeFailure>
            if self.recenterNeedsSample || self.currentAngles == nil {
                result = self.attitudeTracker.reset(with: sample)
            } else {
                result = self.attitudeTracker.angles(for: sample)
            }
            let angles: (x: Double, y: Double)
            switch result {
            case let .failure(failure):
                self.currentAngles = nil
                if self.activePointerSession != nil {
                    self.holdRejectedDTCount += 1; self.endPointerHold(); self.stopTracking()
                }
                if self.activeCalibrationSession != nil { self.cancelCalibration() }
                if failure == .ambiguousConvention {
                    // Do not choose a direction from an uninformative vertical-only pose, or
                    // silently latch later without the explicit tilted Recenter requested below.
                    self.motionNeedsRecenter = true
                    self.cancelUnsentRecenterRequest()
                    self.stopMotionStream()
                }
                self.status = failure.userMessage
                return
            case let .success(value):
                angles = value; self.currentAngles = value
            }

            if self.recenterNeedsSample, let epoch = self.pendingRecenterEpoch {
                self.recenterNeedsSample = false
                self.holdAngleBaseline = nil; self.cumulativeOffset = .zero; self.pendingMotion = nil
                self.enqueue(.recenter(epoch: epoch))
                return
            }
            if self.activeCalibrationSession != nil, self.calibrationStartAcknowledged {
                self.cumulativeOffset = CGSize(width: angles.x * PointerSensitivity.referenceGain,
                                               height: angles.y * PointerSensitivity.referenceGain)
            }
            self.beginTrackingIfPossible()
            guard let session = self.activePointerSession,
                  self.acknowledgedPointerSession == session,
                  let baseline = self.holdAngleBaseline else { return }
            self.holdSampleCount += 1
            let timestamp = update.timestamp
            if let previous = self.lastMotionTimestamp, timestamp.isFinite {
                let gap = timestamp - previous
                if gap.isFinite, gap > 0 { self.holdMaxTimestampGap = max(self.holdMaxTimestampGap, gap) }
            }
            self.lastMotionTimestamp = timestamp.isFinite ? timestamp : self.lastMotionTimestamp
            let relativeX = angles.x - baseline.x, relativeY = angles.y - baseline.y
            guard relativeX.isFinite, relativeY.isFinite else { self.holdRejectedDTCount += 1; return }
            self.holdAcceptedDTCount += 1; self.holdAngleXSum += relativeX; self.holdAngleYSum += relativeY
            self.cumulativeOffset = CGSize(width: relativeX * PointerSensitivity.referenceGain,
                                           height: relativeY * PointerSensitivity.referenceGain)
            guard abs(self.cumulativeOffset.width) <= CGFloat(MotionPacket.maximumCumulativeDisplacement),
                  abs(self.cumulativeOffset.height) <= CGFloat(MotionPacket.maximumCumulativeDisplacement) else {
                self.endPointerHold(); self.stopTracking(); self.status = "Pointing angle exceeded the finite transport range; tracking stopped."; return
            }
                self.submitLatestMotion(session: session)
            }
        }
    }

    /// Stops only local sensing. A queued, submitted, or status-waiting Recenter remains a transport fence.
    private func stopMotionStream() {
        motionGeneration &+= 1
        motion.stopDeviceMotionUpdates()
        attitudeTracker = PointerAttitudeTracker(); currentAngles = nil; holdAngleBaseline = nil
        lastMotionTimestamp = nil
    }

    /// Before a fresh sample, this model owns the request and has not placed a Recenter on transport.
    private func cancelUnsentRecenterRequest() {
        guard recenterNeedsSample, let epoch = pendingRecenterEpoch else { return }
        let queued = orderedMessages.contains { if case let .recenter(queuedEpoch) = $0 { return queuedEpoch == epoch }; return false }
        let inFlight: Bool
        if case let .recenter(inFlightEpoch)? = inFlightMessage { inFlight = inFlightEpoch == epoch } else { inFlight = false }
        guard !queued, !inFlight else { return }
        pendingRecenterEpoch = nil; recenterNeedsSample = false
    }

    private func resetConnection() {
        resetAppearancePresetSync(clearPublishedCatalog: true)
        appearancePresetState = "Appearance presets unavailable"
        cancelAllConnectionWork()
        peripheralDelegateProxy?.invalidate(); peripheralDelegateProxy = nil; peripheral?.delegate = nil
        forceClearPointerVisibility(); stopTracking()
        activeCalibrationSession = nil; calibrationStartAcknowledged = false; calibrationWaiting = false; calibrationFailed = false
        calibrationProposal = nil; calibrationPresented = false; stopMotionStream(); cumulativeOffset = .zero
        motionNeedsRecenter = false
        isApproved = false; subscribed = false; disconnecting = false; heartbeatTimer?.invalidate(); heartbeatTimer = nil
        controlCharacteristic = nil; statusCharacteristic = nil; motionCharacteristic = nil; peripheral = nil
        currentAttemptGeneration = nil; currentAttemptIsAutomatic = false; connectionPhase = .connecting
        currentMacID = nil; currentMacName = nil
        acknowledgedPointerSession = nil; nextCalibrationSession = 0; nextMotionSequence = 0
        pendingRecenterEpoch = nil; recenterNeedsSample = false
        writeInFlight = false; inFlightMessage = nil; inFlightControlSubmittedAt = nil
        lastMotionSubmittedAt = nil
        writeRetryCount = 0; orderedMessages.removeAll(); pendingMotion = nil
    }

    deinit {
        // CoreBluetooth commands are deliberately not issued from teardown: manager readiness is
        // not guaranteed here. Delegate ownership and all remaining local state die with the model.
        central?.delegate = nil
        peripheral?.delegate = nil
    }
}

private enum PhoneTheme {
    static let canvas = Color(red: 0.035, green: 0.06, blue: 0.11)
    static let surface = Color(red: 0.08, green: 0.12, blue: 0.19)
    static let teal = Color(red: 0.18, green: 0.80, blue: 0.72)
    static let violet = Color(red: 0.62, green: 0.48, blue: 0.93)
}

struct PhoneRemoteView: View {
    @StateObject private var model = PhoneRemoteModel()
    @ScaledMetric(relativeTo: .body) private var scriptTextSize: CGFloat = 20
    @State private var settingsPresented = false
    @State private var resetTimerConfirmationPresented = false
    @State private var presetSavePresented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            // Compact controls leave room for the script; short phones can scroll the main screen.
            let compact = proxy.size.height < 900 || proxy.size.width > proxy.size.height
            let holdPadMinimum: CGFloat = compact ? 86 : 150
            ScrollView {
            VStack(spacing: compact ? 8 : 14) {
                HStack {
                    Text("Pointer Remote")
                        .font(.system(size: compact ? 24 : 34, weight: .bold, design: .rounded))
                    Spacer()
                    Button {
                        model.endPointerHold()
                        settingsPresented = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Settings")
                }

                Text(model.status)
                    .font(compact ? .footnote : .body)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(compact ? 2 : 3)
                    .frame(maxWidth: .infinity, minHeight: compact ? 36 : 48)
                    .padding(.horizontal, 10)
                    .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                PhoneAppearancePresetControls(model: model) { presetSavePresented = true }

                Button { model.recenter() } label: {
                    Label("Recenter", systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 120, minHeight: 44)
                }
                .buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.teal))
                .disabled(!model.canRecenter)
                .accessibilityHint("Centers the Mac pointer, rebuilds the gravity-level reference, and renews continuous tracking. An active hold is hidden.")

                HStack(spacing: compact ? 8 : 12) {
                    Button { model.toggleHoldLock() } label: {
                        VStack(spacing: 5) {
                            Image(systemName: model.holdLockEnabled ? "lock.fill" : "lock.open")
                            Text(model.holdLockEnabled ? "Unlock" : "Hold Lock")
                                .font(.caption.weight(.bold))
                                .multilineTextAlignment(.center)
                        }
                        .frame(minWidth: compact ? 82 : 96, minHeight: 58)
                    }
                    .buttonStyle(MaterialPhoneButtonStyle(accent: model.holdLockEnabled ? PhoneTheme.violet : PhoneTheme.surface))
                    .disabled(!model.canToggleHoldLock)
                    .accessibilityLabel(model.holdLockEnabled ? "Unlock Hold Lock" : "Hold Lock")
                    .accessibilityValue(model.holdLockEnabled ? "Locked" : "Unlocked")
                    .accessibilityHint(model.holdLockEnabled
                                       ? "Drops the lock. A current physical Point hold remains visible until release."
                                       : "Keeps the pointer visible without resetting its tracking session or position.")

                    HoldToMoveControl(isEnabled: model.canBeginPointerHold,
                                      isPhysicallyHolding: model.physicalPointerHold,
                                      isLocked: model.holdLockEnabled,
                                      onBegan: { model.beginPointerHold() }, onFinished: { model.endPointerHold() })
                        .frame(maxWidth: .infinity, minHeight: holdPadMinimum, maxHeight: holdPadMinimum)
                        .accessibilityLabel("Point")
                        .accessibilityHint("Press and hold to show the continuously tracked Mac pointer. Release hides it unless Hold Lock is on.")
                }

                HStack(spacing: compact ? 12 : 16) {
                    Button { model.sendKey(.left) } label: {
                        Image(systemName: "play.fill").rotationEffect(.degrees(180))
                    }
                    .accessibilityLabel("Previous slide")
                    Button { model.sendKey(.right) } label: { Image(systemName: "play.fill") }
                        .accessibilityLabel("Next slide")
                }
                .buttonStyle(RemoteButtonStyle(compact: compact))
                .disabled(!model.isApproved)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speaker Notes").font(.headline)
                        Spacer()
                        Picker("Script slide", selection: Binding(
                            get: { model.speakerScript.index },
                            set: { model.selectScriptSlide($0) }
                        )) {
                            ForEach(0..<SpeakerScript.slides.count, id: \.self) { index in
                                Text("\(index + 1) / \(SpeakerScript.slides.count)").tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityHint("Aligns the script only; does not send a slide key. Select 1 to reset.")
                    }
                    ScrollView {
                        Text(SpeakerScript.slides[model.speakerScript.index])
                            .font(.system(size: scriptTextSize))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)
                    }
                    .id(model.speakerScript.index)
                    .frame(height: compact ? 150 : 210)
                    Text("Local cue · use the slide menu to align / reset")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
                .padding(12)
                .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                VStack(spacing: 4) {
                    Text(model.timerMode.title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: compact ? 16 : 24) {
                        Button(model.timerRunning ? "Stop" : "Start") { model.toggleTimer() }
                            .buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.violet))
                            .accessibilityLabel(model.timerRunning ? "Stop timer" : "Start timer")
                        Text(String(format: "%02d:%02d", model.timerDisplaySeconds / 60, model.timerDisplaySeconds % 60))
                            .font(.system(size: compact ? 28 : 42, design: .monospaced))
                            .accessibilityLabel(model.timerAccessibilityLabel)
                        Button {
                            model.endPointerHold()
                            resetTimerConfirmationPresented = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Reset timer")
                        .accessibilityHint("Asks before stopping and clearing the timer.")
                        .disabled(!model.canResetTimer)
                    }
                    if let milestone = model.timerMilestoneText { Text(milestone).font(.caption2).foregroundStyle(PhoneTheme.teal) }
                }
            }
            .padding(compact ? 10 : 16)
            .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(PhoneTheme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .tint(PhoneTheme.teal)
        .alert("Reset timer?", isPresented: $resetTimerConfirmationPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { model.resetTimer() }
        } message: {
            Text(model.timerMode == .countDown ? "Stop the timer and reset it to its full countdown duration?" : "Stop the timer and reset it to 00:00?")
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(model: model)
                .onAppear { model.endPointerHold() }
        }
        .sheet(isPresented: $presetSavePresented) {
            PhonePresetSaveSheet(model: model)
        }
        .alert("Preset changed on the Mac", isPresented: Binding<Bool>(
            get: { model.presetConflictDescription != nil },
            set: { if !$0 { model.dismissPresetConflict() } }
        )) {
            Button("Cancel", role: .cancel) { model.dismissPresetConflict() }
            Button("Overwrite", role: .destructive) { model.confirmConflictingPresetOverwrite() }
        } message: {
            Text(model.presetConflictDescription ?? "The slot changed. Sync again before saving.")
        }
        .onAppear {
            updateIdleTimer(for: scenePhase)
            if scenePhase == .active { model.appBecameActive() } else { model.appBecameInactive() }
        }
        .onDisappear { model.forceClearPointerVisibility(); UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            updateIdleTimer(for: phase)
            if phase == .active { model.appBecameActive() } else { model.appBecameInactive() }
        }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }
}

private struct PhoneAppearancePresetControls: View {
    @ObservedObject var model: PhoneRemoteModel
    let showSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Appearance").font(.caption.weight(.semibold))
            Menu {
                ForEach(model.appearancePresetItems) { item in
                    Button(item.name) { model.selectAppearancePreset(item.slot) }
                        .disabled(!model.canUseAppearancePresets)
                }
                if !model.canUseAppearancePresets {
                    Button("Retry Sync") { model.retryAppearancePresetSync() }
                        .disabled(!model.isApproved || model.presetRequestPending)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.canUseAppearancePresets ? model.selectedAppearancePresetName : model.appearancePresetState).lineLimit(1)
                    Image(systemName: "chevron.down")
                }
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .disabled(!model.isApproved || model.presetRequestPending)
            Button("Save…", action: showSave)
                .controlSize(.small).disabled(!model.canUseAppearancePresets)
        }
        .padding(.horizontal, 10)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

private struct PhonePresetSaveSheet: View {
    @ObservedObject var model: PhoneRemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var slot: PresetSlot = PresetSlot.allCases[0]
    @State private var name = ""
    @State private var overwriteConfirmation = false
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("This saves the Mac’s current appearance. The iPhone does not keep a local copy.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Slot", selection: $slot) {
                    ForEach(PresetSlot.allCases) { candidate in
                        Text(slotLabel(candidate)).tag(candidate)
                    }
                }.pickerStyle(.menu)
                TextField("Preset name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                if let validationMessage { Text(validationMessage).font(.footnote).foregroundStyle(.orange) }
                Spacer()
            }
            .padding()
            .navigationTitle("Save Appearance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { submit() }.disabled(!model.canUseAppearancePresets) }
            }
        }
        .presentationDetents([.medium])
        .alert("Overwrite slot \(slot.displayNumber)?", isPresented: $overwriteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Overwrite", role: .destructive) {
                if model.saveCurrentMacAppearance(slot: slot, rawName: name, overwrite: true) { dismiss() }
            }
        } message: {
            Text("Replace \(model.appearancePresetItems.first(where: { $0.slot == slot })?.name ?? "this preset") with the current Mac appearance named \(name)?")
        }
    }

    private func slotLabel(_ slot: PresetSlot) -> String {
        let existing = model.appearancePresetItems.first { $0.slot == slot }?.name ?? "Empty"
        return "\(slot.displayNumber): \(existing)"
    }

    private func submit() {
        guard let canonical = PresetName(name) else {
            validationMessage = "Use a nonempty single-line name of at most 32 characters and 96 UTF-8 bytes."
            return
        }
        name = canonical.value; validationMessage = nil
        if model.appearancePresetItems.contains(where: { $0.slot == slot }) {
            overwriteConfirmation = true
        } else if model.saveCurrentMacAppearance(slot: slot, rawName: canonical.value, overwrite: false) {
            dismiss()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PhoneRemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var forgetAllConfirmationPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                    settingsCard("Connection") {
                        Text(model.status).foregroundStyle(.white.opacity(0.82))
                        Picker("Mac", selection: $model.selectedMacID) {
                            Text("Select a Mac").tag(UUID?.none)
                            ForEach(model.discoveredMacs) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.menu)
                        .tint(PhoneTheme.teal)
                        HStack {
                            Button("Search") { model.scanForMacs() }
                                .disabled(!model.canSearchForMacs)
                            Button("Connect") { model.connectSelectedMac() }
                                .disabled(!model.canConnectSelectedMac)
                            Button("Disconnect") { model.disconnect() }
                                .disabled(!model.canDisconnect)
                        }
                        .buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.violet))
                        Toggle("Reconnect automatically", isOn: Binding(get: { model.reconnectAutomatically }, set: { model.setReconnectAutomatically($0) }))
                        Text("Reconnect uses only the Mac you explicitly selected. It never starts pointer motion.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        Button("Forget All Macs…", role: .destructive) { forgetAllConfirmationPresented = true }
                            .buttonStyle(MaterialPhoneButtonStyle(accent: .red))
                        Text("Forgetting removes this app's saved Mac identifier, display name, and auto-reconnect choice. It does not change Bluetooth pairing or timer and motion settings.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                    }

                    settingsCard("Pointer") {
                        Text("Pointer sensitivity is set on the connected Mac. This iPhone always sends reference units.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        Picker("Requested sampling", selection: Binding(get: { model.requestedSamplingRate }, set: { model.setRequestedSamplingRate($0) })) {
                            Text("60 Hz").tag(60)
                            Text("100 Hz").tag(100)
                            Text("200 Hz Experimental").tag(200)
                        }
                        .pickerStyle(.menu)
                        .disabled(!model.canChangeSamplingRate)
                        Text("Measured sensor samples: \(model.measuredSamplesPerSecond)/s")
                            .monospacedDigit()
                        Text("Submitted motion packets: \(model.submittedMotionPacketsPerSecond)/s")
                            .monospacedDigit()
                        Text(model.lastHoldDiagnostics)
                            .font(.footnote).foregroundStyle(.white.opacity(0.82))
                        Text("200 Hz is experimental. This requests Core Motion; hardware may cap actual cadence. Submitted means handed to CoreBluetooth, not delivered.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        Text("Saved on this iPhone. Changing it while hidden safely renews continuous tracking at the retained Mac target with a fresh angle baseline.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        Text(model.motionAvailabilityDescription)
                            .font(.footnote).foregroundStyle(.white.opacity(0.82))
                        Button("Calibrate X and Y…") { model.startCalibration() }
                            .buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.teal))
                            .disabled(!model.canStartCalibration)
                        Text("Calibration guides Centre → Upper Left → Upper Right → Lower Right → Lower Left. Aim physically and explicitly record every marker; the Mac changes neither value until you confirm Apply.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                    }

                    settingsCard("Timer") {
                        Picker("Timer", selection: Binding(get: { model.timerMode }, set: { model.setTimerMode($0) })) {
                            ForEach(PhoneRemoteModel.TimerMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).disabled(!model.canConfigureTimer)
                        Stepper("Total minutes: \(model.timerTotalMinutes)", value: Binding(get: { model.timerTotalMinutes }, set: { model.setTimerTotalMinutes($0) }), in: 1...180)
                            .disabled(!model.canConfigureTimer || model.timerMode == .countUp)
                        Toggle("Warning enabled", isOn: Binding(get: { model.timerWarningEnabled }, set: { model.setTimerWarningEnabled($0) }))
                            .disabled(!model.canConfigureTimer || !model.warningIsAvailable || model.timerMode == .countUp)
                        if model.warningIsAvailable {
                            Stepper("Warning after \(model.timerWarningElapsedMinutes) elapsed min", value: Binding(get: { model.timerWarningElapsedMinutes }, set: { model.setTimerWarningElapsedMinutes($0) }), in: 0...(model.timerTotalMinutes - 1))
                                .disabled(!model.canConfigureTimer || !model.timerWarningEnabled || model.timerMode == .countUp)
                            Text("The warning is measured after elapsed minutes; for example, 8 of 10 means 2 minutes remain.")
                                .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        } else {
                            Text("Warning is unavailable for a 1-minute countdown.")
                                .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        }
                        Text(model.canConfigureTimer ? "Reset or keep the timer stopped at zero before changing timer settings." : "Reset the used timer before changing timer settings.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        Text(model.timerHapticsAvailable ? "Alerts use haptics only while this app is active; no sound is created." : "Timer haptics are unavailable on this device or could not start; no sound fallback is used.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                    }

                    settingsCard("Connection Diagnostics") {
                        Text("The newest 16 low-frequency connection incidents are retained across reconnects and relaunches. Each entry is bounded to 2,048 characters (not a byte guarantee) and excludes Mac names, Bluetooth identifiers, NSError userInfo, and motion/control payloads.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.72))
                        HStack {
                            Button("Copy Diagnostics") { model.copyConnectionDiagnostics() }
                                .buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.teal))
                            Button("Clear", role: .destructive) { model.clearConnectionDiagnostics() }
                                .buttonStyle(MaterialPhoneButtonStyle(accent: .red))
                        }
                        Text(model.connectionDiagnostics.isEmpty
                             ? "No connection incidents recorded."
                             : model.connectionDiagnostics.reversed().joined(separator: "\n\n—\n\n"))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsCard("Connection and permissions") {
                        Text("Select a Mac, connect, then approve this iPhone on the Mac. Bluetooth pairing and Mac approval are separate.")
                        Text("The Mac needs Accessibility permission for Previous/Next key events, but not for the on-screen pointer overlay. iOS system warnings about protected preferences or window scenes are platform diagnostics; this app does not change private APIs or permissions to suppress them.")
                    }
                }
                .font(.body)
                .padding()
            }
            .background(PhoneTheme.canvas.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityLabel("Close settings")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(PhoneTheme.teal)
        .alert("Forget all Macs?", isPresented: $forgetAllConfirmationPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Forget All Macs", role: .destructive) { model.forgetAllMacs() }
        } message: {
            Text("This removes only Pointer Remote's remembered Mac connection records and disconnects now. This cannot be undone; a future connection requires Search, selection, and explicit Connect. System Bluetooth pairing is unchanged.")
        }
        .sheet(isPresented: $model.calibrationPresented, onDismiss: { model.cancelCalibration() }) {
            CalibrationView(model: model)
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CalibrationView: View {
    @ObservedObject var model: PhoneRemoteModel

    var body: some View {
        VStack(spacing: 18) {
            Text("Pointer Calibration").font(.title2.bold())
            if let proposal = model.calibrationProposal {
                Text("Proposed sensitivity").font(.headline)
                HStack(spacing: 28) {
                    VStack { Text("X").foregroundStyle(.secondary); Text("\(Int(proposal.x.rounded()))").font(.title.monospacedDigit()) }
                    VStack { Text("Y").foregroundStyle(.secondary); Text("\(Int(proposal.y.rounded()))").font(.title.monospacedDigit()) }
                }
                Text(model.calibrationMessage).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelCalibration() }
                    Button("Apply") { model.applyCalibration() }.disabled(model.calibrationWaiting)
                }.buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.violet))
            } else if model.calibrationFailed {
                Text("Calibration not applied").font(.headline)
                Text(model.calibrationMessage).multilineTextAlignment(.center)
                Button("Close", role: .cancel) { model.cancelCalibration() }
                    .buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.violet))
            } else {
                Text("Step \(model.calibrationStep.rawValue + 1) of \(CalibrationStep.allCases.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(PhoneTheme.teal)
                Text(model.calibrationStep.title).font(.largeTitle.bold())
                Text(model.calibrationMessage).multilineTextAlignment(.center)
                Text("Keep motion continuous between records; do not return to a new baseline.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelCalibration() }
                    Button("Record") { model.recordCalibrationPoint() }
                        .disabled(!model.canRecordCalibration)
                }.buttonStyle(MaterialPhoneButtonStyle(accent: PhoneTheme.teal))
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .presentationDetents([.height(360)])
        .interactiveDismissDisabled(model.calibrationWaiting)
        .background(PhoneTheme.canvas.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

struct HoldToMoveControl: UIViewRepresentable {
    let isEnabled: Bool; let isPhysicallyHolding: Bool; let isLocked: Bool
    let onBegan: () -> Void; let onFinished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onBegan: onBegan, onFinished: onFinished) }
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel(); label.textAlignment = .center; label.numberOfLines = 2; label.layer.cornerRadius = 14; label.clipsToBounds = true
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        recognizer.minimumPressDuration = 0.2; recognizer.cancelsTouchesInView = true; label.addGestureRecognizer(recognizer); label.isUserInteractionEnabled = true
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        if isLocked {
            label.text = isPhysicallyHolding ? "Point\nHeld + locked" : "Point\nLocked visible"
        } else {
            label.text = isPhysicallyHolding ? "Point\nHolding visible" : "Point\nPress and hold"
        }
        label.font = .preferredFont(forTextStyle: .title2); label.adjustsFontForContentSizeCategory = true
        label.textColor = isEnabled ? UIColor(PhoneTheme.canvas) : .white
        label.backgroundColor = UIColor(isEnabled ? PhoneTheme.teal : PhoneTheme.surface)
        label.alpha = isEnabled ? 1 : 0.55; label.isUserInteractionEnabled = isEnabled
    }
    final class Coordinator: NSObject {
        let onBegan: () -> Void; let onFinished: () -> Void; private var began = false
        init(onBegan: @escaping () -> Void, onFinished: @escaping () -> Void) { self.onBegan = onBegan; self.onFinished = onFinished }
        @objc func changed(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: began = true; onBegan()
            case .ended, .cancelled, .failed: if began { began = false; onFinished() }
            default: break
            }
        }
    }
}

struct RemoteButtonStyle: ButtonStyle {
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 40 : 52, weight: .bold))
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: compact ? 104 : 128)
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .background(
                PhoneTheme.violet.opacity(configuration.isPressed ? 0.62 : 0.92),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
struct MaterialPhoneButtonStyle: ButtonStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View { configuration.label.fontWeight(.semibold).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 10).background(accent.opacity(configuration.isPressed ? 0.62 : 0.92), in: RoundedRectangle(cornerRadius: 11)).scaleEffect(configuration.isPressed ? 0.98 : 1) }
}
