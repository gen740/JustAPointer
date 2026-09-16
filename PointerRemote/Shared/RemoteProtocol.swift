import Foundation

/// Reference gain used by the iPhone's cumulative motion coordinates.
/// The Mac applies its independent live gains relative to this value exactly once per delta.
enum PointerSensitivity {
    static let minimum = 80.0
    static let maximum = 16_000.0
    static let referenceGain = 420.0
}

enum CalibrationStep: Int, Codable, CaseIterable {
    case centre = 0, upperLeft, upperRight, lowerRight, lowerLeft

    var title: String {
        switch self {
        case .centre: return "Centre"
        case .upperLeft: return "Upper Left"
        case .upperRight: return "Upper Right"
        case .lowerRight: return "Lower Right"
        case .lowerLeft: return "Lower Left"
        }
    }

    var next: CalibrationStep? { CalibrationStep(rawValue: rawValue + 1) }
}

/// A fixed wire identity. Presets never carry peer names or an unbounded identifier/catalog.
struct PresetSlot: RawRepresentable, Codable, Hashable, CaseIterable, Identifiable {
    static let capacity = 6
    static let allCases = (0..<capacity).map { PresetSlot(validatedRawValue: UInt8($0)) }
    let rawValue: UInt8
    var id: UInt8 { rawValue }
    var displayNumber: Int { Int(rawValue) + 1 }

    init?(rawValue: UInt8) {
        guard Int(rawValue) < Self.capacity else { return nil }
        self.rawValue = rawValue
    }
    private init(validatedRawValue: UInt8) { rawValue = validatedRawValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode(UInt8.self)
        guard let slot = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Preset slot is outside the fixed catalog.")
        }
        self = slot
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// Canonical, bounded user text shared by persistence and both UIs.
struct PresetName: Codable, Hashable {
    static let maximumScalars = 32
    static let maximumUTF8Bytes = 96
    let value: String

    init?(_ input: String) {
        let canonical = input.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty,
              canonical.unicodeScalars.count <= Self.maximumScalars,
              canonical.utf8.count <= Self.maximumUTF8Bytes,
              canonical.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
              }) else { return nil }
        value = canonical
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let name = Self(raw), name.value == raw else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Preset name is not canonical or is outside its bounds.")
        }
        self = name
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(value)
    }
}

enum PresetRejection: String, Codable {
    case unavailable, missingSlot, invalidRequest, counterExhausted
}

/// Small, bounded JSON messages carried only over the encrypted, acknowledged control characteristic.
/// Both apps must be rebuilt together when this protocol changes.
enum RemoteMessage: Codable {
    case tracking(enabled: Bool, session: UInt64)
    case visibility(visible: Bool, session: UInt64)
    case recenter(epoch: UInt64)
    case key(RemoteKey)
    case timer(running: Bool)
    case calibrationStart(session: UInt64)
    case calibrationCapture(session: UInt64, step: CalibrationStep, x: Double, y: Double)
    case calibrationCancel(session: UInt64)
    case calibrationApply(session: UInt64)
    case presetCatalogPage(requestID: UInt64, knownRevision: UInt64, slot: PresetSlot)
    case presetSelect(requestID: UInt64, slot: PresetSlot)
    case presetSave(requestID: UInt64, slot: PresetSlot, name: PresetName, overwrite: Bool)
    case presetDelete(requestID: UInt64, slot: PresetSlot)
    case hello

