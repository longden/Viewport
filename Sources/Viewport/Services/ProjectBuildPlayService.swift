import Foundation

enum ProjectBuildPlayError: LocalizedError, Equatable {
    case noVisibleDevices
    case nothingToBuild
    case iosProjectRequired
    case iosSchemeRequired
    case iosSchemeInvalid
    case androidProjectRequired
    case toolMissing(String)
    case buildFailed(String)
    case artifactNotFound(String)
    case deployFailed(device: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noVisibleDevices:
            "Show Android and/or iOS and select a device in each visible pane."
        case .nothingToBuild:
            "Pick an iOS and/or Android project to build."
        case .iosProjectRequired:
            "Select an Xcode project or workspace."
        case .iosSchemeRequired:
            "Select an Xcode scheme."
        case .iosSchemeInvalid:
            "Scheme name is invalid."
        case .androidProjectRequired:
            "Select an Android Gradle project directory."
        case let .toolMissing(name):
            "\(name) is not available."
        case let .buildFailed(message):
            message
        case let .artifactNotFound(message):
            message
        case let .deployFailed(device, message):
            "\(device): \(message)"
        }
    }
}

struct ProjectBuildPlaySettings: Equatable {
    var iosProjectPath: String?
    var iosScheme: String?
    var androidProjectPath: String?
}

struct ProjectBuildPlayStatus: Equatable {
    var message: String
}

