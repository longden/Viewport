import Foundation

protocol DeviceClient {
    var source: ViewerSource { get }
    func listDevices() async throws -> [LaunchableDevice]
    func launch(_ device: LaunchableDevice) async throws
}

struct AndroidDeviceClient: DeviceClient {
    let source = ViewerSource.android

    private let runner: CommandRunner
    private let androidCLI: URL?
    private let emulator: URL?
    private let adb: URL?
    private let sdkURL: URL

    init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner

        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let sdkPath = environment["ANDROID_SDK_ROOT"]
            ?? environment["ANDROID_HOME"]
            ?? home.appendingPathComponent("Library/Android/sdk").path
        sdkURL = URL(fileURLWithPath: sdkPath)

        androidCLI = ExecutableLocator.executable(
            named: "android",
            candidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/android"),
                home.appendingPathComponent(".local/bin/android"),
                URL(fileURLWithPath: "/usr/local/bin/android")
            ]
        )
        emulator = ExecutableLocator.executable(
            named: "emulator",
            candidates: [
                sdkURL.appendingPathComponent("emulator/emulator")
            ]
        )
        adb = ExecutableLocator.executable(
            named: "adb",
            candidates: [
                sdkURL.appendingPathComponent("platform-tools/adb"),
                URL(fileURLWithPath: "/opt/homebrew/bin/adb")
            ]
        )
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
            arguments: ["-avd", device.id]
        )
    }

    static func parseAVDNames(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isPlausibleAVDIdentifier)
    }

    static func parseADBSerials(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> String? in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2,
                      columns[0].hasPrefix("emulator-"),
                      columns[1] == "device" else {
                    return nil
                }
                return String(columns[0])
            }
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
        guard let adb,
              let devicesResult = try? await runner.run(
                executable: adb,
                arguments: ["devices"]
              ),
              devicesResult.exitCode == 0 else {
            return []
        }

        var names = Set<String>()
        for serial in Self.parseADBSerials(devicesResult.standardOutput) {
            guard let result = try? await runner.run(
                executable: adb,
                arguments: ["-s", serial, "emu", "avd", "name"]
            ), result.exitCode == 0,
            let name = Self.parseAVDNameResponse(result.standardOutput) else {
                continue
            }
            names.insert(name)
        }
        return names
    }
}

struct IOSSimulatorClient: DeviceClient {
    let source = ViewerSource.iOS

    private let runner: CommandRunner
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private let open = URL(fileURLWithPath: "/usr/bin/open")
    private let developerDirectory: URL
    private let simulatorApplication: URL

    init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner

        let xcodeDeveloper = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"
        )
        developerDirectory = xcodeDeveloper
        simulatorApplication = xcodeDeveloper
            .appendingPathComponent("Applications/Simulator.app")
    }

    func listDevices() async throws -> [LaunchableDevice] {
        let result = try await runner.run(
            executable: xcrun,
            arguments: ["simctl", "list", "devices", "available", "--json"],
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

        if device.state != .booted {
            let bootResult = try await runner.run(
                executable: xcrun,
                arguments: ["simctl", "boot", device.id],
                environment: processEnvironment
            )

            let alreadyBooted = bootResult.standardError.localizedCaseInsensitiveContains(
                "current state: Booted"
            )
            guard bootResult.exitCode == 0 || alreadyBooted else {
                throw CommandRunnerError.commandFailed(
                    command: "Boot \(device.name)",
                    code: bootResult.exitCode,
                    message: bootResult.standardError
                )
            }
        }

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
