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
                availabilityStatus
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
                } else if updates.availability.isAvailable {
                    Button("Install Update…") {
                        updates.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updates.canCheckForUpdates)
                    .help("Shows the release notes, then downloads and installs")
                } else {
                    Button(updates.availability == .unknown ? "Check for Updates" : "Check Again") {
                        updates.refreshAvailability()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updates.canCheckForUpdates || updates.availability == .checking)
                }
            }
        }
        .padding(28)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // Opening the window is the check; no second click needed.
            updates.refreshAvailability()
        }
    }

    @ViewBuilder
    private var availabilityStatus: some View {
        switch updates.availability {
        case .unknown:
            // No check is running (updater not started yet, or one was cancelled).
            Text("Check for a new version of Viewport. Updates include release notes before you install.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Viewport is up to date.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case let .available(version):
            Label("Viewport \(version) is available.", systemImage: "arrow.down.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case let .failed(message):
            Label("Couldn’t check for updates: \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