    enum RemoteKey: String, Codable { case left, right }
    enum Kind: String, Codable {
        case tracking, visibility, recenter, key, timer, calibrationStart, calibrationCapture,
             calibrationCancel, calibrationApply, presetCatalogPage, presetSelect, presetSave,
             presetDelete, hello
    }
    enum CodingKeys: String, CodingKey {
        case kind, enabled, visible, session, epoch, key, running, step, x, y
        case requestID, knownRevision, slot, name, overwrite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .tracking: self = .tracking(enabled: try c.decode(Bool.self, forKey: .enabled), session: try Self.validNonzero(.session, c))
        case .visibility: self = .visibility(visible: try c.decode(Bool.self, forKey: .visible), session: try Self.validNonzero(.session, c))
        case .recenter: self = .recenter(epoch: try Self.validNonzero(.epoch, c))
        case .key: self = .key(try c.decode(RemoteKey.self, forKey: .key))
        case .timer: self = .timer(running: try c.decode(Bool.self, forKey: .running))
        case .calibrationStart: self = .calibrationStart(session: try Self.validNonzero(.session, c))
        case .calibrationCapture:
            let x = try c.decode(Double.self, forKey: .x), y = try c.decode(Double.self, forKey: .y)
            guard x.isFinite, y.isFinite,
                  abs(x) <= Double(MotionPacket.maximumCumulativeDisplacement),
                  abs(y) <= Double(MotionPacket.maximumCumulativeDisplacement) else {
                throw DecodingError.dataCorruptedError(forKey: .x, in: c, debugDescription: "Unsafe calibration snapshot.")
            }
            self = .calibrationCapture(session: try Self.validNonzero(.session, c), step: try c.decode(CalibrationStep.self, forKey: .step), x: x, y: y)
        case .calibrationCancel: self = .calibrationCancel(session: try Self.validNonzero(.session, c))
        case .calibrationApply: self = .calibrationApply(session: try Self.validNonzero(.session, c))
        case .presetCatalogPage:
            self = .presetCatalogPage(requestID: try Self.validNonzero(.requestID, c),
                                      knownRevision: try c.decode(UInt64.self, forKey: .knownRevision),
                                      slot: try c.decode(PresetSlot.self, forKey: .slot))
        case .presetSelect:
            self = .presetSelect(requestID: try Self.validNonzero(.requestID, c), slot: try c.decode(PresetSlot.self, forKey: .slot))
        case .presetSave:
            self = .presetSave(requestID: try Self.validNonzero(.requestID, c), slot: try c.decode(PresetSlot.self, forKey: .slot),
                               name: try c.decode(PresetName.self, forKey: .name), overwrite: try c.decode(Bool.self, forKey: .overwrite))
        case .presetDelete:
            self = .presetDelete(requestID: try Self.validNonzero(.requestID, c), slot: try c.decode(PresetSlot.self, forKey: .slot))
        case .hello: self = .hello
        }
    }

    private static func validNonzero(_ key: CodingKeys, _ c: KeyedDecodingContainer<CodingKeys>) throws -> UInt64 {
        let value = try c.decode(UInt64.self, forKey: key)
        guard value != 0 else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Identifier must be nonzero.") }
        return value
    }

    var calibrationSession: UInt64? {
        switch self {
        case let .calibrationStart(session), let .calibrationCapture(session, _, _, _),
             let .calibrationCancel(session), let .calibrationApply(session): return session
        default: return nil
        }
    }
    var presetRequestID: UInt64? {
        switch self {
        case let .presetCatalogPage(id, _, _), let .presetSelect(id, _),
             let .presetSave(id, _, _, _), let .presetDelete(id, _): return id
        default: return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tracking(enabled, session): try c.encode(Kind.tracking, forKey: .kind); try c.encode(enabled, forKey: .enabled); try c.encode(session, forKey: .session)
        case let .visibility(visible, session): try c.encode(Kind.visibility, forKey: .kind); try c.encode(visible, forKey: .visible); try c.encode(session, forKey: .session)
        case let .recenter(epoch): try c.encode(Kind.recenter, forKey: .kind); try c.encode(epoch, forKey: .epoch)
        case let .key(key): try c.encode(Kind.key, forKey: .kind); try c.encode(key, forKey: .key)
        case let .timer(running): try c.encode(Kind.timer, forKey: .kind); try c.encode(running, forKey: .running)
        case let .calibrationStart(session): try c.encode(Kind.calibrationStart, forKey: .kind); try c.encode(session, forKey: .session)
        case let .calibrationCapture(session, step, x, y): try c.encode(Kind.calibrationCapture, forKey: .kind); try c.encode(session, forKey: .session); try c.encode(step, forKey: .step); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case let .calibrationCancel(session): try c.encode(Kind.calibrationCancel, forKey: .kind); try c.encode(session, forKey: .session)
        case let .calibrationApply(session): try c.encode(Kind.calibrationApply, forKey: .kind); try c.encode(session, forKey: .session)
        case let .presetCatalogPage(id, revision, slot): try c.encode(Kind.presetCatalogPage, forKey: .kind); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .knownRevision); try c.encode(slot, forKey: .slot)
        case let .presetSelect(id, slot): try c.encode(Kind.presetSelect, forKey: .kind); try c.encode(id, forKey: .requestID); try c.encode(slot, forKey: .slot)
        case let .presetSave(id, slot, name, overwrite): try c.encode(Kind.presetSave, forKey: .kind); try c.encode(id, forKey: .requestID); try c.encode(slot, forKey: .slot); try c.encode(name, forKey: .name); try c.encode(overwrite, forKey: .overwrite)
        case let .presetDelete(id, slot): try c.encode(Kind.presetDelete, forKey: .kind); try c.encode(id, forKey: .requestID); try c.encode(slot, forKey: .slot)
        case .hello: try c.encode(Kind.hello, forKey: .kind)
        }
    }
}

