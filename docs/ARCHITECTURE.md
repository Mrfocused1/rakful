# Rakful — Architecture

Native iOS app: Swift 6 (strict concurrency), SwiftUI, SwiftData, PhotoKit, Vision, BackgroundTasks, StoreKit 2, Foundation Models (optional, iOS 26+). Deployment target iOS 18.0. No third-party dependencies.

## Modules

```
Rakful/
  App/            Composition root (AppEnvironment), RootView (TabView), AppDelegate (BG registration), debug launch options
  Core/           Domain enums (ResaleCategory, OwnershipStatus, DiscoveryMode…), FeatureVector, PriceRange/ValueSummary, PreferencesStore
  Models/         SwiftData @Model types
  Persistence/    ModelContainer, DiscoveryStore (@ModelActor), SampleData, DataManagement (privacy deletes)
  DesignSystem/   Glass.swift (theme tokens, layered glass icon, frosted folder, black actions, rows, floating dock), grouped sections, badges, thumbnails
  Features/       Onboarding, Discover, Items, Sell, Activity, Settings
  Services/
    PhotoLibrary/          PhotoAssetSource protocol, PhotoKit implementation, PhotoLibraryState, thumbnails, imported images
    VisionAnalysis/        PhotoAnalyzer (Vision), CategoryClassifier (taxonomy → category), BrandTextMatcher
    Discovery/             DiscoveryEngine (pipeline), CandidateGrouper (pure), DiscoveryCoordinator (@MainActor)
    ProductIdentification/ On-device identifier; cloud adapter
    Pricing/               PricingService, PricingProvider protocol, server comparables adapter, statistics
    ListingGeneration/     Template generator, Apple Intelligence generator, validator, claim checker
    Marketplace/           Approval + export (ListingExport: snapshot photo store, approval, handoff), eBay publisher (off in this release), eBay account linking
    BackgroundProcessing/  BackgroundDiscoveryManager (Charge & Discover), DeviceConditionMonitor
    Notifications/         Local notifications for finished work only
    Subscriptions/         Entitlements (pure), EntitlementService (StoreKit 2)
    Backend/               BackendConfiguration (no secrets), BackendClient, Keychain
RakfulTests/   Swift Testing unit/integration tests (70)
RakfulUITests/ XCUITest journeys (3)
```

Views never talk to PhotoKit/Vision directly. All services are protocol-based or value types injected through `AppEnvironment`; tests build their own graphs with fixtures.

## Data model (SwiftData)

| Model | Purpose |
|---|---|
| `DiscoverySession` | One run: mode, status, interruption reason, counts, resumed-from link |
| `PhotoReference` | Checkpoint per PhotoKit asset (analysed / skipped / failed / iCloud-only, attempts). Its presence is what makes runs resumable |
| `CandidateItem` | A possession grouped from ≥1 photos. Brand/model/colour/size hold **user-confirmed** values only |
| `ItemPhoto` | Library reference, or imported/camera file name; duplicate flag; feature print bytes |
| `OwnershipConfirmation` | History of ownership answers |
| `ProductIdentification` | Suggestions with source + evidence (classifier label, visible text). Never auto-applied |
| `PriceEstimate` / `PricingEvidence` | Estimate from real comparables (or flagged sample data), with every comparable |
| `ListingDraft` | Editable listing, uncertain-field flags, defects answer, ordered photo selection, seller declaration, approved `ListingSnapshot` (JSON) and its version, marketplace, status (draft / approved / exported / listed) |
| `MarketplaceConnection` | Connection state; tokens live in the Keychain |
| `BackgroundTaskRecord` | Every BG request/execution/expiration for diagnostics |
| `ActivityEvent` | Timeline |

`UserPreferences` is implemented as `PreferencesStore` over `UserDefaults` (justified: key–value settings that must be readable synchronously at launch and in BG handlers).

## Discovery pipeline

1. `PhotoKitAssetSource.fetchImageAssets` — lightweight descriptors only (respects limited access; screenshots excluded by default).
2. Subtract checkpointed identifiers (`DiscoveryStore.processedIdentifiers`); apply monthly allowance.
3. `PhotoAnalyzer.verifyAvailability()` — model health check (see "Findings").
4. Batches of 24, bounded concurrency (2 manual / 1 background, 1 when thermal state is serious, stop when critical).
5. Per photo: 512px rendition from Photos → `ClassifyImageRequest` → `CategoryClassifier` → if relevant: saliency crop → `GenerateImageFeaturePrintRequest` → `RecognizeTextRequest` (brand hints).
6. `DiscoveryStore.commit` (one save per batch): checkpoint every photo, `CandidateGrouper` assigns photos to existing/new items, flags duplicates, stores suggestions, logs activity.
7. Cancellation at any point loses only in-flight photos; they're simply re-queued.

