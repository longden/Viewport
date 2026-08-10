import Foundation

enum AppPackageKind: String, Equatable, CaseIterable {
    case androidAPK
    case iOSAppBundle
    case iOSIPA

    var fileExtension: String {
        switch self {
        case .androidAPK: "apk"
        case .iOSAppBundle: "app"
        case .iOSIPA: "ipa"
        }
    }

    var displayName: String {
        switch self {
        case .androidAPK: "Android APK"
        case .iOSAppBundle: "iOS app bundle"
        case .iOSIPA: "iOS IPA"
        }
    }
}

enum AppPackageInstallError: LocalizedError, Equatable {
    case unsupportedPackage
    case incompatible(package: AppPackageKind, deviceKind: StreamedDeviceKind)
    case noSelectedDevice
    case toolMissing(String)
    case ipaMissingAppBundle
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPackage:
            "Drop an .apk, .app, or .ipa file to install."
        case let .incompatible(package, deviceKind):
            "\(package.displayName) can't be installed on \(deviceKind.installTargetDescription)."
        case .noSelectedDevice:
            "Select a device in this pane first."
        case let .toolMissing(name):
            "\(name) is not available."
        case .ipaMissingAppBundle:
            "The IPA does not contain a Payload/*.app bundle."
        case let .commandFailed(message):
            message
        }
    }
}

extension StreamedDeviceKind {
    var installTargetDescription: String {
        switch self {
        case .androidEmulator: "an Android emulator"
        case .androidDevice: "an Android device"
        case .iOSSimulator: "an iOS Simulator"
        case .iOSDevice: "a physical iPhone or iPad"
        }
    }

    func accepts(_ package: AppPackageKind) -> Bool {
        switch (self, package) {
        case (.androidEmulator, .androidAPK), (.androidDevice, .androidAPK):
            true
        case (.iOSSimulator, .iOSAppBundle), (.iOSSimulator, .iOSIPA):
            true
        case (.iOSDevice, .iOSAppBundle), (.iOSDevice, .iOSIPA):
            true
        default:
            false
        }
    }
}

