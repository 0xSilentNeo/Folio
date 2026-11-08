import Foundation

/// The sync services' requests: JSON or form bodies, the status and data back.
enum SyncHTTP {
    struct Failure: Error, LocalizedError {
        var status: Int
        var body: String
        var errorDescription: String? { status == 0 ? "Not reached" : "HTTP \(status)" }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Folio/1.0"]
        return URLSession(configuration: c)
    }()

    static func send(_ url: URL, method: String = "GET", headers: [String: String] = [:], json: Any? = nil,
                     form: [String: String]? = nil) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody(form).data(using: .utf8)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Failure(status: 0, body: error.localizedDescription)
        }
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
}
