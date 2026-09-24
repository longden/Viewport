import CoreGraphics
import XCTest
@testable import Viewport

final class LatestValueDeliveryTests: XCTestCase {
    func testCoalescesPendingValuesToNewest() {
        let queue = DispatchQueue(label: "LatestValueDeliveryTests")
        let delivery = LatestValueDelivery<Int>(queue: queue)
        let firstStarted = expectation(description: "first delivery started")
        let finished = expectation(description: "latest value delivered")
        let unblock = DispatchSemaphore(value: 0)
        let values = LockedValues<Int>()

        delivery.submit(1) { value in
            firstStarted.fulfill()
            unblock.wait()
            values.append(value)
        }
        wait(for: [firstStarted], timeout: 1)
        delivery.submit(2) { value in
            values.append(value)
        }
        delivery.submit(3) { value in
            values.append(value)
            finished.fulfill()
        }
        unblock.signal()
        wait(for: [finished], timeout: 1)

        XCTAssertEqual(values.snapshot, [1, 3])
    }

    func testDiscardsReplacedAndClearedValues() {
        let queue = DispatchQueue(label: "LatestValueDeliveryDiscardTests")
        queue.suspend()
        let discarded = LockedValues<Int>()
        let delivery = LatestValueDelivery<Int>(
            queue: queue,
            discard: { value in discarded.append(value) }
        )

        delivery.submit(1) { _ in }
        delivery.submit(2) { _ in }
        delivery.clear()

        XCTAssertEqual(discarded.snapshot, [1, 2])
        queue.resume()
    }
}

final class ToolchainLocatorTests: XCTestCase {
    func testUsesInjectedSDKAndDeveloperDirectories() {
        let locator = ToolchainLocator(
            environment: [
                "ANDROID_SDK_ROOT": "/custom/android",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "PATH": ""
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        XCTAssertEqual(locator.androidSDK.path, "/custom/android")
        XCTAssertEqual(
            locator.developerDirectory.path,
            "/Applications/Xcode.app/Contents/Developer"
        )
        XCTAssertEqual(
            locator.developerEnvironment["DEVELOPER_DIR"],
            "/Applications/Xcode.app/Contents/Developer"
        )
    }

    func testIgnoresCommandLineToolsDeveloperDirectory() {
        let locator = ToolchainLocator(
            environment: [
                "DEVELOPER_DIR": "/Library/Developer/CommandLineTools",
                "PATH": ""
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        XCTAssertEqual(
            locator.developerDirectory.path,
            "/Applications/Xcode.app/Contents/Developer"
        )
        let command = locator.simctlCommand(["list", "devices"])
        XCTAssertNotEqual(command.executable.lastPathComponent, "xcrun")
        XCTAssertEqual(command.arguments, ["list", "devices"])
    }

    func testFallsBackToStandardAndroidSDKLocation() {
        let locator = ToolchainLocator(
            environment: ["PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        XCTAssertEqual(
            locator.androidSDK.path,
            "/Users/test/Library/Android/sdk"
        )
    }
}

final class CaptureTransportPolicyTests: XCTestCase {
    func testDirectEmulatorFallbackOrder() {
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .direct,
                deviceKind: .androidEmulator
            ),
            [.emulatorGrpc, .hostWindow, .scrcpy, .polling]
        )
    }

    func testDirectSimulatorFallbackOrder() {
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .direct,
                deviceKind: .iOSSimulator
            ),
            [.simulatorSurface, .hostWindow, .polling]
        )
    }

    func testClassicSimulatorSkipsPrivateSurface() {
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .classic,
                deviceKind: .iOSSimulator
            ),
            [.hostWindow, .polling]
        )
    }

    func testClassicEmulatorFallbackOrder() {
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .classic,
                deviceKind: .androidEmulator
            ),
            [.hostWindow, .scrcpy, .polling]
        )
    }

    func testPhysicalDeviceStrategies() {
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .direct,
                deviceKind: .iOSDevice
            ),
            [.usbDevice]
        )
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .classic,
                deviceKind: .androidDevice
            ),
            [.scrcpy, .polling]
        )
    }

    func testKeepsPreferredLiveStreamAndRestartsFallbacks() {
        XCTAssertTrue(
            CaptureTransportPolicy.shouldKeepLiveStream(
                transport: .simulatorSurface,
                mode: .direct,
                deviceKind: .iOSSimulator
            )
        )
        XCTAssertFalse(
            CaptureTransportPolicy.shouldKeepLiveStream(
                transport: .windowStream(frameRate: 30),
                mode: .direct,
                deviceKind: .iOSSimulator
            )
        )
        XCTAssertTrue(
            CaptureTransportPolicy.shouldKeepLiveStream(
                transport: .windowStream(frameRate: 30),
                mode: .classic,
                deviceKind: .iOSSimulator
            )
        )
        XCTAssertFalse(
            CaptureTransportPolicy.shouldKeepLiveStream(
                transport: .screencap,
                mode: .direct,
                deviceKind: .androidEmulator
            )
        )
        XCTAssertTrue(
            CaptureTransportPolicy.shouldKeepLiveStream(
                transport: .emulatorGrpc(frameRate: 60),
                mode: .direct,
                deviceKind: .androidEmulator
            )
        )
    }

    func testTransportStatusLabels() {
        XCTAssertEqual(CaptureTransport.screencap.shortLabel, "Screencap")
        XCTAssertEqual(CaptureTransport.simulatorSurface.shortLabel, "Surface")
        XCTAssertEqual(
            CaptureTransport.windowStream(frameRate: 30).shortLabel,
            "Window"
        )
    }
}

