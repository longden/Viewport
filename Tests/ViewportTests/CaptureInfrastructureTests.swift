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
                "DEVELOPER_DIR": "/custom/Xcode/Developer",
                "PATH": ""
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        XCTAssertEqual(locator.androidSDK.path, "/custom/android")
        XCTAssertEqual(
            locator.developerDirectory.path,
            "/custom/Xcode/Developer"
        )
        XCTAssertEqual(
            locator.developerEnvironment["DEVELOPER_DIR"],
            "/custom/Xcode/Developer"
        )
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

    func testClassicSimulatorSkipsPrivateSurface() {
        XCTAssertEqual(
            CaptureTransportPolicy.strategies(
                mode: .classic,
                deviceKind: .iOSSimulator
            ),
            [.hostWindow, .polling]
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
        let first = HTTP2FrameDecoder().push(encoded.prefix(split))
        XCTAssertTrue(first.frames.isEmpty)
        XCTAssertEqual(first.remainder.count, split)

        let completed = HTTP2FrameDecoder().push(
            first.remainder + encoded.dropFirst(split)
        )
        XCTAssertEqual(completed.frames.count, 1)
        XCTAssertEqual(completed.frames[0].streamID, 3)
        XCTAssertEqual(completed.frames[0].payload, Data([1, 2, 3]))
        XCTAssertTrue(completed.remainder.isEmpty)
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
        try? await Task.sleep(for: .milliseconds(100))
        throw TestError.staleRefresh
    }

    func launch(_ device: LaunchableDevice) async throws {}

    private enum TestError: Error {
        case staleRefresh
    }
}
