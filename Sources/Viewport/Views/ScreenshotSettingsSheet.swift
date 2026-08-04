import SwiftUI

struct ScreenshotSettingsSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshot settings")
                    .font(.title3.weight(.semibold))
                Text("Choose how combined screenshots are labelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                dismiss()
            }
        }
        .padding(16)
    }

    private var content: some View {
        List {
            Button {
                workspace.setScreenshotPlatformLabelsEnabled(
                    !workspace.screenshotPlatformLabelsEnabled
                )
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(
                        systemName: workspace.screenshotPlatformLabelsEnabled
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        workspace.screenshotPlatformLabelsEnabled
                            ? Color.accentColor
                            : Color.secondary
                    )
                    .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show platform labels")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(
                            "Adds a caption above each pane: Web, Android, or iOS."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
