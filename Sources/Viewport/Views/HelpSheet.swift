import SwiftUI

struct HelpSheet: View {
    @ObservedObject var androidDevices: DeviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var report: AndroidSetupReport?
    @State private var isChecking = true
    @State private var showCreateSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(
                        "Viewport needs a few Android tools on this Mac to list, create, and stream emulators. This check only looks at what’s already installed."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if isChecking {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking this Mac…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    } else if let report {
                        VStack(spacing: 10) {
                            ForEach(report.items) { item in
                                checkRow(item)
                            }
                        }

                        if report.canCreateEmulators {
                            Button {
                                showCreateSheet = true
                            } label: {
                                Label(
                                    "Create Android emulator…",
                                    systemImage: "plus.circle"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        } else {
                            Text(
                                "Once the missing Android pieces above are installed, you can create an emulator here without leaving Viewport."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .task {
            await refreshReport()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateAndroidEmulatorSheet(manager: androidDevices)
        }
        .onChange(of: androidDevices.devices.count) {
            Task { await refreshReport() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Help")
                    .font(.title2.weight(.semibold))
                Text("Android setup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await refreshReport() }
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
            }
            .disabled(isChecking)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func checkRow(_ item: SetupCheckItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol(item.status))
                .foregroundStyle(statusColor(item.status))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func statusSymbol(_ status: SetupCheckStatus) -> String {
        switch status {
        case .ready:
            "checkmark.circle.fill"
        case .missing:
            "xmark.circle.fill"
        case .optionalMissing:
            "exclamationmark.circle"
        }
    }

    private func statusColor(_ status: SetupCheckStatus) -> Color {
        switch status {
        case .ready:
            .green
        case .missing:
            .red
        case .optionalMissing:
            .orange
        }
    }

    private func refreshReport() async {
        isChecking = true
        report = await AndroidSetupDiagnostics().evaluate()
        isChecking = false
    }
}
