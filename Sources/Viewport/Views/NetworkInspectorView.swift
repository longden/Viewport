import SwiftUI
import UniformTypeIdentifiers

/// Network shaping and debugging-proxy setup across panes.
struct NetworkInspectorView: View {
    @ObservedObject var store: NetworkConditionsStore
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PlatformTargetToggles(targets: $store.targets, workspace: workspace)

            conditions
            proxy

            InspectorStatusLine(status: store.status)
        }
        .disabled(store.isBusy)
    }

    private var conditions: some View {
        InspectorSection("Conditions") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NetworkProfile.allCases) { profile in
                    Button {
                        store.applyProfile(profile)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: store.appliedProfile == profile
                                ? "largecircle.fill.circle"
                                : "circle")
                                .foregroundStyle(store.appliedProfile == profile ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.title).font(.caption.weight(.medium))
                                Text(profile.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PaneToolbarButtonStyle())
                }
                Toggle("Airplane mode (Android)", isOn: Binding(
                    get: { store.isOffline },
                    set: { store.setOffline($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 4)
                Text(NetworkConditionsService.iOSThrottleMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var proxy: some View {
        InspectorSection("Debugging proxy") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("App", selection: $store.proxyPreset) {
                    ForEach(ProxyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .controlSize(.small)
                HStack(spacing: 6) {
                    TextField("Host", text: $store.proxyHost)
                        .textFieldStyle(.roundedBorder)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("Port", text: $store.proxyPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                }
                .font(.caption.monospaced())

                HStack(spacing: 6) {
                    Image(systemName: store.certificate == nil ? "lock.open" : "lock.fill")
                        .foregroundStyle(store.certificate == nil ? Color.secondary : Color.green)
                    Text(store.certificate?.summary ?? "No CA certificate (HTTPS stays encrypted)")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(store.certificate == nil ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if store.certificate != nil {
                        Button {
                            store.removeCertificate()
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(PaneToolbarButtonStyle())
                        .help("Forget the certificate")
                    }
                    Button("Choose…") {
                        chooseCertificate()
                    }
                    .controlSize(.small)
                }

                HStack {
                    if let active = store.activeProxy {
                        Label("On · \(active.trimmedHost):\(active.port)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Turn off") {
                        store.clearProxy()
                    }
                    .disabled(store.activeProxy == nil)
                    Button("Route through proxy") {
                        store.applyProxy()
                    }
                    .disabled(store.proxySettings == nil)
                }
                .controlSize(.small)

                if store.certificate != nil {
                    Button("Copy CA to Android Downloads") {
                        store.copyCertificateToAndroid()
                    }
                    .controlSize(.small)
                    .help("Then install it from Settings ▸ Security ▸ Encryption & credentials ▸ Install a certificate ▸ CA certificate")
                }

                Text("Android uses adb reverse for local proxies, so USB phones work too. Simulators trust the CA and use the Mac’s proxy. The web pane trusts the CA for itself only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseCertificate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "pem") ?? .data,
            UTType(filenameExtension: "crt") ?? .data,
            UTType(filenameExtension: "cer") ?? .data,
            UTType(filenameExtension: "der") ?? .data,
            .x509Certificate
        ]
        panel.allowsMultipleSelection = false
        panel.message = "Choose your proxy’s root CA certificate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.loadCertificate(from: url)
    }
}