/// Installs dropped app packages onto the selected Android or iOS target.
actor AppPackageInstaller {
    private let runner: CommandRunner
    private let adb: URL?
    private let toolchains: ToolchainLocator
    private let xcrun: URL
    private let developerEnvironment: [String: String]
    private let fileManager: FileManager

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator(),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        adb = toolchains.adb
        self.toolchains = toolchains
        xcrun = toolchains.xcrun
        developerEnvironment = toolchains.developerEnvironment
        self.fileManager = fileManager
    }

    /// Classifies a dropped file/directory as an installable app package.
    nonisolated static func classify(_ url: URL) -> AppPackageKind? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "apk":
            return .androidAPK
        case "ipa":
            return .iOSIPA
        case "app":
            return .iOSAppBundle
        default:
            return nil
        }
    }

    /// Packages among `urls` that this device kind can accept, preserving order.
    nonisolated static func compatiblePackages(
        in urls: [URL],
        for deviceKind: StreamedDeviceKind
    ) -> [(url: URL, kind: AppPackageKind)] {
        urls.compactMap { url in
            guard let kind = classify(url),
                  deviceKind.accepts(kind) else { return nil }
            return (url, kind)
        }
    }

    func install(
        packageURL: URL,
        on device: StreamedDevice
    ) async throws {
        guard let kind = Self.classify(packageURL) else {
            throw AppPackageInstallError.unsupportedPackage
        }
        guard device.kind.accepts(kind) else {
            throw AppPackageInstallError.incompatible(
                package: kind,
                deviceKind: device.kind
            )
        }

        let accessing = packageURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                packageURL.stopAccessingSecurityScopedResource()
            }
        }

        switch device.kind {
        case .androidEmulator, .androidDevice:
            try await installAndroidAPK(packageURL, serial: device.id)
        case .iOSSimulator:
            let resolved = try await resolveiOSAppBundle(packageURL, kind: kind)
            defer { resolved.cleanup() }
            try await installSimulatorApp(resolved.appURL, udid: device.id)
        case .iOSDevice:
            let resolved = try await resolveiOSAppBundle(packageURL, kind: kind)
            defer { resolved.cleanup() }
            try await installPhysicalDeviceApp(resolved.appURL, udid: device.id)
        }
    }

    private func installAndroidAPK(_ url: URL, serial: String) async throws {
        guard let adb else {
            throw AppPackageInstallError.toolMissing("adb")
        }
        let result = try await runner.run(
            executable: adb,
            arguments: [
                "-s", serial,
                "install",
                "-r", // replace existing
                "-d", // allow version downgrade (common while iterating)
                url.path
            ],
            timeout: 180
        )
        guard result.exitCode == 0,
              !result.standardOutput.localizedCaseInsensitiveContains("Failure"),
              !result.standardError.localizedCaseInsensitiveContains("Failure") else {
            throw AppPackageInstallError.commandFailed(
                Self.cleanInstallMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "adb install failed."
                )
            )
        }
    }

    private func installSimulatorApp(_ url: URL, udid: String) async throws {
        let command = toolchains.simctlCommand(["install", udid, url.path])
        let result = try await runner.run(
            executable: command.executable,
            arguments: command.arguments,
            environment: developerEnvironment,
            timeout: 180
        )
        guard result.exitCode == 0 else {
            throw AppPackageInstallError.commandFailed(
                Self.cleanInstallMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "simctl install failed."
                )
            )
        }
    }

    private func installPhysicalDeviceApp(
        _ url: URL,
        udid: String
    ) async throws {
        let result = try await runner.run(
            executable: xcrun,
            arguments: [
                "devicectl", "device", "install", "app",
                "--device", udid,
                url.path
            ],
            environment: developerEnvironment,
            timeout: 180
        )
        guard result.exitCode == 0 else {
            throw AppPackageInstallError.commandFailed(
                Self.cleanInstallMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "devicectl install failed. The app must be signed for this device."
                )
            )
        }
    }

    /// `.ipa` archives contain `Payload/<Name>.app`; extract when needed.
    /// Returns a cleanup closure that deletes temporary unzip / staging trees.
    private func resolveiOSAppBundle(
        _ url: URL,
        kind: AppPackageKind
    ) async throws -> (appURL: URL, cleanup: () -> Void) {
        if kind == .iOSAppBundle {
            return (url, {})
        }

        let workRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "Viewport-IPA-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: workRoot,
            withIntermediateDirectories: true
        )

        do {
            let unzip = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-qq", url.path, "-d", workRoot.path],
                timeout: 60
            )
            guard unzip.exitCode == 0 else {
                throw AppPackageInstallError.commandFailed(
                    Self.cleanInstallMessage(
                        stdout: unzip.standardOutput,
                        stderr: unzip.standardError,
                        fallback: "Could not unpack the IPA."
                    )
                )
            }

            let payload = workRoot.appendingPathComponent("Payload", isDirectory: true)
            guard let apps = try? fileManager.contentsOfDirectory(
                at: payload,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ),
            let app = apps.first(where: {
                $0.pathExtension.lowercased() == "app"
            }) else {
                throw AppPackageInstallError.ipaMissingAppBundle
            }

            // Copy `.app` out of the unzip tree so install tools keep a stable path
            // while we can delete the full Payload tree immediately after.
            let stagingRoot = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "Viewport-App-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true
            )
            let stagedApp = stagingRoot.appendingPathComponent(app.lastPathComponent)
            try fileManager.copyItem(at: app, to: stagedApp)
            try? fileManager.removeItem(at: workRoot)

            return (stagedApp, {
                try? self.fileManager.removeItem(at: stagingRoot)
            })
        } catch {
            try? fileManager.removeItem(at: workRoot)
            throw error
        }
    }

    nonisolated static func cleanInstallMessage(
        stdout: String,
        stderr: String,
        fallback: String
    ) -> String {
        let lines = [stderr, stdout]
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return fallback }

        // adb/simctl bury the actionable Failure/error after progress lines.
        if let failure = lines.last(where: {
            let lower = $0.lowercased()
            return lower.contains("failure")
                || lower.contains("failed")
                || lower.contains("error")
        }) {
            return failure
        }
        return lines.last ?? fallback
    }
}
