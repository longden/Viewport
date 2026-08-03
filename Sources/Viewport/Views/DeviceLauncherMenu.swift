import SwiftUI

struct DeviceLauncherMenu: View {
    @ObservedObject var manager: DeviceManager
    var compact = true

    var body: some View {
        Menu {
            if manager.devices.isEmpty {
                emptyMenuContent
            } else {
                ForEach(manager.devices) { device in
                    Button {
                        manager.launch(device)
                    } label: {
                        Label(
                            menuTitle(for: device),
                            systemImage: device.state.systemImage
                        )
                    }
                    .disabled(
                        device.state == .unavailable
                            || (device.source == .android && device.state == .booted)
                    )
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

    private func menuTitle(for device: LaunchableDevice) -> String {
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
