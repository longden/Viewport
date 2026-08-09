import AppKit
import Foundation

enum BatchURLSnapshotError: LocalizedError {
    case noURLs
    case cancelled
    case folderCreationFailed
    case loadTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .noURLs:
            "Add at least one valid http(s) URL."
        case .cancelled:
            "Batch snapshotting was cancelled."
        case .folderCreationFailed:
            "Could not create the output folder."
        case let .loadTimedOut(url):
            "Timed out loading \(url)."
        }
    }
}

struct BatchURLSnapshotProgress: Equatable {
    var index: Int
    var total: Int
    var url: String
    var savedURL: URL?
    var message: String?
}

@MainActor
final class BatchURLSnapshotService {
    /// Delay after load settles before capturing the web pane.
    var settleDelay: Duration = .milliseconds(900)
    /// Max time to wait for the web pane to finish loading.
    var loadTimeout: Duration = .seconds(20)

    func parseURLList(_ text: String) -> [URL] {
        let lines = text
            .replacingOccurrences(of: ",", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var urls: [URL] = []
        for line in lines {
            // One candidate per line; ignore free-form notes without a host dot.
            guard let url = WebViewModel.normalizedURL(from: line),
                  let host = url.host,
                  host.contains(".") || host == "localhost" else {
                continue
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    func run(
        urls: [URL],
        web: WebViewModel,
        workspace: WorkspaceStore,
        alsoOpenOnDevices: Bool,
        outputDirectory: URL,
        onProgress: (BatchURLSnapshotProgress) -> Void
    ) async throws -> [URL] {
        guard !urls.isEmpty else { throw BatchURLSnapshotError.noURLs }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let screenshots = WorkspaceScreenshotService()
        var saved: [URL] = []

        for (offset, url) in urls.enumerated() {
            try Task.checkCancellation()
            onProgress(
                BatchURLSnapshotProgress(
                    index: offset + 1,
                    total: urls.count,
                    url: url.absoluteString,
                    savedURL: nil,
                    message: "Loading…"
                )
            )

            web.load(url)
            do {
                try await waitForLoad(web: web)
            } catch let error as BatchURLSnapshotError {
                onProgress(
                    BatchURLSnapshotProgress(
                        index: offset + 1,
                        total: urls.count,
                        url: url.absoluteString,
                        savedURL: nil,
                        message: error.errorDescription
                    )
                )
                throw error
            }

            if alsoOpenOnDevices {
                let openResult = try? await workspace.broadcastOpenURL(
                    url.absoluteString,
                    targets: .both,
                    alsoOpenWeb: false,
                    web: nil
                )
                if let openResult, !openResult.didSucceed {
                    onProgress(
                        BatchURLSnapshotProgress(
                            index: offset + 1,
                            total: urls.count,
                            url: url.absoluteString,
                            savedURL: nil,
                            message: openResult.summary(verb: "Device open")
                        )
                    )
                }
                try await Task.sleep(for: .milliseconds(500))
            }

            try await Task.sleep(for: settleDelay)
            try Task.checkCancellation()

            let image = try await screenshots.captureWeb(web)

            let fileURL = outputDirectory.appendingPathComponent(
                Self.filename(for: url, index: offset + 1)
            )
            try writePNG(image, to: fileURL)
            saved.append(fileURL)
            onProgress(
                BatchURLSnapshotProgress(
                    index: offset + 1,
                    total: urls.count,
                    url: url.absoluteString,
                    savedURL: fileURL,
                    message: "Saved"
                )
            )
        }

        return saved
    }

    nonisolated static func filename(
        for url: URL,
        index: Int,
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let host = (url.host ?? "page")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let stamp = formatter.string(from: date)
        return String(format: "%03d-%@-%@.png", index, host, stamp)
    }

    private func waitForLoad(web: WebViewModel) async throws {
        let deadline = ContinuousClock.now + loadTimeout
        // Give navigation a chance to start.
        try await Task.sleep(for: .milliseconds(150))
        while web.isLoading {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline {
                throw BatchURLSnapshotError.loadTimedOut(
                    web.address.isEmpty ? "page" : web.address
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw WorkspaceScreenshotError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }
}
