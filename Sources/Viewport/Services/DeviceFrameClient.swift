import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

enum StreamedDeviceKind: Equatable {
    case androidEmulator
    case androidDevice
    case iOSSimulator
    case iOSDevice
}

struct StreamedDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let source: ViewerSource
    let pixelSize: CGSize?
    let kind: StreamedDeviceKind

    var displayName: String {
        switch kind {
        case .androidDevice:
            "\(name) · ADB"
        case .iOSDevice:
            "\(name) · USB · View only"
        case .androidEmulator, .iOSSimulator:
            name
        }
    }

    var supportsInput: Bool {
        kind != .iOSDevice
    }
}

actor DeviceFrameClient {
    let source: ViewerSource

    private let runner: CommandRunner
    private let adb: URL?
    private let xcrun: URL
    private let simctl: URL
    private let invokesSimctlThroughXcrun: Bool
    private let developerDirectory: String
    private let iOSScreenshotURL: URL

    init(
        source: ViewerSource,
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator()
    ) {
        self.source = source
        self.runner = runner
        xcrun = toolchains.xcrun
        developerDirectory = toolchains.developerDirectory.path

        let directSimctl = URL(
            fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
        )
        if FileManager.default.isExecutableFile(atPath: directSimctl.path) {
            simctl = directSimctl
            invokesSimctlThroughXcrun = false
        } else {
            simctl = xcrun
            invokesSimctlThroughXcrun = true
        }
        iOSScreenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-ios-\(UUID().uuidString).jpg")

        adb = toolchains.adb
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

    /// One-shot framebuffer size used to crop host-window chrome before touch
    /// mapping. Falls back to `wm size` / screenshot dimensions.
    func measureScreenSize(deviceID: String) async -> CGSize? {
        switch source {
        case .android:
            if let size = await androidSize(serial: deviceID) {
                return size
            }
            guard let data = try? await captureAndroidFrame(serial: deviceID) else {
                return nil
            }
            return Self.imagePixelSize(of: data)
        case .iOS:
            guard let data = try? await captureIOSFrame(udid: deviceID) else {
                return nil
            }
            return Self.imagePixelSize(of: data)
        case .web:
            return nil
        }
    }

    private nonisolated static func imagePixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .doubleValue,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func listAndroidDevices() async throws -> [StreamedDevice] {
        guard let adb else {
            throw CommandRunnerError.executableNotFound("adb")
        }
        let result = try await runner.run(
            executable: adb,
            arguments: ["devices", "-l"]
        )
        guard result.exitCode == 0 else {
            throw CommandRunnerError.commandFailed(
                command: "List Android emulators",
                code: result.exitCode,
                message: result.standardError
            )
        }

        let records = AndroidDeviceClient.parseADBDevices(
            result.standardOutput
        )
        let onlineDevices = records.filter(\.isOnline)
        if onlineDevices.isEmpty,
           let blockedDevice = records.first(where: {
               !$0.isEmulator && $0.state != "device"
           }) {
            throw AndroidDeviceAvailabilityError(
                serial: blockedDevice.serial,
                state: blockedDevice.state
            )
        }

        var devices: [StreamedDevice] = []
        for record in onlineDevices {
            async let size = androidSize(serial: record.serial)
            async let name = androidName(for: record)
            devices.append(
                StreamedDevice(
                    id: record.serial,
                    name: await name,
                    source: .android,
                    pixelSize: await size,
                    kind: record.isEmulator
                        ? .androidEmulator
                        : .androidDevice
                )
            )
        }
        return devices.sorted {
            if $0.kind != $1.kind {
                return $0.kind == .androidDevice
            }
            return $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
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

    private func androidName(for device: ADBDeviceRecord) async -> String {
        guard let adb else { return device.displayModel ?? device.serial }

        if device.isEmulator,
           let result = try? await runner.run(
            executable: adb,
            arguments: ["-s", device.serial, "emu", "avd", "name"]
           ), result.exitCode == 0,
           let name = AndroidDeviceClient.parseAVDNameResponse(
            result.standardOutput
           ) {
            return name.replacingOccurrences(of: "_", with: " ")
        }

        if let model = device.displayModel, !model.isEmpty {
            return model
        }

        if let result = try? await runner.run(
            executable: adb,
            arguments: [
                "-s", device.serial, "shell", "getprop", "ro.product.model"
            ]
        ), result.exitCode == 0 {
            let model = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !model.isEmpty {
                return model
            }
        }
        return device.serial
    }

    private func captureAndroidFrame(serial: String) async throws -> Data {
        guard let adb else {
            throw CommandRunnerError.executableNotFound("adb")
        }
        let result = try await runner.runData(
            executable: adb,
            arguments: ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: 4
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
        let connectedDevices = Self.connectedIOSCaptureDevices()

        do {
            return try await (listIOSSimulators() + connectedDevices)
                .sorted(by: Self.sortIOSDevices)
        } catch where !connectedDevices.isEmpty {
            // A trusted USB device is still useful when CoreSimulator is not
            // installed or temporarily unavailable.
            return connectedDevices.sorted(by: Self.sortIOSDevices)
        }
    }

    private func listIOSSimulators() async throws -> [StreamedDevice] {
        let result = try await runner.run(
            executable: simctl,
            arguments: simctlArguments(["list", "devices", "--json"]),
            environment: processEnvironment,
            timeout: 3
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
                    pixelSize: nil,
                    kind: .iOSSimulator
                )
            }
    }

    private nonisolated static func connectedIOSCaptureDevices() -> [StreamedDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.compactMap { device in
            guard device.isConnected,
                  isConnectedIOSCaptureDevice(
                    name: device.localizedName,
                    modelID: device.modelID,
                    manufacturer: device.manufacturer,
                    isContinuityCamera: device.isContinuityCamera
                  ) else {
                return nil
            }
            return StreamedDevice(
                id: device.uniqueID,
                name: device.localizedName,
                source: .iOS,
                pixelSize: nil,
                kind: .iOSDevice
            )
        }
    }

    nonisolated static func isConnectedIOSCaptureDevice(
        name: String,
        modelID: String,
        manufacturer: String,
        isContinuityCamera: Bool
    ) -> Bool {
        guard !isContinuityCamera else { return false }

        let identity = "\(name) \(modelID)".lowercased()
        let iOSDeviceNames = ["iphone", "ipad", "ipod", "ios device"]
        let hasAppleManufacturer = manufacturer.isEmpty
            || manufacturer.localizedCaseInsensitiveContains("apple")
        return iOSDeviceNames.contains(where: identity.contains)
            && hasAppleManufacturer
    }

    private nonisolated static func sortIOSDevices(
        _ lhs: StreamedDevice,
        _ rhs: StreamedDevice
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .iOSDevice
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func captureIOSFrame(udid: String) async throws -> Data {
        // Despite `simctl io help` advertising `-` for stdout, Xcode 26.5
        // treats it as a literal filename. Use an isolated temporary file,
        // which is also the compatibility path used by Simmer.
        defer { try? FileManager.default.removeItem(at: iOSScreenshotURL) }

        let result = try await runner.run(
            executable: simctl,
            arguments: simctlArguments([
                "io", udid, "screenshot", "--type=jpeg", "--mask=ignored",
                iOSScreenshotURL.path
            ]),
            environment: processEnvironment,
            timeout: 4
        )
        guard result.exitCode == 0,
              let data = try? Data(contentsOf: iOSScreenshotURL),
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

    private func simctlArguments(_ arguments: [String]) -> [String] {
        invokesSimctlThroughXcrun ? ["simctl"] + arguments : arguments
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

private struct AndroidDeviceAvailabilityError: LocalizedError {
    let serial: String
    let state: String

    var errorDescription: String? {
        switch state {
        case "unauthorized":
            "Android device \(serial) is waiting for USB debugging "
                + "authorization. Unlock it and approve this Mac."
        case "offline":
            "Android device \(serial) is offline. Reconnect it or restart "
                + "ADB, then refresh."
        default:
            "Android device \(serial) is unavailable (\(state))."
        }
    }
}
