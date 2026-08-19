import XCTest
@testable import Viewport

final class LogLineDecoderTests: XCTestCase {
    func testDecodesChunkedUTF8AndCRLF() {
        var decoder = LogLineDecoder()
        let first = Data([0x68, 0x69, 0x20, 0xF0, 0x9F])
        let second = Data([0x98, 0x80, 0x0D, 0x0A])

        XCTAssertEqual(decoder.append(first), [])
        XCTAssertEqual(decoder.append(second), ["hi 😀"])
    }

    func testDecodesMultipleLinesAndTrailingLine() {
        var decoder = LogLineDecoder()

        XCTAssertEqual(
            decoder.append(Data("one\ntwo\nthree".utf8)),
            ["one", "two"]
        )
        XCTAssertEqual(decoder.finish(), ["three"])
    }

    func testBoundsOversizedLine() {
        var decoder = LogLineDecoder(maximumLineBytes: 4)

        XCTAssertEqual(
            decoder.append(Data("12345".utf8)),
            ["1234 …"]
        )
        XCTAssertEqual(decoder.append(Data("discarded\nnext\n".utf8)), ["next"])
    }

    func testCompactsConsumedPrefixInsteadOfShiftingEveryLine() {
        var decoder = LogLineDecoder(
            maximumLineBytes: 64,
            compactionThreshold: 8
        )

        XCTAssertEqual(decoder.append(Data("aa\nbb\ncc\n".utf8)), ["aa", "bb", "cc"])
        XCTAssertEqual(decoder.consumedByteCount, 0)
        XCTAssertTrue(decoder.bufferedData.isEmpty)

        XCTAssertEqual(decoder.append(Data("partial".utf8)), [])
        XCTAssertEqual(decoder.bufferedData, Data("partial".utf8))
        XCTAssertEqual(decoder.append(Data("-line\n".utf8)), ["partial-line"])
        XCTAssertEqual(decoder.consumedByteCount, 0)
    }
}

@MainActor
final class DeveloperLogStoreTests: XCTestCase {
    func testBoundsEntriesPerSource() {
        let store = DeveloperLogStore(
            maximumEntriesPerSource: 2,
            maximumBytesPerSource: 1_024
        )
        store.setEnabled(true)

        store.appendWeb(level: .info, message: "one")
        store.appendWeb(level: .warning, message: "two")
        store.appendWeb(level: .error, message: "three")
        store.togglePaused()
        store.togglePaused()

        XCTAssertEqual(
            store.entries(for: .web).map(\.message),
            ["two", "three"]
        )
    }

    func testPauseFreezesPublishedEntriesUntilResume() {
        let store = DeveloperLogStore()
        store.setEnabled(true)
        store.togglePaused()
        store.appendWeb(level: .info, message: "queued")

        XCTAssertTrue(store.entries(for: .web).isEmpty)

        store.togglePaused()
        XCTAssertEqual(store.entries(for: .web).map(\.message), ["queued"])
    }

    func testRetentionLimitDropsOldestEntriesAndPersists() {
        let suiteName = "DeveloperLogStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DeveloperLogStore(defaults: defaults)
        store.setEnabled(true)
        store.setRetentionLimit(.kilobytes128)

        store.appendWeb(
            level: .info,
            message: String(repeating: "a", count: 80 * 1_024)
        )
        store.appendWeb(
            level: .info,
            message: String(repeating: "b", count: 80 * 1_024)
        )
        store.togglePaused()
        store.togglePaused()

        XCTAssertEqual(store.entries(for: .web).count, 1)
        XCTAssertTrue(store.entries(for: .web)[0].message.hasPrefix("b"))

        let restored = DeveloperLogStore(defaults: defaults)
        XCTAssertEqual(
            restored.retentionLimitBytes,
            DeveloperLogRetention.kilobytes128.rawValue
        )
    }

    func testStartsSimulatorLogStreamWithSelectedUDID() {
        let recorder = ProcessRecorder()
        let store = DeveloperLogStore(
            processFactory: {
                executable, arguments, environment, onLines, onTermination in
                recorder.executable = executable
                recorder.arguments = arguments
                recorder.environment = environment
                let process = FakeStreamingProcess(
                    onLines: onLines,
                    onTermination: onTermination
                )
                recorder.process = process
                return process
            }
        )
        let device = StreamedDevice(
            id: "SIMULATOR-UDID",
            name: "iPhone",
            source: .iOS,
            pixelSize: nil,
            kind: .iOSSimulator
        )

        store.setEnabled(true)
        store.updateIOSDevice(device, isVisible: true)

        XCTAssertEqual(
            recorder.arguments,
            [
                "spawn", "SIMULATOR-UDID",
                "log", "stream",
                "--style", "compact",
                "--level", "default"
            ]
        )
        XCTAssertEqual(
            recorder.executable?.lastPathComponent,
            "simctl"
        )
        XCTAssertEqual(recorder.environment?["DEVELOPER_DIR"], ToolchainLocator().developerDirectory.path)
        XCTAssertEqual(store.status(for: .iOS), .streaming)
        XCTAssertTrue(recorder.process?.started == true)
    }

