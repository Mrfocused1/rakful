import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
///
/// Preferences are key–value settings that must be readable synchronously at
/// launch and from background-task handlers, so `UserDefaults` is a better fit
/// than SwiftData here. `snapshot` provides a `Sendable` copy for the engine.
@MainActor
@Observable
final class PreferencesStore {
    enum RetentionPeriod: Int, CaseIterable, Identifiable, Sendable {
        case thirtyDays = 30
        case ninetyDays = 90
        case oneYear = 365
        case forever = 0

        var id: Int { rawValue }
        var displayName: String {
            switch self {
            case .thirtyDays: "30 Days"
            case .ninetyDays: "90 Days"
            case .oneYear: "1 Year"
            case .forever: "Forever"
            }
        }
    }

    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    var enabledCategories: Set<ResaleCategory> {
        didSet { defaults.set(enabledCategories.map(\.rawValue).sorted(), forKey: Keys.categories) }
    }
    var includeScreenshots: Bool { didSet { defaults.set(includeScreenshots, forKey: Keys.screenshots) } }
    var allowICloudDownloads: Bool { didSet { defaults.set(allowICloudDownloads, forKey: Keys.iCloud) } }
    var chargeAndDiscoverEnabled: Bool { didSet { defaults.set(chargeAndDiscoverEnabled, forKey: Keys.chargeAndDiscover) } }
    var requireExternalPower: Bool { didSet { defaults.set(requireExternalPower, forKey: Keys.externalPower) } }
    var wifiOnlyForICloud: Bool { didSet { defaults.set(wifiOnlyForICloud, forKey: Keys.wifiOnly) } }
    var pauseInLowPowerMode: Bool { didSet { defaults.set(pauseInLowPowerMode, forKey: Keys.lowPower) } }
    var cloudAnalysisConsent: Bool { didSet { defaults.set(cloudAnalysisConsent, forKey: Keys.cloudConsent) } }
    var useAppleIntelligence: Bool { didSet { defaults.set(useAppleIntelligence, forKey: Keys.appleIntelligence) } }
    var retention: RetentionPeriod { didSet { defaults.set(retention.rawValue, forKey: Keys.retention) } }
    var notifyDiscoveryCompleted: Bool { didSet { defaults.set(notifyDiscoveryCompleted, forKey: Keys.notifyDiscovery) } }
    var notifyMorningReport: Bool { didSet { defaults.set(notifyMorningReport, forKey: Keys.notifyMorning) } }
    var notifyListingReminders: Bool { didSet { defaults.set(notifyListingReminders, forKey: Keys.notifyListings) } }
    var lastReportViewedAt: Date? { didSet { defaults.set(lastReportViewedAt, forKey: Keys.lastReport) } }
    var currencyCode: String { didSet { defaults.set(currencyCode, forKey: Keys.currency) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.iCloud: true,
            Keys.externalPower: true,
            Keys.wifiOnly: true,
            Keys.lowPower: true,
            Keys.appleIntelligence: true,
            Keys.retention: RetentionPeriod.ninetyDays.rawValue,
        ])
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        if let stored = defaults.stringArray(forKey: Keys.categories) {
            enabledCategories = Set(stored.compactMap(ResaleCategory.init(rawValue:)))
        } else {
            enabledCategories = ResaleCategory.allEnabledByDefault
        }
        includeScreenshots = defaults.bool(forKey: Keys.screenshots)
        allowICloudDownloads = defaults.bool(forKey: Keys.iCloud)
        chargeAndDiscoverEnabled = defaults.bool(forKey: Keys.chargeAndDiscover)
        requireExternalPower = defaults.bool(forKey: Keys.externalPower)
        wifiOnlyForICloud = defaults.bool(forKey: Keys.wifiOnly)
        pauseInLowPowerMode = defaults.bool(forKey: Keys.lowPower)
        cloudAnalysisConsent = defaults.bool(forKey: Keys.cloudConsent)
        useAppleIntelligence = defaults.bool(forKey: Keys.appleIntelligence)
        retention = RetentionPeriod(rawValue: defaults.integer(forKey: Keys.retention)) ?? .ninetyDays
        notifyDiscoveryCompleted = defaults.bool(forKey: Keys.notifyDiscovery)
        notifyMorningReport = defaults.bool(forKey: Keys.notifyMorning)
        notifyListingReminders = defaults.bool(forKey: Keys.notifyListings)
        lastReportViewedAt = defaults.object(forKey: Keys.lastReport) as? Date
        currencyCode = defaults.string(forKey: Keys.currency) ?? Locale.current.currency?.identifier ?? "GBP"
    }

    /// Clears every stored preference (used by "Erase All Data").
    func reset() {
        for key in Keys.all { defaults.removeObject(forKey: key) }
        let fresh = PreferencesStore(defaults: defaults)
        hasCompletedOnboarding = fresh.hasCompletedOnboarding
        enabledCategories = fresh.enabledCategories
        includeScreenshots = fresh.includeScreenshots
        allowICloudDownloads = fresh.allowICloudDownloads
        chargeAndDiscoverEnabled = fresh.chargeAndDiscoverEnabled
        requireExternalPower = fresh.requireExternalPower
        wifiOnlyForICloud = fresh.wifiOnlyForICloud
        pauseInLowPowerMode = fresh.pauseInLowPowerMode
        cloudAnalysisConsent = fresh.cloudAnalysisConsent
        useAppleIntelligence = fresh.useAppleIntelligence
        retention = fresh.retention
        notifyDiscoveryCompleted = fresh.notifyDiscoveryCompleted
        notifyMorningReport = fresh.notifyMorningReport
        notifyListingReminders = fresh.notifyListingReminders
        lastReportViewedAt = nil
        currencyCode = fresh.currencyCode
    }

    private enum Keys {
        static let onboarding = "rr.onboardingComplete"
        static let categories = "rr.enabledCategories"
        static let screenshots = "rr.includeScreenshots"
        static let iCloud = "rr.allowICloudDownloads"
        static let chargeAndDiscover = "rr.chargeAndDiscover"
        static let externalPower = "rr.requireExternalPower"
        static let wifiOnly = "rr.wifiOnlyForICloud"
        static let lowPower = "rr.pauseInLowPowerMode"
        static let cloudConsent = "rr.cloudAnalysisConsent"
        static let appleIntelligence = "rr.useAppleIntelligence"
        static let retention = "rr.retentionDays"
        static let notifyDiscovery = "rr.notifyDiscoveryCompleted"
        static let notifyMorning = "rr.notifyMorningReport"
        static let notifyListings = "rr.notifyListingReminders"
        static let lastReport = "rr.lastReportViewedAt"
        static let currency = "rr.currencyCode"
        static let all = [onboarding, categories, screenshots, iCloud, chargeAndDiscover, externalPower, wifiOnly,
                          lowPower, cloudConsent, appleIntelligence, retention, notifyDiscovery, notifyMorning,
                          notifyListings, lastReport, currency]
    }
}
