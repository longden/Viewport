import SwiftUI

struct CreateAndroidEmulatorSheet: View {
    @ObservedObject var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [AndroidEmulatorProfile] = []
    @State private var selectedProfileID: String?
    @State private var isLoadingProfiles = true
    @State private var loadError: String?
    @State private var didStartCreating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 360)
        .task {
            await loadProfiles()
        }
        .onChange(of: manager.phase) { _, phase in
            guard didStartCreating else { return }
            switch phase {
            case .launching, .ready:
                dismiss()
            case .failed:
                didStartCreating = false
            default:
                break
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Android emulator")
                    .font(.title3.weight(.semibold))
                Text("Pick a device size. Viewport will create it and start it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .disabled(manager.phase.isBusy)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingProfiles {
            ProgressView("Loading device sizes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(loadError)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List(selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.displayName)
                                    .font(.body.weight(.medium))
                                if profile.isRecommended {
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            .green.opacity(0.15),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(profile.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(Optional(profile.id))
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if case let .creating(name) = manager.phase {
                ProgressView()
                    .controlSize(.small)
                Text("Creating \(name)…")
                    .foregroundStyle(.secondary)
            } else if case let .failed(message) = manager.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            Button("Create and start") {
                guard let id = selectedProfileID,
                      let profile = profiles.first(where: { $0.id == id })
                else { return }
                didStartCreating = true
                manager.createEmulator(profile: profile)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                selectedProfileID == nil
                    || manager.phase.isBusy
                    || isLoadingProfiles
                    || loadError != nil
            )
        }
        .padding(16)
    }

    private func loadProfiles() async {
        isLoadingProfiles = true
        loadError = nil
        do {
            let loaded = try await manager.listCreateProfiles()
            profiles = loaded
            selectedProfileID = loaded.first(where: \.isRecommended)?.id
                ?? loaded.first?.id
            isLoadingProfiles = false
        } catch {
            loadError = error.localizedDescription
            isLoadingProfiles = false
        }
    }
}
