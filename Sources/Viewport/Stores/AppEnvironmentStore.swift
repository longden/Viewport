import Combine
import Foundation

/// Permissions and push notifications for the app under test on visible devices.
@MainActor
final class AppEnvironmentStore: ObservableObject {
    @Published var iOSAppID: String {
        didSet { defaults.set(iOSAppID, forKey: Self.iOSAppKey) }
    }
    @Published var androidAppID: String {
        didSet { defaults.set(androidAppID, forKey: Self.androidAppKey) }
    }
    @Published var pushPayload: String
    @Published private(set) var iOSApps: [InstalledApp] = []
    @Published private(set) var androidApps: [InstalledApp] = []
    @Published private(set) var isLoadingApps = false
    @Published private(set) var isBusy = false
    @Published private(set) var status: EnvironmentStatus?

    private weak var workspace: WorkspaceStore?
    private let service: AppEnvironmentService
    private let defaults: UserDefaults

    private static let iOSAppKey = "appEnvironmentIOSAppID"
    private static let androidAppKey = "appEnvironmentAndroidAppID"

    init(
        workspace: WorkspaceStore,
        service: AppEnvironmentService = AppEnvironmentService(),
        defaults: UserDefaults = .standard
    ) {
        self.workspace = workspace
        self.service = service
        self.defaults = defaults
        iOSAppID = defaults.string(forKey: Self.iOSAppKey) ?? ""
        androidAppID = defaults.string(forKey: Self.androidAppKey) ?? ""
        pushPayload = PushPayloadTemplate.alert.json
    }

    var hasIOSTarget: Bool {
        devices(for: .iOS).contains { $0.kind == .iOSSimulator }
    }

    var hasAndroidTarget: Bool {
        !devices(for: .android).isEmpty
    }

    func refreshInstalledApps() {
        isLoadingApps = true
        Task {
            var iOS = Set<InstalledApp>()
            var android = Set<InstalledApp>()
            for device in devices(for: .iOS) + devices(for: .android) {
                guard let apps = try? await service.installedApps(on: device) else { continue }
                if device.source == .iOS {
                    iOS.formUnion(apps)
                } else {
                    android.formUnion(apps)
                }
            }
            iOSApps = iOS.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            androidApps = android.sorted { $0.id < $1.id }
            if iOSAppID.isEmpty, let first = iOSApps.first { iOSAppID = first.id }
            if androidAppID.isEmpty, let first = androidApps.first { androidAppID = first.id }
            isLoadingApps = false
        }
    }

    func apply(_ action: PermissionAction, _ permission: AppPermission) {
        run(verb: "\(action.pastTense) \(permission.title.lowercased())") { [self] in
            await forEachTarget { device, appID in
                try await self.service.apply(action, permission, appID: appID, on: device)
            }
        }
    }

    func resetAllPermissions() {
        run(verb: "Reset permissions") { [self] in
            await forEachTarget { device, appID in
                try await self.service.resetAllPermissions(appID: appID, on: device)
            }
        }
    }

    func applyTemplate(_ template: PushPayloadTemplate) {
        pushPayload = template.json
    }

    func sendPush() {
        let payload: Data
        do {
            payload = try PushPayloadValidator.validate(pushPayload)
        } catch {
            status = .failure(error)
            return
        }
        let bundleID = iOSAppID.trimmingCharacters(in: .whitespaces)
        let simulators = devices(for: .iOS).filter { $0.kind == .iOSSimulator }
        guard !simulators.isEmpty else {
            status = EnvironmentStatus(message: "Show an iOS Simulator to send a push.", isError: true)
            return
        }
        run(verb: "Push sent") { [self] in
            await DeviceInjectionResult.collect(simulators) {
                try await self.service.sendPush(payload: payload, bundleID: bundleID, on: $0)
            }
        }
    }

    private func forEachTarget(
        _ work: (StreamedDevice, String) async throws -> Void
    ) async -> DeviceInjectionResult {
        var result = DeviceInjectionResult()
        let iOSID = iOSAppID.trimmingCharacters(in: .whitespaces)
        let androidID = androidAppID.trimmingCharacters(in: .whitespaces)
        for device in devices(for: .iOS) + devices(for: .android) {
            let appID = device.source == .iOS ? iOSID : androidID
            guard !appID.isEmpty else {
                let message = "Choose the \(device.source.title) app first."
                if !result.skipped.contains(message) {
                    result.skipped.append(message)
                }
                continue
            }
            do {
                try await work(device, appID)
                result.record(device, .success(()))
            } catch {
                result.record(device, .failure(error))
            }
        }
        return result
    }

    private func devices(for source: ViewerSource) -> [StreamedDevice] {
        (workspace?.visibleSelectedDevices() ?? []).filter { $0.source == source }
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
                    message: "Show an iOS Simulator or Android device first.",
                    isError: true
                )
            } else {
                status = .from(result, verb: verb)
            }
            isBusy = false
        }
    }
}
