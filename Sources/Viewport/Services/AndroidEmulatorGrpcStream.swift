import CoreGraphics
import Foundation
import Network

struct EmulatorGrpcWorkerConfiguration {
    let host: String
    let port: Int
    let authorization: String
    let maxDimension: Int
    let targetFPS: Int
}

protocol EmulatorGrpcWorking: AnyObject, Sendable {
    func start() async throws
    func stop()
    func sendTouch(x: Int32, y: Int32, isDown: Bool)
}

/// Streams RGBA frames from the Android Emulator gRPC `streamScreenshot` API.
@MainActor
final class AndroidEmulatorGrpcStream {
    typealias WorkerFactory = (
        EmulatorGrpcWorkerConfiguration,
        @escaping @Sendable (CGImage) -> Void,
        @escaping @Sendable (Error) -> Void
    ) -> any EmulatorGrpcWorking

    private var worker: (any EmulatorGrpcWorking)?
    private var onFrame: ((CGImage) -> Void)?
    private var onFailure: ((Error) -> Void)?
    private var generation = UUID()
    private let endpointProvider: @Sendable (String) -> EmulatorGrpcEndpoint?
    private let workerFactory: WorkerFactory

    init(
        endpointProvider: @escaping @Sendable (String) -> EmulatorGrpcEndpoint? = {
            AndroidEmulatorGrpcStream.endpoint(for: $0)
        },
        workerFactory: @escaping WorkerFactory = { configuration, onFrame, onFailure in
            EmulatorGrpcWorker(
                host: configuration.host,
                port: configuration.port,
                authorization: configuration.authorization,
                maxDimension: configuration.maxDimension,
                targetFPS: configuration.targetFPS,
                onFrame: onFrame,
                onFailure: onFailure
            )
        }
    ) {
        self.endpointProvider = endpointProvider
        self.workerFactory = workerFactory
    }

    var isAvailable: Bool { true }

    func start(
        serial: String,
        profile: CapturePerformanceProfile,
        onFrame: @escaping (CGImage) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws -> Bool {
        stop()
        let generation = UUID()
        self.generation = generation
        // Modern emulators require `authorization: Bearer <grpc.token>` from the
        // Studio/emulator discovery file. Without it, streamScreenshot returns
        // UNAUTHENTICATED and the pane would otherwise hang on Connecting.
        guard let endpoint = endpointProvider(serial),
              let token = endpoint.token else {
            return false
        }

        self.onFrame = onFrame
        self.onFailure = onFailure

        // Cap well below native phone resolution so RGBA frames stay manageable
        // over localhost gRPC (1080×1920×4 ≈ 8 MB/frame).
        let maxDimension = min(profile.maximumDisplayDimension ?? 1_024, 1_280)
        let firstFrame = FirstFrameGate()
        let configuration = EmulatorGrpcWorkerConfiguration(
            host: "127.0.0.1",
            port: endpoint.port,
            authorization: "Bearer \(token)",
            maxDimension: maxDimension,
            targetFPS: profile.targetFrameRate
        )
        let worker = workerFactory(configuration, { [weak self] image in
            firstFrame.fulfill()
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.onFrame?(image)
            }
        }, { [weak self] error in
            firstFrame.fail(error)
            Task { @MainActor in
                guard let self,
                      self.generation == generation,
                      self.worker != nil else { return }
                let onFailure = self.onFailure
                self.stop()
                onFailure?(error)
            }
        })
        self.worker = worker

        do {
            try await withTaskCancellationHandler {
                try await worker.start()
                try Task.checkCancellation()
                try await firstFrame.wait(seconds: 3)
                try Task.checkCancellation()
            } onCancel: {
                worker.stop()
            }
        } catch {
            worker.stop()
            if self.generation == generation {
                self.worker = nil
                self.onFrame = nil
                self.onFailure = nil
            }
            return false
        }

        guard self.generation == generation, self.worker === worker else {
            worker.stop()
            return false
        }
        return true
    }

