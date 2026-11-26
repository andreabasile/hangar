import Foundation

public enum ModelChoice {
    /// The ids an agent can use: embedding models are listed by servers like LM Studio too.
    public static func chatModels(_ ids: [String]) -> [String] {
        ids.filter { !$0.localizedCaseInsensitiveContains("embed") }
    }

    /// The model to fill in by itself: only when none is set and there is nothing to choose.
    public static func automatic(current: String, ids: [String]) -> String? {
        let chat = chatModels(ids)
        return current.trimmingCharacters(in: .whitespaces).isEmpty && chat.count == 1 ? chat[0] : nil
    }

    /// Set when the preset's model is not among the server's chat models. `suggestion` is the
    /// only chat model, when there is exactly one.
    public struct Mismatch: Equatable, Sendable {
        public let suggestion: String?
    }

    public static func mismatch(current: String, ids: [String]) -> Mismatch? {
        let chat = chatModels(ids)
        let model = current.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !chat.contains(model) else { return nil }
        return Mismatch(suggestion: chat.count == 1 ? chat[0] : nil)
    }
}

public enum RecentFolders {
    public static let limit = 8

    /// Most recent first, without duplicates.
    public static func adding(_ folder: String, to recents: [String]) -> [String] {
        Array(([folder] + recents.filter { $0 != folder }).prefix(limit))
    }
}
