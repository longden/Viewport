import Combine
import Foundation

@MainActor
final class DeepLinkHistoryStore: ObservableObject {
    @Published private(set) var history: DeepLinkHistory

    private let defaults: UserDefaults
    private let key: String
    private let favoritesKey: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "deepLinkHistory",
        favoritesKey: String = "deepLinkFavorites"
    ) {
        self.defaults = defaults
        self.key = key
        self.favoritesKey = favoritesKey
        history = DeepLinkHistory(
            entries: defaults.stringArray(forKey: key) ?? [],
            favorites: defaults.stringArray(forKey: favoritesKey) ?? []
        )
    }

    func record(_ link: String) {
        history.record(link)
        persist()
    }

    func remove(_ link: String) {
        history.remove(link)
        persist()
    }

    func clear() {
        history.clear()
        persist()
    }

    func addFavorite(_ link: String) {
        history.addFavorite(link)
        persist()
    }

    func removeFavorite(_ link: String) {
        history.removeFavorite(link)
        persist()
    }

    private func persist() {
        defaults.set(history.entries, forKey: key)
        defaults.set(history.favorites, forKey: favoritesKey)
    }
}