/// Exactly 20 bytes, little-endian: session UInt64, sequence UInt32, cumulative x/y Float32.
/// Cumulative coordinates make a dropped or coalesced packet harmless.
struct MotionPacket: Equatable {
    static let byteCount = 20
    static let maximumCumulativeDisplacement: Float = 100_000
    let session: UInt64; let sequence: UInt32; let x: Float; let y: Float

    init?(session: UInt64, sequence: UInt32, x: Float, y: Float) {
        guard session != 0, sequence != 0, x.isFinite, y.isFinite,
              abs(x) <= Self.maximumCumulativeDisplacement, abs(y) <= Self.maximumCumulativeDisplacement else { return nil }
        self.session = session; self.sequence = sequence; self.x = x; self.y = y
    }

    func encoded() -> Data {
        var bytes = [UInt8](); bytes.reserveCapacity(Self.byteCount)
        Self.appendLittleEndian(session, to: &bytes); Self.appendLittleEndian(sequence, to: &bytes)
        Self.appendLittleEndian(x.bitPattern, to: &bytes); Self.appendLittleEndian(y.bitPattern, to: &bytes)
        return Data(bytes)
    }

    static func decode(_ data: Data) -> MotionPacket? {
        guard data.count == byteCount else { return nil }
        let bytes = [UInt8](data)
        let session: UInt64 = readLittleEndian(bytes, at: 0); let sequence: UInt32 = readLittleEndian(bytes, at: 8)
        let xBits: UInt32 = readLittleEndian(bytes, at: 12); let yBits: UInt32 = readLittleEndian(bytes, at: 16)
        return MotionPacket(session: session, sequence: sequence, x: Float(bitPattern: xBits), y: Float(bitPattern: yBits))
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> T(shift))) }
    }
    private static func readLittleEndian<T: FixedWidthInteger>(_ bytes: [UInt8], at offset: Int) -> T {
        var value: T = 0
        for index in 0..<(T.bitWidth / 8) { value |= T(bytes[offset + index]) << T(index * 8) }
        return value
    }
}

enum RemoteStatus: Codable {
    private static let maximumFailureMessageLength = 160

    case waitingForApproval, approved, rejected, stopped, heartbeatTimedOut
    case recentered(epoch: UInt64)
    case calibrationReady(session: UInt64, step: CalibrationStep)
    case calibrationResult(session: UInt64, xGain: Double, yGain: Double)
    case calibrationFailed(session: UInt64, message: String)
    case calibrationApplied(session: UInt64)
    case calibrationCancelled(session: UInt64)
    case presetCatalogPage(requestID: UInt64, revision: UInt64, slot: PresetSlot, name: PresetName?, selectedSlot: PresetSlot?)
    case presetSelected(requestID: UInt64, revision: UInt64, selectedSlot: PresetSlot)
    case presetSaved(requestID: UInt64, revision: UInt64, slot: PresetSlot, name: PresetName, selectedSlot: PresetSlot)
    case presetDeleted(requestID: UInt64, revision: UInt64, slot: PresetSlot, selectedSlot: PresetSlot?)
    case presetConflict(requestID: UInt64, revision: UInt64, slot: PresetSlot, existingName: PresetName)
    case presetRejected(requestID: UInt64, revision: UInt64, reason: PresetRejection)
    case presetInvalidated(revision: UInt64, selectedSlot: PresetSlot?)

