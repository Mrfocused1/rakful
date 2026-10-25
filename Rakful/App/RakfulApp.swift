import SwiftData
import SwiftUI
import UIKit

@main
struct RakfulApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.preferences)
                .environment(environment.photoState)
                .environment(environment.device)
                .environment(environment.entitlements)
                .environment(environment.discovery)
                .environment(environment.background)
                .environment(environment.router)
                .environment(environment.saveFailures)
                .environment(environment.photoReview)
                // The approved design is a light one; there's no separate dark design yet.
                .preferredColorScheme(.light)
        }
        .modelContainer(environment.modelContainer)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let environment = AppEnvironment.shared
        // BGTaskScheduler requires registration before launch completes,
        // including launches made by iOS purely to run a background task.
        environment.background.register()
        environment.launch()
        return true
    }
}
