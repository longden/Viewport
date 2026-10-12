import SwiftUI

/// Toolbar button that sends one link to every visible pane.
struct DeepLinkToolbarButton: View {
    @ObservedObject var workspace: WorkspaceStore
    let web: WebViewModel
    @ObservedObject var history: DeepLinkHistoryStore
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Open Link", systemImage: "link")
                .labelStyle(.titleAndIcon)
        }
        .help("Open a URL or deep link on every visible pane (⇧⌘L)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DeepLinkPopover(
                workspace: workspace,
                web: web,
                history: history,
                onDismiss: { isPresented = false }
            )
        }
    }
}

struct DeepLinkPopover: View {
    @ObservedObject var workspace: WorkspaceStore
    let web: WebViewModel
    @ObservedObject var history: DeepLinkHistoryStore
    var onDismiss: () -> Void

    @AppStorage("deepLinkTargetsAndroid") private var targetsAndroid = true
    @AppStorage("deepLinkTargetsIOS") private var targetsIOS = true
    @AppStorage("deepLinkTargetsWeb") private var targetsWeb = true
    @State private var link = ""
    @State private var isSending = false
    @State private var status: DeepLinkStatus?
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Link")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("myapp://path or https://example.com", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldIsFocused)
                    .onSubmit { send(link) }
                    .frame(minWidth: 300)

                Button("Open") {
                    send(link)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend(link))
            }

            HStack(spacing: 14) {
                Toggle("Android", isOn: $targetsAndroid)
                    .disabled(!workspace.isVisible(.android))
                Toggle("iOS", isOn: $targetsIOS)
                    .disabled(!workspace.isVisible(.iOS))
                Toggle("Web", isOn: $targetsWeb)
                    .disabled(!workspace.isVisible(.web) || !webAccepts(link))
                    .help(
                        webAccepts(link)
                            ? "Also load the link in the web pane"
                            : "The web pane only loads http and https links"
                    )
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if let status {
                Label(status.message, systemImage: status.systemImage)
                    .font(.caption)
                    .foregroundStyle(status.isError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !history.history.favorites.isEmpty || !history.history.entries.isEmpty {
                Divider()
            }

            if !history.history.favorites.isEmpty {
                linkSection("Favorites") {
                    ForEach(history.history.favorites, id: \.self) { entry in
                        DeepLinkRow(
                            link: entry,
                            isFavorite: true,
                            onOpen: { open(entry) },
                            onToggleFavorite: { history.removeFavorite(entry) },
                            onRemove: nil
                        )
                    }
                }
            }

            if !history.history.entries.isEmpty {
                linkSection("Recently", accessory: {
                    Button("Clear") {
                        history.clear()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Clear recent links (favorites stay)")
                }) {
                    ForEach(history.history.entries, id: \.self) { entry in
                        DeepLinkRow(
                            link: entry,
                            isFavorite: false,
                            onOpen: { open(entry) },
                            onToggleFavorite: { history.addFavorite(entry) },
                            onRemove: { history.remove(entry) }
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            fieldIsFocused = true
        }
    }

    private func linkSection<Rows: View, Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            VStack(alignment: .leading, spacing: 2) {
                rows()
            }
        }
    }

    private func open(_ entry: String) {
        link = entry
        send(entry)
    }

    private var deviceTargets: DeviceInjectionTargets {
        var targets: DeviceInjectionTargets = []
        if targetsAndroid, workspace.isVisible(.android) { targets.insert(.android) }
        if targetsIOS, workspace.isVisible(.iOS) { targets.insert(.iOS) }
        return targets
    }

    private func webAccepts(_ rawLink: String) -> Bool {
        rawLink.trimmingCharacters(in: .whitespaces).isEmpty
            || DeepLinkHistory.isWebLoadable(rawLink)
    }

    private func wantsWeb(_ rawLink: String) -> Bool {
        targetsWeb && workspace.isVisible(.web) && DeepLinkHistory.isWebLoadable(rawLink)
    }

    private func canSend(_ rawLink: String) -> Bool {
        !isSending
            && DeviceAutomationService.normalizedURL(rawLink) != nil
            && (!deviceTargets.isEmpty || wantsWeb(rawLink))
    }

    private func send(_ rawLink: String) {
        guard canSend(rawLink) else { return }
        isSending = true
        status = nil
        let alsoOpenWeb = wantsWeb(rawLink)
        let targets = deviceTargets
        Task {
            do {
                let result = try await workspace.broadcastOpenURL(
                    rawLink,
                    targets: targets,
                    alsoOpenWeb: alsoOpenWeb,
                    web: web
                )
                history.record(rawLink)
                status = DeepLinkStatus(
                    message: result.summary(verb: "Opened"),
                    isError: !result.skipped.isEmpty
                )
            } catch {
                status = DeepLinkStatus(
                    message: error.localizedDescription,
                    isError: true
                )
            }
            isSending = false
        }
    }
}

private struct DeepLinkStatus: Equatable {
    let message: String
    let isError: Bool

    var systemImage: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
}

/// One saved link. The star (and remove button for recents) appear on hover;
/// favorites keep a filled star so they read as starred.
private struct DeepLinkRow: View {
    let link: String
    let isFavorite: Bool
    var onOpen: () -> Void
    var onToggleFavorite: () -> Void
    var onRemove: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: DeepLinkHistory.isWebLoadable(link) ? "globe" : "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PaneToolbarButtonStyle())
            .help("Open \(link)")

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PaneToolbarButtonStyle())
            .opacity(isFavorite || isHovered ? 1 : 0)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PaneToolbarButtonStyle())
                .opacity(isHovered ? 1 : 0)
                .help("Remove from recent links")
                .accessibilityLabel("Remove from recent links")
            }
        }
        .font(.callout)
        .onHover { isHovered = $0 }
    }
}