    enum Kind: String, Codable {
        case waitingForApproval, approved, rejected, stopped, heartbeatTimedOut, recentered,
             calibrationReady, calibrationResult, calibrationFailed, calibrationApplied, calibrationCancelled,
             presetCatalogPage, presetSelected, presetSaved, presetDeleted, presetConflict, presetRejected,
             presetInvalidated
    }
    private enum CodingKeys: String, CodingKey {
        case kind, session, epoch, step, xGain, yGain, message
        case requestID, revision, slot, name, selectedSlot, existingName, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .waitingForApproval: self = .waitingForApproval
        case .approved: self = .approved
        case .rejected: self = .rejected
        case .stopped: self = .stopped
        case .heartbeatTimedOut: self = .heartbeatTimedOut
        case .recentered: self = .recentered(epoch: try Self.nonzero(.epoch, c))
        case .calibrationReady: self = .calibrationReady(session: try Self.nonzero(.session, c), step: try c.decode(CalibrationStep.self, forKey: .step))
        case .calibrationResult:
            let x = try c.decode(Double.self, forKey: .xGain), y = try c.decode(Double.self, forKey: .yGain)
            guard x.isFinite, y.isFinite else { throw DecodingError.dataCorruptedError(forKey: .xGain, in: c, debugDescription: "Non-finite calibration result.") }
            self = .calibrationResult(session: try Self.nonzero(.session, c), xGain: x, yGain: y)
        case .calibrationFailed: self = .calibrationFailed(session: try Self.nonzero(.session, c), message: Self.boundedFailureMessage(try c.decode(String.self, forKey: .message)))
        case .calibrationApplied: self = .calibrationApplied(session: try Self.nonzero(.session, c))
        case .calibrationCancelled: self = .calibrationCancelled(session: try Self.nonzero(.session, c))
        case .presetCatalogPage:
            self = .presetCatalogPage(requestID: try Self.nonzero(.requestID, c), revision: try Self.nonzero(.revision, c),
                                      slot: try c.decode(PresetSlot.self, forKey: .slot), name: try c.decodeIfPresent(PresetName.self, forKey: .name),
                                      selectedSlot: try c.decodeIfPresent(PresetSlot.self, forKey: .selectedSlot))
        case .presetSelected:
            self = .presetSelected(requestID: try Self.nonzero(.requestID, c), revision: try Self.nonzero(.revision, c), selectedSlot: try c.decode(PresetSlot.self, forKey: .selectedSlot))
        case .presetSaved:
            self = .presetSaved(requestID: try Self.nonzero(.requestID, c), revision: try Self.nonzero(.revision, c), slot: try c.decode(PresetSlot.self, forKey: .slot), name: try c.decode(PresetName.self, forKey: .name), selectedSlot: try c.decode(PresetSlot.self, forKey: .selectedSlot))
        case .presetDeleted:
            self = .presetDeleted(requestID: try Self.nonzero(.requestID, c), revision: try Self.nonzero(.revision, c), slot: try c.decode(PresetSlot.self, forKey: .slot), selectedSlot: try c.decodeIfPresent(PresetSlot.self, forKey: .selectedSlot))
        case .presetConflict:
            self = .presetConflict(requestID: try Self.nonzero(.requestID, c), revision: try Self.nonzero(.revision, c), slot: try c.decode(PresetSlot.self, forKey: .slot), existingName: try c.decode(PresetName.self, forKey: .existingName))
        case .presetRejected:
            self = .presetRejected(requestID: try Self.nonzero(.requestID, c), revision: try Self.nonzero(.revision, c), reason: try c.decode(PresetRejection.self, forKey: .reason))
        case .presetInvalidated:
            self = .presetInvalidated(revision: try Self.nonzero(.revision, c), selectedSlot: try c.decodeIfPresent(PresetSlot.self, forKey: .selectedSlot))
        }
    }

    private static func nonzero(_ key: CodingKeys, _ c: KeyedDecodingContainer<CodingKeys>) throws -> UInt64 {
        let value = try c.decode(UInt64.self, forKey: key)
        guard value != 0 else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Identifier must be nonzero.") }
        return value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func base(_ kind: Kind) throws { try c.encode(kind, forKey: .kind) }
        switch self {
        case .waitingForApproval: try base(.waitingForApproval)
        case .approved: try base(.approved)
        case .rejected: try base(.rejected)
        case .stopped: try base(.stopped)
        case .heartbeatTimedOut: try base(.heartbeatTimedOut)
        case let .recentered(epoch): try base(.recentered); try c.encode(epoch, forKey: .epoch)
        case let .calibrationReady(session, step): try base(.calibrationReady); try c.encode(session, forKey: .session); try c.encode(step, forKey: .step)
        case let .calibrationResult(session, x, y): try base(.calibrationResult); try c.encode(session, forKey: .session); try c.encode(x, forKey: .xGain); try c.encode(y, forKey: .yGain)
        case let .calibrationFailed(session, message): try base(.calibrationFailed); try c.encode(session, forKey: .session); try c.encode(Self.boundedFailureMessage(message), forKey: .message)
        case let .calibrationApplied(session): try base(.calibrationApplied); try c.encode(session, forKey: .session)
        case let .calibrationCancelled(session): try base(.calibrationCancelled); try c.encode(session, forKey: .session)
        case let .presetCatalogPage(id, revision, slot, name, selected): try base(.presetCatalogPage); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .revision); try c.encode(slot, forKey: .slot); try c.encodeIfPresent(name, forKey: .name); try c.encodeIfPresent(selected, forKey: .selectedSlot)
        case let .presetSelected(id, revision, selected): try base(.presetSelected); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .revision); try c.encode(selected, forKey: .selectedSlot)
        case let .presetSaved(id, revision, slot, name, selected): try base(.presetSaved); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .revision); try c.encode(slot, forKey: .slot); try c.encode(name, forKey: .name); try c.encode(selected, forKey: .selectedSlot)
        case let .presetDeleted(id, revision, slot, selected): try base(.presetDeleted); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .revision); try c.encode(slot, forKey: .slot); try c.encodeIfPresent(selected, forKey: .selectedSlot)
        case let .presetConflict(id, revision, slot, name): try base(.presetConflict); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .revision); try c.encode(slot, forKey: .slot); try c.encode(name, forKey: .existingName)
        case let .presetRejected(id, revision, reason): try base(.presetRejected); try c.encode(id, forKey: .requestID); try c.encode(revision, forKey: .revision); try c.encode(reason, forKey: .reason)
        case let .presetInvalidated(revision, selected): try base(.presetInvalidated); try c.encode(revision, forKey: .revision); try c.encodeIfPresent(selected, forKey: .selectedSlot)
        }
    }

    private static func boundedFailureMessage(_ message: String) -> String {
        let ascii = message.unicodeScalars.map { scalar -> Character in
            (32...126).contains(scalar.value) ? Character(String(scalar)) : "?"
        }
        return String(ascii.prefix(maximumFailureMessageLength))
    }
}