    func stop() {
        generation = UUID()
        worker?.stop()
        worker = nil
        onFrame = nil
        onFailure = nil
    }

    func sendTouch(
        serial: String,
        deviceSize: CGSize,
        action: AndroidMotionAction,
        at normalizedPoint: CGPoint
    ) {
        guard let worker,
              deviceSize.width > 0,
              deviceSize.height > 0 else { return }
        let point = CGPoint(
            x: min(max(normalizedPoint.x, 0), 1) * deviceSize.width,
            y: min(max(normalizedPoint.y, 0), 1) * deviceSize.height
        )
        worker.sendTouch(
            x: Int32(point.x.rounded()),
            y: Int32(point.y.rounded()),
            isDown: action != .up
        )
    }

    /// Maps `emulator-5554` → gRPC 8554, `emulator-5556` → 8555, …
    nonisolated static func grpcPort(for serial: String) -> Int? {
        endpoint(for: serial)?.port
    }

    nonisolated static func endpoint(for serial: String) -> EmulatorGrpcEndpoint? {
        guard serial.hasPrefix("emulator-"),
              let console = Int(serial.dropFirst("emulator-".count)),
              console >= 5554 else {
            return nil
        }
        let fallbackPort = 8554 + (console - 5554) / 2
        if let discovered = EmulatorGrpcDiscovery.endpoint(consolePort: console) {
            return discovered
        }
        return EmulatorGrpcEndpoint(port: fallbackPort, token: nil)
    }
}

struct EmulatorGrpcEndpoint: Equatable {
    let port: Int
    let token: String?
}

enum AndroidEmulatorGrpcError: LocalizedError {
    case connectionFailed
    case protocolError(String)
    case streamEnded
    case firstFrameTimedOut

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            "Could not connect to the Android emulator gRPC port."
        case let .protocolError(message):
            "Android emulator gRPC error: \(message)"
        case .streamEnded:
            "The Android emulator gRPC stream ended."
        case .firstFrameTimedOut:
            "Timed out waiting for the first Android emulator gRPC frame."
        }
    }
}

/// Reads `grpc.port` / `grpc.token` from the emulator discovery ini.
enum EmulatorGrpcDiscovery {
    nonisolated static func endpoint(consolePort: Int) -> EmulatorGrpcEndpoint? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/TemporaryItems/avd/running",
                isDirectory: true
            )
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for file in contents
        where file.pathExtension == "ini"
            && file.lastPathComponent.hasPrefix("pid_") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            let values = parseINI(text)
            guard let serial = Int(values["port.serial"] ?? ""),
                  serial == consolePort else {
                continue
            }
            let port = Int(values["grpc.port"] ?? "")
                ?? (8554 + (consolePort - 5554) / 2)
            let token = values["grpc.token"]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let token, !token.isEmpty else {
                return EmulatorGrpcEndpoint(port: port, token: nil)
            }
            return EmulatorGrpcEndpoint(port: port, token: token)
        }
        return nil
    }

    nonisolated static func parseINI(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            values[key] = value
        }
        return values
    }
}

private final class FirstFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var error: Error?

    func fulfill() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        self.error = error
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func wait(seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if finished {
                let error = self.error
                lock.unlock()
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
                return
            }
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + seconds
            ) { [weak self] in
                self?.fail(AndroidEmulatorGrpcError.firstFrameTimedOut)
            }
        }
    }
}

private final class EmulatorGrpcWorker: EmulatorGrpcWorking, @unchecked Sendable {
    private static let maxWindow = UInt32(0x7FFF_FFFF)
    private static let defaultWindow = UInt32(65_535)

