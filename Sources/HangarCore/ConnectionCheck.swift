import Foundation

public enum ConnectionStatus: Equatable, Sendable {
    case ok(models: [String])
    case unauthorized
    case loading
    case timeout
    /// No server behind the URL; the reason is short ("HTTP 404" or the network error).
    case unreachable(String)
    case keyUnreadable
    case unexpected(Int)

    /// Failures that clear up by themselves while a server starts (a pod downloading its model),
    /// so the check keeps polling.
    public var isTransient: Bool {
        switch self {
        case .loading, .timeout, .unreachable: true
        case .ok, .unauthorized, .keyUnreadable, .unexpected: false
        }
    }
}

public enum ConnectionCheck {
    private static let session = URLSession(configuration: .ephemeral)

    /// `GET <root>/v1/models`, with the key read from the key file if the server has one.
    /// The key stays in memory only.
    public static func run(_ server: Server, timeout: TimeInterval = 10) async -> ConnectionStatus {
        guard let url = URL(string: server.root + "/v1/models"), url.host() != nil else {
            return .unreachable(String(localized: "invalid URL", bundle: .module))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let keyPath = server.keyPath {
            guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return .keyUnreadable }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (body, response) = try await session.data(for: request)
            return status(code: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        } catch let error as URLError where error.code == .timedOut {
            return .timeout
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    public static func status(code: Int, body: Data) -> ConnectionStatus {
        switch code {
        case 200:
            struct Models: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            return .ok(models: (try? JSONDecoder().decode(Models.self, from: body))?.data.map(\.id) ?? [])
        case 401, 403: return .unauthorized
        case 503: return .loading
        // what a proxy answers when the server behind it is gone (a stopped or booting RunPod pod gives 404)
        case 404, 502, 504: return .unreachable("HTTP \(code)")
        default: return .unexpected(code)
        }
    }
}

public enum Polling {
    public static let interval: Duration = .seconds(10)
    /// A pod downloading its model can take a quarter of an hour; past this, something is wrong.
    public static let limit: Duration = .seconds(30 * 60)

    public static func shouldContinue(after status: ConnectionStatus, elapsed: Duration) -> Bool {
        status.isTransient && elapsed < limit
    }
}

/// When to check after the URL field changed. With a key file, a check sends the key to the URL,
/// so half-typed URLs are never checked: only pastes here, and Enter or leaving the field (in the UI).
public enum CheckTrigger: Equatable, Sendable {
    case debounced
    case now
    case wait

    public static let pasteLength = 8

    public static func afterEdit(from old: String, to new: String, hasKey: Bool) -> CheckTrigger {
        guard hasKey else { return .debounced }
        let old = Array(old), new = Array(new)
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        return new.count - prefix - suffix >= pasteLength ? .now : .wait
    }
}
