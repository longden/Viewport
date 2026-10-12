import Combine
import Foundation

/// Simulated location for every visible pane, including GPX route playback.
@MainActor
final class LocationSimulationStore: ObservableObject {
    @Published var targets: PlatformTargets {
        didSet { targets.save(to: defaults, key: Self.targetsKey) }
    }
    @Published private(set) var appliedCoordinate: GeoCoordinate?
    @Published private(set) var route: LocationRoute?
    @Published var routeSpeed: RouteSpeed = .city
    @Published private(set) var isPlayingRoute = false
    @Published private(set) var routeProgress: Double = 0
    @Published private(set) var routePosition: GeoCoordinate?
    @Published private(set) var isBusy = false
    @Published private(set) var status: EnvironmentStatus?

    private weak var workspace: WorkspaceStore?
    private weak var web: WebViewModel?
    private let service: LocationSimulationService
    private let defaults: UserDefaults
    private var playbackTask: Task<Void, Never>?
    /// Simulators running their own `simctl location start` scenario.
    private var routeSimulators: [StreamedDevice] = []

    private static let targetsKey = "locationSimulationTargets"
    /// Android / web updates while a route plays (Simulator interpolates itself).
    private static let playbackTick: Duration = .seconds(1)

    init(
        workspace: WorkspaceStore,
        web: WebViewModel,
        service: LocationSimulationService = LocationSimulationService(),
        defaults: UserDefaults = .standard
    ) {
        self.workspace = workspace
        self.web = web
        self.service = service
        self.defaults = defaults
        targets = PlatformTargets(defaults: defaults, key: Self.targetsKey)
    }

    deinit {
        playbackTask?.cancel()
    }

    var webIsTargeted: Bool {
        targets.web && workspace?.isVisible(.web) == true
    }

    func apply(_ coordinate: GeoCoordinate) {
        guard coordinate.isValid else {
            status = EnvironmentStatus(message: "Enter a valid latitude and longitude.", isError: true)
            return
        }
        stopRoute(updateDevices: false)
        run(verb: "Location set") { [self] in
            var result = await DeviceInjectionResult.collect(targetDevices()) {
                try await self.service.set(coordinate, on: $0)
            }
            if webIsTargeted {
                web?.setGeolocationOverride(coordinate)
                result.succeeded.append("Web")
            }
            if result.didSucceed {
                appliedCoordinate = coordinate
            }
            return result
        }
    }

    func clear() {
        stopRoute(updateDevices: false)
        run(verb: "Location cleared") { [self] in
            var result = await DeviceInjectionResult.collect(targetDevices()) {
                try await self.service.clear(on: $0)
            }
            if web?.geolocationOverride != nil {
                web?.setGeolocationOverride(nil)
                result.succeeded.append("Web")
            }
            appliedCoordinate = nil
            return result
        }
    }

    func loadRoute(from url: URL) {
        do {
            let route = try GPXRouteParser.parse(contentsOf: url)
            stopRouteForNewRoute()
            self.route = route
            routeProgress = 0
            routePosition = route.points.first
            status = EnvironmentStatus(
                message: "\(route.name): \(route.points.count) points, \(Self.distanceText(route.totalDistance))",
                isError: false
            )
        } catch {
            status = .failure(error)
        }
    }

    func setRoute(_ route: LocationRoute?) {
        stopRouteForNewRoute()
        self.route = route
        routeProgress = 0
        routePosition = route?.points.first
    }

    func playRoute() {
        guard let route, route.isPlayable, !isPlayingRoute else { return }
        let devices = targetDevices()
        let includeWeb = webIsTargeted
        guard !devices.isEmpty || includeWeb else {
            status = EnvironmentStatus(
                message: "Show a Simulator, Android emulator, or the web pane first.",
                isError: true
            )
            return
        }
        let speed = routeSpeed.metersPerSecond
        let duration = route.duration(speed: speed)
        isPlayingRoute = true
        routeProgress = 0
        status = EnvironmentStatus(
            message: "Playing \(route.name) at \(routeSpeed.title.lowercased()) speed (\(Self.durationText(duration)))",
            isError: false
        )

        let simulators = devices.filter { $0.kind == .iOSSimulator }
        let tickedDevices = devices.filter { $0.kind != .iOSSimulator }
        routeSimulators = simulators
        playbackTask = Task { [weak self] in
            guard let self else { return }
            var skipped: [String] = []
            for simulator in simulators {
                guard !Task.isCancelled else { return }
                do {
                    try await service.startRoute(route, metersPerSecond: speed, on: simulator)
                } catch {
                    skipped.append("\(simulator.name): \(error.localizedDescription)")
                }
            }
            let start = ContinuousClock.now
            var unsupported = Set<String>()
            while !Task.isCancelled {
                let elapsed = Self.seconds(ContinuousClock.now - start)
                guard let position = route.coordinate(atElapsed: elapsed, speed: speed) else { break }
                routePosition = position
                routeProgress = duration > 0 ? min(elapsed / duration, 1) : 1
                for device in tickedDevices where !unsupported.contains(device.id) {
                    do {
                        try await service.set(position, on: device)
                    } catch {
                        unsupported.insert(device.id)
                        skipped.append("\(device.name): \(error.localizedDescription)")
                    }
                }
                if includeWeb {
                    web?.moveGeolocationOverride(to: position)
                }
                if elapsed >= duration { break }
                try? await Task.sleep(for: Self.playbackTick)
            }
            guard !Task.isCancelled else { return }
            isPlayingRoute = false
            appliedCoordinate = route.points.last
            status = EnvironmentStatus(
                message: skipped.isEmpty
                    ? "Finished \(route.name)"
                    : "Finished \(route.name). \(skipped.joined(separator: " · "))",
                isError: false
            )
        }
    }

    /// Stops playback and pins devices at the current position.
    func stopRoute() {
        stopRoute(updateDevices: true)
    }

    private func stopRoute(updateDevices: Bool) {
        guard isPlayingRoute else { return }
        playbackTask?.cancel()
        playbackTask = nil
        isPlayingRoute = false
        routeSimulators = []
        guard updateDevices, let position = routePosition else { return }
        // `simctl location set` also ends the Simulator's own scenario.
        apply(position)
    }

    /// Stops playback before switching routes. `apply` and `clear` replace the
    /// Simulator scenario themselves; here Simulators are pinned at the current
    /// position so they don't keep playing the old route.
    private func stopRouteForNewRoute() {
        guard isPlayingRoute else { return }
        let simulators = routeSimulators
        let position = routePosition
        stopRoute(updateDevices: false)
        guard let position, !simulators.isEmpty else { return }
        Task {
            for simulator in simulators {
                try? await service.set(position, on: simulator)
            }
        }
    }

    private func targetDevices() -> [StreamedDevice] {
        (workspace?.visibleSelectedDevices() ?? []).filter { targets.includes($0.source) }
    }

    private func run(
        verb: String,
        _ work: @escaping @MainActor () async -> DeviceInjectionResult
    ) {
        isBusy = true
        status = nil
        Task {
            let result = await work()
            if result.succeeded.isEmpty && result.skipped.isEmpty {
                status = EnvironmentStatus(
                    message: "Show a Simulator, Android emulator, or the web pane first.",
                    isError: true
                )
            } else {
                status = .from(result, verb: verb)
            }
            isBusy = false
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    nonisolated static func distanceText(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = meters >= 1_000 ? 1 : 0
        return formatter.string(from: measurement)
    }

    nonisolated static func durationText(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(seconds, 1)) ?? "\(Int(seconds))s"
    }
}