    private let host: String
    private let port: Int
    private let authorization: String
    private let maxDimension: Int
    private let targetFPS: Int
    private let onFrame: @Sendable (CGImage) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let queue = DispatchQueue(
        label: "com.longden.viewport.emulator-grpc",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var connection: NWConnection?
    private var stopped = false
    private var receiveBuffer = Data()
    private var settingsAcked = false
    private var streamStarted = false
    private let frameDelivery = LatestValueDelivery<CGImage>()
    private var nextStreamID: UInt32 = 1
    private var screenshotStreamID: UInt32 = 1
    private var decoder = HTTP2FrameDecoder()
    private var grpcBuffer = Data()

    init(
        host: String,
        port: Int,
        authorization: String,
        maxDimension: Int,
        targetFPS: Int,
        onFrame: @escaping @Sendable (CGImage) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.host = host
        self.port = port
        self.authorization = authorization
        self.maxDimension = maxDimension
        self.targetFPS = targetFPS
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ResumeGate: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func claim() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
            }
            let gate = ResumeGate()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    do {
                        try self.beginHTTP2()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case let .failed(error):
                    if gate.claim() {
                        continuation.resume(throwing: error)
                    } else {
                        self.fail(error)
                    }
                case .cancelled:
                    if gate.claim() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        receiveLoop()
    }

    func stop() {
        lock.lock()
        stopped = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        frameDelivery.clear()
        connection?.cancel()
    }

    func sendTouch(x: Int32, y: Int32, isDown: Bool) {
        queue.async { [weak self] in
            self?.sendTouchOnQueue(x: x, y: y, isDown: isDown)
        }
    }

    private func sendTouchOnQueue(x: Int32, y: Int32, isDown: Bool) {
        lock.lock()
        guard !stopped, settingsAcked, let connection else {
            lock.unlock()
            return
        }
        let streamID = nextStreamID
        nextStreamID += 2
        lock.unlock()

        let touch = EmulatorProtobuf.touchEvent(x: x, y: y, identifier: 0, pressed: isDown)
        let message = EmulatorProtobuf.grpcMessage(touch)
        let headers = EmulatorProtobuf.headersFrame(
            streamID: streamID,
            path: "/android.emulation.control.EmulatorController/sendTouch",
            authorization: authorization,
            endStream: false
        )
        let data = EmulatorProtobuf.dataFrame(
            streamID: streamID,
            payload: message,
            endStream: true
        )
        connection.send(
            content: headers + data,
            completion: .contentProcessed { _ in }
        )
    }

    private func beginHTTP2() throws {
        guard let connection else { throw AndroidEmulatorGrpcError.connectionFailed }
        var preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        // Raise stream windows; connection window must still be bumped with
        // WINDOW_UPDATE on stream 0 (SETTINGS_INITIAL_WINDOW_SIZE does not).
        preface.append(
            EmulatorProtobuf.settingsFrame(
                flags: 0,
                initialWindowSize: Self.maxWindow
            )
        )
        preface.append(
            EmulatorProtobuf.windowUpdateFrame(
                streamID: 0,
                increment: Self.maxWindow - Self.defaultWindow
            )
        )
        connection.send(content: preface, completion: .contentProcessed { _ in })
    }

    private func startScreenshotStreamIfNeeded() {
        lock.lock()
        guard !stopped, settingsAcked, !streamStarted, let connection else {
            lock.unlock()
            return
        }
        streamStarted = true
        screenshotStreamID = nextStreamID
        nextStreamID += 2
        let streamID = screenshotStreamID
        lock.unlock()

        let format = EmulatorProtobuf.imageFormat(
            rgba: true,
            width: UInt32(maxDimension),
            height: UInt32(maxDimension)
        )
        let message = EmulatorProtobuf.grpcMessage(format)
        let headers = EmulatorProtobuf.headersFrame(
            streamID: streamID,
            path: "/android.emulation.control.EmulatorController/streamScreenshot",
            authorization: authorization,
            endStream: false
        )
        let data = EmulatorProtobuf.dataFrame(
            streamID: streamID,
            payload: message,
            endStream: true
        )
        connection.send(
            content: headers + data,
            completion: .contentProcessed { _ in }
        )
    }

    private func receiveLoop() {
        lock.lock()
        guard !stopped, let connection else {
            lock.unlock()
            return
        }
        lock.unlock()

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(error)
                return
            }
            if let content, !content.isEmpty {
                self.consume(content)
            }
            if isComplete {
                self.fail(AndroidEmulatorGrpcError.streamEnded)
                return
            }
            self.receiveLoop()
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)
        let buffer = receiveBuffer
        receiveBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        let (frames, remainder) = decoder.push(buffer)
        lock.lock()
        receiveBuffer = remainder
        lock.unlock()

