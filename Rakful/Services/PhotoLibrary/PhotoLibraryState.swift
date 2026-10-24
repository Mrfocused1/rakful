import Observation
import Photos
import PhotosUI
import UIKit

/// Observable photo-library authorisation and counts for the UI. Updates when
/// the user changes their limited selection or revokes access in Settings.
@MainActor
@Observable
final class PhotoLibraryState {
    private(set) var accessLevel: PhotoAccessLevel
    private(set) var authorizedPhotoCount: Int = 0
    /// True if access was previously granted and has since been removed.
    private(set) var accessWasRevoked = false

    private let source: PhotoAssetSource
    private let preferences: PreferencesStore
    private let observesLibrary: Bool
    private var observer: LibraryChangeObserver?
    private var refreshTask: Task<Void, Never>?

    init(source: PhotoAssetSource, preferences: PreferencesStore, observesLibrary: Bool = true) {
        self.source = source
        self.preferences = preferences
        self.observesLibrary = observesLibrary
        self.accessLevel = source.accessLevel()
    }

    func refresh() {
        let previous = accessLevel
        accessLevel = source.accessLevel()
        if previous.canRead && !accessLevel.canRead { accessWasRevoked = true }
        if accessLevel.canRead { accessWasRevoked = false }
        startObservingIfNeeded()
        refreshTask?.cancel()
        let source = source
        let includeScreenshots = preferences.includeScreenshots
        refreshTask = Task {
            let count = await Task.detached(priority: .utility) {
                source.authorizedImageCount(includeScreenshots: includeScreenshots)
            }.value
            guard !Task.isCancelled else { return }
            authorizedPhotoCount = count
        }
    }

    func requestAccess() async -> PhotoAccessLevel {
        accessLevel = await source.requestAccess()
        refresh()
        return accessLevel
    }

    /// Presents the system picker for changing a limited selection.
    func presentLimitedLibraryPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func startObservingIfNeeded() {
        guard observesLibrary, observer == nil, accessLevel.canRead else { return }
        let observer = LibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }
}

private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}
