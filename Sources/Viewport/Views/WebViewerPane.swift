import SwiftUI

struct WebViewerPane: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject var favorites: FavoritesStore
    var onScreenshot: (() -> Void)?
    var onCaptureTargetChange: (@MainActor (WorkspaceRecordingTarget?) -> Void)?
    /// Composite recording squares the live web clip so it matches device panes.
    var squareContentCorners: Bool = false
    var showNetworkOverlay: Bool = false
    @FocusState private var addressIsFocused: Bool

    private var contentCornerRadius: CGFloat {
        squareContentCorners ? 0 : 16
    }

    var body: some View {
        ViewerPane(
            source: .web,
            contentCornerRadius: contentCornerRadius
        ) {
            addressBar
        } content: {
            ZStack(alignment: .bottom) {
                viewportContent
                    .overlay(alignment: .topTrailing) {
                        if showNetworkOverlay {
                            WebNetworkOverlayPanel(model: model.networkOverlay)
                                .padding(12)
                        }
                    }

                if let message = model.noticeMessage ?? model.errorMessage {
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                        .padding(12)
                }
            }
            .onChange(of: showNetworkOverlay) { _, enabled in
                model.networkOverlay.setEnabled(enabled)
            }
            .onAppear {
                model.networkOverlay.setEnabled(showNetworkOverlay)
            }
        }
    }

    private var viewportContent: some View {
        GeometryReader { proxy in
            let preset = model.viewportPreset
            let scale = preset.scaleFitting(in: proxy.size)
            let layoutSize = preset.fittedLayoutSize(in: proxy.size)

            ZStack {
                Color.primary.opacity(preset.size == nil ? 0 : 0.035)

                Group {
                    if let target = preset.size {
                        WebContentView(model: model)
                            .frame(width: target.width, height: target.height)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: contentCornerRadius,
                                    style: .continuous
                                )
                            )
                            .scaleEffect(scale, anchor: .center)
                            .frame(width: layoutSize.width, height: layoutSize.height)
                            .background {
                                webCaptureAnchor
                            }
                    } else {
                        WebContentView(model: model)
                            .frame(
                                width: proxy.size.width,
                                height: proxy.size.height
                            )
                            .background {
                                webCaptureAnchor
                            }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private var webCaptureAnchor: some View {
        if let onCaptureTargetChange {
            WorkspaceRecordingAnchor(onTargetChange: onCaptureTargetChange)
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

                viewportPresetPicker

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

    private var viewportPresetPicker: some View {
        Menu {
            ForEach(WebViewportPreset.Category.allCases, id: \.self) { category in
                Section(category.title) {
                    ForEach(WebViewportPreset.presets(in: category)) { preset in
                        Button {
                            model.setViewportPreset(preset)
                        } label: {
                            if model.viewportPreset == preset {
                                Label(preset.menuLabel, systemImage: "checkmark")
                            } else {
                                Text(preset.menuLabel)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(model.viewportPreset.menuLabel, systemImage: model.viewportPreset.systemImage)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: true, vertical: false)
        .help("Match a device or desktop CSS viewport")
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
