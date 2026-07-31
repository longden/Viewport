import CoreGraphics
import Foundation

struct StreamedDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let source: ViewerSource
    let pixelSize: CGSize?

    var displayName: String { name }
}

actor DeviceFrameClient {
    let source: ViewerSource

    private let runner: CommandRunner
    private let adb: URL?
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private let developerDirectory = "/Applications/Xcode.app/Contents/Developer"

    init(source: ViewerSource, runner: CommandRunner = CommandRunner()) {
        self.source = source
        self.runner = runner

        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let sdkPath = environment["ANDROID_SDK_ROOT"]
            ?? environment["ANDROID_HOME"]
            ?? home.appendingPathComponent("Library/Android/sdk").path
        adb = ExecutableLocator.executable(
            named: "adb",
            candidates: [
                URL(fileURLWithPath: sdkPath)
                    .appendingPathComponent("platform-tools/adb"),
                URL(fileURLWithPath: "/opt/homebrew/bin/adb")
            ]
        )
    }

    nonisolated var isAvailable: Bool {
        switch source {
        case .android:
            adb != nil
        case .iOS:
            FileManager.default.isExecutableFile(atPath: xcrun.path)
        case .web:
            false
        }
    }

    nonisolated var frameInterval: Duration {
        source == .iOS ? .milliseconds(125) : .milliseconds(67)
    }

    func listRunningDevices() async throws -> [StreamedDevice] {
        switch source {
        case .android:
            try await listAndroidDevices()
        case .iOS:
            try await listIOSDevices()
        case .web:
            []
        }
    }

    func captureFrame(deviceID: String) async throws -> Data {
        switch source {
        case .android:
            try await captureAndroidFrame(serial: deviceID)
        case .iOS:
            try await captureIOSFrame(udid: deviceID)
        case .web:
            Data()
        }
    }

    private func listAndroidDevices() async throws -> [StreamedDevice] {
        guard let adb else {
            throw CommandRunnerError.executableNotFound("adb")
        }
        let result = try await runner.run(
            executable: adb,
            arguments: ["devices"]
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "List Android emulators",
                code: result.exitCode,
                message: result.standardError
            )
        }

        var devices: [StreamedDevice] = []
        for serial in AndroidDeviceClient.parseADBSerials(result.standardOutput) {
            async let size = androidSize(serial: serial)
            async let name = androidName(serial: serial)
            devices.append(
                StreamedDevice(
                    id: serial,
                    name: await name ?? serial,
                    source: .android,
                    pixelSize: await size
                )
            )
        }
        return devices.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func androidSize(serial: String) async -> CGSize? {
        guard let adb,
              let result = try? await runner.run(
                executable: adb,
                arguments: ["-s", serial, "shell", "wm", "size"]
              ),
              let range = result.standardOutput.range(
                of: #"\d+x\d+"#,
                options: .regularExpression
              ) else {
            return nil
        }
        let parts = result.standardOutput[range].split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func androidName(serial: String) async -> String? {
        guard let adb,
              let result = try? await runner.run(
                executable: adb,
                arguments: ["-s", serial, "emu", "avd", "name"]
              ), result.exitCode == 0 else {
            return nil
        }
        return AndroidDeviceClient.parseAVDNameResponse(result.standardOutput)?
            .replacingOccurrences(of: "_", with: " ")
    }

    private func captureAndroidFrame(serial: String) async throws -> Data {
        guard let adb else {
            throw CommandRunnerError.executableNotFound("adb")
        }
        let result = try await runner.runData(
            executable: adb,
            arguments: ["-s", serial, "exec-out", "screencap", "-p"]
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "Capture Android screen",
                code: result.exitCode,
                message: String(decoding: result.standardError, as: UTF8.self)
            )
        }

        // Multi-display emulators can prepend a diagnostic to stdout. Strip it
        // so the AppKit image decoder always receives a clean PNG.
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard let range = result.standardOutput.range(of: signature) else {
            throw CommandRunnerError.commandFailed(
                command: "Capture Android screen",
                code: -1,
                message: "adb did not return a PNG frame."
            )
        }
        return result.standardOutput.subdata(in: range.lowerBound..<result.standardOutput.endIndex)
    }

    private func listIOSDevices() async throws -> [StreamedDevice] {
        let result = try await runner.run(
            executable: xcrun,
            arguments: ["simctl", "list", "devices", "--json"],
            environment: processEnvironment
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "List iOS Simulators",
                code: result.exitCode,
                message: result.standardError
            )
        }

        let catalog = try JSONDecoder().decode(
            StreamSimulatorCatalog.self,
            from: Data(result.standardOutput.utf8)
        )
        return catalog.devices.values
            .flatMap { $0 }
            .filter { $0.isAvailable && $0.state.caseInsensitiveCompare("booted") == .orderedSame }
            .map {
                StreamedDevice(
                    id: $0.udid,
                    name: $0.name,
                    source: .iOS,
                    pixelSize: nil
                )
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func captureIOSFrame(udid: String) async throws -> Data {
        // Despite `simctl io help` advertising `-` for stdout, Xcode 26.5
        // treats it as a literal filename. Use an isolated temporary file,
        // which is also the compatibility path used by Simmer.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let result = try await runner.run(
            executable: xcrun,
            arguments: [
                "simctl", "io", udid, "screenshot",
                "--type=jpeg", "--mask=ignored", temporaryURL.path
            ],
            environment: processEnvironment
        )
        guard result.exitCode == 0,
              let data = try? Data(contentsOf: temporaryURL),
              data.starts(with: [0xFF, 0xD8]) else {
            throw CommandRunnerError.commandFailed(
                command: "Capture iOS Simulator screen",
                code: result.exitCode,
                message: result.standardError
            )
        }
        return data
    }

    private nonisolated var processEnvironment: [String: String] {
        ["DEVELOPER_DIR": developerDirectory]
    }
}

private struct StreamSimulatorCatalog: Decodable {
    let devices: [String: [StreamSimulatorDevice]]
}

private struct StreamSimulatorDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
}
