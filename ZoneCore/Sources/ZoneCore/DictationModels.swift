// by zayd/cold @ zayd.wtf

import Foundation

/// One tap of the mic button. Written by the keyboard, read by the app.
public struct DictationRequest: Codable, Equatable, Sendable {
    public let id: UUID
    /// Monotonic per keyboard process; a cancel bumps the ledger's dropped generation so a
    /// late result for an older generation is ignored.
    public let generation: Int
    public let createdAt: Date
    // SharedStore's ISO dates have whole-second precision. Keep the fraction for
    // a keyboard tap in the same second as standby expiry. Older keyboards omit it.
    private let exactCreationTime: TimeInterval?
    public var tappedAt: Date {
        exactCreationTime.map(Date.init(timeIntervalSinceReferenceDate:)) ?? createdAt
    }
    /// `UITextDocumentProxy.documentIdentifier` of the field being edited, if the host exposed one.
    /// Identifies an input session, not a document: it changes when the keyboard is dismissed.
    public let inputSession: String?
    /// The last characters before the cursor at request time, for spacing decisions and as a
    /// weak context check when no input session identifier exists.
    public let contextBefore: String?
    /// A held space bar ends on finger-up. Absent in requests from older keyboards.
    public let holdToTalk: Bool?
    public let schema: Int

    public init(id: UUID, generation: Int, createdAt: Date, inputSession: String?, contextBefore: String?,
                holdToTalk: Bool? = nil, schema: Int = ZoneContract.schemaVersion) {
        self.id = id
        self.generation = generation
        self.createdAt = createdAt
        exactCreationTime = createdAt.timeIntervalSinceReferenceDate
        self.inputSession = inputSession
        self.contextBefore = contextBefore
        self.holdToTalk = holdToTalk
        self.schema = schema
    }
}

public enum DictationPhase: String, Codable, Sendable {
    /// Keyboard asked; app has not answered yet.
    case requested
    /// App received the request and is starting capture; the keyboard keeps waiting.
    case starting
    /// Capture is running for this request.
    case recording
    /// Capture stopped; the engine is finishing.
    case transcribing
    /// A `DictationResult` is available.
    case ready
    case cancelled
    case failed
    /// An audio interruption (call, Siri, another recorder) ended capture early.
    case interrupted
    /// The app is alive but cannot start capture from the background; the keyboard must open it.
    case needsApp
}

/// Progress of one request. Written by the app, read by the keyboard.
public struct DictationStatus: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let generation: Int
    public let phase: DictationPhase
    public let updatedAt: Date
    /// Short user-facing reason for `failed`, `interrupted` or `needsApp`.
    public let message: String?
    /// While `recording`: the recording is held by Pause. Optional so older payloads decode.
    public let paused: Bool?

    public init(requestID: UUID, generation: Int, phase: DictationPhase, updatedAt: Date, message: String?, paused: Bool? = nil) {
        self.requestID = requestID
        self.generation = generation
        self.phase = phase
        self.updatedAt = updatedAt
        self.message = message
        self.paused = paused
    }
}

/// The transcript for one request. Written once by the app.
public struct DictationResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let generation: Int
    public let text: String
    public let audioSeconds: Double
    public let createdAt: Date
    /// Copied from the request so the keyboard can tell whether the field changed.
    public let inputSession: String?
    /// Words the engine was unsure of, under `DoubtfulWords.candidateCeiling`, in spoken order.
    /// Nil from engines without confidence and from builds before it existed.
    public let doubts: [DoubtfulWord]?

    public init(requestID: UUID, generation: Int, text: String, audioSeconds: Double, createdAt: Date, inputSession: String?,
                doubts: [DoubtfulWord]? = nil) {
        self.requestID = requestID
        self.generation = generation
        self.text = text
        self.audioSeconds = audioSeconds
        self.createdAt = createdAt
        self.inputSession = inputSession
        self.doubts = doubts
    }
}

public enum ControlAction: String, Codable, Sendable {
    case stop
    case cancel
    /// Hold the recording: the mic stays open but no audio reaches the recognizer or the
    /// recovery file until `resume`.
    case pause
    case resume
}

/// A flag the audio thread reads on every buffer, set from the main actor.
public final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    public init() {}
    public var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }
}

