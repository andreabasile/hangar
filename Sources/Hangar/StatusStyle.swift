import HangarCore
import SwiftUI

/// One vocabulary for the connection state, used by the form row and the launch bar alike.
extension ConnectionStatus {
    static var gaveUpTitle: String { String(localized: "Still no answer after 30 minutes") }

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    func title(authenticated: Bool) -> String {
        switch self {
        case .ok: authenticated ? String(localized: "Reachable and authorized") : String(localized: "Reachable")
        case .unauthorized: String(localized: "Key refused (401)")
        case .loading: String(localized: "Model loading (503)")
        case .timeout, .unreachable: String(localized: "The server isn’t answering yet")
        case .keyUnreadable: String(localized: "Key file not readable")
        case .unexpected(let code): String(localized: "Unexpected response (HTTP \(code))")
        }
    }

    var detail: String {
        switch self {
        case .ok(let models):
            let chat = ModelChoice.chatModels(models).count
            return chat == 1 ? String(localized: "1 model available") : String(localized: "\(chat) models available")
        case .unauthorized: return String(localized: "Check the preset’s key file.")
        case .loading: return String(localized: "The server answers but isn’t ready yet.")
        case .timeout: return String(localized: "No answer within 10 seconds: the pod may still be starting, be off, or the URL is wrong.")
        case .unreachable(let reason): return String(localized: "The pod may still be starting, be off, or the URL is wrong (\(reason))")
        case .keyUnreadable: return String(localized: "Check the path of the preset’s key file.")
        case .unexpected: return String(localized: "Check the server URL.")
        }
    }

    /// The full model list, for the tooltip on "N modelli disponibili".
    var help: String? {
        if case .ok(let models) = self { return models.joined(separator: "\n") }
        return nil
    }

    /// While polling, a startup failure is a wait (orange clock), not yet an error.
    func symbol(polling: Bool) -> String {
        if polling, isTransient { return "clock.circle.fill" }
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .unauthorized: return "lock.circle.fill"
        case .loading: return "hourglass.circle.fill"
        case .timeout, .unreachable: return "xmark.circle.fill"
        case .keyUnreadable: return "key.circle.fill"
        case .unexpected: return "exclamationmark.circle.fill"
        }
    }

    func color(polling: Bool) -> Color {
        if polling, isTransient { return .orange }
        switch self {
        case .ok: return .green
        case .loading, .unexpected: return .orange
        case .unauthorized, .timeout, .unreachable, .keyUnreadable: return .red
        }
    }
}
