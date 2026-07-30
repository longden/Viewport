import SwiftUI

struct CaptureViewerPane: View {
    @ObservedObject var session: WindowCaptureSession
    @ObservedObject var deviceManager: DeviceManager
    let onRequestScreenAccess: () -> Void

    var body: some View {
        ViewerPane(
            source: session.source,
            status: session.phase.label,
            statusStyle: statusStyle
        ) {
            sourcePicker
        } content: {
            ZStack {
                Color.black

                if session.phase == .live {
                    CapturePreviewView(session: session)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("Live mirror")
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
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        HStack(spacing: 8) {
            if session.availableWindows.isEmpty {
                Text("No \(session.source.detail.lowercased()) window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker(
                    "Window",
                    selection: Binding(
                        get: { session.selectedWindowID },
                        set: { id in
                            if let id {
                                session.selectWindow(id)
                            }
                        }
                    )
                ) {
                    ForEach(session.availableWindows) { window in
                        Text(window.displayName)
                            .tag(Optional(window.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Button {
                session.refreshWindows()
            } label: {
                Label("Refresh windows", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Refresh windows")

            if session.phase == .live {
                Button {
                    session.activateSelectedApplication()
                } label: {
                    Label(
                        "Open device window",
                        systemImage: "arrow.up.forward.app"
                    )
                }
                .labelStyle(.iconOnly)
                .help(
                    "Open the device window to interact; this pane is a live mirror"
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

            if session.phase == .permissionNeeded {
                Button {
                    onRequestScreenAccess()
                } label: {
                    Label("Open screen access", systemImage: "lock.open")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            session.source.accentColor,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            } else {
                DeviceLauncherMenu(manager: deviceManager, compact: false)
            }
        }
        .padding(24)
    }

    private var statusStyle: StatusStyle {
        return switch session.phase {
        case .live:
            .active
        case .failed:
            .error
        case .permissionNeeded, .noWindow:
            .warning
        case .idle, .searching, .connecting:
            .neutral
        }
    }

    private var emptyStateIcon: String {
        return switch session.phase {
        case .permissionNeeded:
            "rectangle.inset.filled.and.person.filled"
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
        case .permissionNeeded:
            "Screen access needed"
        case .failed:
            "Capture stopped"
        case .searching:
            "Looking for a window"
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
            return "The live view will connect when the window appears."
        }

        return switch session.phase {
        case .permissionNeeded:
            "Enable Viewport in System Settings, then return here. It will reconnect automatically."
        case let .failed(message):
            message
        case .searching:
            "This usually takes a moment."
        case .connecting:
            "Preparing the live view."
        default:
            "Keep the \(session.source.detail.lowercased()) window open and unminimized, then refresh."
        }
    }
}