/// Keyboard asks the app to stop or cancel the current request.
public struct DictationControl: Codable, Equatable, Sendable {
    /// Identifies this one press. The shared store keeps dates to the whole second, so two
    /// controls in the same second (Pause, then Stop) used to look identical and the second was
    /// dropped. Older payloads without it decode with the nil UUID and compare by their fields.
    public let id: UUID
    public let requestID: UUID
    public let generation: Int
    public let action: ControlAction
    public let issuedAt: Date

    public init(id: UUID = UUID(), requestID: UUID, generation: Int, action: ControlAction, issuedAt: Date) {
        self.id = id
        self.requestID = requestID
        self.generation = generation
        self.action = action
        self.issuedAt = issuedAt
    }

    private enum CodingKeys: String, CodingKey { case id, requestID, generation, action, issuedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        requestID = try container.decode(UUID.self, forKey: .requestID)
        generation = try container.decode(Int.self, forKey: .generation)
        action = try container.decode(ControlAction.self, forKey: .action)
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
    }
}

/// What the app can do right now. Written by the app, read by the keyboard before it decides
/// between the warm path (ping) and the cold path (open the app).
public struct SessionState: Codable, Equatable, Sendable {
    /// The audio session is active and the engine is resident; a ping starts capture.
    public var isArmed: Bool
    /// When the armed session ends if nothing happens.
    public var armedUntil: Date?
    /// The model files are on disk and loaded.
    public var modelReady: Bool
    /// Refreshed by the app while armed. Stale heartbeat means the process is gone.
    public var heartbeat: Date

    /// Absent on records from older releases.
    public var recording: Bool?
    public var holdsMicrophoneLease: Bool?
    public var microphoneBusyMessage: String?

    public init(isArmed: Bool, armedUntil: Date?, modelReady: Bool, heartbeat: Date, recording: Bool? = nil) {
        self.recording = recording
        self.isArmed = isArmed
        self.armedUntil = armedUntil
        self.modelReady = modelReady
        self.heartbeat = heartbeat
    }

    /// True when the app is armed and its heartbeat is recent enough to trust a ping.
    public func isAlive(now: Date, tolerance: TimeInterval = 8) -> Bool {
        guard isArmed else { return false }
        // A heartbeat from the future means the clock moved back after it was written. A live
        // app rewrites it within seconds with the new clock, so only a dead one stays ahead;
        // without the lower bound a dead app looked alive until the clock caught up (a manual
        // clock change, a network time correction), and every warm ping meanwhile went unanswered.
        let age = now.timeIntervalSince(heartbeat)
        return age <= tolerance && age >= -tolerance
    }
}

/// The keyboard's durable record of what it has inserted. Insertion into the host field and
/// this record cannot commit atomically, so the ledger distinguishes "claimed" from "consumed";
/// the gap between them is the ambiguous interval that requires explicit recovery.
public struct InsertionLedger: Codable, Equatable, Sendable {
    public var claimedResultID: UUID?
    public var claimedAt: Date?
    public var consumedResultID: UUID?
    /// Results with a generation at or below this were cancelled and must never be inserted.
    public var droppedGeneration: Int

    mutating func claim(_ offered: DictationResult, current: DictationResult?, explicit: Bool, now: Date) -> Bool {
        guard current == offered, InsertionDecider.unavailableReason(for: offered, ledger: self, now: now) == nil,
              explicit || claimedResultID != offered.requestID else { return false }
        claimedResultID = offered.requestID
        claimedAt = now
        return true
    }

    mutating func consume(_ id: UUID) {
        consumedResultID = id
        if claimedResultID == id {
            claimedResultID = nil
            claimedAt = nil
        }
    }

    public init(claimedResultID: UUID? = nil, claimedAt: Date? = nil, consumedResultID: UUID? = nil, droppedGeneration: Int = 0) {
        self.claimedResultID = claimedResultID
        self.claimedAt = claimedAt
        self.consumedResultID = consumedResultID
        self.droppedGeneration = droppedGeneration
    }
}

/// Written by the keyboard each time it appears with Full Access, so the app can confirm the
/// keyboard is enabled and allowed to reach the shared store.
public struct KeyboardPresence: Codable, Equatable, Sendable {
    public var lastSeen: Date
    public var hasFullAccess: Bool

    public init(lastSeen: Date, hasFullAccess: Bool) {
        self.lastSeen = lastSeen
        self.hasFullAccess = hasFullAccess
    }
}