/// Builds native iOS / Android projects once, then installs and launches on every
/// visible capture-pane device in parallel.
actor ProjectBuildPlayService {
    typealias LogHandler = @Sendable (
        StreamingProcessOutput,
        String
    ) -> Void
    typealias StatusHandler = @Sendable (String) -> Void

    private let runner: CommandRunner
    private let adb: URL?
    private let xcrun: URL
    private let developerEnvironment: [String: String]
    private let androidSDK: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let iosProjectKey: String
    private let iosSchemeKey: String
    private let androidProjectKey: String

    init(
        runner: CommandRunner = CommandRunner(),
        toolchains: ToolchainLocator = ToolchainLocator(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        iosProjectKey: String = "buildPlayIOSProjectPath",
        iosSchemeKey: String = "buildPlayIOSScheme",
        androidProjectKey: String = "buildPlayAndroidProjectPath"
    ) {
        self.runner = runner
        adb = toolchains.adb
        xcrun = toolchains.xcrun
        developerEnvironment = toolchains.developerEnvironment
        androidSDK = toolchains.androidSDK
        self.fileManager = fileManager
        self.defaults = defaults
        self.iosProjectKey = iosProjectKey
        self.iosSchemeKey = iosSchemeKey
        self.androidProjectKey = androidProjectKey
    }

    func loadSettings() -> ProjectBuildPlaySettings {
        ProjectBuildPlaySettings(
            iosProjectPath: defaults.string(forKey: iosProjectKey),
            iosScheme: defaults.string(forKey: iosSchemeKey),
            androidProjectPath: defaults.string(forKey: androidProjectKey)
        )
    }

    func saveSettings(_ settings: ProjectBuildPlaySettings) {
        if let path = settings.iosProjectPath {
            defaults.set(path, forKey: iosProjectKey)
        } else {
            defaults.removeObject(forKey: iosProjectKey)
        }
        if let scheme = settings.iosScheme {
            defaults.set(scheme, forKey: iosSchemeKey)
        } else {
            defaults.removeObject(forKey: iosSchemeKey)
        }
        if let path = settings.androidProjectPath {
            defaults.set(path, forKey: androidProjectKey)
        } else {
            defaults.removeObject(forKey: androidProjectKey)
        }
    }

    func discoverSchemes(projectPath: String) async throws -> [String] {
        let url = URL(fileURLWithPath: projectPath)
        guard Self.isXcodeProject(url) else {
            throw ProjectBuildPlayError.iosProjectRequired
        }

        var arguments = ["xcodebuild", "-list", "-json"]
        switch url.pathExtension.lowercased() {
        case "xcworkspace":
            arguments += ["-workspace", url.path]
        case "xcodeproj":
            arguments += ["-project", url.path]
        default:
            throw ProjectBuildPlayError.iosProjectRequired
        }

        let result = try await runner.run(
            executable: xcrun,
            arguments: arguments,
            environment: developerEnvironment,
            timeout: 120
        )
        guard result.exitCode == 0 else {
            throw ProjectBuildPlayError.buildFailed(
                AppPackageInstaller.cleanInstallMessage(
                    stdout: result.standardOutput,
                    stderr: result.standardError,
                    fallback: "xcodebuild -list failed."
                )
            )
        }
        guard let data = result.standardOutput.data(using: .utf8) else {
            return []
        }
        return Self.parseSchemes(from: data)
    }

    func buildAndPlay(
        workspace: WorkspaceStore,
        settings: ProjectBuildPlaySettings,
        onLog: @escaping LogHandler,
        onStatus: @escaping StatusHandler
    ) async throws {
        let devices = await workspace.visibleSelectedDevices()
        guard !devices.isEmpty else {
            throw ProjectBuildPlayError.noVisibleDevices
        }

        let iosSimulators = devices.filter { $0.kind == .iOSSimulator }
        let androidTargets = devices.filter {
            $0.kind == .androidEmulator || $0.kind == .androidDevice
        }

        let needsIOS = !iosSimulators.isEmpty
        let needsAndroid = !androidTargets.isEmpty

        let iosConfigured = settings.iosProjectPath.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        let androidConfigured = settings.androidProjectPath.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false

        guard (needsIOS && iosConfigured) || (needsAndroid && androidConfigured) else {
            if needsIOS && !iosConfigured {
                throw ProjectBuildPlayError.iosProjectRequired
            }
            if needsAndroid && !androidConfigured {
                throw ProjectBuildPlayError.androidProjectRequired
            }
            throw ProjectBuildPlayError.nothingToBuild
        }

        if needsIOS {
            guard let scheme = settings.iosScheme,
                  !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectBuildPlayError.iosSchemeRequired
            }
            guard Self.isSafeXcodeScheme(scheme) else {
                throw ProjectBuildPlayError.iosSchemeInvalid
            }
        }

        async let iosArtifact: IOSBuildArtifact? = {
            guard needsIOS, iosConfigured,
                  let projectPath = settings.iosProjectPath,
                  let scheme = settings.iosScheme else {
                return nil
            }
            return try await self.buildIOS(
                projectPath: projectPath,
                scheme: scheme,
                onLog: onLog,
                onStatus: onStatus
            )
        }()

        async let androidArtifact: AndroidBuildArtifact? = {
            guard needsAndroid, androidConfigured,
                  let projectPath = settings.androidProjectPath else {
                return nil
            }
            return try await self.buildAndroid(
                projectPath: projectPath,
                onLog: onLog,
                onStatus: onStatus
            )
        }()

        // Await iOS first so its staging cleanup is registered even if Android
        // build fails (both builds still run concurrently via `async let`).
        let builtIOS = try await iosArtifact
        defer {
            builtIOS?.cleanup()
        }
        let builtAndroid = try await androidArtifact

        onStatus("Installing on \(devices.count) device(s)…")

        try await withThrowingTaskGroup(of: Void.self) { group in
            if let builtIOS {
                for device in iosSimulators {
                    let udid = device.id
                    let name = device.name
                    group.addTask {
                        try await self.installAndLaunchIOS(
                            artifact: builtIOS,
                            udid: udid,
                            deviceName: name,
                            onLog: onLog
                        )
                    }
                }
            }
            if let builtAndroid {
                for device in androidTargets {
                    let serial = device.id
                    let name = device.name
                    group.addTask {
                        try await self.installAndLaunchAndroid(
                            artifact: builtAndroid,
                            serial: serial,
                            deviceName: name,
                            onLog: onLog
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        onStatus("Done — launched on \(devices.count) device(s).")
    }

    // MARK: - Path classification

    nonisolated static func isXcodeProject(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "xcodeproj", "xcworkspace":
            true
        default:
            false
        }
    }

    /// Rejects scheme names that could be interpreted as `xcodebuild` flags.
    nonisolated static func isSafeXcodeScheme(_ scheme: String) -> Bool {
        let trimmed = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\:\0")
            .union(.newlines)
            .union(.controlCharacters)
        return trimmed.rangeOfCharacter(from: forbidden) == nil
    }

    nonisolated static func isGradleProject(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let gradlew = url.appendingPathComponent("gradlew")
        if fm.isExecutableFile(atPath: gradlew.path) {
            return true
        }
        let names = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        return names.contains { name in
            fm.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }

    nonisolated static func parseSchemes(from json: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return []
        }
        if let project = root["project"] as? [String: Any],
           let schemes = project["schemes"] as? [String] {
            return schemes.sorted()
        }
        if let workspace = root["workspace"] as? [String: Any],
           let schemes = workspace["schemes"] as? [String] {
            return schemes.sorted()
        }
        return []
    }

    nonisolated static func bundleIdentifier(fromInfoPlistXML xml: String) -> String? {
        guard let open = xml.range(of: "<key>CFBundleIdentifier</key>") else {
            return nil
        }
        let tail = xml[open.upperBound...]
        guard let stringOpen = tail.range(of: "<string>"),
              let stringClose = tail[stringOpen.upperBound...].range(of: "</string>") else {
            return nil
        }
        let value = tail[stringOpen.upperBound..<stringClose.lowerBound]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - iOS

    private struct IOSBuildArtifact {
        let appURL: URL
        let bundleID: String
        let cleanup: () -> Void
    }

    private func buildIOS(
        projectPath: String,
        scheme: String,
        onLog: @escaping LogHandler,
        onStatus: @escaping StatusHandler
    ) async throws -> IOSBuildArtifact {
        let projectURL = URL(fileURLWithPath: projectPath)
        guard Self.isXcodeProject(projectURL) else {
            throw ProjectBuildPlayError.iosProjectRequired
        }

        onStatus("Building iOS (\(scheme))…")
        onLog(.standardOutput, "=== xcodebuild \(scheme) ===")
        guard Self.isSafeXcodeScheme(scheme) else {
            throw ProjectBuildPlayError.iosSchemeInvalid
        }

        let derivedData = fileManager.temporaryDirectory
            .appendingPathComponent(
                "Viewport-DerivedData-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: derivedData,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: derivedData) }

        var arguments = [
            "xcodebuild",
            "-scheme", scheme,
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path,
            "build"
        ]
        switch projectURL.pathExtension.lowercased() {
        case "xcworkspace":
            arguments.insert(contentsOf: ["-workspace", projectURL.path], at: 1)
        case "xcodeproj":
            arguments.insert(contentsOf: ["-project", projectURL.path], at: 1)
        default:
            break
        }

        let exitCode = try await runStreaming(
            executable: xcrun,
            arguments: arguments,
            environment: developerEnvironment,
            onLog: onLog
        )
        guard exitCode == 0 else {
            throw ProjectBuildPlayError.buildFailed("xcodebuild failed (exit \(exitCode)).")
        }

        guard let appURL = findBuiltApp(in: derivedData) else {
            throw ProjectBuildPlayError.artifactNotFound(
                "Could not find a built .app in DerivedData."
            )
        }
        guard let bundleID = bundleIdentifier(forApp: appURL) else {
            throw ProjectBuildPlayError.artifactNotFound(
                "Could not read CFBundleIdentifier from the built app."
            )
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "Viewport-App-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let stagedApp = stagingRoot.appendingPathComponent(appURL.lastPathComponent)
        try fileManager.copyItem(at: appURL, to: stagedApp)

        onLog(.standardOutput, "Built \(stagedApp.lastPathComponent) (\(bundleID))")
        return IOSBuildArtifact(
            appURL: stagedApp,
            bundleID: bundleID,
            cleanup: { [fileManager] in
                try? fileManager.removeItem(at: stagingRoot)
            }
        )
    }

    private func installAndLaunchIOS(
        artifact: IOSBuildArtifact,
        udid: String,
        deviceName: String,
        onLog: @escaping LogHandler
    ) async throws {
        onLog(.standardOutput, "=== \(deviceName): install ===")
        let install = try await runner.run(
            executable: xcrun,
            arguments: ["simctl", "install", udid, artifact.appURL.path],
            environment: developerEnvironment,
            timeout: 180
        )
        guard install.exitCode == 0 else {
            throw ProjectBuildPlayError.deployFailed(
                device: deviceName,
                message: AppPackageInstaller.cleanInstallMessage(
                    stdout: install.standardOutput,
                    stderr: install.standardError,
                    fallback: "simctl install failed."
                )
            )
        }

        onLog(.standardOutput, "=== \(deviceName): launch \(artifact.bundleID) ===")
        let launch = try await runner.run(
            executable: xcrun,
            arguments: ["simctl", "launch", udid, artifact.bundleID],
            environment: developerEnvironment,
            timeout: 60
        )
        guard launch.exitCode == 0 else {
            throw ProjectBuildPlayError.deployFailed(
                device: deviceName,
                message: AppPackageInstaller.cleanInstallMessage(
                    stdout: launch.standardOutput,
                    stderr: launch.standardError,
                    fallback: "simctl launch failed."
                )
            )
        }
    }

    private func bundleIdentifier(forApp appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(
               from: data,
               format: nil
           ) as? [String: Any],
           let bundleID = plist["CFBundleIdentifier"] as? String {
            return bundleID
        }
        if let xml = try? String(contentsOf: plistURL, encoding: .utf8) {
            return Self.bundleIdentifier(fromInfoPlistXML: xml)
        }
        return nil
    }

    private func findBuiltApp(in derivedData: URL) -> URL? {
        let products = derivedData
            .appendingPathComponent("Build/Products", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: products,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "app" {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - Android

    private struct AndroidBuildArtifact {
        let apkURL: URL
        let packageName: String
    }

    private func buildAndroid(
        projectPath: String,
        onLog: @escaping LogHandler,
        onStatus: @escaping StatusHandler
    ) async throws -> AndroidBuildArtifact {
        let projectURL = URL(fileURLWithPath: projectPath)
        guard Self.isGradleProject(at: projectURL) else {
            throw ProjectBuildPlayError.androidProjectRequired
        }

        guard let gradle = gradleExecutable(in: projectURL) else {
            throw ProjectBuildPlayError.toolMissing("gradlew or gradle")
        }

        onStatus("Building Android…")
        onLog(.standardOutput, "=== \(gradle.lastPathComponent) assembleDebug ===")

        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_HOME"] = androidSDK.path
        environment["ANDROID_SDK_ROOT"] = androidSDK.path
        environment.removeValue(forKey: "ANDROID_SERIAL")

        let exitCode = try await runStreaming(
            executable: gradle,
            arguments: ["assembleDebug"],
            environment: environment,
            workingDirectory: projectURL,
            onLog: onLog
        )
        guard exitCode == 0 else {
            throw ProjectBuildPlayError.buildFailed(
                "Gradle assembleDebug failed (exit \(exitCode))."
            )
        }

        guard let apkURL = findDebugAPK(in: projectURL) else {
            throw ProjectBuildPlayError.artifactNotFound(
                "Could not find app/build/outputs/apk/debug/*.apk after build."
            )
        }
        guard let packageName = try await packageName(forAPK: apkURL) else {
            throw ProjectBuildPlayError.artifactNotFound(
                "Could not read the APK package name."
            )
        }

        onLog(.standardOutput, "Built \(apkURL.lastPathComponent) (\(packageName))")
        return AndroidBuildArtifact(apkURL: apkURL, packageName: packageName)
    }

    private func installAndLaunchAndroid(
        artifact: AndroidBuildArtifact,
        serial: String,
        deviceName: String,
        onLog: @escaping LogHandler
    ) async throws {
        guard let adb else {
            throw ProjectBuildPlayError.toolMissing("adb")
        }

        onLog(.standardOutput, "=== \(deviceName): install ===")
        let install = try await runner.run(
            executable: adb,
            arguments: [
                "-s", serial,
                "install", "-r", "-d",
                artifact.apkURL.path
            ],
            timeout: 180
        )
        guard install.exitCode == 0,
              !install.standardOutput.localizedCaseInsensitiveContains("Failure"),
              !install.standardError.localizedCaseInsensitiveContains("Failure") else {
            throw ProjectBuildPlayError.deployFailed(
                device: deviceName,
                message: AppPackageInstaller.cleanInstallMessage(
                    stdout: install.standardOutput,
                    stderr: install.standardError,
                    fallback: "adb install failed."
                )
            )
        }

        onLog(.standardOutput, "=== \(deviceName): launch \(artifact.packageName) ===")
        let launch = try await runner.run(
            executable: adb,
            arguments: [
                "-s", serial,
                "shell", "monkey",
                "-p", artifact.packageName,
                "-c", "android.intent.category.LAUNCHER",
                "1"
            ],
            timeout: 60
        )
        guard launch.exitCode == 0 else {
            throw ProjectBuildPlayError.deployFailed(
                device: deviceName,
                message: AppPackageInstaller.cleanInstallMessage(
                    stdout: launch.standardOutput,
                    stderr: launch.standardError,
                    fallback: "adb launch failed."
                )
            )
        }
    }

    private func gradleExecutable(in projectURL: URL) -> URL? {
        let gradlew = projectURL.appendingPathComponent("gradlew")
        if fileManager.isExecutableFile(atPath: gradlew.path) {
            return gradlew
        }
        return ExecutableLocator.executable(named: "gradle")
    }

    private func findDebugAPK(in projectURL: URL) -> URL? {
        let outputs = projectURL.appendingPathComponent(
            "app/build/outputs/apk/debug",
            isDirectory: true
        )
        if let apks = try? fileManager.contentsOfDirectory(
            at: outputs,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            if let apk = apks.first(where: {
                $0.pathExtension.lowercased() == "apk"
            }) {
                return apk
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: projectURL.appendingPathComponent("build", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var newest: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator {
            guard url.path.contains("/outputs/apk/debug/"),
                  url.pathExtension.lowercased() == "apk" else {
                continue
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if date >= newestDate {
                newest = url
                newestDate = date
            }
        }
        return newest
    }

    private func packageName(forAPK apkURL: URL) async throws -> String? {
        guard let aapt = aaptExecutable() else {
            return nil
        }
        let result = try await runner.run(
            executable: aapt,
            arguments: ["dump", "badging", apkURL.path],
            timeout: 30
        )
        guard result.exitCode == 0 else { return nil }
        return Self.parsePackageName(fromBadging: result.standardOutput)
    }

    private func aaptExecutable() -> URL? {
        let buildTools = androidSDK.appendingPathComponent("build-tools", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: buildTools,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let sorted = versions.sorted {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: .numeric
            ) == .orderedDescending
        }
        for version in sorted {
            let candidate = version.appendingPathComponent("aapt")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func parsePackageName(fromBadging output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package: name=") else { continue }
            if let start = trimmed.firstIndex(of: "'"),
               let end = trimmed[trimmed.index(after: start)...].firstIndex(of: "'") {
                let name = trimmed[trimmed.index(after: start)..<end]
                return String(name)
            }
        }
        return nil
    }

    // MARK: - Streaming

    private func runStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        onLog: @escaping LogHandler
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            let process = StreamingProcess(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                onLines: { output, lines in
                    for line in lines where !line.isEmpty {
                        onLog(output, line)
                    }
                },
                onTermination: { code in
                    continuation.resume(returning: code)
                }
            )
            do {
                try process.start()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}