// MARK: - Roll-independent three-axis pointing math

/// A small platform-neutral snapshot of Core Motion's native data. `matrix` preserves the native
/// row-major CMAttitude.rotationMatrix values without assuming its vector-multiplication direction.
/// The iPhone requests xArbitraryZVertical; a stream-latched gravity test resolves matrix versus
/// transpose only from a sufficiently informative pose, then rejects any later physical mismatch.
struct PointerAttitudeSample {
    let quaternion: (x: Double, y: Double, z: Double, w: Double)
    let matrix: (m11: Double, m12: Double, m13: Double,
                 m21: Double, m22: Double, m23: Double,
                 m31: Double, m32: Double, m33: Double)
    let gravity: PointerVector3
}

struct PointerVector3: Equatable {
    var x: Double; var y: Double; var z: Double
    static let deviceTop = PointerVector3(x: 0, y: 1, z: 0)
    static func + (l: Self, r: Self) -> Self { .init(x: l.x + r.x, y: l.y + r.y, z: l.z + r.z) }
    static func - (l: Self, r: Self) -> Self { .init(x: l.x - r.x, y: l.y - r.y, z: l.z - r.z) }
    static func * (l: Self, r: Double) -> Self { .init(x: l.x * r, y: l.y * r, z: l.z * r) }
    var finite: Bool { x.isFinite && y.isFinite && z.isFinite }
    var length: Double { sqrt(x * x + y * y + z * z) }
    func dot(_ r: Self) -> Double { x * r.x + y * r.y + z * r.z }
    func cross(_ r: Self) -> Self { .init(x: y * r.z - z * r.y, y: z * r.x - x * r.z, z: x * r.y - y * r.x) }
    func normalized() -> Self? { let n = length; return finite && n > 1e-9 ? self * (1 / n) : nil }
}

enum PointerAttitudeFailure: Error, Equatable {
    case invalidQuaternion, invalidRotationMatrix, inconsistentGravity, ambiguousConvention
    case gravityParallelToAim, pointingNearVertical, discontinuity

