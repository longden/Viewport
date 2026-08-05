import SwiftUI

struct WebViewerPane: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject var favorites: FavoritesStore
    var onScreenshot: (() -> Void)?
    @FocusState private var addressIsFocused: Bool

    var body: some View {
        ViewerPane(source: .web) {
            addressBar
        } content: {
            ZStack(alignment: .bottom) {
                WebContentView(model: model)
                    .background(.background)

                if let message = model.noticeMessage ?? model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                }
            }
        }
    }

    private var canTakeScreenshot: Bool {
        onScreenshot != nil && model.currentURL != nil
    }

    private var currentWebsiteIsSaved: Bool {
        favorites.contains(url: model.currentURL)
    }

    private var addressBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ControlGroup {
                    Button {
                        model.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(!model.canGoBack)

                    Button {
                        model.goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(!model.canGoForward)
                }
                .labelStyle(.iconOnly)

                Spacer(minLength: 0)

                clearDataMenu

                FavoritesMenu(favorites: favorites, web: model)

                Button {
                    onScreenshot?()
                } label: {
                    Label("Screenshot", systemImage: "camera")
                }
                .labelStyle(.iconOnly)
                .disabled(!canTakeScreenshot)
                .help(
                    canTakeScreenshot
                        ? "Save this web pane"
                        : "Nothing to capture yet"
                )

                Button {
                    model.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Reload page")
            }

            HStack(spacing: 8) {
                TextField("Web address", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressIsFocused)
                    .onSubmit {
                        model.loadAddress()
                        addressIsFocused = false
                    }

                Button {
                    toggleFavorite()
                } label: {
                    Label(
                        currentWebsiteIsSaved ? "Unsave website" : "Save website",
                        systemImage: currentWebsiteIsSaved ? "star.fill" : "star"
                    )
                }
                .labelStyle(.iconOnly)
                .disabled(model.currentURL == nil)
                .help(
                    currentWebsiteIsSaved
                        ? "Remove from saved websites"
                        : "Save current website"
                )
            }
        }
        .controlSize(.small)
    }

    private var clearDataMenu: some View {
        Menu {
            Button("Clear cookies") {
                model.clearCookies()
            }

            Button("Clear website data", role: .destructive) {
                model.clearAllWebsiteData()
            }

            Button("Clear both", role: .destructive) {
                model.clearCookiesAndWebsiteData()
            }
        } label: {
            if model.isClearingData {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Clear website data", systemImage: "eraser")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(model.isClearingData)
        .help("Clear cookies and website data")
    }

    private func toggleFavorite() {
        guard let url = model.currentURL else { return }

        if favorites.contains(url: url) {
            favorites.remove(url: url)
        } else {
            favorites.add(title: model.title, url: url)
        }
    }
}
