import SwiftUI

struct UpdatesView: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject var activity: AppActivityStore
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text("Viewport Updates")
                    .font(.title2.weight(.semibold))
                Text("Installed version \(updates.configuration.installedVersion)")
                    .foregroundStyle(.secondary)
            }

            if !updates.configuration.isEnabled {
                Text("In-app updates are available in official release builds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if updates.hasPendingInstallation {
                Text(activity.isBusy
                     ? "Finish \(activity.busyDescription) before restarting."
                     : "Your downloaded update is ready to install.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Check for a new version of Viewport. Updates include release notes before you install.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                .disabled(!updates.isUpdaterStarted)

            HStack {
                Link("View releases", destination: URL(string: "https://github.com/longden/Viewport/releases")!)
                Spacer()
                Button("Close") {
                    dismissWindow(id: "updates")
                }
                .keyboardShortcut(.cancelAction)

                if updates.hasPendingInstallation {
                    Button("Install Update and Restart") {
                        updates.installPendingUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activity.isBusy || activity.isTerminating)
                } else {
                    Button("Check for Updates…") {
                        updates.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updates.canCheckForUpdates)
                }
            }
        }
        .padding(28)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
