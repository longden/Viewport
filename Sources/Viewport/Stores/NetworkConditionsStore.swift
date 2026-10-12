import Combine
import Foundation

/// Network shaping and proxy routing for the visible panes.
@MainActor
final class NetworkConditionsStore: ObservableObject {
    @Published var targets: PlatformTargets {
        didSet { targets.save(to: defaults, key: Self.targetsKey) }
    }
    @Published private(set) var appliedProfile: NetworkProfile?
    @Published private(set) var isOffline = false
    @Published var proxyPreset: ProxyPreset {
        didSet {
            defaults.set(proxyPreset.rawValue, forKey: Self.presetKey)
            if let port = proxyPreset.defaultPort {
                proxyPort = String(port)
            }
            if certificate == nil,
               let url = proxyPreset.defaultCertificateURL(),
               FileManager.default.fileExists(atPath: url.path) {
                loadCertificate(from: url)
            }
        }
    }
    @Published var proxyHost: String {
        didSet { defaults.set(proxyHost, forKey: Self.hostKey) }
    }
    @Published var proxyPort: String {
        didSet { defaults.set(proxyPort, forKey: Self.portKey) }
    }
    @Published private(set) var certificate: ProxyCertificate?
    @Published private(set) var activeProxy: ProxySettings?
    @Published private(set) var isBusy = false
    @Published private(set) var status: EnvironmentStatus?

    private weak var workspace: WorkspaceStore?
    private weak var web: WebViewModel?
    private let service: NetworkConditionsService
    private let defaults: UserDefaults

    private static let targetsKey = "networkConditionsTargets"
    private static let presetKey = "networkProxyPreset"
    private static let hostKey = "networkProxyHost"
    private static let portKey = "networkProxyPort"
    private static let certificateKey = "networkProxyCertificatePath"

    init(
        workspace: WorkspaceStore,
        web: WebViewModel,
        service: NetworkConditionsService = NetworkConditionsService(),
        defaults: UserDefaults = .standard
    ) {
        self.workspace = workspace
        self.web = web
        self.service = service
        self.defaults = defaults
        targets = PlatformTargets(defaults: defaults, key: Self.targetsKey)
        let preset = defaults.string(forKey: Self.presetKey)
            .flatMap(ProxyPreset.init(rawValue:)) ?? .proxyman
        proxyPreset = preset
        proxyHost = defaults.string(forKey: Self.hostKey) ?? "127.0.0.1"
        proxyPort = defaults.string(forKey: Self.portKey)
            ?? preset.defaultPort.map(String.init) ?? "8080"
        if let path = defaults.string(forKey: Self.certificateKey) {
            certificate = try? ProxyCertificate.load(from: URL(fileURLWithPath: path))
        }
    }

    var proxySettings: ProxySettings? {
        guard let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)) else { return nil }
        let settings = ProxySettings(host: proxyHost, port: port)
        return settings.isValid ? settings : nil
    }

    func applyProfile(_ profile: NetworkProfile) {
        run(verb: "Network set to \(profile.title)") { [self] in
            let result = await DeviceInjectionResult.collect(targetDevices()) {
                try await self.service.setProfile(profile, on: $0)
            }
            if result.didSucceed {
                appliedProfile = profile
            }
            return result
        }
    }

    func setOffline(_ offline: Bool) {
        run(verb: offline ? "Offline" : "Back online") { [self] in
            let result = await DeviceInjectionResult.collect(targetDevices()) {
                try await self.service.setOffline(offline, on: $0)
            }
            if result.didSucceed {
                isOffline = offline
            }
            return result
        }
    }

    func loadCertificate(from url: URL) {
        do {
            let loaded = try ProxyCertificate.load(from: url)
            certificate = loaded
            defaults.set(url.path, forKey: Self.certificateKey)
            status = EnvironmentStatus(message: "Loaded \(loaded.summary)", isError: false)
        } catch {
            status = .failure(error)
        }
    }

    func removeCertificate() {
        certificate = nil
        defaults.removeObject(forKey: Self.certificateKey)
    }

    func applyProxy() {
        guard let settings = proxySettings else {
            status = EnvironmentStatus(message: "Enter a proxy host and a port between 1 and 65535.", isError: true)
            return
        }
        let certificate = certificate
        let previousReversePort = activeProxy.flatMap { $0.isLoopback ? $0.port : nil }
        run(verb: "Routing through \(settings.trimmedHost):\(settings.port)") { [self] in
            var notes: [String] = []
            var result = await DeviceInjectionResult.collect(targetDevices()) {
                if let note = try await self.service.applyProxy(
                    settings,
                    certificate: certificate,
                    previousReversePort: previousReversePort,
                    on: $0
                ), !notes.contains(note) {
                    notes.append(note)
                }
            }
            if webIsTargeted {
                web?.setProxy(settings, certificate: certificate)
                result.succeeded.append("Web")
            }
            result.skipped.append(contentsOf: notes)
            if result.didSucceed {
                activeProxy = settings
            }
            return result
        }
    }

    func clearProxy() {
        let port = activeProxy?.port ?? proxySettings?.port
        run(verb: "Proxy removed") { [self] in
            var clearFailed = false
            var result = await DeviceInjectionResult.collect(targetDevices()) {
                do {
                    try await self.service.clearProxy(port: port, on: $0)
                } catch {
                    if case .unsupported = error as? DeviceAutomationError {} else {
                        clearFailed = true
                    }
                    throw error
                }
            }
            if web?.proxySettings != nil {
                web?.setProxy(nil, certificate: nil)
                result.succeeded.append("Web")
            }
            // Keep the proxy marked active so a retry can still clear it.
            if !clearFailed {
                activeProxy = nil
            }
            return result
        }
    }

    func copyCertificateToAndroid() {
        guard let certificate else {
            status = EnvironmentStatus(message: "Choose the proxy’s CA certificate first.", isError: true)
            return
        }
        let android = targetDevices().filter { $0.source == .android }
        guard !android.isEmpty else {
            status = EnvironmentStatus(message: "Show an Android device first.", isError: true)
            return
        }
        run(verb: "Copied CA to Downloads") { [self] in
            await DeviceInjectionResult.collect(android) {
                try await self.service.copyCertificateToAndroid(certificate, on: $0)
            }
        }
    }

    private var webIsTargeted: Bool {
        targets.web && workspace?.isVisible(.web) == true
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
                    message: "Show a device or the web pane first.",
                    isError: true
                )
            } else {
                status = .from(result, verb: verb)
            }
            isBusy = false
        }
    }
}
