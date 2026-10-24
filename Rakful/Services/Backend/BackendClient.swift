import Foundation

enum BackendError: LocalizedError, Equatable {
    case notConfigured
    case notAuthenticated
    case consentRequired
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This feature isn't available right now."
        case .notAuthenticated: "Connect your account to use this feature."
        case .consentRequired: "Allow cloud analysis in Settings › Privacy first."
        case .http(let code): "The server responded with an error (\(code))."
        case .invalidResponse: "The server response couldn't be read."
        }
    }
}

/// JSON client for the Rakful server. The server holds all third-party
/// secrets (eBay, AI providers); the app sends only a per-user session token.
struct BackendClient: Sendable {
    let configuration: BackendConfiguration
    var keychain = KeychainStore()
    var session: URLSession = .shared

    static let sessionTokenAccount = "server.session"

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ path: String, body: Body, as: Response.Type) async throws -> Response {
        guard let base = configuration.baseURL else { throw BackendError.notConfigured }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = keychain.string(for: Self.sessionTokenAccount) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.backend.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401 ? BackendError.notAuthenticated : BackendError.http(http.statusCode)
        }
        do { return try JSONDecoder.backend.decode(Response.self, from: data) } catch { throw BackendError.invalidResponse }
    }
}

extension JSONEncoder {
    static let backend: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let backend: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
