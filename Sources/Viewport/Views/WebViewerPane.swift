import SwiftUI

struct WebViewerPane: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject var favorites: FavoritesStore
    @FocusState private var addressIsFocused: Bool

    var body: some View {
        ViewerPane(
            source: .web,
            status: status,
            statusStyle: model.errorMessage == nil ? .active : .error
        ) {
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

    private var addressBar: some View {
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

            TextField("Web address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .focused($addressIsFocused)
                .onSubmit {
                    model.loadAddress()
                    addressIsFocused = false
                }

            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Reload page")

            FavoritesMenu(favorites: favorites, web: model)

            Button {
                model.clearCookies()
            } label: {
                if model.isClearingData {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Clear cookies", systemImage: "eraser")
                }
            }
            .labelStyle(.iconOnly)
            .disabled(model.isClearingData)
            .help("Clear cookies immediately")

            Menu {
                Button("Clear cookies") {
                    model.clearCookies()
                }

                Button("Clear all website data", role: .destructive) {
                    model.clearAllWebsiteData()
                }
            } label: {
                Label("Website data", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .help("Website data options")
        }
        .controlSize(.small)
    }

    private var status: String {
        if model.isClearingData {
            return "Clearing data"
        }
        return model.isLoading ? "Loading" : "Ready"
    }
}
