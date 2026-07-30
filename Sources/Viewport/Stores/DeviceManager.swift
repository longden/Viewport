import Combine
import Foundation

enum DeviceManagerPhase: Equatable {
    case idle
    case loading
    case ready
    case launching(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .launching:
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

    private let client: any DeviceClient
    private var refreshTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var refreshGeneration = UUID()

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
        phase = .loading

        refreshTask = Task { [weak self] in
            guard let self else { return }

            do {
                let devices = try await client.listDevices()
                guard !Task.isCancelled,
                      refreshGeneration == generation else {
                    return
                }
                self.devices = devices
                self.phase = .ready
            } catch {
                guard !Task.isCancelled,
                      refreshGeneration == generation else {
                    return
                }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func launch(_ device: LaunchableDevice) {
        guard devices.contains(where: { $0.id == device.id }) else { return }

        launchTask?.cancel()
        phase = .launching(device.name)

        launchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.launch(device)
                guard !Task.isCancelled else { return }

                self.lastLaunchToken = UUID()
                self.phase = .ready

                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self.refreshDevices()
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}