final class AndroidEmulatorProtocolTests: XCTestCase {
    func testHTTP2DecoderPreservesPartialFrame() {
        let encoded = EmulatorProtobuf.dataFrame(
            streamID: 3,
            payload: Data([1, 2, 3]),
            endStream: true
        )
        let split = 7
        var decoder = HTTP2FrameDecoder()
        let first = decoder.push(Data(encoded.prefix(split)))
        XCTAssertTrue(first.isEmpty)

        let completed = decoder.push(Data(encoded.dropFirst(split)))
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].streamID, 3)
        XCTAssertEqual(completed[0].payload, Data([1, 2, 3]))
    }

    func testGrpcMessagePrefixesCompressionAndLength() {
        let message = EmulatorProtobuf.grpcMessage(Data([10, 20, 30]))
        XCTAssertEqual(Array(message.prefix(5)), [0, 0, 0, 0, 3])
        XCTAssertEqual(Array(message.dropFirst(5)), [10, 20, 30])
    }
}

@MainActor
final class AndroidEmulatorGrpcLifecycleTests: XCTestCase {
    func testMidStreamFailureStopsWorkerAndCallsFailureHandler() async throws {
        let worker = FakeEmulatorGrpcWorker()
        let failed = expectation(description: "failure forwarded")
        let stream = makeStream(worker: worker)

        let started = try await stream.start(
            serial: "emulator-5554",
            profile: .smooth,
            onFrame: { _ in },
            onFailure: { _ in failed.fulfill() }
        )
        XCTAssertTrue(started)

        worker.fail(AndroidEmulatorGrpcError.streamEnded)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(worker.isStopped)
    }

    func testCancellationDuringStartupStopsAndDoesNotDeliverStaleFrame() async {
        let worker = FakeEmulatorGrpcWorker(blocksOnStart: true)
        let staleFrame = expectation(description: "stale frame")
        staleFrame.isInverted = true
        let stream = makeStream(worker: worker)
        let task = Task {
            try await stream.start(
                serial: "emulator-5554",
                profile: .smooth,
                onFrame: { _ in staleFrame.fulfill() },
                onFailure: { _ in }
            )
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let started = try? await task.value
        XCTAssertEqual(started, false)
        XCTAssertTrue(worker.isStopped)
        worker.emitFrame()
        await fulfillment(of: [staleFrame], timeout: 0.1)
    }

    private func makeStream(
        worker: FakeEmulatorGrpcWorker
    ) -> AndroidEmulatorGrpcStream {
        AndroidEmulatorGrpcStream(
            endpointProvider: { _ in
                EmulatorGrpcEndpoint(port: 8554, token: "token")
            },
            workerFactory: { _, onFrame, onFailure in
                worker.configure(onFrame: onFrame, onFailure: onFailure)
                return worker
            }
        )
    }
}

@MainActor
final class DeviceManagerRaceTests: XCTestCase {
    func testLaunchInvalidatesStaleRefreshFailure() async {
        let device = LaunchableDevice(
            id: "test",
            source: .android,
            name: "Test",
            runtime: nil,
            state: .shutdown
        )
        let client = RacingDeviceClient(device: device)
        let manager = DeviceManager(client: client)

        manager.refreshDevices()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(manager.devices, [device])

        manager.refreshDevices()
        manager.launch(device)
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(manager.phase, .ready)
    }

