import Foundation

public struct RelayAPI {
    public let baseURL: URL
    public let jwt: String?
    public init(url: String, jwt: String? = nil) throws {
        baseURL = try RelayURL.validate(url); self.jwt = jwt
    }
    public func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL), url.host == baseURL.host,
              url.scheme == baseURL.scheme, url.port == baseURL.port else { throw RelayError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("agentring-ios", forHTTPHeaderField: "User-Agent")
        if let jwt { request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    // Reject redirects: bearer credentials must never follow a relay redirect.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    public func data(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request(path, method: method, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            throw RelayError.http(status, error?["message"] as? String ?? "Request failed")
        }
        return data
    }
    public func get<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(path, method: method, body: body))
    }
    public func socket(after: Int) throws -> URLSessionWebSocketTask {
        var request = try request("/v1/ws?after_seq=\(after)")
        var c = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!
        c.scheme = "wss"; request.url = c.url
        return Self.session.webSocketTask(with: request)
    }
}
