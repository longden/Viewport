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
        } label: {
            Label("Saved websites", systemImage: "bookmark")
        }
        .labelStyle(.iconOnly)
        .help("Saved websites")
    }
}
