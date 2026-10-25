# Rakful

A native iPhone app that finds resellable possessions in the photos you allow, asks you to confirm what you still own, and prepares listings.

Swift 6 · SwiftUI · SwiftData · PhotoKit · Vision · BackgroundTasks · StoreKit 2 · iOS 18+ (Liquid Glass and Apple Intelligence on iOS 26+). No third-party dependencies. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Run it

1. Open `Rakful.xcodeproj` in Xcode 26 or later.
2. Select the **Rakful** scheme and your iPhone (set your Team under Signing & Capabilities, and change the bundle ID `com.resaleready.app` if needed).
3. Run. To try purchases locally, check *Edit Scheme › Run › Options › StoreKit Configuration* points at `Config/Rakful.storekit`.

> Photo analysis must be tried **on an iPhone**. In the iOS Simulator, Vision's classifier returns the same labels for every image, so the app detects this and reports "Discovery Couldn't Run" instead of producing results. Everything else works in Simulator; use **Explore Sample Items** to explore.

Command line (Xcode installed but not selected? prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`):

```sh
xcodebuild -project Rakful.xcodeproj -scheme Rakful \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Testing Charge & Discover on a device

1. Settings › Charge & Discover on (requires Plus; Debug builds can override the tier in *Background Diagnostics*). Ensure Background App Refresh is on.
2. Background the app and plug in. iOS decides when to run — often overnight while idle.
3. To force a launch: run from Xcode, background the app, pause the debugger and run
   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.resaleready.app.discovery"]`
4. Inspect every request, execution, expiration and resume in Settings › Background Diagnostics.

## Status

| Area | State |
|---|---|
| Onboarding, 5 tabs, settings, dark mode, Dynamic Type, VoiceOver labels | Implemented, verified in Simulator |
| Photo permissions (full / limited / denied / revoked), limited picker | Implemented; denied & prompt flows verified in Simulator |
| Discovery pipeline, grouping, dedup, checkpoints, resume, iCloud & failure retries | Implemented, covered by tests with fixtures; **Vision results unverified on device** |
| Ownership review, combine/separate items, item library, search/filter/sort | Implemented, verified |
| Listing editor, template generation, validation | Implemented, verified |
| Listing approval and manual handoff | One approval screen records a versioned snapshot (text, facts, photo copies); any material edit clears it; exports use only the snapshot. States: Draft → Approved → Handed Off (not confirmed) → Listed (seller's own confirmation, optional link). Covered by unit tests and a UI journey in Simulator |
| Listing photos | Every photo (discovered, imported, camera) gets the same person check; unchecked or failed checks need the seller's review; photos showing a person are never listed. Person detection verified in Simulator only as "unavailable" (Vision doesn't run there); **real-device accuracy unverified** |
| Saving | Failed saves show an alert with Try Again; an unopenable store falls back to memory with a permanent warning. `DataMigration` upgrades older records (tested against a real pre-approval store) |
| Apple Intelligence listing text | Implemented (iOS 26+); **unverified** (simulator runtime is iOS 18.5) |
| Charge & Discover (BGProcessingTask), diagnostics | Implemented; handler covered by tests incl. expiration/resume; **real BG launches unverified** |
| Notifications (completion, morning report, listing reminders) | Implemented; delivery unverified |
| StoreKit 2 entitlements, native subscription store | Implemented; purchase flow unverified (needs StoreKit config or App Store Connect) |
| Pricing | No estimates: eBay's API licence forbids suggesting prices from eBay data. Items and listings link to eBay's sold listings (`Marketplace.soldListingsURL`); the seller sets the price |
| eBay publishing, cloud identification | Adapters kept for future work; direct publishing is switched off in this release (`DirectPublishing.isEnabled`), every listing is posted by the seller |
| Sample data | 12 clothing items, clearly labelled, isolated, removable. Example values are marked "Demo"; real items never get estimates. Photos: free-licence stock (Unsplash/Pexels), see below |

Tests: 110 unit/integration tests (Swift Testing) and 4 UI journeys (XCUITest). See the latest run for results; two journeys depend on the Simulator's photo library and permissions and also fail on the original commit there.

## Configuration

- `Config/Info.plist` › `RRBackendBaseURL`: HTTPS base URL of the Rakful server. Empty = all cloud features off. Never put API keys in the app.
- Product IDs: `Services/Subscriptions/Entitlements.swift` (`ProductCatalog`).
- Privacy policy: `Resources/PrivacyPolicy.html` is shown in the app (Settings, Subscription, paywall) and is the file to host for App Store Connect's Privacy Policy URL. Fill in the contact email first. Terms of Use = Apple's standard EULA (`LegalLinks`).
- `Resources/PrivacyInfo.xcprivacy` declares no tracking or collected data and the UserDefaults reason (CA92.1). Update it when the server and eBay features go live.

## Name and code

The app is **Rakful** (products `com.rackful.*`). Its bundle ID stays `com.resaleready.app` so existing installs update in place. The Xcode project, targets, module and folders are named `Rakful`. Two earlier names remain on purpose, neither user-visible: the on-device database file is still `ResaleReady` (renaming it would lose existing data), and identifiers such as products and the URL scheme use `rackful`.

Sample photos (`Assets.xcassets/Sample*`), all free for commercial use without attribution, cropped and lightly retouched (brand text removed from the trainers):
- Denim jacket: engin akyurt, Unsplash: https://unsplash.com/photos/a-pair-of-jeans-and-a-jean-jacket-on-a-white-background-LdekusMFSsA
- Trainers: SJ (@uxsj_ph), Unsplash: https://unsplash.com/photos/wHUlMvFHEbA
- Wool jumper: Shelter, Unsplash: https://unsplash.com/photos/white-knit-sweater-on-white-wooden-surface-xEraWP_ZRGU
- Leather handbag: Muneeb Malhotra, Pexels: https://www.pexels.com/photo/black-bag-on-white-background-22434774/
