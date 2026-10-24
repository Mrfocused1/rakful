import Foundation
import SwiftData

@Model
final class DiscoverySession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var modeRaw: String
    var statusRaw: String
    var interruptionRaw: String?
    /// Image assets the app was authorised to see when the session started.
    var authorizedPhotoCount: Int
    /// Photos queued for this session (not yet analysed at start).
    var queuedPhotoCount: Int
    var photosAnalyzed: Int
    var photosSkipped: Int
    var photosInICloud: Int
    var photosFailed: Int
    var newCandidates: Int
    var photosMatchedToExisting: Int
    var errorMessage: String?
    var resumedFromSessionID: UUID?
    var isDemo: Bool

    init(mode: DiscoveryMode, authorizedPhotoCount: Int, queuedPhotoCount: Int, isDemo: Bool = false, startedAt: Date = .now) {
        self.id = UUID()
        self.startedAt = startedAt
        self.modeRaw = mode.rawValue
        self.statusRaw = SessionStatus.running.rawValue
        self.authorizedPhotoCount = authorizedPhotoCount
        self.queuedPhotoCount = queuedPhotoCount
        self.photosAnalyzed = 0
        self.photosSkipped = 0
        self.photosInICloud = 0
        self.photosFailed = 0
        self.newCandidates = 0
        self.photosMatchedToExisting = 0
        self.isDemo = isDemo
    }

    var mode: DiscoveryMode { DiscoveryMode(rawValue: modeRaw) ?? .manual }
    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
    var interruption: InterruptionReason? { interruptionRaw.flatMap(InterruptionReason.init(rawValue:)) }
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Checkpoint record for a single photo. Its presence means the photo will
/// not be re-analysed (except iCloud-only/failed photos, which are retried).
@Model
final class PhotoReference {
    @Attribute(.unique) var localIdentifier: String
    var creationDate: Date?
    var processedAt: Date
    var statusRaw: String
    var detail: String?
    var attemptCount: Int
    var topLabel: String?
    var topLabelConfidence: Double?
    var categoryRaw: String?
    var sessionID: UUID?

    init(localIdentifier: String, creationDate: Date?, status: PhotoProcessingStatus, detail: String? = nil, sessionID: UUID?) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.processedAt = .now
        self.statusRaw = status.rawValue
        self.detail = detail
        self.attemptCount = 1
        self.sessionID = sessionID
    }

    var status: PhotoProcessingStatus {
        get { PhotoProcessingStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class ActivityEvent {
    @Attribute(.unique) var id: UUID
    var date: Date
    var kindRaw: String
    var title: String
    var detail: String?
    var count: Int?
    var sessionID: UUID?
    var itemID: UUID?
    var isDemo: Bool

    init(kind: ActivityKind, title: String, detail: String? = nil, count: Int? = nil, sessionID: UUID? = nil, itemID: UUID? = nil, isDemo: Bool = false, date: Date = .now) {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.title = title
        self.detail = detail
        self.count = count
        self.sessionID = sessionID
        self.itemID = itemID
        self.isDemo = isDemo
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .discoveryStarted }
}

/// Diagnostics for Charge & Discover: every request, execution, expiration
/// and outcome is recorded so reliability can be inspected on a real device.
@Model
final class BackgroundTaskRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var outcomeRaw: String
    var createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var photosProcessed: Int
    var remainingAfter: Int?
    var wasCharging: Bool?
    var lowPowerMode: Bool?
    var thermalStateRaw: String?
    var resumedFromCheckpoint: Bool
    var expirationReceived: Bool
    var requiresExternalPower: Bool?
    var note: String?
    var sessionID: UUID?

    init(kind: BackgroundTaskKind, outcome: BackgroundTaskOutcome, createdAt: Date = .now) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.outcomeRaw = outcome.rawValue
        self.createdAt = createdAt
        self.photosProcessed = 0
        self.resumedFromCheckpoint = false
        self.expirationReceived = false
    }

    var kind: BackgroundTaskKind { BackgroundTaskKind(rawValue: kindRaw) ?? .execution }
    var outcome: BackgroundTaskOutcome {
        get { BackgroundTaskOutcome(rawValue: outcomeRaw) ?? .failed }
        set { outcomeRaw = newValue.rawValue }
    }
    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
