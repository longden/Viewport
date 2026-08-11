import SwiftUI

struct WebViewerPane: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject var favorites: FavoritesStore
    var onScreenshot: (() -> Void)?
    var onCaptureTargetChange: (@MainActor (WorkspaceRecordingTarget?) -> Void)?
    /// Kept for recording callers; squares the live web clip while recording.
    var squareContentCorners: Bool = false
    var onClose: (() -> Void)? = nil
    @FocusState private var addressIsFocused: Bool
    @State private var showCloseConfirm = false

    private var surfaceCornerRadius: CGFloat {
        squareContentCorners ? 0 : ViewerSource.surfaceCornerRadius
    }

    var body: some View {
        ViewerPane(
            source: .web,
            contentCornerRadius: surfaceCornerRadius,
            onClose: onClose == nil ? nil : { showCloseConfirm = true }
        ) {
            addressBar
        } content: {
            ZStack(alignment: .bottom) {
                viewportContent

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
        }
        .alert("Hide Web pane?", isPresented: $showCloseConfirm) {
            Button("Hide", role: .destructive) {
                onClose?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Web pane from the workspace. You can show it again from the toolbar.")
        }
    }

    private var viewportContent: some View {
        GeometryReader { proxy in
            let preset = model.viewportPreset
            let scale = preset.scaleFitting(in: proxy.size)
            let layoutSize = preset.fittedLayoutSize(in: proxy.size)

            ZStack {
                Group {
                    if let target = preset.size {
                        WebContentView(model: model)
                            .frame(width: target.width, height: target.height)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: surfaceCornerRadius,
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
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: surfaceCornerRadius,
                                    style: .continuous
                                )
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
        .background(.clear)
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
            ScrollView(.horizontal, showsIndicators: false) {
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
                .controlSize(.small)
                .buttonStyle(PaneToolbarButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
                .buttonStyle(PaneToolbarButtonStyle())
                .disabled(model.currentURL == nil)
                .help(
                    currentWebsiteIsSaved
                        ? "Remove from saved websites"
                        : "Save current website"
                )
            }
            .controlSize(.small)
        }
    }

    private var viewportPresetPicker: some View {
        Picker(
            "Viewport",
            selection: Binding(
                get: { model.viewportPreset },
                set: { model.setViewportPreset($0) }
            )
        ) {
            ForEach(WebViewportPreset.Category.allCases, id: \.self) { category in
                Section(category.title) {
                    ForEach(WebViewportPreset.presets(in: category)) { preset in
                        Text(preset.menuLabel)
                            .tag(preset)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
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
        .paneChromeHover()
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
