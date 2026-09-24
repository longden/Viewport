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
    private var guestLaunchTasks: [String: Task<Void, Never>] = [:]
    private var guestLaunchGenerations: [String: UUID] = [:]
    /// Used for creating an AVD; guest boots are tracked separately above.
    private var launchTask: Task<Void, Never>?
    private var shutdownTasks: [String: Task<Void, Never>] = [:]
    private var refreshGeneration = UUID()
    private var launchGeneration = UUID()
    private var lastListedLightSimAvailability: Bool?
    /// Guests this manager booted during the current app session.
    private var sessionStartedGuests: [String: LaunchableDevice] = [:]

    init(client: any DeviceClient) {
        self.client = client
        source = client.source
    }

    deinit {
        refreshTask?.cancel()
        launchTask?.cancel()
        guestLaunchTasks.values.forEach { $0.cancel() }
        shutdownTasks.values.forEach { $0.cancel() }
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
            isLaunching = !guestLaunchTasks.isEmpty || !shutdownTasks.isEmpty
            launchTask?.cancel()
            launchGeneration = UUID()
            if !isLaunching { phase = .loading }
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
                self.lastListedLightSimAvailability = client.isLightSimAvailable
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
        let deviceID = device.guestID
        guard guestLaunchTasks[deviceID] == nil,
              shutdownTasks[deviceID] == nil else { return }

        refreshTask?.cancel()
        refreshGeneration = UUID()
        let generation = UUID()
        guestLaunchGenerations[deviceID] = generation
        lastLaunchFailureMessage = nil
        sessionStartedGuests[deviceID] = device
        phase = .launching(device.name)

        guestLaunchTasks[deviceID] = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.launch(device)
                guard !Task.isCancelled,
                      guestLaunchGenerations[deviceID] == generation else { return }

                self.guestLaunchTasks.removeValue(forKey: deviceID)
                self.guestLaunchGenerations.removeValue(forKey: deviceID)
                self.lastLaunchToken = UUID()
                if self.guestLaunchTasks.isEmpty, self.shutdownTasks.isEmpty {
                    self.phase = .ready
                }
                self.refreshDevices()
            } catch is CancellationError {
                guard guestLaunchGenerations[deviceID] == generation else { return }
                self.guestLaunchTasks.removeValue(forKey: deviceID)
                self.guestLaunchGenerations.removeValue(forKey: deviceID)
                self.sessionStartedGuests.removeValue(forKey: deviceID)
                self.lastLaunchFailureDeviceID = deviceID
                self.lastLaunchFailureToken = UUID()
                if self.guestLaunchTasks.isEmpty, self.shutdownTasks.isEmpty {
                    self.phase = .ready
                }
            } catch {
                guard !Task.isCancelled,
                      guestLaunchGenerations[deviceID] == generation else { return }
                self.guestLaunchTasks.removeValue(forKey: deviceID)
                self.guestLaunchGenerations.removeValue(forKey: deviceID)
                self.sessionStartedGuests.removeValue(forKey: deviceID)
                self.lastLaunchFailureMessage = error.localizedDescription
                self.lastLaunchFailureDeviceID = deviceID
                self.lastLaunchFailureToken = UUID()
                if self.guestLaunchTasks.isEmpty, self.shutdownTasks.isEmpty {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func shutdown(_ device: LaunchableDevice) {
        guard devices.contains(where: { $0.guestID == device.guestID })
            || sessionStartedGuests[device.guestID] != nil else { return }
        guard shutdownTasks[device.guestID] == nil else { return }

        refreshTask?.cancel()
        refreshGeneration = UUID()
        guestLaunchTasks[device.guestID]?.cancel()
        guestLaunchTasks.removeValue(forKey: device.guestID)
        guestLaunchGenerations.removeValue(forKey: device.guestID)
        launchTask?.cancel()
        launchTask = nil
        launchGeneration = UUID()
        phase = .shuttingDown(device.name)

        shutdownTasks[device.guestID] = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.shutdown(device)
                guard !Task.isCancelled else { return }
                self.sessionStartedGuests.removeValue(forKey: device.guestID)
                self.shutdownTasks.removeValue(forKey: device.guestID)
                if self.shutdownTasks.isEmpty {
                    self.phase = self.guestLaunchTasks.isEmpty
                        ? .ready
                        : .launching("devices")
                }
                self.refreshDevices()
            } catch is CancellationError {
                self.shutdownTasks.removeValue(forKey: device.guestID)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
                self.shutdownTasks.removeValue(forKey: device.guestID)
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
        guestLaunchTasks.values.forEach { $0.cancel() }
        guestLaunchTasks.removeAll()
        guestLaunchGenerations.removeAll()
        shutdownTasks.values.forEach { $0.cancel() }
        shutdownTasks.removeAll()
        refreshTask?.cancel()
        refreshGeneration = UUID()
        for device in devices {
            do {
                try await client.shutdown(device)
                sessionStartedGuests.removeValue(forKey: device.guestID)
            } catch {}
        }
        phase = .ready
    }

    var isLightSimAvailable: Bool {
        client.isLightSimAvailable
    }

    func refreshIfLightSimAvailabilityChanged() {
        guard source == .iOS,
              let lastListedLightSimAvailability,
              lastListedLightSimAvailability != client.isLightSimAvailable,
              !phase.isBusy else { return }
        refreshDevices()
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
