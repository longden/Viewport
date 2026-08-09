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
    /// Terminal command users can copy when this check is not ready.
    var installCommand: String? = nil
    /// Optional docs / download page.
    var installURL: URL? = nil
    var installURLTitle: String? = nil

    var isBlocking: Bool {
        status == .missing
    }
}

/// Static install recipes shown in Help regardless of check status.
struct SetupInstallGuide: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    var command: String? = nil
    var url: URL? = nil
    var urlTitle: String? = nil
}

enum SetupInstallGuides {
    static let androidStudio = SetupInstallGuide(
        id: "android-studio",
        title: "Android Studio",
        summary: "Easiest full setup. Installs the Android SDK, ADB, Emulator, and system images.",
        url: URL(string: "https://developer.android.com/studio"),
        urlTitle: "Download Android Studio"
    )

    static let adb = SetupInstallGuide(
        id: "adb",
        title: "ADB",
        summary: "Talks to emulators and phones. Also included with Android Studio.",
        command: "brew install android-platform-tools"
    )

    static let androidCLI = SetupInstallGuide(
        id: "android-cli",
        title: "Android CLI",
        summary: "Lets Viewport create emulators from Help. You can also create devices in Android Studio’s Device Manager.",
        command: "brew tap android/tap && brew install android-cli",
        url: URL(string: "https://developer.android.com/tools/agents/android-cli/download"),
        urlTitle: "Android CLI download"
    )

    static let scrcpy = SetupInstallGuide(
        id: "scrcpy",
        title: "scrcpy",
        summary: "Optional. Smoother streaming and touch for physical Android devices.",
        command: "brew install scrcpy",
        url: URL(string: "https://github.com/Genymobile/scrcpy"),
        urlTitle: "scrcpy on GitHub"
    )

    static let xcode = SetupInstallGuide(
        id: "xcode",
        title: "Xcode",
        summary: "Required for the iOS Simulator pane. Install from the Mac App Store, then open Xcode once to finish setup.",
        url: URL(string: "https://apps.apple.com/app/xcode/id497799835"),
        urlTitle: "Get Xcode"
    )

    static let all: [SetupInstallGuide] = [
        androidStudio,
        adb,
        androidCLI,
        scrcpy,
        xcode
    ]
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
                    : "Install Android Studio (recommended), then reopen Viewport.",
                installURL: sdkExists ? nil : SetupInstallGuides.androidStudio.url,
                installURLTitle: sdkExists ? nil : SetupInstallGuides.androidStudio.urlTitle
            ),
            SetupCheckItem(
                id: "adb",
                title: "ADB",
                status: adb == nil ? .missing : .ready,
                detail: adb.map(\.path)
                    ?? "Install platform-tools so Viewport can talk to emulators and phones.",
                installCommand: adb == nil ? SetupInstallGuides.adb.command : nil,
                installURL: adb == nil ? SetupInstallGuides.androidStudio.url : nil,
                installURLTitle: adb == nil ? "Or install via Android Studio" : nil
            ),
            SetupCheckItem(
                id: "emulator",
                title: "Android Emulator",
                status: emulator == nil ? .missing : .ready,
                detail: emulator.map(\.path)
                    ?? "Install the Android Emulator package from Android Studio’s SDK Manager.",
                installURL: emulator == nil ? SetupInstallGuides.androidStudio.url : nil,
                installURLTitle: emulator == nil ? SetupInstallGuides.androidStudio.urlTitle : nil
            ),
            SetupCheckItem(
                id: "android-cli",
                title: "Android CLI",
                status: androidCLI == nil ? .missing : .ready,
                detail: androidCLI.map(\.path)
                    ?? "Needed to create emulators inside Viewport. Or create a device in Android Studio and refresh.",
                installCommand: androidCLI == nil
                    ? SetupInstallGuides.androidCLI.command
                    : nil,
                installURL: androidCLI == nil ? SetupInstallGuides.androidCLI.url : nil,
                installURLTitle: androidCLI == nil
                    ? SetupInstallGuides.androidCLI.urlTitle
                    : nil
            ),
            SetupCheckItem(
                id: "system-images",
                title: "System images",
                status: systemImageCount > 0 ? .ready : .missing,
                detail: systemImageCount > 0
                    ? "\(systemImageCount) installed"
                    : "Install at least one Android system image in Android Studio’s SDK Manager so new emulators can boot.",
                installURL: systemImageCount > 0
                    ? nil
                    : SetupInstallGuides.androidStudio.url,
                installURLTitle: systemImageCount > 0
                    ? nil
                    : SetupInstallGuides.androidStudio.urlTitle
            ),
            SetupCheckItem(
                id: "scrcpy",
                title: "scrcpy",
                status: scrcpy == nil ? .optionalMissing : .ready,
                detail: scrcpy.map(\.path)
                    ?? "Optional. Install for smoother physical Android streaming.",
                installCommand: scrcpy == nil ? SetupInstallGuides.scrcpy.command : nil,
                installURL: scrcpy == nil ? SetupInstallGuides.scrcpy.url : nil,
                installURLTitle: scrcpy == nil ? SetupInstallGuides.scrcpy.urlTitle : nil
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
