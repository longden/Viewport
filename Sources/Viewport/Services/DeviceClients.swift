import Foundation

protocol DeviceClient {
    var source: ViewerSource { get }
    func listDevices() async throws -> [LaunchableDevice]
    func launch(_ device: LaunchableDevice) async throws
    func shutdown(_ device: LaunchableDevice) async throws
}

struct ADBDeviceRecord: Equatable {
    let serial: String
    let state: String
    let model: String?

    var isEmulator: Bool {
        serial.hasPrefix("emulator-")
    }

    var isOnline: Bool {
        state == "device"
    }

    var displayModel: String? {
        model?.replacingOccurrences(of: "_", with: " ")
    }
}

struct AndroidDeviceClient: DeviceClient {
    let source = ViewerSource.android

    private let runner: CommandRunner
    private let androidCLI: URL?
    private let emulator: URL?
    private let adb: URL?
    private let sdkURL: URL
    private let defaults: UserDefaults

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator(),
        defaults: UserDefaults = .standard
    ) {
        self.runner = runner
        sdkURL = toolchains.androidSDK
        androidCLI = toolchains.androidCLI
        emulator = toolchains.androidEmulator
        adb = toolchains.adb
        self.defaults = defaults
    }

    func listDevices() async throws -> [LaunchableDevice] {
        let avdNames = try await listAVDNames()
        let runningNames = await runningAVDNames()

        return avdNames.map { name in
            LaunchableDevice(
                id: name,
                source: .android,
                name: name.replacingOccurrences(of: "_", with: " "),
                runtime: nil,
                state: runningNames.contains(name) ? .booted : .shutdown
            )
        }
    }

    func launch(_ device: LaunchableDevice) async throws {
        guard device.source == .android else { return }

        let preferHeadless = defaults.object(
            forKey: AndroidEmulatorLaunchArguments.preferHeadlessUserDefaultsKey
        ) as? Bool ?? true
        let runningEmulatorCount = await countRunningEmulators()
        let emulatorArguments = AndroidEmulatorLaunchArguments.make(
            avdName: device.id,
            preferHeadless: preferHeadless,
            runningEmulatorCount: runningEmulatorCount
        )

        if preferHeadless, let emulator {
            try await runner.launchDetached(
                executable: emulator,
                arguments: emulatorArguments
            )
            return
        }

        if let androidCLI {
            try await runner.launchDetached(
                executable: androidCLI,
                arguments: [
                    "--no-metrics",
                    "--sdk=\(sdkURL.path)",
                    "emulator",
                    "start",
                    device.id
                ]
            )
            return
        }

        guard let emulator else {
            throw CommandRunnerError.executableNotFound("Android Emulator")
        }

        try await runner.launchDetached(
            executable: emulator,
            arguments: emulatorArguments
        )
    }

    func shutdown(_ device: LaunchableDevice) async throws {
        guard device.source == .android else { return }
        guard let adb else {
            throw CommandRunnerError.executableNotFound("adb")
        }
        guard let serial = await serial(forAVDNamed: device.id) else {
            throw CommandRunnerError.commandFailed(
                command: "Stop \(device.name)",
                code: 1,
                message: "No running emulator is using AVD \(device.id)."
            )
        }

        let result = try await runner.run(
            executable: adb,
            arguments: ["-s", serial, "emu", "kill"]
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "Stop \(device.name)",
                code: result.exitCode,
                message: result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
            )
        }
    }

    func listCreateProfiles() async throws -> [AndroidEmulatorProfile] {
        guard let androidCLI else {
            throw CommandRunnerError.executableNotFound("Android CLI")
        }

        let result = try await runner.run(
            executable: androidCLI,
            arguments: [
                "--no-metrics",
                "--sdk=\(sdkURL.path)",
                "emulator",
                "create",
                "--list-profiles"
            ]
        )

        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "List emulator profiles",
                code: result.exitCode,
                message: result.standardError
            )
        }

        return Self.parseCreateProfiles(result.standardOutput)
    }

    @discardableResult
    func createEmulator(profile: AndroidEmulatorProfile) async throws -> [String] {
        guard let androidCLI else {
            throw CommandRunnerError.executableNotFound("Android CLI")
        }

        let before = Set(try await listAVDNames())
        let result = try await runner.run(
            executable: androidCLI,
            arguments: [
                "--no-metrics",
                "--sdk=\(sdkURL.path)",
                "emulator",
                "create",
                profile.id
            ]
        )

        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "Create \(profile.displayName) emulator",
                code: result.exitCode,
                message: result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
            )
        }

        let after = Set(try await listAVDNames())
        let created = after.subtracting(before).sorted()
        if !created.isEmpty {
            return created
        }

        // Some CLI versions print the new AVD name without changing list timing.
        let mentioned = Self.parseAVDNames(
            result.standardOutput + "\n" + result.standardError
        )
        return mentioned.filter { !before.contains($0) }
    }

    static func parseCreateProfiles(_ output: String) -> [AndroidEmulatorProfile] {
        parseAVDNames(output).map(AndroidEmulatorProfile.init(id:))
            .sorted { lhs, rhs in
                if lhs.isRecommended != rhs.isRecommended {
                    return lhs.isRecommended
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName)
                    == .orderedAscending
            }
    }

    static func parseAVDNames(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isPlausibleAVDIdentifier)
    }

    static func parseADBDevices(_ output: String) -> [ADBDeviceRecord] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ADBDeviceRecord? in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2,
                      columns[0] != "List",
                      !columns[0].hasPrefix("*") else {
                    return nil
                }

                let model = columns.dropFirst(2).compactMap {
                    column -> String? in
                    let field = column.split(
                        separator: ":",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    )
                    guard field.count == 2, field[0] == "model" else {
                        return nil
                    }
                    return String(field[1])
                }.first

                return ADBDeviceRecord(
                    serial: String(columns[0]),
                    state: String(columns[1]),
                    model: model
                )
            }
    }

    static func parseADBSerials(_ output: String) -> [String] {
        parseADBDevices(output)
            .filter(\.isOnline)
            .map(\.serial)
    }

    static func parseAVDNameResponse(_ output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isPlausibleAVDIdentifier)
    }

    private static func isPlausibleAVDIdentifier(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }

        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return line.unicodeScalars.allSatisfy(allowed.contains)
            && line.rangeOfCharacter(from: .alphanumerics) != nil
            && line.caseInsensitiveCompare("OK") != .orderedSame
            && line.caseInsensitiveCompare("AVD") != .orderedSame
            && line.caseInsensitiveCompare("AVD_ID") != .orderedSame
    }

    private func listAVDNames() async throws -> [String] {
        let result: CommandResult

        if let androidCLI {
            result = try await runner.run(
                executable: androidCLI,
                arguments: [
                    "--no-metrics",
                    "--sdk=\(sdkURL.path)",
                    "emulator",
                    "list"
                ]
            )
        } else if let emulator {
            result = try await runner.run(
                executable: emulator,
                arguments: ["-list-avds"]
            )
        } else {
            throw CommandRunnerError.executableNotFound("Android Emulator")
        }

        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "List Android emulators",
                code: result.exitCode,
                message: result.standardError
            )
        }

        return Self.parseAVDNames(result.standardOutput)
    }

    private func runningAVDNames() async -> Set<String> {
        Set(await runningAVDSerials().keys)
    }

    private func serial(forAVDNamed name: String) async -> String? {
        await runningAVDSerials().first(where: { $0.key == name })?.value
    }

    private func runningAVDSerials() async -> [String: String] {
        guard let adb,
              let devicesResult = try? await runner.run(
                executable: adb,
                arguments: ["devices"]
              ),
              devicesResult.exitCode == 0 else {
            return [:]
        }

        var mapping: [String: String] = [:]
        for serial in Self.parseADBDevices(devicesResult.standardOutput)
            .filter({ $0.isOnline && $0.isEmulator })
            .map(\.serial) {
            guard let result = try? await runner.run(
                executable: adb,
                arguments: ["-s", serial, "emu", "avd", "name"]
            ), result.exitCode == 0,
            let name = Self.parseAVDNameResponse(result.standardOutput) else {
                continue
            }
            mapping[name] = serial
        }
        return mapping
    }

    private func countRunningEmulators() async -> Int {
        guard let adb,
              let devicesResult = try? await runner.run(
                executable: adb,
                arguments: ["devices"]
              ),
              devicesResult.exitCode == 0 else {
            return 0
        }

        return Self.parseADBDevices(devicesResult.standardOutput)
            .filter { $0.isOnline && $0.isEmulator }
            .count
    }
}

