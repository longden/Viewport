import Foundation

/// Opens setup commands in Terminal so the user sees progress and Homebrew
/// runs in their normal interactive shell environment.
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

    static var homebrewURL: URL {
        URL(string: "https://brew.sh")!
    }

    /// True when this command is expected to need Homebrew.
    static func requiresBrew(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("brew ") || trimmed.contains(" brew ")
    }

    /// Opens a temporary `.command` file in Terminal without Apple Events
    /// automation permission. The script removes itself after it runs.
    static func runInTerminal(_ command: String) async throws {
        let command = try terminalCommand(
            for: command,
            brewExecutable: brewExecutable
        )
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-install-\(UUID().uuidString).command")
        let script = """
            #!/bin/zsh
            \(command)
            result=$?
            printf '\\nInstall finished (exit %s). Return to Viewport.\\n' "$result"
            rm -- "$0"
            exit "$result"
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.standardError = standardError
        process.arguments = [
            "-a", "/System/Applications/Utilities/Terminal.app", scriptURL.path
        ]

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
                try? standardError.fileHandleForWriting.close()
            } catch {
                try? FileManager.default.removeItem(at: scriptURL)
                continuation.resume(
                    throwing: InstallError.launchFailed(error.localizedDescription)
                )
            }
        }
        guard exitCode == 0 else {
            try? FileManager.default.removeItem(at: scriptURL)
            let detail = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                throw InstallError.launchFailed(detail)
            }
            throw InstallError.launchFailed("Terminal could not start the install.")
        }
    }

    /// Use the located Homebrew binary for commands that start with `brew`.
    /// GUI apps do not inherit the user's interactive shell PATH.
    static func terminalCommand(
        for command: String,
        brewExecutable: URL?
    ) throws -> String {
        guard requiresBrew(command) else { return command }
        guard let brewExecutable else { throw InstallError.brewMissing }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("brew ") else { return command }
        let quotedPath = "'\(brewExecutable.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        return quotedPath + String(trimmed.dropFirst("brew".count))
    }
}
