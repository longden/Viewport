import SwiftUI
import UniformTypeIdentifiers

struct CaptureViewerPane: View {
    @ObservedObject var session: WindowCaptureSession
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var workspace: WorkspaceStore
    var paneID: UUID?
    var paneTitleSuffix: String?
    var isClosable: Bool = false
    var onScreenshot: (() -> Void)?
    var showPerfHUD: Bool = false
    var showDeviceBezels: Bool = false
    @State private var showCreateEmulator = false
    @State private var showCloseConfirm = false
    @State private var isDropTargeted = false
    @State private var installBanner: PackageInstallBanner?
    @State private var installTask: Task<Void, Never>?
    @State private var dismissBannerTask: Task<Void, Never>?
    @State private var automationStatus: AutomationStatusMessage?

    var body: some View {
        ViewerPane(
            source: session.source,
            titleSuffix: paneTitleSuffix,
            onClose: isClosable ? { showCloseConfirm = true } : nil
        ) {
            sourcePicker
        } content: {
            ZStack {
                if session.phase == .live {
                    Color.primary.opacity(0.035)
                    CapturePreviewView(session: session)
                        .padding(showDeviceBezels ? 12 : 0)
                        .background {
                            if showDeviceBezels {
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .fill(Color(white: 0.12))
                                    .padding(-2)
                            }
                        }
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: showDeviceBezels ? 22 : 0,
                                style: .continuous
                            )
                        )

                    if session.capturedFrameSize == nil {
                        waitingForFrameOverlay
                    }

                    VStack {
                        HStack {
                            if showPerfHUD, session.framesPerSecond > 0 {
                                PaneFPSHud(framesPerSecond: session.framesPerSecond)
                            }
                            Spacer()
                        }
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

                if isDropTargeted {
                    packageDropOverlay
                }

                VStack {
                    if let installBanner {
                        packageInstallBanner(installBanner)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if let automationStatus {
                        automationStatusBanner(automationStatus)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.snappy(duration: 0.2), value: installBanner)
            .animation(.snappy(duration: 0.2), value: automationStatus)
            .dropDestination(for: URL.self) { urls, _ in
                handleDroppedPackages(urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .onTapGesture {
                workspace.focusedCaptureSource = session.source
                workspace.focusedCapturePaneID = paneID
            }
            .onPasteCommand(of: [.plainText]) { providers in
                guard let provider = providers.first else { return }
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    let text: String?
                    if let data = item as? Data {
                        text = String(data: data, encoding: .utf8)
                    } else {
                        text = item as? String
                    }
                    guard let text,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    Task { @MainActor in
                        workspace.focusedCaptureSource = session.source
                        workspace.focusedCapturePaneID = paneID
                        do {
                            try await workspace.pasteClipboard(text, to: session.source)
                        } catch {
                            presentAutomationError(error)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateEmulator) {
            CreateAndroidEmulatorSheet(manager: deviceManager)
        }
        .alert("Remove this pane?", isPresented: $showCloseConfirm) {
            Button("Remove", role: .destructive) {
                if let paneID {
                    _ = workspace.removePane(id: paneID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This closes the live view and shuts down the emulator or Simulator shown in this pane."
            )
        }
        .onDisappear {
            installTask?.cancel()
            dismissBannerTask?.cancel()
            installBanner = nil
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if session.availableDevices.isEmpty {
                    Text("No running \(session.source.detail.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            Text(devicePickerLabel(for: device))
                                .tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Button {
                    session.refreshWindows()
                } label: {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh devices")

                Button {
                    onScreenshot?()
                } label: {
                    Label("Screenshot", systemImage: "camera")
                }
                .labelStyle(.iconOnly)
                .disabled(!canTakeScreenshot)
                .help(
                    canTakeScreenshot
                        ? "Save this \(session.source.title) pane"
                        : "Nothing to capture yet"
                )

                Button {
                    rotateDevice()
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                .labelStyle(.iconOnly)
                .disabled(session.selectedDevice == nil)
                .help("Rotate the selected device")

                DeviceLauncherMenu(
                    manager: deviceManager,
                    onCreateEmulator: deviceManager.supportsCreatingEmulators
                        ? { showCreateEmulator = true }
                        : nil,
                    onLaunch: { device in
                        workspace.launch(device, into: session)
                    }
                )
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rotateDevice() {
        workspace.focusedCaptureSource = session.source
        workspace.focusedCapturePaneID = paneID
        automationStatus = nil
        Task {
            do {
                try await workspace.rotateFocusedDevice()
            } catch {
                presentAutomationError(error)
            }
        }
    }

    private func presentAutomationError(_ error: Error) {
        let accessibility = (error as? DeviceAutomationError)?.isAccessibilityRequired == true
        automationStatus = AutomationStatusMessage(
            text: error.localizedDescription,
            showsAccessibilitySettings: accessibility
        )
    }

    @ViewBuilder
    private func automationStatusBanner(
        _ status: AutomationStatusMessage
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.showsAccessibilitySettings
                ? "hand.raised.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(status.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if status.showsAccessibilitySettings {
                Button("Settings") {
                    AccessibilityPermission.openSystemSettings()
                }
                .controlSize(.small)
            }

            Button {
                automationStatus = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(
            cornerRadius: 12,
            style: .continuous
        ))
    }

    private var canTakeScreenshot: Bool {
        onScreenshot != nil && session.snapshotFrame() != nil
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
                        : nil,
                    onLaunch: { device in
                        workspace.launch(device, into: session)
                    }
                )
            }
        }
        .padding(24)
    }

    private var isLoadingState: Bool {
        if session.pendingLaunchName != nil {
            return true
        }
        // Creating an AVD is global; only show it on panes that are not live yet.
        if case .creating = deviceManager.phase, session.phase != .live {
            return true
        }
        switch session.phase {
        case .searching, .connecting:
            return true
        default:
            return false
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
        if let pendingLaunchName = session.pendingLaunchName {
            return "Starting \(pendingLaunchName)"
        }
        if case let .creating(name) = deviceManager.phase {
            return "Creating \(name)"
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

        if session.pendingLaunchName != nil {
            return "The live view will connect when the device finishes booting."
        }

        if case .creating = deviceManager.phase {
            return "This can take a minute the first time packages are downloaded."
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
                ? "Start a Simulator, or connect and trust an unlocked iPhone, then refresh. Drop an .app or .ipa to install."
                : "Start or create a device, then refresh. Drop an .apk onto this pane to install."
        }
    }

    private var packageDropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(session.source.accentColor.opacity(0.18))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    session.source.accentColor.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 28, weight: .medium))
                Text(dropPromptTitle)
                    .font(.headline)
                Text(dropPromptDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
            .foregroundStyle(.primary)
            .padding(24)
        }
        .allowsHitTesting(false)
    }

    private var dropPromptTitle: String {
        guard session.selectedDevice != nil else {
            return "Select a device first"
        }
        return session.source == .iOS
            ? "Drop to install"
            : "Drop APK to install"
    }

    private func devicePickerLabel(for device: StreamedDevice) -> String {
        guard device.id == session.selectedDeviceID,
              session.phase == .live else {
            return device.displayName
        }
        return "\(device.displayName) (\(session.transport.shortLabel))"
    }

    private var dropPromptDetail: String {
        if session.selectedDevice == nil {
            return "Choose a running \(session.source.detail.lowercased()) in the picker above."
        }
        return session.source == .iOS
            ? "Simulator accepts .app bundles. Physical devices need a signed .app or .ipa."
            : "Installs with adb install -r on the selected device."
    }

    @ViewBuilder
    private func packageInstallBanner(
        _ banner: PackageInstallBanner
    ) -> some View {
        HStack(spacing: 8) {
            switch banner {
            case .installing:
                ProgressView()
                    .controlSize(.small)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(banner.message)
                .font(.caption.weight(.medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(
            cornerRadius: 12,
            style: .continuous
        ))
    }

    private func handleDroppedPackages(_ urls: [URL]) -> Bool {
        guard let device = session.selectedDevice else {
            presentInstallBanner(
                .failed("Select a device in this pane first."),
                autoDismiss: true
            )
            return false
        }

        let packages = AppPackageInstaller.compatiblePackages(
            in: urls,
            for: device.kind
        )
        guard !packages.isEmpty else {
            let hint = session.source == .iOS
                ? "Drop an .app or .ipa for this device."
                : "Drop an .apk for this device."
            presentInstallBanner(.failed(hint), autoDismiss: true)
            return false
        }

        installTask?.cancel()
        dismissBannerTask?.cancel()
        installBanner = nil
        let installer = AppPackageInstaller()
        installTask = Task {
            for (index, package) in packages.enumerated() {
                guard !Task.isCancelled else {
                    installBanner = nil
                    return
                }
                let name = package.url.lastPathComponent
                presentInstallBanner(
                    .installing("Installing \(name)…"),
                    autoDismiss: false
                )
                do {
                    try await installer.install(
                        packageURL: package.url,
                        on: device
                    )
                    guard !Task.isCancelled else {
                        installBanner = nil
                        return
                    }
                    presentInstallBanner(
                        .succeeded("Installed \(name)"),
                        autoDismiss: index == packages.count - 1
                    )
                } catch is CancellationError {
                    installBanner = nil
                    return
                } catch {
                    guard !Task.isCancelled else {
                        installBanner = nil
                        return
                    }
                    presentInstallBanner(
                        .failed(error.localizedDescription),
                        autoDismiss: true
                    )
                    return
                }
            }
        }
        return true
    }

    private func presentInstallBanner(
        _ banner: PackageInstallBanner,
        autoDismiss: Bool
    ) {
        installBanner = banner
        dismissBannerTask?.cancel()
        guard autoDismiss else { return }
        dismissBannerTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if installBanner == banner {
                installBanner = nil
            }
        }
    }
}

private struct AutomationStatusMessage: Equatable {
    let text: String
    let showsAccessibilitySettings: Bool
}

private enum PackageInstallBanner: Equatable {
    case installing(String)
    case succeeded(String)
    case failed(String)

    var message: String {
        switch self {
        case let .installing(message),
             let .succeeded(message),
             let .failed(message):
            message
        }
    }
}
