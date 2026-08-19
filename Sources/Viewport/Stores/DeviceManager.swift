import Combine
import Foundation

enum DeviceManagerPhase: Equatable {
    case idle
    case loading
    case ready
    case launching(String)
    case creating(String)
    case shuttingDown(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .launching, .creating, .shuttingDown:
            true
        case .idle, .ready, .failed:
            false
        }
    }
}

@MainActor
final class DeviceManager: ObservableObject {
    let source: ViewerSource

    @Published private(set) var devices: [LaunchableDevice] = []
    @Published private(set) var phase: DeviceManagerPhase = .idle
    @Published private(set) var lastLaunchToken = UUID()
    /// Bumped when a Play/boot attempt fails so panes can clear "Starting…" state.
    @Published private(set) var lastLaunchFailureToken = UUID()
    /// Device whose pending launch should clear when `lastLaunchFailureToken` bumps.
    /// Scoped so superseding a boot into another pane does not wipe that pane’s pending.
    @Published private(set) var lastLaunchFailureDeviceID: String?
    @Published private(set) var lastLaunchFailureMessage: String?

    private let client: any DeviceClient
    private var refreshTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private var launchGeneration = UUID()
    /// Guests this manager booted during the current app session.
    private var sessionStartedGuests: [String: LaunchableDevice] = [:]

    init(client: any DeviceClient) {
        self.client = client
        source = client.source
    }

    deinit {
        refreshTask?.cancel()
        launchTask?.cancel()
    }

    func refreshDevices() {
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation

        // Never abort an in-flight boot/create — that left panes stuck on
        // "Starting…" with no process left to finish the launch.
        let isLaunching: Bool
        switch phase {
        case .launching, .creating:
            isLaunching = true
        default:
            isLaunching = false
            launchTask?.cancel()
            launchGeneration = UUID()
            phase = .loading
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }

            do {
                let devices = try await client.listDevices()
                guard !Task.isCancelled,
                      refreshGeneration == generation else {
                    return
                }
                self.devices = devices
                if !isLaunching {
                    switch self.phase {
                    case .launching, .creating:
                        break
                    default:
                        self.phase = .ready
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      refreshGeneration == generation else {
                    return
                }
                switch self.phase {
                case .launching, .creating:
                    break
                default:
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func launch(_ device: LaunchableDevice) {
        guard devices.contains(where: { $0.id == device.id }) else { return }

        refreshTask?.cancel()
        refreshGeneration = UUID()
        launchTask?.cancel()
        let generation = UUID()
        launchGeneration = generation
        lastLaunchFailureMessage = nil
        let deviceID = device.id
        sessionStartedGuests[device.id] = device
        phase = .launching(device.name)

        launchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.launch(device)
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }

                self.lastLaunchToken = UUID()
                self.phase = .ready
                self.launchTask = nil
                self.refreshDevices()
            } catch is CancellationError {
                // Superseded by another launch/create; the new operation owns phase.
                // Clear only this device’s pending “Starting…” — not sibling panes.
                self.lastLaunchFailureDeviceID = deviceID
                self.lastLaunchFailureToken = UUID()
            } catch {
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }
                self.lastLaunchFailureMessage = error.localizedDescription
                self.lastLaunchFailureDeviceID = deviceID
                self.lastLaunchFailureToken = UUID()
                self.phase = .failed(error.localizedDescription)
                self.launchTask = nil
            }
        }
    }

    func shutdown(_ device: LaunchableDevice) {
        guard devices.contains(where: { $0.id == device.id })
            || sessionStartedGuests[device.id] != nil else { return }

        refreshTask?.cancel()
        refreshGeneration = UUID()
        launchTask?.cancel()
        let generation = UUID()
        launchGeneration = generation
        sessionStartedGuests.removeValue(forKey: device.id)
        phase = .shuttingDown(device.name)

        launchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.shutdown(device)
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }

                self.phase = .ready
                self.launchTask = nil
                self.refreshDevices()
            } catch is CancellationError {
                // Superseded by another operation.
            } catch {
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }
                self.phase = .failed(error.localizedDescription)
                self.launchTask = nil
            }
        }
    }

    var bootedDevices: [LaunchableDevice] {
        devices.filter { $0.state == .booted }
    }

    var sessionStartedGuestIDs: [String] {
        sessionStartedGuests.keys.sorted()
    }

    var sessionStartedGuestNames: [String] {
        sessionStartedGuests.values.map(\.name).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var sessionStartedGuestDevices: [LaunchableDevice] {
        Array(sessionStartedGuests.values)
    }

    func forgetSessionStarted(matching guest: StreamedDevice) {
        sessionStartedGuests = sessionStartedGuests.filter { _, device in
            !device.matchesSessionGuest(guest)
        }
    }

    /// Snapshot and clear guests launched this session so quit can power them off.
    func takeSessionStartedGuests() -> [LaunchableDevice] {
        let guests = Array(sessionStartedGuests.values)
        sessionStartedGuests.removeAll()
        return guests
    }

    /// Awaits `emu kill` / `simctl shutdown` without going through `launchTask`,
    /// so quitting can stop several guests without cancelling sibling shutdowns.
    func shutdownAwaiting(_ devices: [LaunchableDevice]) async {
        guard !devices.isEmpty else { return }
        launchTask?.cancel()
        launchGeneration = UUID()
        refreshTask?.cancel()
        refreshGeneration = UUID()
        for device in devices {
            sessionStartedGuests.removeValue(forKey: device.id)
            try? await client.shutdown(device)
        }
    }

    var supportsCreatingEmulators: Bool {
        source == .android && client is AndroidDeviceClient
    }

    func listCreateProfiles() async throws -> [AndroidEmulatorProfile] {
        guard let androidClient = client as? AndroidDeviceClient else {
            throw CommandRunnerError.executableNotFound("Android CLI")
        }
        return try await androidClient.listCreateProfiles()
    }

    func createEmulator(profile: AndroidEmulatorProfile) {
        guard let androidClient = client as? AndroidDeviceClient else {
            phase = .failed("Android CLI is not available.")
            return
        }

        refreshTask?.cancel()
        refreshGeneration = UUID()
        launchTask?.cancel()
        let generation = UUID()
        launchGeneration = generation
        phase = .creating(profile.displayName)

        launchTask = Task { [weak self] in
            guard let self else { return }

            do {
                let created = try await androidClient.createEmulator(
                    profile: profile
                )
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }

                let devices = try await androidClient.listDevices()
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }

                self.devices = devices
                self.phase = .ready
                self.launchTask = nil

                if let createdID = created.first,
                   let device = devices.first(where: { $0.id == createdID }) {
                    self.launch(device)
                }
            } catch is CancellationError {
                // Superseded by another operation.
            } catch {
                guard !Task.isCancelled,
                      launchGeneration == generation else { return }
                self.phase = .failed(error.localizedDescription)
                self.launchTask = nil
            }
        }
    }
}
