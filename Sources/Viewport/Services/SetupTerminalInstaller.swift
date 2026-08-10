import Foundation

/// Opens Terminal.app to run setup commands (brew installs, etc.).
/// Prefer Terminal over an in-process brew run so the user sees progress and
/// Homebrew can use their normal interactive shell environment.
enum SetupTerminalInstaller {
    enum InstallError: LocalizedError {
        case brewMissing
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .brewMissing:
                "Homebrew is not installed. Install it from https://brew.sh first."
            case let .launchFailed(message):
                message
            }
        }
    }

    static var brewExecutable: URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew")
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static var hasBrew: Bool {
        brewExecutable != nil
    }

    static var homebrewURL: URL {
        URL(string: "https://brew.sh")!
    }

    /// True when this command is expected to need Homebrew.
    static func requiresBrew(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("brew ") || trimmed.contains(" brew ")
    }

    /// Activates Terminal.app and runs `command` in a new window/tab.
    static func runInTerminal(_ command: String) throws {
        if requiresBrew(command), !hasBrew {
            throw InstallError.brewMissing
        }

        let escaped = escapeForAppleScript(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"\(escaped)\""
        ]

        do {
            try process.run()
        } catch {
            throw InstallError.launchFailed(error.localizedDescription)
        }
    }

    private static func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