    var userMessage: String {
        switch self {
        case .ambiguousConvention: return "Tilt the phone top edge slightly toward the screen, then tap Recenter."
        case .gravityParallelToAim: return "Aim the phone top edge forward, not nearly straight up or down, then try again."
        case .pointingNearVertical: return "Aim away from the reset basis pole to continue without a pointer jump."
        case .discontinuity: return "Pointing changed too abruptly; hold steady and try again."
        default: return "Attitude data is invalid; hold steady and try again."
        }
    }
}

/// Defines a gravity-level tangent basis at reset and extracts yaw/pitch only from the transformed
/// +device-Y (the physical top edge). Rolling around that forward axis therefore cannot move aim.
struct PointerAttitudeTracker {
    private enum MatrixDirection { case matrix, transpose }
    private var matrixDirection: MatrixDirection?
    private var forward0: PointerVector3?
    private var right0: PointerVector3?
    private var up0: PointerVector3?
    private var lastRawYaw: Double?
    private var unwrappedYaw = 0.0

    /// Explicit Recenter replaces only the pointing basis. The physical matrix convention remains
    /// fixed for the Core Motion stream and is cleared only by constructing a tracker for a restart.
    mutating func resetBasis() {
        forward0 = nil; right0 = nil; up0 = nil
        lastRawYaw = nil; unwrappedYaw = 0
    }

    mutating func reset(with sample: PointerAttitudeSample) -> Result<(x: Double, y: Double), PointerAttitudeFailure> {
        switch vectors(from: sample) {
        case let .failure(error): return .failure(error)
        case let .success((forward, down)):
            let projectedDown = down - forward * down.dot(forward)
            guard projectedDown.length >= 0.17, let up = (projectedDown * -1).normalized(),
                  let right = forward.cross(up).normalized() else { return .failure(.gravityParallelToAim) }
            forward0 = forward; right0 = right; up0 = up
            lastRawYaw = 0; unwrappedYaw = 0
            return .success((0, 0))
        }
    }

    mutating func angles(for sample: PointerAttitudeSample) -> Result<(x: Double, y: Double), PointerAttitudeFailure> {
        guard let baseForward = forward0, let right = right0, let up = up0 else {
            return reset(with: sample)
        }
        switch vectors(from: sample) {
        case let .failure(error): return .failure(error)
        case let .success((forward, _)):
            let f = forward.dot(baseForward), r = forward.dot(right), u = forward.dot(up)
            let horizontal = hypot(f, r)
            guard horizontal >= 0.05 else { return .failure(.pointingNearVertical) }
            let rawYaw = atan2(r, f)
            if let previous = lastRawYaw {
                var delta = rawYaw - previous
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                // More than 90 degrees between delivered samples is treated as a pole/reset artifact.
                guard abs(delta) <= .pi / 2 else { return .failure(.discontinuity) }
                unwrappedYaw += delta
            } else { unwrappedYaw = rawYaw }
            lastRawYaw = rawYaw
            let pitch = atan2(u, horizontal)
            guard unwrappedYaw.isFinite, pitch.isFinite else { return .failure(.invalidRotationMatrix) }
            return .success((unwrappedYaw, -pitch)) // Core Graphics screen y grows downward.
        }
    }

