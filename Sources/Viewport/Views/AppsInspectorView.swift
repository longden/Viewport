import SwiftUI

/// Permissions and simulated push notifications for the app under test.
struct AppsInspectorView: View {
    @ObservedObject var store: AppEnvironmentStore
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("App", accessory: {
                if store.isLoadingApps {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        store.refreshInstalledApps()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(PaneToolbarButtonStyle())
                    .help("List apps installed on the visible devices")
                }
            }) {
                appField(
                    title: "iOS",
                    placeholder: "com.example.app",
                    text: $store.iOSAppID,
                    apps: store.iOSApps
                )
                appField(
                    title: "Android",
                    placeholder: "com.example.app",
                    text: $store.androidAppID,
                    apps: store.androidApps
                )
            }

            permissions
            push

            InspectorStatusLine(status: store.status)
        }
        .onAppear {
            if store.iOSApps.isEmpty && store.androidApps.isEmpty {
                store.refreshInstalledApps()
            }
        }
    }

    private func appField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        apps: [InstalledApp]
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            Menu {
                if apps.isEmpty {
                    Text("No installed apps found")
                } else {
                    ForEach(apps) { app in
                        Button(app.menuLabel) {
                            text.wrappedValue = app.id
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Installed \(title) apps")
        }
    }

    private var permissions: some View {
        InspectorSection("Permissions") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AppPermission.allCases) { permission in
                    HStack(spacing: 6) {
                        Image(systemName: permission.systemImage)
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(permission.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        platformBadges(for: permission)
                        ForEach(PermissionAction.allCases) { action in
                            Button(action.title) {
                                store.apply(action, permission)
                            }
                            .controlSize(.mini)
                            .help("\(action.title) \(permission.title.lowercased()) on visible devices")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset all permissions", role: .destructive) {
                        store.resetAllPermissions()
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
                Text("iOS may quit the app when a permission changes. Android resets clear the “don’t ask again” flag.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(store.isBusy)
        }
    }

    private func platformBadges(for permission: AppPermission) -> some View {
        HStack(spacing: 2) {
            if permission.simctlService != nil {
                Image(systemName: ViewerSource.iOS.systemImage)
                    .help("Simulator")
            }
            if !permission.androidPermissions.isEmpty {
                Image(systemName: ViewerSource.android.systemImage)
                    .help("Android")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: 30, alignment: .trailing)
    }

    private var push: some View {
        InspectorSection("Push notification") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Menu("Template") {
                        ForEach(PushPayloadTemplate.allCases) { template in
                            Button(template.title) {
                                store.applyTemplate(template)
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button {
                        store.sendPush()
                    } label: {
                        Label("Send to Simulators", systemImage: "paperplane.fill")
                    }
                    .disabled(store.isBusy || store.iOSAppID.isEmpty)
                }
                .controlSize(.small)
                TextEditor(text: $store.pushPayload)
                    .font(.caption.monospaced())
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                if let validation = validationMessage {
                    Label(validation, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Uses the iOS bundle ID above. Android pushes need Firebase, so they aren’t simulated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var validationMessage: String? {
        do {
            _ = try PushPayloadValidator.validate(store.pushPayload)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
