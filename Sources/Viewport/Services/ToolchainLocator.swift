import Foundation

/// How to invoke `simctl` without relying on the Mac's active `xcode-select`.
/// Prefer a real `simctl` binary so Command Line Tools-only selections still work.
struct SimctlCommand: Equatable {
    let executable: URL
    let arguments: [String]
}

struct ToolchainLocator {
    let environment: [String: String]
    let homeDirectory: URL
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
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

    /// Xcode developer directory that actually contains Simulator tools.
    /// Ignores `DEVELOPER_DIR` / `xcode-select` when they point at Command Line
    /// Tools (which do not ship `simctl`).
    var developerDirectory: URL {
        let fallback = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"
        )
        return developerDirectoryCandidates.first(where: isUsableDeveloperDirectory)
            ?? fallback
    }

    var developerEnvironment: [String: String] {
        ["DEVELOPER_DIR": developerDirectory.path]
    }

    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    /// Resolved `simctl` binary when one exists on disk.
    var simctl: URL? {
        let candidates = [
            URL(
                fileURLWithPath:
                    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
            ),
            developerDirectory.appendingPathComponent("usr/bin/simctl")
        ]
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    /// Build an invocation that prefers a direct `simctl` binary over `xcrun`.
    func simctlCommand(_ arguments: [String]) -> SimctlCommand {
        if let simctl {
            return SimctlCommand(executable: simctl, arguments: arguments)
        }
        return SimctlCommand(
            executable: xcrun,
            arguments: ["simctl"] + arguments
        )
    }

    private var developerDirectoryCandidates: [URL] {
        var candidates: [URL] = []
        if let override = environment["DEVELOPER_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
        )
        if let selected = readXcodeSelectLink(),
           !candidates.contains(where: { $0.path == selected.path }) {
            candidates.append(selected)
        }
        return candidates
    }

    private func isUsableDeveloperDirectory(_ url: URL) -> Bool {
        fileManager.isExecutableFile(
            atPath: url.appendingPathComponent("usr/bin/simctl").path
        )
    }

    private func readXcodeSelectLink() -> URL? {
        let link = URL(fileURLWithPath: "/var/db/xcode_select_link")
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: link.path
        ) else {
            return nil
        }
        return URL(fileURLWithPath: destination)
    }
}