struct IOSSimulatorClient: DeviceClient {
    let source = ViewerSource.iOS

    private let runner: CommandRunner
    private let toolchains: ToolchainLocator
    private let defaults: UserDefaults
    private let open = URL(fileURLWithPath: "/usr/bin/open")
    private let developerDirectory: URL
    private let simulatorApplication: URL

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator(),
        defaults: UserDefaults = .standard
    ) {
        self.runner = runner
        self.toolchains = toolchains
        self.defaults = defaults
        developerDirectory = toolchains.developerDirectory
        simulatorApplication = developerDirectory
            .appendingPathComponent("Applications/Simulator.app")
    }

    func listDevices() async throws -> [LaunchableDevice] {
        let command = toolchains.simctlCommand([
            "list", "devices", "available", "--json"
        ])
        let result = try await runner.run(
            executable: command.executable,
            arguments: command.arguments,
            environment: processEnvironment
        )

        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "List iOS Simulators",
                code: result.exitCode,
                message: result.standardError
            )
        }

        return try Self.parseDevices(
            Data(result.standardOutput.utf8)
        )
    }

    func launch(_ device: LaunchableDevice) async throws {
        guard device.source == .iOS else { return }

        // `bootstatus -b` boots when needed and blocks until the runtime is
        // ready for IOSurface / HID. Prefer it over a separate `simctl boot`
        // (which had no timeout and could leave Play stuck on "Starting…").
        let bootStatusCommand = toolchains.simctlCommand([
            "bootstatus", device.id, "-b"
        ])
        let bootStatus = try await runner.run(
            executable: bootStatusCommand.executable,
            arguments: bootStatusCommand.arguments,
            environment: processEnvironment,
            timeout: 180
        )
        guard bootStatus.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "Boot \(device.name)",
                code: bootStatus.exitCode,
                message: bootStatus.standardError.isEmpty
                    ? bootStatus.standardOutput
                    : bootStatus.standardError
            )
        }

        // Direct Surface + HID do not need Simulator.app. Open it when the
        // user opts out of headless (Legacy host-window capture needs the UI).
        let preferHeadless = defaults.object(
            forKey: Self.preferHeadlessUserDefaultsKey
        ) as? Bool ?? true
        guard !preferHeadless else { return }

        let openResult = try await runner.run(
            executable: open,
            arguments: [
                simulatorApplication.path,
                "--args",
                "-CurrentDeviceUDID",
                device.id
            ],
            environment: processEnvironment
        )

        guard openResult.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "Open Simulator",
                code: openResult.exitCode,
                message: openResult.standardError
            )
        }
    }

    func shutdown(_ device: LaunchableDevice) async throws {
        guard device.source == .iOS else { return }

        let command = toolchains.simctlCommand(["shutdown", device.id])
        let result = try await runner.run(
            executable: command.executable,
            arguments: command.arguments,
            environment: processEnvironment
        )

        let alreadyShutdown = result.standardError
            .localizedCaseInsensitiveContains("current state: Shutdown")
            || result.standardError
                .localizedCaseInsensitiveContains("Invalid device state")
        guard result.exitCode == 0 || alreadyShutdown else {
            throw CommandRunnerError.commandFailed(
                command: "Shut down \(device.name)",
                code: result.exitCode,
                message: result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
            )
        }
    }

    /// Settings key — mirrors Android headless preference.
    static let preferHeadlessUserDefaultsKey = "preferHeadlessIOSSimulators"

    static func parseDevices(_ data: Data) throws -> [LaunchableDevice] {
        let catalog = try JSONDecoder().decode(SimulatorCatalog.self, from: data)

        return catalog.devices
            .filter { $0.key.contains(".iOS-") }
            .flatMap { runtime, devices in
                let runtimeName = runtime
                    .replacingOccurrences(
                        of: "com.apple.CoreSimulator.SimRuntime.",
                        with: ""
                    )
                    .replacingOccurrences(of: "-", with: ".")
                    .replacingOccurrences(of: "iOS.", with: "iOS ")

                return devices
                    .filter(\.isAvailable)
                    .map { device in
                        LaunchableDevice(
                            id: device.udid,
                            source: .iOS,
                            name: device.name,
                            runtime: runtimeName,
                            state: device.state.lowercased() == "booted"
                                ? .booted
                                : .shutdown
                        )
                    }
            }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .booted
                }
                let lhsIsPhone = lhs.name.hasPrefix("iPhone")
                let rhsIsPhone = rhs.name.hasPrefix("iPhone")
                if lhsIsPhone != rhsIsPhone {
                    return lhsIsPhone
                }
                return lhs.name.localizedStandardCompare(rhs.name)
                    == .orderedAscending
            }
    }

    private var processEnvironment: [String: String] {
        ["DEVELOPER_DIR": developerDirectory.path]
    }
}

private struct SimulatorCatalog: Decodable {
    let devices: [String: [SimulatorDevice]]
}

private struct SimulatorDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
}
