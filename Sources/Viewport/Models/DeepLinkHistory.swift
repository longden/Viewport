import Foundation

/// Links sent from the deep-link bar: starred favorites, then a
/// most-recent-first list of everything else.
struct DeepLinkHistory: Equatable {
    static let defaultLimit = 12

    /// Recently sent links, newest first. Never contains a favorite.
    private(set) var entries: [String]
    /// Starred links, in the order they were starred.
    private(set) var favorites: [String]
    let limit: Int

    init(
        entries: [String] = [],
        favorites: [String] = [],
        limit: Int = DeepLinkHistory.defaultLimit
    ) {
        self.limit = max(limit, 1)
        let favorites = Self.uniqueTrimmed(favorites)
        self.favorites = favorites
        self.entries = Array(
            Self.uniqueTrimmed(entries).filter { !favorites.contains($0) }.prefix(self.limit)
        )
    }

    func isFavorite(_ link: String) -> Bool {
        favorites.contains(link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    mutating func record(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // Favorites keep their place; they don't also appear in Recently.
        guard !trimmed.isEmpty, !favorites.contains(trimmed) else { return }
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    mutating func remove(_ link: String) {
        entries.removeAll { $0 == link }
    }

    /// Clears Recently; favorites stay.
    mutating func clear() {
        entries.removeAll()
    }

    /// Moves a link from Recently into Favorites.
    mutating func addFavorite(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !favorites.contains(trimmed) else { return }
        favorites.append(trimmed)
        entries.removeAll { $0 == trimmed }
    }

    /// Unstars a link and puts it back at the top of Recently.
    mutating func removeFavorite(_ link: String) {
        guard favorites.contains(link) else { return }
        favorites.removeAll { $0 == link }
        record(link)
    }

    private static func uniqueTrimmed(_ links: [String]) -> [String] {
        var unique: [String] = []
        for link in links {
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !unique.contains(trimmed) else { continue }
            unique.append(trimmed)
        }
        return unique
    }

    /// Web panes only load http(s); custom schemes go to devices only.
    static func isWebLoadable(_ rawLink: String) -> Bool {
        guard let normalized = DeviceAutomationService.normalizedURL(rawLink) else {
            return false
        }
        return WebViewModel.normalizedURL(from: normalized) != nil
    }
}
