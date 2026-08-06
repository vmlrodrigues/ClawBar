import Foundation

struct FetchError: LocalizedError {
    enum Kind { case noToken, auth, limited, other }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}

/// The one network call. A minimal inference request whose *response headers* are the
/// payload; the message body is discarded.
///
/// There is no cheaper probe — `count_tokens`, `/v1/models`, and 400/404 validation
/// errors all return zero rate-limit headers (verified). Only a successful
/// `/v1/messages` call carries them.
enum AnthropicUsageClient {

    /// The only model a Claude subscription token can call. Every other model returns
    /// 429 `rate_limit_error` regardless of actual utilization. If this one is ever
    /// retired the data source stops, which is why it is a single named constant.
    static let pollModel = "claude-haiku-4-5-20251001"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let requestBody = Data(
        #"{"model":"\#(pollModel)","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#.utf8
    )

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 1
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    static func fetch() async throws -> Snapshot {
        guard let token = TokenStore.read() else {
            throw FetchError(kind: .noToken, message: "No token configured")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        // Bearer only — x-api-key with the same token returns 401.
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // `anthropic-beta: oauth-2025-04-20` is deliberately omitted — verified
        // unnecessary, and leaving it out drops one undocumented dependency.
        req.httpBody = requestBody

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError(kind: .other, message: "Malformed response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw FetchError(kind: .auth, message: "Token rejected — re-authenticate")
        case 429:
            // Carries no rate-limit headers at all. The caller must keep its last good
            // snapshot rather than clearing to zero or unknown.
            throw FetchError(kind: .limited, message: "Rate limited")
        default:
            throw FetchError(kind: .other, message: "HTTP \(http.statusCode)")
        }

        func window(_ key: String) -> UsageWindow? {
            let base = "anthropic-ratelimit-unified-\(key)"
            guard let u = http.value(forHTTPHeaderField: "\(base)-utilization").flatMap(Double.init),
                  let r = http.value(forHTTPHeaderField: "\(base)-reset").flatMap(Double.init)
            else { return nil }   // absent stays nil — never coerced to zero
            return UsageWindow(utilization: u,
                               resetsAt: Date(timeIntervalSince1970: r),
                               status: http.value(forHTTPHeaderField: "\(base)-status") ?? "unknown")
        }

        return Snapshot(
            session: window("5h"),
            weekly: window("7d"),
            overage: window("overage"),
            representative: http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-representative-claim") ?? "",
            fallbackPercentage: http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-fallback-percentage").flatMap(Double.init),
            fetchedAt: Date()
        )
    }

    /// Used by onboarding to check a pasted token before storing it.
    static func validate(token: String) async -> Result<Void, FetchError> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = requestBody
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(FetchError(kind: .other, message: "Malformed response"))
            }
            switch http.statusCode {
            case 200: return .success(())
            case 401: return .failure(FetchError(kind: .auth, message: "That token was rejected."))
            case 429: return .failure(FetchError(kind: .limited, message: "Rate limited — try again shortly."))
            default:  return .failure(FetchError(kind: .other, message: "Unexpected response (HTTP \(http.statusCode))."))
            }
        } catch {
            return .failure(FetchError(kind: .other, message: error.localizedDescription))
        }
    }
}