    func testRefreshDuringLaunchDoesNotAbortBoot() async {
        let device = LaunchableDevice(
            id: "iphone",
            source: .iOS,
            name: "iPhone",
            runtime: "iOS 26",
            state: .shutdown
        )
        let client = SlowLaunchDeviceClient(device: device)
        let manager = DeviceManager(client: client)

        manager.refreshDevices()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(manager.devices, [device])

        manager.launch(device)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(manager.phase, .launching("iPhone"))

        manager.refreshDevices()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(manager.phase, .launching("iPhone"))

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.phase, .ready)
    }

    func testLaunchingSecondGuestKeepsFirstLaunchRunning() async {
        let first = LaunchableDevice(
            id: "first",
            source: .android,
            name: "First",
            runtime: nil,
            state: .shutdown
        )
        let second = LaunchableDevice(
            id: "second",
            source: .android,
            name: "Second",
            runtime: nil,
            state: .shutdown
        )
        let client = SlowLaunchDeviceClient(device: first, extraDevices: [second])
        let manager = DeviceManager(client: client)

        manager.refreshDevices()
        try? await Task.sleep(for: .milliseconds(20))

        manager.launch(first)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(manager.phase, .launching("First"))

        let priorFailureToken = manager.lastLaunchFailureToken
        manager.launch(second)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(manager.lastLaunchFailureToken, priorFailureToken)
        XCTAssertEqual(manager.sessionStartedGuestIDs, ["first", "second"])
        XCTAssertEqual(manager.phase, .launching("Second"))
        try? await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(manager.phase, .ready)
    }

    func testLaunchRemembersSessionGuestsUntilTaken() async {
        let device = LaunchableDevice(
            id: "pixel",
            source: .android,
            name: "Pixel",
            runtime: nil,
            state: .shutdown
        )
        let client = SlowLaunchDeviceClient(device: device)
        let manager = DeviceManager(client: client)

        manager.refreshDevices()
        try? await Task.sleep(for: .milliseconds(20))
        manager.launch(device)

        XCTAssertEqual(manager.sessionStartedGuestIDs, ["pixel"])
        let taken = manager.takeSessionStartedGuests()
        XCTAssertEqual(taken.map(\.id), ["pixel"])
        XCTAssertEqual(manager.sessionStartedGuestIDs, [])
        await manager.shutdownAwaiting(taken)
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [Value] {
        lock.withLock { values }
    }
}

private final class FakeEmulatorGrpcWorker:
    EmulatorGrpcWorking,
    @unchecked Sendable {
    private let lock = NSLock()
    private let blocksOnStart: Bool
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var onFrame: (@Sendable (CGImage) -> Void)?
    private var onFailure: (@Sendable (Error) -> Void)?
    private(set) var isStopped = false

    init(blocksOnStart: Bool = false) {
        self.blocksOnStart = blocksOnStart
    }

    func configure(
        onFrame: @escaping @Sendable (CGImage) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        lock.withLock {
            self.onFrame = onFrame
            self.onFailure = onFailure
        }
    }

    func start() async throws {
        if blocksOnStart {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if isStopped {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        startContinuation = continuation
                    }
                }
            }
        } else {
            emitFrame()
        }
    }

    func stop() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            isStopped = true
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func sendTouch(x: Int32, y: Int32, isDown: Bool) {}

    func emitFrame() {
        guard let image = Self.image else { return }
        lock.withLock { onFrame }?(image)
    }

    func fail(_ error: Error) {
        lock.withLock { onFailure }?(error)
    }

    private static let image: CGImage? = {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }()
}

private actor RacingDeviceClient: DeviceClient {
    nonisolated let source = ViewerSource.android
    private let device: LaunchableDevice
    private var listCount = 0

    init(device: LaunchableDevice) {
        self.device = device
    }

    func listDevices() async throws -> [LaunchableDevice] {
        listCount += 1
        if listCount == 1 {
            return [device]
        }
        if listCount == 2 {
            // Overlapping refresh that launch should invalidate.
            try? await Task.sleep(for: .milliseconds(100))
            throw TestError.staleRefresh
        }
        return [device]
    }

    func launch(_ device: LaunchableDevice) async throws {}

    func shutdown(_ device: LaunchableDevice) async throws {}

    private enum TestError: Error {
        case staleRefresh
    }
}

private actor SlowLaunchDeviceClient: DeviceClient {
    nonisolated let source: ViewerSource
    private let device: LaunchableDevice
    private let extraDevices: [LaunchableDevice]

    init(device: LaunchableDevice, extraDevices: [LaunchableDevice] = []) {
        self.device = device
        self.extraDevices = extraDevices
        source = device.source
    }

    func listDevices() async throws -> [LaunchableDevice] {
        [device] + extraDevices
    }

    func launch(_ device: LaunchableDevice) async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    func shutdown(_ device: LaunchableDevice) async throws {}
}
