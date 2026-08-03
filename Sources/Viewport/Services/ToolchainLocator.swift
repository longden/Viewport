import Foundation

struct ToolchainLocator {
    let environment: [String: String]
    let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var androidSDK: URL {
        if let path = environment["ANDROID_SDK_ROOT"]
            ?? environment["ANDROID_HOME"] {
            return URL(fileURLWithPath: path)
        }
        return homeDirectory.appendingPathComponent("Library/Android/sdk")
    }

    var adb: URL? {
        ExecutableLocator.executable(
            named: "adb",
            candidates: [
                androidSDK.appendingPathComponent("platform-tools/adb"),
                URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
                URL(fileURLWithPath: "/usr/local/bin/adb")
            ],
            environment: environment
        )
    }

    var androidCLI: URL? {
        ExecutableLocator.executable(
            named: "android",
            candidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/android"),
                homeDirectory.appendingPathComponent(".local/bin/android"),
                URL(fileURLWithPath: "/usr/local/bin/android")
            ],
            environment: environment
        )
    }

    var androidEmulator: URL? {
        ExecutableLocator.executable(
            named: "emulator",
            candidates: [androidSDK.appendingPathComponent("emulator/emulator")],
            environment: environment
        )
    }

    var scrcpy: URL? {
        ExecutableLocator.executable(
            named: "scrcpy",
            candidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/scrcpy"),
                URL(fileURLWithPath: "/usr/local/bin/scrcpy")
            ],
            environment: environment
        )
    }

    var developerDirectory: URL {
        environment["DEVELOPER_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
    }

    var developerEnvironment: [String: String] {
        ["DEVELOPER_DIR": developerDirectory.path]
    }

    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
}
