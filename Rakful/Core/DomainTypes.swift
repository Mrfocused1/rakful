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
    case listingHandedOff
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
        case .listingHandedOff: "arrow.up.forward.app"
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
        case .listingDraftCreated, .listingHandedOff: .listings
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

enum ListingStatus: String, Codable, Sendable {
    case draft
    case handedOff
    case published

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .handedOff: "Listed Manually"
        case .published: "Published"
        }
    }
}

enum ListingField: String, Codable, Sendable, CaseIterable, Hashable {
    case title, description, category, brand, model, colour, size, condition, keywords, price

    var displayName: String {
        switch self {
        case .title: "Title"
        case .description: "Description"
        case .category: "Category"
        case .brand: "Brand"
        case .model: "Model"
        case .colour: "Colour"
        case .size: "Size"
        case .condition: "Condition"
        case .keywords: "Keywords"
        case .price: "Price"
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
