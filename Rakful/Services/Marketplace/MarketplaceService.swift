import AuthenticationServices
import UIKit
import Foundation

/// Direct publishing through marketplace APIs is off for this release:
/// every listing is posted by the seller. The eBay adapter below is kept for
/// future work and isn't reachable while this is false.
enum DirectPublishing {
    static let isEnabled = false
}

struct ListingPayload: Sendable, Equatable, Encodable {
    var title: String
    var description: String
    var category: String
    var brand: String
    var model: String
    var colour: String
    var size: String
    var material: String
    var measurements: String
    var condition: String
    var defects: String
    var keywords: [String]
    var price: Double
    var currencyCode: String
}

extension ListingPayload {
    /// Built from an approved snapshot's content, never the live draft.
    init(content: ListingContent) {
        self.init(
            title: content.title,
            description: content.description,
            category: content.category,
            brand: content.brand,
            model: content.model,
            colour: content.colour,
            size: content.size,
            material: content.material,
            measurements: content.measurements,
            condition: content.condition?.displayName ?? "",
            defects: content.defectsAssessment == .noneFound ? "None found" : content.defects,
            keywords: content.keywords,
            price: content.askingPrice ?? 0,
            currencyCode: content.currencyCode
        )
    }
}

struct PublishedListing: Sendable, Decodable {
    var listingID: String
    var url: String?
}

/// Publishes through an official seller API.
protocol MarketplacePublisher: Sendable {
    var marketplace: Marketplace { get }
    var isAvailable: Bool { get }
    func publish(_ payload: ListingPayload, images: [Data]) async throws -> PublishedListing
}

/// eBay publishing via the Rakful server, which performs the Sell
/// Inventory API flow (inventory item → offer → publish) with the user's
/// OAuth grant. Requires eBay developer approval and a connected account.
/// Not operational in this release (see `DirectPublishing`).
struct EbayPublisher: MarketplacePublisher {
    let client: BackendClient
    let marketplace = Marketplace.ebay

    var isAvailable: Bool {
        DirectPublishing.isEnabled && client.configuration.isConfigured && client.keychain.string(for: BackendClient.sessionTokenAccount) != nil
    }

    struct Request: Encodable, Sendable {
        let listing: ListingPayload
        let imagesJPEGBase64: [String]
    }

    func publish(_ payload: ListingPayload, images: [Data]) async throws -> PublishedListing {
        guard client.configuration.isConfigured else { throw BackendError.notConfigured }
        guard isAvailable else { throw BackendError.notAuthenticated }
        return try await client.post(
            "v1/marketplaces/ebay/listings",
            body: Request(listing: payload, imagesJPEGBase64: images.map { $0.base64EncodedString() }),
            as: PublishedListing.self
        )
    }
}

/// Links an eBay account through the Rakful server using
/// `ASWebAuthenticationSession`. The server exchanges eBay's authorisation
/// code and returns a Rakful session token, stored in the Keychain.
/// eBay's API licence restricts storing eBay user IDs, so neither the app
/// nor the server keeps the seller's username — only eBay's opaque ID.
@MainActor
final class EbayAccountLinker: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let client: BackendClient

    init(client: BackendClient) {
        self.client = client
    }

    var isAvailable: Bool { client.configuration.isConfigured }

    func connect() async throws {
        guard let base = client.configuration.baseURL else { throw BackendError.notConfigured }
        let startURL = base.appending(path: "v1/oauth/ebay/start")
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: startURL, callbackURLScheme: "rackful") { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? BackendError.invalidResponse) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let token = items.first(where: { $0.name == "session" })?.value else { throw BackendError.invalidResponse }
        try client.keychain.set(token, for: BackendClient.sessionTokenAccount)
    }

    func disconnect() {
        client.keychain.remove(BackendClient.sessionTokenAccount)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
