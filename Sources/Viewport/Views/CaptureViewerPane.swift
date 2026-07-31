import SwiftUI

struct CaptureViewerPane: View {
    @ObservedObject var session: WindowCaptureSession
    @ObservedObject var deviceManager: DeviceManager

    var body: some View {
        ViewerPane(
            source: session.source,
            status: session.phase.label,
            statusStyle: statusStyle
        ) {
            sourcePicker
        } content: {
            ZStack {
                if session.phase == .live {
                    Color.primary.opacity(0.035)
                    CapturePreviewView(session: session)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(session.inputAccess.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    .black.opacity(0.54),
                                    in: Capsule()
                                )
                        }
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                } else {
                    Color.black
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        HStack(spacing: 8) {
            if session.availableDevices.isEmpty {
                Text("No running \(session.source.detail.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker(
                    "Device",
                    selection: Binding(
                        get: { session.selectedDeviceID },
                        set: { id in
                            if let id {
                                session.selectDevice(id)
                            }
                        }
                    )
                ) {
                    ForEach(session.availableDevices) { device in
                        Text(device.displayName)
                            .tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Button {
                session.refreshWindows()
            } label: {
                Label("Refresh devices", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Refresh devices")

            if session.phase == .live {
                Button {
                    session.requestInputAccess()
                } label: {
                    Label(
                        session.inputAccess.label,
                        systemImage: session.inputAccess == .ready
                            ? "cursorarrow.click.2"
                            : "hand.raised"
                    )
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(
                    session.inputAccess == .ready
                        ? Color.green
                        : Color.orange
                )
                .help(
                    session.inputAccess == .ready
                        ? "Direct device input is active; keyboard input follows focus"
                        : "Direct device input is unavailable"
                )
            }

            DeviceLauncherMenu(manager: deviceManager)
        }
        .controlSize(.small)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(session.source.accentColor)

            VStack(spacing: 4) {
                Text(emptyStateTitle)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(emptyStateMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            DeviceLauncherMenu(manager: deviceManager, compact: false)
        }
        .padding(24)
    }

    private var statusStyle: StatusStyle {
        return switch session.phase {
        case .live:
            .active
        case .failed:
            .error
        case .noWindow:
            .warning
        case .idle, .searching, .connecting:
            .neutral
        }
    }

    private var emptyStateIcon: String {
        return switch session.phase {
        case .failed:
            "exclamationmark.triangle"
        default:
            session.source.systemImage
        }
    }

    private var emptyStateTitle: String {
        if case let .launching(name) = deviceManager.phase {
            return "Starting \(name)"
        }

        return switch session.phase {
        case .failed:
            "Device stream stopped"
        case .searching:
            "Looking for a device"
        case .connecting:
            "Connecting"
        default:
            "Start \(session.source.detail)"
        }
    }

    private var emptyStateMessage: String {
        if case let .failed(message) = deviceManager.phase {
            return message
        }

        if case .launching = deviceManager.phase {
            return "The live view will connect when the device finishes booting."
        }

        return switch session.phase {
        case let .failed(message):
            message
        case .searching:
            "This usually takes a moment."
        case .connecting:
            "Connecting directly to the device framebuffer."
        default:
            "Start a device, then refresh. Its host window may stay hidden or closed."
        }
    }
}
