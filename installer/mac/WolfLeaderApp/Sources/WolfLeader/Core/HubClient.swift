import Foundation

/// Thin REST client for the hub (FastAPI on :6971). Add endpoint helpers in extensions.
struct HubClient {
    var baseURL: String

    enum HubError: LocalizedError {
        case badURL, http(Int), offline(String)
        var errorDescription: String? {
            switch self {
            case .badURL: return "The hub address isn't a valid URL."
            case .http(let code): return "The hub answered with HTTP \(code)."
            case .offline(let why): return "Can't reach the hub: \(why)"
            }
        }
    }

    func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var comps = URLComponents(string: trimmed + path) else { throw HubError.badURL }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let u = comps.url else { throw HubError.badURL }
        return u
    }

    func data(_ path: String, query: [String: String] = [:], method: String = "GET",
              body: Data? = nil, timeout: TimeInterval = 10) async throws -> Data {
        var req = URLRequest(url: try url(path, query: query), timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw HubError.http(http.statusCode)
            }
            return data
        } catch let e as HubError {
            throw e
        } catch {
            throw HubError.offline(error.localizedDescription)
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(path, query: query))
    }

    /// True when GET /health answers 2xx within the timeout.
    func isHealthy(timeout: TimeInterval = 4) async -> Bool {
        (try? await data("/health", timeout: timeout)) != nil
    }
}
