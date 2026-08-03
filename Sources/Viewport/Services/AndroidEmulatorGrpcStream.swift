import CoreGraphics
import Foundation
import Network

/// Streams RGBA frames from the Android Emulator gRPC `streamScreenshot` API.
@MainActor
final class AndroidEmulatorGrpcStream {
    private var worker: EmulatorGrpcWorker?
    private var onFrame: ((CGImage) -> Void)?
    private var onFailure: ((Error) -> Void)?

    var isAvailable: Bool { true }

    func start(
        serial: String,
        profile: CapturePerformanceProfile,
        onFrame: @escaping (CGImage) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws -> Bool {
        stop()
        // Modern emulators require `authorization: Bearer <grpc.token>` from the
        // Studio/emulator discovery file. Without it, streamScreenshot returns
        // UNAUTHENTICATED and the pane would otherwise hang on Connecting.
        guard let endpoint = Self.endpoint(for: serial),
              let token = endpoint.token else {
            return false
        }

        self.onFrame = onFrame
        self.onFailure = onFailure

        // Cap well below native phone resolution so RGBA frames stay manageable
        // over localhost gRPC (1080×1920×4 ≈ 8 MB/frame).
        let maxDimension = min(profile.maximumDisplayDimension ?? 1_024, 1_280)
        let firstFrame = FirstFrameGate()
        let worker = EmulatorGrpcWorker(
            host: "127.0.0.1",
            port: endpoint.port,
            authorization: "Bearer \(token)",
            maxDimension: maxDimension,
            targetFPS: profile.targetFrameRate
        ) { [weak self] image in
            firstFrame.fulfill()
            Task { @MainActor in
                self?.onFrame?(image)
            }
        } onFailure: { [weak self] error in
            firstFrame.fail(error)
            Task { @MainActor in
                guard let self else { return }
                // Only surface mid-session failures once we have claimed success.
                guard self.worker != nil else { return }
                self.stop()
                self.onFailure?(error)
            }
        }

        do {
            try await worker.start()
            try await firstFrame.wait(seconds: 3)
        } catch {
            worker.stop()
            self.onFrame = nil
            self.onFailure = nil
            return false
        }

        self.worker = worker
        return true
    }

    func stop() {
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

private final class EmulatorGrpcWorker: @unchecked Sendable {
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
    private let frameDelivery = LatestCGImageDelivery()
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

private struct HTTP2Frame {
    enum FrameType: UInt8 {
        case data = 0
        case headers = 1
        case priority = 2
        case rstStream = 3
        case settings = 4
        case pushPromise = 5
        case ping = 6
        case goAway = 7
        case windowUpdate = 8
        case continuation = 9
    }

    var length: Int
    var type: FrameType
    var flags: UInt8
    var streamID: UInt32
    var payload: Data
}

private struct HTTP2FrameDecoder {
    func push(_ data: Data) -> (frames: [HTTP2Frame], remainder: Data) {
        var buffer = data
        var frames: [HTTP2Frame] = []
        while buffer.count >= 9 {
            let length = Int(buffer[buffer.startIndex]) << 16
                | Int(buffer[buffer.startIndex + 1]) << 8
                | Int(buffer[buffer.startIndex + 2])
            guard buffer.count >= 9 + length else { break }
            let typeRaw = buffer[buffer.startIndex + 3]
            let flags = buffer[buffer.startIndex + 4]
            let streamID = UInt32(buffer[buffer.startIndex + 5] & 0x7F) << 24
                | UInt32(buffer[buffer.startIndex + 6]) << 16
                | UInt32(buffer[buffer.startIndex + 7]) << 8
                | UInt32(buffer[buffer.startIndex + 8])
            let payloadStart = buffer.startIndex + 9
            let payload = buffer.subdata(in: payloadStart..<(payloadStart + length))
            buffer.removeSubrange(buffer.startIndex..<(payloadStart + length))
            guard let type = HTTP2Frame.FrameType(rawValue: typeRaw) else { continue }
            frames.append(
                HTTP2Frame(
                    length: length,
                    type: type,
                    flags: flags,
                    streamID: streamID,
                    payload: payload
                )
            )
        }
        return (frames, buffer)
    }
}

private enum EmulatorProtobuf {
    static func imageFormat(rgba: Bool, width: UInt32, height: UInt32) -> Data {
        var data = Data()
        // format = 1 (RGBA8888)
        data.append(contentsOf: encodeKey(field: 1, wire: 0))
        data.append(contentsOf: encodeVarint(UInt64(rgba ? 1 : 0)))
        if width > 0 {
            data.append(contentsOf: encodeKey(field: 3, wire: 0))
            data.append(contentsOf: encodeVarint(UInt64(width)))
        }
        if height > 0 {
            data.append(contentsOf: encodeKey(field: 4, wire: 0))
            data.append(contentsOf: encodeVarint(UInt64(height)))
        }
        return data
    }

    static func touchEvent(x: Int32, y: Int32, identifier: Int32, pressed: Bool) -> Data {
        var touch = Data()
        touch.append(contentsOf: encodeKey(field: 1, wire: 0))
        touch.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(x))))
        touch.append(contentsOf: encodeKey(field: 2, wire: 0))
        touch.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(y))))
        touch.append(contentsOf: encodeKey(field: 3, wire: 0))
        touch.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(identifier))))
        touch.append(contentsOf: encodeKey(field: 4, wire: 0))
        touch.append(contentsOf: encodeVarint(pressed ? 1 : 0))

        var event = Data()
        event.append(contentsOf: encodeKey(field: 1, wire: 2))
        event.append(contentsOf: encodeVarint(UInt64(touch.count)))
        event.append(touch)
        return event
    }

    static func grpcMessage(_ message: Data) -> Data {
        var framed = Data(count: 5 + message.count)
        framed[0] = 0
        let length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: length) { bytes in
            for index in 0..<4 {
                framed[1 + index] = bytes[index]
            }
        }
        framed.replaceSubrange(5..<(5 + message.count), with: message)
        return framed
    }

    static func settingsFrame(flags: UInt8, initialWindowSize: UInt32? = nil) -> Data {
        var payload = Data()
        if let initialWindowSize {
            // SETTINGS_INITIAL_WINDOW_SIZE = 0x4
            payload.append(contentsOf: [
                0x00, 0x04,
                UInt8((initialWindowSize >> 24) & 0xFF),
                UInt8((initialWindowSize >> 16) & 0xFF),
                UInt8((initialWindowSize >> 8) & 0xFF),
                UInt8(initialWindowSize & 0xFF)
            ])
        }
        return encodeFrame(
            HTTP2Frame(
                length: payload.count,
                type: .settings,
                flags: flags,
                streamID: 0,
                payload: payload
            )
        )
    }

    static func windowUpdateFrame(streamID: UInt32, increment: UInt32) -> Data {
        var payload = Data(count: 4)
        payload[0] = UInt8((increment >> 24) & 0x7F)
        payload[1] = UInt8((increment >> 16) & 0xFF)
        payload[2] = UInt8((increment >> 8) & 0xFF)
        payload[3] = UInt8(increment & 0xFF)
        return encodeFrame(
            HTTP2Frame(
                length: 4,
                type: .windowUpdate,
                flags: 0,
                streamID: streamID,
                payload: payload
            )
        )
    }

    static func headersFrame(
        streamID: UInt32,
        path: String,
        authorization: String,
        endStream: Bool
    ) -> Data {
        var payload = Data()
        payload.append(literalHeader(":method", "POST"))
        payload.append(literalHeader(":scheme", "http"))
        payload.append(literalHeader(":path", path))
        payload.append(literalHeader(":authority", "127.0.0.1"))
        payload.append(literalHeader("content-type", "application/grpc"))
        payload.append(literalHeader("te", "trailers"))
        payload.append(literalHeader("authorization", authorization))
        payload.append(literalHeader("user-agent", "viewport-grpc/1.0"))

        var flags: UInt8 = 0x4 // END_HEADERS
        if endStream { flags |= 0x1 }
        return encodeFrame(
            HTTP2Frame(
                length: payload.count,
                type: .headers,
                flags: flags,
                streamID: streamID,
                payload: payload
            )
        )
    }

    static func dataFrame(streamID: UInt32, payload: Data, endStream: Bool) -> Data {
        encodeFrame(
            HTTP2Frame(
                length: payload.count,
                type: .data,
                flags: endStream ? 0x1 : 0,
                streamID: streamID,
                payload: payload
            )
        )
    }

    static func encodeFrame(_ frame: HTTP2Frame) -> Data {
        var data = Data(count: 9 + frame.payload.count)
        data[0] = UInt8((frame.payload.count >> 16) & 0xFF)
        data[1] = UInt8((frame.payload.count >> 8) & 0xFF)
        data[2] = UInt8(frame.payload.count & 0xFF)
        data[3] = frame.type.rawValue
        data[4] = frame.flags
        data[5] = UInt8((frame.streamID >> 24) & 0x7F)
        data[6] = UInt8((frame.streamID >> 16) & 0xFF)
        data[7] = UInt8((frame.streamID >> 8) & 0xFF)
        data[8] = UInt8(frame.streamID & 0xFF)
        data.replaceSubrange(9..<(9 + frame.payload.count), with: frame.payload)
        return data
    }

    static func parseImage(_ message: Data) -> CGImage? {
        var width: UInt32 = 0
        var height: UInt32 = 0
        var pixels = Data()
        var index = message.startIndex
        while index < message.endIndex {
            let (key, next) = readVarint(message, at: index)
            index = next
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            switch (field, wire) {
            case (1, 2): // nested ImageFormat
                let (length, afterLength) = readVarint(message, at: index)
                index = afterLength
                let end = index + Int(length)
                guard end <= message.endIndex else { return nil }
                parseImageFormat(
                    message.subdata(in: index..<end),
                    width: &width,
                    height: &height
                )
                index = end
            case (2, 0):
                let (value, after) = readVarint(message, at: index)
                width = UInt32(value)
                index = after
            case (3, 0):
                let (value, after) = readVarint(message, at: index)
                height = UInt32(value)
                index = after
            case (4, 2):
                let (length, afterLength) = readVarint(message, at: index)
                index = afterLength
                let end = index + Int(length)
                guard end <= message.endIndex else { return nil }
                pixels = message.subdata(in: index..<end)
                index = end
            default:
                index = skip(message, at: index, wire: wire)
            }
        }

        guard width > 0, height > 0, !pixels.isEmpty else { return nil }
        return rgbaImage(pixels: pixels, width: Int(width), height: Int(height))
    }

    private static func parseImageFormat(
        _ message: Data,
        width: inout UInt32,
        height: inout UInt32
    ) {
        var index = message.startIndex
        while index < message.endIndex {
            let (key, next) = readVarint(message, at: index)
            index = next
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            switch (field, wire) {
            case (3, 0):
                let (value, after) = readVarint(message, at: index)
                width = UInt32(value)
                index = after
            case (4, 0):
                let (value, after) = readVarint(message, at: index)
                height = UInt32(value)
                index = after
            default:
                index = skip(message, at: index, wire: wire)
            }
        }
    }

    private static func rgbaImage(
        pixels: Data,
        width: Int,
        height: Int
    ) -> CGImage? {
        let bytesPerRow = width * 4
        guard pixels.count >= bytesPerRow * height else { return nil }

        guard let provider = CGDataProvider(data: pixels as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func literalHeader(_ name: String, _ value: String) -> Data {
        var data = Data()
        // Literal Header Field without Indexing — New Name (0x00)
        data.append(0x00)
        let nameData = Data(name.utf8)
        data.append(contentsOf: encodeVarint(UInt64(nameData.count)))
        data.append(nameData)
        let valueData = Data(value.utf8)
        data.append(contentsOf: encodeVarint(UInt64(valueData.count)))
        data.append(valueData)
        return data
    }

    private static func encodeKey(field: UInt32, wire: UInt32) -> [UInt8] {
        encodeVarint(UInt64((field << 3) | wire))
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private static func readVarint(_ data: Data, at start: Data.Index) -> (UInt64, Data.Index) {
        var result: UInt64 = 0
        var shift = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
        }
        return (result, index)
    }

    private static func skip(_ data: Data, at start: Data.Index, wire: Int) -> Data.Index {
        switch wire {
        case 0:
            return readVarint(data, at: start).1
        case 1:
            return min(start + 8, data.endIndex)
        case 2:
            let (length, next) = readVarint(data, at: start)
            return min(next + Int(length), data.endIndex)
        case 5:
            return min(start + 4, data.endIndex)
        default:
            return data.endIndex
        }
    }
}

private final class LatestCGImageDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGImage?
    private var deliveryIsScheduled = false

    func submit(
        _ image: CGImage,
        deliver: @escaping @Sendable (CGImage) -> Void
    ) {
        lock.lock()
        latest = image
        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.deliverLatest(deliver)
        }
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    private func deliverLatest(
        _ deliver: @escaping @Sendable (CGImage) -> Void
    ) {
        lock.lock()
        let image = latest
        latest = nil
        lock.unlock()
        if let image { deliver(image) }

        lock.lock()
        let hasAnother = latest != nil
        if !hasAnother { deliveryIsScheduled = false }
        lock.unlock()
        if hasAnother {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.deliverLatest(deliver)
            }
        }
    }
}