    func testStartsAndroidLogcatForSelectedSerial() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let adb = temporaryDirectory.appendingPathComponent("adb")
        try Data("#!/bin/sh\n".utf8).write(to: adb)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adb.path
        )

        let recorder = ProcessRecorder()
        let store = DeveloperLogStore(
            toolchains: ToolchainLocator(
                environment: ["PATH": temporaryDirectory.path],
                homeDirectory: temporaryDirectory
            ),
            processFactory: {
                executable, arguments, environment, onLines, onTermination in
                recorder.executable = executable
                recorder.arguments = arguments
                recorder.environment = environment
                let process = FakeStreamingProcess(
                    onLines: onLines,
                    onTermination: onTermination
                )
                recorder.process = process
                return process
            }
        )

        store.setEnabled(true)
        store.updateAndroidDevice(id: "emulator-5554", isVisible: true)

        XCTAssertEqual(recorder.executable?.lastPathComponent, "adb")
        XCTAssertEqual(
            recorder.arguments,
            [
                "-s", "emulator-5554",
                "logcat", "-v", "threadtime", "-T", "1"
            ]
        )
        XCTAssertEqual(store.status(for: .android), .streaming)
    }

    func testPhysicalIOSDeviceReportsUnavailable() {
        let store = DeveloperLogStore()
        let device = StreamedDevice(
            id: "PHONE-UDID",
            name: "iPhone",
            source: .iOS,
            pixelSize: nil,
            kind: .iOSDevice
        )

        store.setEnabled(true)
        store.updateIOSDevice(device, isVisible: true)

        XCTAssertEqual(
            store.status(for: .iOS),
            .unavailable("Logs are unavailable for USB iOS devices")
        )
    }

    func testDisablingStopsStreamsAndIgnoresIncomingLogs() {
        let recorder = ProcessRecorder()
        let store = DeveloperLogStore(
            processFactory: {
                executable, arguments, environment, onLines, onTermination in
                recorder.executable = executable
                recorder.arguments = arguments
                recorder.environment = environment
                let process = FakeStreamingProcess(
                    onLines: onLines,
                    onTermination: onTermination
                )
                recorder.process = process
                return process
            }
        )
        let device = StreamedDevice(
            id: "SIMULATOR-UDID",
            name: "iPhone",
            source: .iOS,
            pixelSize: nil,
            kind: .iOSSimulator
        )

        store.setEnabled(true)
        store.updateIOSDevice(device, isVisible: true)
        XCTAssertTrue(recorder.process?.started == true)

        store.setEnabled(false)

        XCTAssertTrue(recorder.process?.stopped == true)
        XCTAssertEqual(store.status(for: .iOS), .idle)
        XCTAssertFalse(store.isEnabled)

        store.appendWeb(level: .info, message: "should be dropped")
        store.togglePaused()
        store.togglePaused()
        XCTAssertTrue(store.entries(for: .web).isEmpty)

        // Visibility alone must not restart capture while disabled.
        store.updateIOSDevice(device, isVisible: true)
        XCTAssertEqual(store.status(for: .iOS), .idle)
        XCTAssertTrue(recorder.process?.stopped == true)
    }
}

final class WebConsoleBridgeTests: XCTestCase {
    func testMapsConsoleLevels() {
        XCTAssertEqual(WebConsoleBridge.level(from: "debug"), .debug)
        XCTAssertEqual(WebConsoleBridge.level(from: "warn"), .warning)
        XCTAssertEqual(WebConsoleBridge.level(from: "error"), .error)
        XCTAssertEqual(WebConsoleBridge.level(from: "log"), .info)
    }
}

private final class ProcessRecorder {
    var executable: URL?
    var arguments: [String]?
    var environment: [String: String]?
    var process: FakeStreamingProcess?
}

private final class FakeStreamingProcess: StreamingProcessRunning {
    let onLines: StreamingProcess.LinesHandler
    let onTermination: StreamingProcess.TerminationHandler
    private(set) var started = false
    private(set) var stopped = false

    init(
        onLines: @escaping StreamingProcess.LinesHandler,
        onTermination: @escaping StreamingProcess.TerminationHandler
    ) {
        self.onLines = onLines
        self.onTermination = onTermination
    }

    func start() throws {
        started = true
    }

    func stop() {
        stopped = true
    }
}
