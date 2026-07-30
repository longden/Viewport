import SwiftUI

struct FavoritesMenu: View {
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var web: WebViewModel

    var body: some View {
        Menu {
            if favorites.sites.isEmpty {
                Text("No saved websites")
            } else {
                ForEach(favorites.sites) { site in
                    Button {
                        web.load(site.url)
                    } label: {
                        Label(site.title, systemImage: "globe")
                    }
                }
            }

            Divider()

            Button {
                saveCurrentWebsite()
            } label: {
                Label("Save current website", systemImage: "star")
            }
            .disabled(web.currentURL == nil || currentWebsiteIsSaved)

            if currentWebsiteIsSaved {
                Button {
                    removeCurrentWebsite()
                } label: {
                    Label("Remove current website", systemImage: "star.slash")
                }
            }

            if !favorites.sites.isEmpty {
                Menu("Remove saved website") {
                    ForEach(favorites.sites) { site in
                        Button(site.title, role: .destructive) {
                            favorites.remove(site)
                        }
                    }
                }
            }
        } label: {
            Label(
                "Saved websites",
                systemImage: currentWebsiteIsSaved ? "star.fill" : "star"
            )
        }
        .labelStyle(.iconOnly)
        .help("Saved websites")
    }

    private var currentWebsiteIsSaved: Bool {
        favorites.contains(url: web.currentURL)
    }

    private func saveCurrentWebsite() {
        guard let url = web.currentURL else { return }
        favorites.add(title: web.title, url: url)
    }

    private func removeCurrentWebsite() {
        guard let url = web.currentURL else { return }
        favorites.remove(url: url)
    }
}
