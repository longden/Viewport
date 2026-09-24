import AppKit
import SwiftUI

struct DeviceLauncherMenu: View {
    @ObservedObject var manager: DeviceManager
    var compact = true
    var onCreateEmulator: (() -> Void)?
    /// When set, Play routes through this instead of `manager.launch` directly
    /// so the caller can bind the launch to a specific pane.
    var onLaunch: ((LaunchableDevice) -> Void)?
    var onShutdown: ((LaunchableDevice) -> Void)?
    var onShutdownAll: (() -> Void)?
    var canLaunchAnotherGuest: () -> Bool = { true }

    @State private var installAlertMessage: String?

    private var availableDevices: [LaunchableDevice] {
        manager.devices.filter { $0.state != .unavailable }
    }

    private var stockDevices: [LaunchableDevice] {
        availableDevices.filter { !$0.isLightSim }
    }

    private var lightSimDevices: [LaunchableDevice] {
        availableDevices.filter(\.isLightSim)
    }

    private var runningGuests: [LaunchableDevice] {
        var seen = Set<String>()
        return (manager.sessionStartedGuestDevices + manager.bootedDevices).filter { device in
            (device.source == .iOS || device.source == .android)
                && seen.insert(device.guestID).inserted
        }
    }

    private var isCreatingEmulator: Bool {
        if case .creating = manager.phase { return true }
        return false
    }

    private func isRunning(_ device: LaunchableDevice) -> Bool {
        device.state == .booted
            || manager.sessionStartedGuestIDs.contains(device.guestID)
    }

    var body: some View {
        Menu {
            if manager.supportsCreatingEmulators, let onCreateEmulator {
                Button {
                    onCreateEmulator()
                } label: {
                    Label(
                        "Create emulator…",
                        systemImage: "plus.circle"
                    )
                }

                Divider()
            }

            if stockDevices.isEmpty && runningGuests.isEmpty {
                emptyMenuContent
            } else if !stockDevices.isEmpty {
                ForEach(stockDevices) { device in
                    launchButton(for: device)
                }
            }

            if manager.source == .iOS {
                Section("Light Sim") {
                    if manager.isLightSimAvailable {
                        if lightSimDevices.isEmpty {
                            Text("No Simulators to slim")
                        } else {
                            ForEach(lightSimDevices) { device in
                                launchButton(for: device)
                            }
                        }
                    } else {
                        lightSimInstallRow
                    }
                }
            }

            if !runningGuests.isEmpty {
                Divider()

                ForEach(runningGuests) { device in
                    Button(role: .destructive) {
                        if let onShutdown {
                            onShutdown(device)
                        } else {
                            manager.shutdown(device)
                        }
                    } label: {
                        Label(
                            "Shut down \(shutdownName(for: device))",
                            systemImage: "stop.circle"
                        )
                    }
                }

                if runningGuests.count > 1, let onShutdownAll {
                    Button(role: .destructive) {
                        onShutdownAll()
                    } label: {
                        Label(
                            "Shut down all \(manager.source.title) devices",
                            systemImage: "stop.circle.fill"
                        )
                    }
                }
            }

            Divider()

            Button {
                manager.refreshDevices()
            } label: {
                Label("Refresh devices", systemImage: "arrow.clockwise")
            }
        } label: {
            if manager.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if compact {
                Image(systemName: "play.circle")
            } else {
                Label(
                    "Choose \(manager.source.launchDetail)",
                    systemImage: "play.circle"
                )
            }
        }
        .help("Choose and start \(manager.source.launchDetail)")
        .accessibilityLabel("Start or stop \(manager.source.launchDetail)")
        .alert(
            "Couldn’t start install",
            isPresented: Binding(
                get: { installAlertMessage != nil },
                set: { if !$0 { installAlertMessage = nil } }
            )
        ) {
            if installAlertMessage?.contains("Homebrew") == true {
                Button("Open brew.sh") {
                    NSWorkspace.shared.open(SetupTerminalInstaller.homebrewURL)
                    installAlertMessage = nil
                }
            }
            Button("OK", role: .cancel) {
                installAlertMessage = nil
            }
        } message: {
            Text(installAlertMessage ?? "")
        }
    }

    @ViewBuilder
    private var emptyMenuContent: some View {
        switch manager.phase {
        case .loading:
            Text("Looking for devices…")
        case let .failed(message):
            Text(message)
        default:
            Text("No devices found")
        }
    }

    private var lightSimInstallRow: some View {
        Button {
            Task {
                do {
                    try await SetupTerminalInstaller.runInTerminal(
                        SimSlimClient.installCommand
                    )
                } catch {
                    installAlertMessage = error.localizedDescription
                }
            }
        } label: {
            Label("Install Light Sim…", systemImage: "arrow.down.circle")
        }
        .help(
            "Installs simslim with Homebrew. Return to Viewport when Terminal finishes; Light Sim will appear automatically."
        )
    }

    private func launchButton(for device: LaunchableDevice) -> some View {
        Button {
            if let onLaunch {
                onLaunch(device)
            } else {
                manager.launch(device)
            }
        } label: {
            Label(
                menuTitle(for: device),
                systemImage: device.state.systemImage
            )
        }
        .disabled(
            isRunning(device)
                || isCreatingEmulator
                || !canLaunchAnotherGuest()
        )
    }

    private func shutdownName(for device: LaunchableDevice) -> String {
        device.name.replacingOccurrences(of: "Light Sim — ", with: "")
    }

    private func menuTitle(for device: LaunchableDevice) -> String {
        if isRunning(device) {
            return "\(device.name) — Running"
        }
        if device.detail.isEmpty {
            return device.name
        }
        return "\(device.name) — \(device.detail)"
    }
}

private extension DeviceState {
    var systemImage: String {
        switch self {
        case .booted:
            "checkmark.circle.fill"
        case .starting:
            "clock"
        case .offline:
            "exclamationmark.circle"
        case .unavailable:
            "xmark.circle"
        case .shutdown, .unknown:
            "play.circle"
        }
    }
}