        for frame in frames {
            handle(frame)
        }
    }

    private func handle(_ frame: HTTP2Frame) {
        switch frame.type {
        case .settings:
            if frame.flags & 0x1 == 0 {
                connection?.send(
                    content: EmulatorProtobuf.settingsFrame(flags: 0x1),
                    completion: .contentProcessed { _ in }
                )
                lock.lock()
                settingsAcked = true
                lock.unlock()
                startScreenshotStreamIfNeeded()
            }
        case .windowUpdate:
            break
        case .ping:
            if frame.flags & 0x1 == 0 {
                var ack = frame
                ack.flags |= 0x1
                connection?.send(
                    content: EmulatorProtobuf.encodeFrame(ack),
                    completion: .contentProcessed { _ in }
                )
            }
        case .data:
            // Always refund flow-control credit for the wire length of DATA,
            // including padding. Without this the peer stalls after ~64 KB.
            let credited = UInt32(frame.length)
            if credited > 0 {
                connection?.send(
                    content: EmulatorProtobuf.windowUpdateFrame(streamID: 0, increment: credited)
                        + EmulatorProtobuf.windowUpdateFrame(
                            streamID: frame.streamID,
                            increment: credited
                        ),
                    completion: .contentProcessed { _ in }
                )
            }
            guard frame.streamID == screenshotStreamID else { return }
            let payload = Self.stripPadding(from: frame)
            handleGRPCData(payload)
            if frame.flags & 0x1 != 0 {
                fail(AndroidEmulatorGrpcError.streamEnded)
            }
        case .headers:
            if frame.streamID == screenshotStreamID, frame.flags & 0x1 != 0 {
                fail(AndroidEmulatorGrpcError.streamEnded)
            }
        case .rstStream, .goAway:
            fail(AndroidEmulatorGrpcError.streamEnded)
        default:
            break
        }
    }

    private static func stripPadding(from frame: HTTP2Frame) -> Data {
        guard frame.flags & 0x8 != 0, !frame.payload.isEmpty else {
            return frame.payload
        }
        let padLength = Int(frame.payload[frame.payload.startIndex])
        let contentStart = frame.payload.startIndex + 1
        let contentEnd = frame.payload.endIndex - padLength
        guard contentEnd >= contentStart else { return Data() }
        return frame.payload.subdata(in: contentStart..<contentEnd)
    }

    private func handleGRPCData(_ payload: Data) {
        grpcBuffer.append(payload)
        while grpcBuffer.count >= 5 {
            let compressed = grpcBuffer[grpcBuffer.startIndex]
            let length = Int(grpcBuffer[grpcBuffer.startIndex + 1]) << 24
                | Int(grpcBuffer[grpcBuffer.startIndex + 2]) << 16
                | Int(grpcBuffer[grpcBuffer.startIndex + 3]) << 8
                | Int(grpcBuffer[grpcBuffer.startIndex + 4])
            guard compressed == 0 else {
                fail(AndroidEmulatorGrpcError.protocolError("Compressed gRPC frames are unsupported"))
                return
            }
            guard length >= 0, length < 32 * 1024 * 1024 else {
                fail(AndroidEmulatorGrpcError.protocolError("Invalid gRPC message length"))
                return
            }
            guard grpcBuffer.count >= 5 + length else { return }
            let messageStart = grpcBuffer.startIndex + 5
            let message = grpcBuffer.subdata(in: messageStart..<(messageStart + length))
            grpcBuffer.removeSubrange(grpcBuffer.startIndex..<(messageStart + length))
            if let image = EmulatorProtobuf.parseImage(message) {
                frameDelivery.submit(image, deliver: onFrame)
            }
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
        if !alreadyStopped {
            onFailure(error)
        }
    }
}
