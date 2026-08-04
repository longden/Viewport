import SwiftUI

struct CaptureViewerPane: View {
    @ObservedObject var session: WindowCaptureSession
    @ObservedObject var deviceManager: DeviceManager
    @State private var showCreateEmulator = false

    var body: some View {
        ViewerPane(
            source: session.source,
            status: session.phase == .live
                ? session.liveStatus
                : session.phase.label,
            statusStyle: statusStyle
        ) {
            sourcePicker
        } content: {
            ZStack {
                if session.phase == .live {
                    Color.primary.opacity(0.035)
                    CapturePreviewView(session: session)

                    if session.capturedFrameSize == nil {
                        waitingForFrameOverlay
                    }

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
        .sheet(isPresented: $showCreateEmulator) {
            CreateAndroidEmulatorSheet(manager: deviceManager)
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
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
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
                        systemImage: inputStatusIcon
                    )
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(inputStatusColor)
                .disabled(session.inputAccess == .viewOnly)
                .help(inputStatusHelp)
            }

            DeviceLauncherMenu(
                manager: deviceManager,
                onCreateEmulator: deviceManager.supportsCreatingEmulators
                    ? { showCreateEmulator = true }
                    : nil
            )
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waitingForFrameOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                Text("Loading device screen…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                Text("Waiting for the first video frame.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(24)
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if isLoadingState {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            } else {
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(session.source.accentColor)
            }

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

            if !isLoadingState {
                DeviceLauncherMenu(
                    manager: deviceManager,
                    compact: false,
                    onCreateEmulator: deviceManager.supportsCreatingEmulators
                        ? { showCreateEmulator = true }
                        : nil
                )
            }
        }
        .padding(24)
    }

    private var isLoadingState: Bool {
        if case .launching = deviceManager.phase {
            return true
        }
        if case .creating = deviceManager.phase {
            return true
        }
        switch session.phase {
        case .searching, .connecting:
            return true
        default:
            return false
        }
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

    private var inputStatusIcon: String {
        switch session.inputAccess {
        case .ready:
            "cursorarrow.click.2"
        case .permissionNeeded:
            "hand.raised"
        case .viewOnly:
            "eye"
        }
    }

    private var inputStatusColor: Color {
        switch session.inputAccess {
        case .ready:
            .green
        case .permissionNeeded:
            .orange
        case .viewOnly:
            .secondary
        }
    }

    private var inputStatusHelp: String {
        switch session.inputAccess {
        case .ready:
            "Direct device input is active; keyboard input follows focus"
        case .permissionNeeded:
            "Direct device input is unavailable"
        case .viewOnly:
            "Connected iPhones are view only; interact on the phone itself"
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
        if case let .creating(name) = deviceManager.phase {
            return "Creating \(name)"
        }
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

        if case .creating = deviceManager.phase {
            return "This can take a minute the first time packages are downloaded."
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
            "Connecting to the device video stream."
        default:
            session.source == .iOS
                ? "Start a Simulator, or connect and trust an unlocked iPhone, then refresh."
                : "Start or create a device, then refresh. Its host window may stay hidden or closed."
        }
    }
}
