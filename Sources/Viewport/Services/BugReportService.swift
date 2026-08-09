import AppKit
import Foundation
import UniformTypeIdentifiers

enum BugReportError: LocalizedError {
    case screenshotFailed
    case encodingFailed
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenshotFailed:
            "Could not capture panes for the bug report."
        case .encodingFailed:
            "Could not encode the bug-report screenshot."
        case let .zipFailed(message):
            "Could not create the bug-report archive: \(message)"
        }
    }
}

struct BugReportManifest: Encodable {
    let generatedAt: String
    let appVersion: String
    let macOSVersion: String
    let currentURL: String?
    let visibleSources: [String]
    let androidDevice: String?
    let iOSDevice: String?
    let captureMode: String
    let performanceProfile: String
    let logLineCount: Int
}

@MainActor
struct BugReportService {
    var logLineLimit = 400

    func export(
        web: WebViewModel,
        workspace: WorkspaceStore,
        logs: DeveloperLogStore,
        includePlatformLabels: Bool
    ) async throws -> URL? {
        let screenshotService = WorkspaceScreenshotService()
        let panes = await screenshotService.collectPanes(
            sources: workspace.orderedVisibleSources,
            web: web,
            workspace: workspace
        )
        guard !panes.isEmpty else {
            throw BugReportError.screenshotFailed
        }
        let composite = try screenshotService.compose(
            panes,
            includePlatformLabels: includePlatformLabels
        )
        guard let pngData = pngData(from: composite) else {
            throw BugReportError.encodingFailed
        }

        let logText = logs.exportRecentLines(limitPerSource: logLineLimit)
        let manifest = BugReportManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "0.1.0-dev",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            currentURL: web.currentURL?.absoluteString,
            visibleSources: workspace.orderedVisibleSources.map(\.rawValue),
            androidDevice: workspace.androidCapture.selectedDevice.map {
                "\($0.name) (\($0.id))"
            },
            iOSDevice: workspace.iOSCapture.selectedDevice.map {
                "\($0.name) (\($0.id))"
            },
            captureMode: workspace.captureMode.rawValue,
            performanceProfile: workspace.performanceProfile.rawValue,
            logLineCount: logText.split(
                whereSeparator: \.isNewline
            ).count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = WorkspaceScreenshotNaming.filename(
            fileExtension: "zip"
        ).replacingOccurrences(of: "Viewport", with: "Viewport-BugReport")
        panel.title = "Save Bug Report"
        guard panel.runModal() == .OK, let destination = panel.url else {
            return nil
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "viewport-bug-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        try pngData.write(
            to: staging.appendingPathComponent("screenshot.png"),
            options: .atomic
        )
        try logText.write(
            to: staging.appendingPathComponent("logs.txt"),
            atomically: true,
            encoding: .utf8
        )
        try manifestData.write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        try await Self.zipDirectory(staging, to: destination)
        return destination
    }

    private func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .png,
            properties: [:]
        )
    }

    /// Runs `/usr/bin/zip` off the main actor. Stderr is drained while the
    /// process runs so a full pipe buffer cannot deadlock `waitUntilExit`.
    private nonisolated static func zipDirectory(
        _ directory: URL,
        to destination: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-qr", destination.path, "."]
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice

            let stderr = Pipe()
            process.standardError = stderr
            let stderrBuffer = LockedData()
            let stderrHandle = stderr.fileHandleForReading
            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
            }

            do {
                try process.run()
            } catch {
                stderrHandle.readabilityHandler = nil
                throw BugReportError.zipFailed(error.localizedDescription)
            }

            process.waitUntilExit()
            stderrHandle.readabilityHandler = nil
            stderrBuffer.append(stderrHandle.readDataToEndOfFile())
            let messageData = stderrBuffer.data

            guard process.terminationStatus == 0 else {
                let message = String(data: messageData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw BugReportError.zipFailed(
                    message?.isEmpty == false
                        ? message!
                        : "zip exited with status \(process.terminationStatus)"
                )
            }
        }.value
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }
}
