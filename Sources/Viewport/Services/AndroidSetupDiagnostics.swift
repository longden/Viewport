import Foundation

enum SetupCheckStatus: Equatable {
    case ready
    case missing
    case optionalMissing
}

struct SetupCheckItem: Identifiable, Equatable {
    let id: String
    let title: String
    let status: SetupCheckStatus
    let detail: String

    var isBlocking: Bool {
        status == .missing
    }
}

struct AndroidSetupReport: Equatable {
    let items: [SetupCheckItem]
    let canCreateEmulators: Bool
    let canLaunchEmulators: Bool
    let existingEmulatorCount: Int

    var isReady: Bool {
        !items.contains(where: \.isBlocking)
    }
}

struct AndroidSetupDiagnostics {
    private let toolchains: ToolchainLocator
    private let runner: CommandRunner
    private let fileManager: FileManager

    init(
        toolchains: ToolchainLocator = ToolchainLocator(),
        runner: CommandRunner = CommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.toolchains = toolchains
        self.runner = runner
        self.fileManager = fileManager
    }

    func evaluate() async -> AndroidSetupReport {
        let sdk = toolchains.androidSDK
        let sdkExists = fileManager.fileExists(atPath: sdk.path)
        let adb = toolchains.adb
        let emulator = toolchains.androidEmulator
        let androidCLI = toolchains.androidCLI
        let scrcpy = toolchains.scrcpy
        let systemImageCount = countSystemImages(in: sdk)
        let existingEmulators = await existingAVDCount()

        let items: [SetupCheckItem] = [
            SetupCheckItem(
                id: "sdk",
                title: "Android SDK",
                status: sdkExists ? .ready : .missing,
                detail: sdkExists
                    ? sdk.path
                    : "Install the Android SDK (Android Studio or command-line tools), then reopen Viewport."
            ),
            SetupCheckItem(
                id: "adb",
                title: "ADB",
                status: adb == nil ? .missing : .ready,
                detail: adb.map(\.path)
                    ?? "Install platform-tools so Viewport can talk to emulators and phones."
            ),
            SetupCheckItem(
                id: "emulator",
                title: "Android Emulator",
                status: emulator == nil ? .missing : .ready,
                detail: emulator.map(\.path)
                    ?? "Install the Android Emulator package from the SDK Manager."
            ),
            SetupCheckItem(
                id: "android-cli",
                title: "Android CLI",
                status: androidCLI == nil ? .missing : .ready,
                detail: androidCLI.map(\.path)
                    ?? "Needed to create emulators inside Viewport. Install Google’s Android CLI, or create a device in Android Studio and refresh."
            ),
            SetupCheckItem(
                id: "system-images",
                title: "System images",
                status: systemImageCount > 0 ? .ready : .missing,
                detail: systemImageCount > 0
                    ? "\(systemImageCount) installed"
                    : "Install at least one Android system image so new emulators can boot."
            ),
            SetupCheckItem(
                id: "scrcpy",
                title: "scrcpy",
                status: scrcpy == nil ? .optionalMissing : .ready,
                detail: scrcpy.map(\.path)
                    ?? "Optional. Install with `brew install scrcpy` for smoother physical Android streaming."
            ),
            SetupCheckItem(
                id: "avds",
                title: "Saved emulators",
                status: .ready,
                detail: existingEmulators == 0
                    ? "None yet — create one from Help or the Android play menu."
                    : "\(existingEmulators) ready to start"
            )
        ]

        return AndroidSetupReport(
            items: items,
            canCreateEmulators: androidCLI != nil
                && sdkExists
                && systemImageCount > 0,
            canLaunchEmulators: (androidCLI != nil || emulator != nil)
                && adb != nil,
            existingEmulatorCount: existingEmulators
        )
    }

    private func countSystemImages(in sdk: URL) -> Int {
        let root = sdk.appendingPathComponent("system-images")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if ["arm64-v8a", "x86_64", "x86"].contains(name) {
                count += 1
            }
        }
        return count
    }

    private func existingAVDCount() async -> Int {
        do {
            let client = AndroidDeviceClient(
                runner: runner,
                toolchains: toolchains
            )
            return try await client.listDevices().count
        } catch {
            return 0
        }
    }
}
