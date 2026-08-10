import Combine
import Foundation

final class FavoritesStore: ObservableObject {
    @Published private(set) var sites: [FavoriteSite]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "favoriteSites"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FavoriteSite].self, from: data) else {
            sites = []
            return
        }

        sites = decoded
    }

    func add(title: String, url: URL) {
        let normalizedURL = url.absoluteURL
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = displayTitle.isEmpty
            ? (normalizedURL.host ?? normalizedURL.absoluteString)
            : displayTitle

        if let existingIndex = sites.firstIndex(where: {
            $0.url.absoluteString == normalizedURL.absoluteString
        }) {
            var existing = sites.remove(at: existingIndex)
            existing.title = resolvedTitle
            existing.url = normalizedURL
            sites.insert(existing, at: 0)
        } else {
            sites.insert(
                FavoriteSite(title: resolvedTitle, url: normalizedURL),
                at: 0
            )
        }

        let maximumFavorites = 50
        if sites.count > maximumFavorites {
            sites = Array(sites.prefix(maximumFavorites))
        }

        persist()
    }

    func remove(_ site: FavoriteSite) {
        sites.removeAll(where: { $0.id == site.id })
        persist()
    }

    func remove(url: URL) {
        sites.removeAll(where: { $0.url.absoluteString == url.absoluteString })
        persist()
    }

    func contains(url: URL?) -> Bool {
        guard let url else { return false }
        return sites.contains(where: { $0.url.absoluteString == url.absoluteString })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
