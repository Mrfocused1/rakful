import Foundation

/// How a discovery session was run. Shown to people so it's always clear
/// which mode did the work.
enum DiscoveryMode: String, Codable, Sendable, CaseIterable {
    case manual
    case chargeAndDiscover
    case cloud

    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .chargeAndDiscover: "Charge & Discover"
        case .cloud: "Cloud Processing"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: "hand.tap"
        case .chargeAndDiscover: "bolt.batteryblock"
        case .cloud: "icloud"
        }
    }
}

enum SessionStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
    case failed

    var displayName: String {
        switch self {
        case .running: "In Progress"
        case .completed: "Completed"
        case .interrupted: "Paused"
        case .failed: "Failed"
        }
    }
}

/// Why a run stopped before reaching the end of its queue.
enum InterruptionReason: String, Codable, Sendable {
    case cancelledByUser
    case systemExpiration
    case thermalState
    case appBackgrounded
    case lowPowerMode

    var displayName: String {
        switch self {
        case .cancelledByUser: "Stopped by you"
        case .systemExpiration: "iOS ended background time"
        case .thermalState: "iPhone was too warm"
        case .appBackgrounded: "App left the foreground"
        case .lowPowerMode: "Low Power Mode is on"
        }
    }
}

/// Outcome of analysing a single photo.
enum PhotoProcessingStatus: String, Codable, Sendable {
    case analyzed
    case skipped
    case failed
    case iCloudUnavailable
}

enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case discoveryStarted
    case photosAnalyzed
    case candidateIdentified
    case ownershipConfirmed
    case valuationCompleted
    case listingDraftCreated
    case listingApproved
    case listingHandedOff
    case listingConfirmedListed
    case scanInterrupted
    case scanResumed
    case backgroundTaskCompleted
    case backgroundTaskScheduled

    var systemImage: String {
        switch self {
        case .discoveryStarted: "sparkle.magnifyingglass"
        case .photosAnalyzed: "photo.stack"
        case .candidateIdentified: "viewfinder"
        case .ownershipConfirmed: "checkmark.seal"
        case .valuationCompleted: "sterlingsign.circle"
        case .listingDraftCreated: "square.and.pencil"
        case .listingApproved: "checkmark.rectangle"
        case .listingHandedOff: "arrow.up.forward.app"
        case .listingConfirmedListed: "storefront"
        case .scanInterrupted: "pause.circle"
        case .scanResumed: "play.circle"
        case .backgroundTaskCompleted: "moon.stars"
        case .backgroundTaskScheduled: "bolt.batteryblock"
        }
    }

    var group: ActivityGroup {
        switch self {
        case .discoveryStarted, .photosAnalyzed, .scanInterrupted, .scanResumed: .discovery
        case .candidateIdentified, .ownershipConfirmed, .valuationCompleted: .items
        case .listingDraftCreated, .listingApproved, .listingHandedOff, .listingConfirmedListed: .listings
        case .backgroundTaskCompleted, .backgroundTaskScheduled: .background
        }
    }
}

enum ActivityGroup: String, CaseIterable, Identifiable, Sendable {
    case all, discovery, items, listings, background
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: "All"
        case .discovery: "Discovery"
        case .items: "Items"
        case .listings: "Listings"
        case .background: "Background"
        }
    }
}

/// Where a listing is in the manual-posting workflow. Rakful can't see
/// marketplaces, so "listed" is always the seller's own confirmation.
enum ListingStatus: String, Codable, Sendable {
    case draft
    /// The seller approved an exact snapshot; it's ready to export.
    case approved
    /// The approved snapshot was copied, shared, or the marketplace opened.
    /// Publication isn't confirmed.
    case exported
    /// The seller confirmed the listing is live. Rakful hasn't verified it.
    case listed
    /// Published through a marketplace API. Not available in this release.
    case published

    /// Before approvals existed, "handedOff" meant the seller had tapped
    /// "Mark as Listed". `DataMigration` rewrites it to `listed`.
    static let legacyHandedOffRawValue = "handedOff"

