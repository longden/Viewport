import SwiftUI

/// Trailing inspector column: element inspection, design QA, and device environment.
struct InspectorPanel: View {
    @ObservedObject var inspector: InspectorStore
    @ObservedObject var location: LocationSimulationStore
    @ObservedObject var apps: AppEnvironmentStore
    @ObservedObject var network: NetworkConditionsStore
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspector.tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .labelStyle(.iconOnly)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Text(inspector.tab.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch inspector.tab {
                    case .elements:
                        ElementsInspectorView(inspector: inspector)
                    case .design:
                        DesignInspectorView(inspector: inspector)
                    case .location:
                        LocationInspectorView(store: location, workspace: workspace)
                    case .apps:
                        AppsInspectorView(store: apps, workspace: workspace)
                    case .network:
                        NetworkInspectorView(store: network, workspace: workspace)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Small titled group used across inspector tabs.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
    }
}

struct InspectorStatusLine: View {
    let status: EnvironmentStatus?

    var body: some View {
        if let status {
            Label {
                Text(status.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.isError ? Color.orange : Color.green)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}

/// Android / iOS / Web checkboxes; hidden panes are disabled.
struct PlatformTargetToggles: View {
    @Binding var targets: PlatformTargets
    @ObservedObject var workspace: WorkspaceStore
    var sources: [ViewerSource] = [.android, .iOS, .web]

    var body: some View {
        HStack(spacing: 12) {
            Text("Apply to")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                Toggle(source.title, isOn: binding(for: source))
                    .disabled(!workspace.isVisible(source))
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private func binding(for source: ViewerSource) -> Binding<Bool> {
        Binding(
            get: { targets.includes(source) },
            set: { isOn in
                switch source {
                case .android: targets.android = isOn
                case .iOS: targets.iOS = isOn
                case .web: targets.web = isOn
                }
            }
        )
    }
}

struct InspectorPlaceholder: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

/// Label / value row with optional copy button.
struct InspectorPropertyRow: View {
    let title: String
    let value: String?
    var monospaced = false
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value ?? "—")
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable, let value {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(PaneToolbarButtonStyle())
                .help("Copy \(title.lowercased())")
            }
        }
    }
}