    private mutating func vectors(from sample: PointerAttitudeSample) -> Result<(PointerVector3, PointerVector3), PointerAttitudeFailure> {
        let q = sample.quaternion
        let qn = sqrt(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w)
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite, abs(qn - 1) < 0.02 else {
            return .failure(.invalidQuaternion)
        }
        let m = sample.matrix
        let values = [m.m11,m.m12,m.m13,m.m21,m.m22,m.m23,m.m31,m.m32,m.m33]
        guard values.allSatisfy({ $0.isFinite }) else { return .failure(.invalidRotationMatrix) }
        let row1 = PointerVector3(x: m.m11, y: m.m12, z: m.m13)
        let row2 = PointerVector3(x: m.m21, y: m.m22, z: m.m23)
        let row3 = PointerVector3(x: m.m31, y: m.m32, z: m.m33)
        let determinant = row1.dot(row2.cross(row3))
        guard abs(row1.length - 1) < 0.02, abs(row2.length - 1) < 0.02,
              abs(row3.length - 1) < 0.02, abs(row1.dot(row2)) < 0.02,
              abs(row1.dot(row3)) < 0.02, abs(row2.dot(row3)) < 0.02,
              abs(determinant - 1) < 0.04 else {
            return .failure(.invalidRotationMatrix)
        }
        func matrixTransform(_ v: PointerVector3) -> PointerVector3 {
            .init(x: row1.dot(v), y: row2.dot(v), z: row3.dot(v))
        }
        func transposeTransform(_ v: PointerVector3) -> PointerVector3 {
            .init(x: m.m11 * v.x + m.m21 * v.y + m.m31 * v.z,
                  y: m.m12 * v.x + m.m22 * v.y + m.m32 * v.z,
                  z: m.m13 * v.x + m.m23 * v.y + m.m33 * v.z)
        }
        // CMQuaternion exposes named scalar-last x/y/z/w fields. Verify, rather than assume, its
        // rotation direction by requiring either q·v·q^-1 or its inverse to agree with the native
        // rotation matrix on all three device axes. q and -q necessarily produce the same result.
        let qVector = PointerVector3(x: q.x / qn, y: q.y / qn, z: q.z / qn)
        let qw = q.w / qn
        func quaternionRotate(_ v: PointerVector3, vector: PointerVector3) -> PointerVector3 {
            let t = vector.cross(v) * 2
            return v + t * qw + vector.cross(t)
        }
        let axes = [PointerVector3(x: 1, y: 0, z: 0), .deviceTop,
                    PointerVector3(x: 0, y: 0, z: 1)]
        func agreementError(vector: PointerVector3) -> Double {
            axes.reduce(0) { total, axis in
                let difference = quaternionRotate(axis, vector: vector) - matrixTransform(axis)
                return total + difference.dot(difference)
            }
        }
        guard min(agreementError(vector: qVector), agreementError(vector: qVector * -1)) < 0.01 else {
            return .failure(.invalidQuaternion)
        }
        guard let nativeDown = sample.gravity.normalized(),
              let matrixDown = matrixTransform(nativeDown).normalized(),
              let transposeDown = transposeTransform(nativeDown).normalized() else {
            return .failure(.inconsistentGravity)
        }
        let referenceDown = PointerVector3(x: 0, y: 0, z: -1)
        let matrixError = (matrixDown - referenceDown).length
        let transposeError = (transposeDown - referenceDown).length

        // The matching allowance accounts for bounded gravity/attitude noise. A candidate must be
        // within 0.12 chord units (~6.9 degrees), while the other must be at least 0.30 (~17.3 degrees)
        // away. Identity and pure vertical-yaw poses therefore remain deliberately unresolved.
        if matrixDirection == nil {
            if matrixError <= 0.12, transposeError >= 0.30 {
                matrixDirection = .matrix
            } else if transposeError <= 0.12, matrixError >= 0.30 {
                matrixDirection = .transpose
            } else if min(matrixError, transposeError) <= 0.12 {
                return .failure(.ambiguousConvention)
            } else {
                return .failure(.inconsistentGravity)
            }
        }
        let transform: (PointerVector3) -> PointerVector3
        let chosenDown: PointerVector3
        switch matrixDirection! {
        case .matrix: transform = matrixTransform; chosenDown = matrixDown
        case .transpose: transform = transposeTransform; chosenDown = transposeDown
        }
        // A latched stream never changes direction based on a later closer candidate.
        guard (chosenDown - referenceDown).length <= 0.12,
              let forward = transform(.deviceTop).normalized() else {
            return .failure(.inconsistentGravity)
        }
        return .success((forward, chosenDown))
    }
}

enum Wire {
    static let maximumBytes = 512
    static func encode(_ message: RemoteMessage) -> Data? {
        guard let data = try? JSONEncoder().encode(message), data.count <= maximumBytes else { return nil }
        return data
    }
    static func encode(_ status: RemoteStatus) -> Data? {
        guard let data = try? JSONEncoder().encode(status), data.count <= maximumBytes else { return nil }
        return data
    }
    static func decode(_ data: Data) -> RemoteMessage? { guard data.count <= maximumBytes else { return nil }; return try? JSONDecoder().decode(RemoteMessage.self, from: data) }
    static func decodeStatus(_ data: Data) -> RemoteStatus? { guard data.count <= maximumBytes else { return nil }; return try? JSONDecoder().decode(RemoteStatus.self, from: data) }
}