    init(storedValue: String) {
        self = storedValue == Self.legacyHandedOffRawValue ? .listed : ListingStatus(rawValue: storedValue) ?? .draft
    }

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .approved: "Approved"
        case .exported: "Handed Off"
        case .listed: "Listed"
        case .published: "Published"
        }
    }

    var detail: String {
        switch self {
        case .draft: "Not approved yet"
        case .approved: "Ready to export"
        case .exported: "Not confirmed as listed"
        case .listed: "Confirmed by you"
        case .published: "Published through eBay"
        }
    }

    /// Still being prepared or posted, as opposed to listed.
    var isActive: Bool { self == .draft || self == .approved || self == .exported }
}

/// The seller's answer about wear and defects. A draft with no answer is
/// different from one where they checked and found none.
enum DefectsAssessment: String, Codable, Sendable, CaseIterable, Identifiable {
    case noneFound
    case described

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .noneFound: "None Found"
        case .described: "Yes, I'll Describe Them"
        }
    }
}

/// Result of the automatic check for people in a photo.
enum PersonCheck: String, Codable, Sendable {
    case unchecked
    case noPersonDetected
    case personDetected
    /// The check couldn't run (unavailable model, unreadable photo).
    case failed
}

/// The seller's own decision after looking at a photo.
enum PhotoUserReview: String, Codable, Sendable {
    case confirmedNoPerson
    case markedShowsPerson
}

/// Whether a photo may go in a listing. Only `eligible` photos can be
/// approved; nothing defaults to eligible without a check or a review.
enum PhotoEligibility: Sendable, Equatable {
    case eligible
    /// The automatic check hasn't run yet.
    case unchecked
    /// The automatic check couldn't run, so the seller has to look.
    case needsReview
    /// A person is visible (detected, or marked by the seller). Never listed.
    case showsPerson
}

enum ListingField: String, Codable, Sendable, CaseIterable, Hashable {
    case title, description, category, brand, model, colour, size, material, measurements, condition, defects, keywords, price, photos

    var displayName: String {
        switch self {
        case .title: "Title"
        case .description: "Description"
        case .category: "Category"
        case .brand: "Brand"
        case .model: "Model"
        case .colour: "Colour"
        case .size: "Size"
        case .material: "Material"
        case .measurements: "Measurements"
        case .condition: "Condition"
        case .defects: "Wear and Defects"
        case .keywords: "Keywords"
        case .price: "Price"
        case .photos: "Photos"
        }
    }
}

enum PhotoSource: String, Codable, Sendable {
    case library
    case camera
    case imported
}

enum IdentificationSource: String, Codable, Sendable {
    case onDeviceClassifier
    case onDeviceText
    case cloudService
    case user

    var displayName: String {
        switch self {
        case .onDeviceClassifier: "On-device image analysis"
        case .onDeviceText: "Text detected in photo"
        case .cloudService: "Cloud identification"
        case .user: "Entered by you"
        }
    }
}

enum PriceKind: String, Codable, Sendable {
    case activeAsking
    case completedSale
    case estimatedRange

    var displayName: String {
        switch self {
        case .activeAsking: "Active Asking Prices"
        case .completedSale: "Completed Sales"
        case .estimatedRange: "Estimated Range"
        }
    }

    var shortName: String {
        switch self {
        case .activeAsking: "Asking"
        case .completedSale: "Sold"
        case .estimatedRange: "Estimate"
        }
    }
}

enum BackgroundTaskOutcome: String, Codable, Sendable {
    case requested
    case running
    case completed
    case expired
    case skipped
    case failed

    var displayName: String {
        switch self {
        case .requested: "Requested"
        case .running: "Running"
        case .completed: "Completed"
        case .expired: "Expired"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

enum BackgroundTaskKind: String, Codable, Sendable {
    case request
    case execution
    case simulatedExecution
}