## Listing workflow

1. **Photos.** `ListingPhotoReviewer` runs the same Vision person check (`VisionPhotoAnalyzer.personCheck`) on discovered, imported and camera photos. Results: unchecked, no person, person, failed. Only "no person" or the seller's own review makes a photo eligible; a detected person always excludes it.
2. **Facts.** Suggestions (e.g. a brand read from a photo) must be confirmed or cleared. `ListingClaimChecker` flags brand, material, size, measurement, authenticity and condition claims in the text that confirmed details don't support; the seller edits them out or confirms them. Generators only ever see confirmed facts and never write condition or defects.
3. **Approval.** `ListingApproval` validates, copies the selected photos (in order) into `ApprovedPhotoStore` with SHA-256 digests, and records a `ListingSnapshot` with the exact export text. `ListingContent` equality detects any material change, which clears the approval.
4. **Ownership withdrawals.** Withdrawing ownership (the item, or the seller's declaration) withdraws approval of listings not yet listed. So that this survives a failed save followed by the app closing, `ApprovalRevocationJournal` first writes the revoked draft ID and approval version to a small file beside the database (replaced atomically). Every export, handoff and listing confirmation checks it; at launch `reconcile` applies it to the database before anything can be exported; entries are removed only after a save records them. An unreadable journal withdraws every approval not yet listed. Listed records are never rewritten. Limitation: if neither the journal nor the database can be written, the withdrawal applies for the rest of the session and the save error says it may be lost, but it can't survive the app closing. Atomic file replacement survives the app closing; very recent writes could still be lost if the phone itself loses power.
5. **Handoff.** `ListingExporter` serves only the snapshot, verifying photo digests. Copying, a completed share or opening the marketplace moves it to Handed Off; only the seller's confirmation marks it Listed. Saves that fail roll the draft back.

## Charge & Discover

- `BGProcessingTaskRequest` (`com.resaleready.app.discovery`), `requiresExternalPower` per user setting, submitted when the app backgrounds and after partial runs. iOS decides if/when it runs.
- Handler: record execution → set expiration handler (cancels via `RunControl`) → run engine in `.chargeAndDiscover` mode → record outcome/photos/remaining/resume → reschedule if work remains → `setTaskCompleted`. Always completes the task, including after expiration.
- Skips (and records why) when disabled, not entitled, or Low Power Mode is on and the user chose to pause.
- Manual runs use `beginBackgroundTask` only to reach a checkpoint when the app is backgrounded.
- No audio/location/networking tricks. `BGContinuedProcessingTask` (iOS 26) is a candidate for a future "keep going after I lock my phone" manual mode.

## Privacy boundaries

- Analysis is on-device. Stored per photo: identifier, status, top label, and (for candidates) a 768-float feature vector. No copies of library photos, apart from approved listing photos (below).
- Imported/camera photos are downsampled JPEGs (≤2048px) in Application Support; removable in Settings.
- Approving a listing keeps downsampled copies of its chosen photos (`ApprovedPhotoStore`) so exports match the approval exactly; removed with the draft, the item, or Delete All Data.
- Cloud identification requires a configured server **and** explicit consent; sends one downsized JPEG on demand.
- No API secrets in the app. `RRBackendBaseURL` (Info.plist) is empty in this build, so every cloud feature reports unavailable.
- The app never deletes, edits or moves library photos.

## External dependencies (not available in this build)

| Feature | Needs |
|---|---|
| Verified pricing | Rakful server calling eBay Browse API (asking prices) / Marketplace Insights (sold prices, restricted access) |
| eBay publishing | eBay developer approval, server performing Sell Inventory API (inventory item → offer → publish) with user OAuth |
| Cloud identification | Server + specialised model/provider |
| Subscriptions | App Store Connect products matching `ProductCatalog` (local `.storekit` file provided for testing) |
| Apple Intelligence listings | iOS 26+, eligible device with Apple Intelligence on (falls back to template) |

## Findings from verification

- **Grouping thresholds were measured, not guessed.** Vision feature prints of two *different* laptops are only ~0.105 apart (cosine), while a crop of the same image is ~0.08. Grouping is therefore tight (0.07 any time; 0.095 within 10 minutes; duplicate < 0.03) and users can **Combine** or **Separate** items. Thresholds need calibration on real libraries.
- **Vision in the iOS 18.5 Simulator is unusable**: GPU/ANE path fails ("Failed to create espresso context"); the CPU path returns identical labels for every image. The app forces CPU in Simulator and runs a probe-based health check before each run, so a broken model fails the run honestly instead of marking photos "analysed".
- SwiftData batch `delete(model:)` failed on the relationship graph; privacy deletes use per-object deletes (cascade-correct, keeps `@Query` live) plus a batch delete only for relationship-free photo checkpoints.
