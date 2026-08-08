import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Low-latency Android device video backed by scrcpy's MediaCodec stream.
/// ADB only installs the temporary server and opens the tunnel; frames and
/// touch events ride persistent sockets (video + control), not per-event
/// `adb shell` processes.
@MainActor
final class ScrcpyDeviceStream {
    private let runner = CommandRunner()
    // Cleared from `stop()`, which must be callable from nonisolated `deinit`.
    private nonisolated(unsafe) var worker: ScrcpyStreamWorker?
    private nonisolated(unsafe) var forwardedPort: Int?
    private nonisolated(unsafe) var adb: URL?
    private nonisolated(unsafe) var serial: String?

    var isAvailable: Bool {
        ScrcpyInstallation.locate() != nil
    }

    /// True once the control socket is connected. Touch also needs a known
    /// video session size (see `hasTouchControl`).
    var hasControlConnection: Bool {
        worker?.hasControlConnection == true
    }

    /// Ready for touch injects: control socket up and session size known.
    var hasTouchControl: Bool {
        worker?.hasTouchControl == true
    }

    /// Injects a touch over scrcpy's control socket. No-op until control is up.
    /// Coordinates are mapped into the server's announced video session size:
    /// the server drops any event whose embedded screen size differs from the
    /// current video size (e.g. `wm size` 1008x2244 vs the encoder's 1008x2240
    /// after rounding to a multiple of 8).
    func sendTouch(action: AndroidMotionAction, at normalizedPoint: CGPoint) {
        worker?.sendTouch(action: action, at: normalizedPoint)
    }

    /// Injects an Android keycode down+up over the control socket.
    @discardableResult
    func sendKeycode(_ keycode: Int32, metastate: UInt32 = 0) -> Bool {
        guard let worker, worker.hasControlConnection else { return false }
        worker.sendControl(
            ScrcpyControlMessage.injectKeycode(
                action: 0,
                keycode: keycode,
                metastate: metastate
            )
        )
        worker.sendControl(
            ScrcpyControlMessage.injectKeycode(
                action: 1,
                keycode: keycode,
                metastate: metastate
            )
        )
        return true
    }

    /// Injects UTF-8 text over the control socket.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard let worker, worker.hasControlConnection,
              !text.isEmpty else { return false }
        worker.sendControl(ScrcpyControlMessage.injectText(text))
        return true
    }

    func start(
        serial: String,
        profile: CapturePerformanceProfile,
        onFrame: @escaping @MainActor @Sendable (CVPixelBuffer) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) async throws -> Bool {
        await stopAndWait()
        guard let installation = ScrcpyInstallation.locate() else {
            return false
        }

        let adb = installation.adb
        let remoteServer = "/data/local/tmp/viewport-scrcpy-server.jar"
        let push = try await runner.run(
            executable: adb,
            arguments: [
                "-s", serial, "push", installation.server.path, remoteServer
            ],
            timeout: 8
        )
        guard push.exitCode == 0 else {
            throw ScrcpyStreamError.commandFailed(
                push.standardError.isEmpty
                    ? push.standardOutput
                    : push.standardError
            )
        }

        let streamID = Self.streamID(for: serial)
        await removeStaleForwards(
            adb: adb,
            serial: serial,
            streamID: streamID
        )
        let forward = try await runner.run(
            executable: adb,
            arguments: [
                "-s", serial,
                "forward", "tcp:0", "localabstract:scrcpy_\(streamID)"
            ],
            timeout: 3
        )
        guard forward.exitCode == 0,
              let port = Int(
                forward.standardOutput.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ) else {
            throw ScrcpyStreamError.commandFailed(
                forward.standardError.isEmpty
                    ? forward.standardOutput
                    : forward.standardError
            )
        }

        let maximumDimension = profile.maximumDisplayDimension ?? 2_800
        let process = Process()
        process.executableURL = adb
        process.arguments = [
            "-s", serial,
            "shell",
            "CLASSPATH=\(remoteServer)",
            "app_process", "/", "com.genymobile.scrcpy.Server",
            installation.version,
            "scid=\(streamID)",
            "log_level=warn",
            "audio=false",
            "control=true",
            "cleanup=true",
            "tunnel_forward=true",
            "send_device_meta=false",
            // Required with adb forward: the server writes 0x00 on the first
            // socket so the client can detect the real accept (adb otherwise
            // accepts early and EOF's). Viewport reads that byte before codec.
            "send_dummy_byte=true",
            "video_codec=h264",
            "max_size=\(maximumDimension)",
            "max_fps=\(profile.targetFrameRate)",
            "video_bit_rate=\(profile.scrcpyVideoBitRate)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            await Self.removeForward(adb: adb, serial: serial, port: port)
            throw ScrcpyStreamError.failedToLaunch(error.localizedDescription)
        }

        let worker = ScrcpyStreamWorker(
            process: process,
            port: port,
            onFrame: onFrame,
            onFailure: onFailure
        )
        self.worker = worker
        self.forwardedPort = port
        self.adb = adb
        self.serial = serial
        worker.start()
        return true
    }

    nonisolated func stop() {
        let worker = self.worker
        self.worker = nil
        let adb = self.adb
        let serial = self.serial
        let forwardedPort = self.forwardedPort
        self.adb = nil
        self.serial = nil
        self.forwardedPort = nil

        worker?.requestStop()
        Task {
            await worker?.waitUntilFinished()
            if let adb, let serial, let forwardedPort {
                await Self.removeForward(
                    adb: adb,
                    serial: serial,
                    port: forwardedPort
                )
            }
        }
    }

    private func stopAndWait() async {
        let worker = self.worker
        self.worker = nil
        let adb = self.adb
        let serial = self.serial
        let forwardedPort = self.forwardedPort
        self.adb = nil
        self.serial = nil
        self.forwardedPort = nil

        worker?.requestStop()
        await worker?.waitUntilFinished()
        if let adb, let serial, let forwardedPort {
            await Self.removeForward(
                adb: adb,
                serial: serial,
                port: forwardedPort
            )
        }
    }

    private nonisolated static func removeForward(
        adb: URL,
        serial: String,
        port: Int
    ) async {
        _ = try? await CommandRunner().run(
            executable: adb,
            arguments: [
                "-s", serial, "forward", "--remove", "tcp:\(port)"
            ],
            timeout: 2
        )
    }

    private func removeStaleForwards(
        adb: URL,
        serial: String,
        streamID: String
    ) async {
        guard let result = try? await runner.run(
            executable: adb,
            arguments: ["forward", "--list"],
            timeout: 2
        ), result.exitCode == 0 else { return }

        let remote = "localabstract:scrcpy_\(streamID)"
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  fields[0] == serial,
                  fields[2] == remote,
                  fields[1].hasPrefix("tcp:") else { continue }
            _ = try? await runner.run(
                executable: adb,
                arguments: [
                    "-s", serial, "forward", "--remove", String(fields[1])
                ],
                timeout: 2
            )
        }
    }

    private static func streamID(for serial: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in "viewport:\(serial)".utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        // scrcpy reserves the top bit, so its SCID is a positive 31-bit value.
        return String(format: "%08x", hash & 0x7FFF_FFFF)
    }
}

private struct ScrcpyInstallation {
    let adb: URL
    let server: URL
    let version: String

    static func locate() -> ScrcpyInstallation? {
        let toolchains = ToolchainLocator()
        let environment = toolchains.environment
        guard let adb = toolchains.adb, let scrcpy = toolchains.scrcpy else {
            return nil
        }

        let explicitServer = environment["SCRCPY_SERVER_PATH"].map {
            URL(fileURLWithPath: $0)
        }
        let prefix = scrcpy
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            explicitServer,
            prefix.appendingPathComponent("opt/scrcpy/share/scrcpy/scrcpy-server"),
            prefix.appendingPathComponent("share/scrcpy/scrcpy-server"),
            URL(fileURLWithPath: "/opt/homebrew/opt/scrcpy/share/scrcpy/scrcpy-server"),
            URL(fileURLWithPath: "/usr/local/opt/scrcpy/share/scrcpy/scrcpy-server")
        ].compactMap { $0 }
        guard let server = candidates.first(where: {
            FileManager.default.isReadableFile(atPath: $0.path)
        }),
        let version = version(fromServerURL: server, scrcpyBinary: scrcpy) else {
            return nil
        }

        return ScrcpyInstallation(adb: adb, server: server, version: version)
    }

    /// Homebrew's stable `opt` symlink resolves into
    /// `Cellar/scrcpy/<version>/share/scrcpy/scrcpy-server`.
    private static func version(
        fromServerURL server: URL,
        scrcpyBinary: URL
    ) -> String? {
        if let configured = ProcessInfo.processInfo.environment[
            "SCRCPY_SERVER_VERSION"
        ], configured.first?.isNumber == true {
            return configured
        }
        let resolved = server.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        for index in components.indices where components[index] == "Cellar" {
            guard components.indices.contains(index + 2),
                  components[index + 1] == "scrcpy" else { continue }
            let version = components[index + 2]
            if version.first?.isNumber == true { return version }
        }
        return version(fromBinary: scrcpyBinary)
    }

    private static func version(fromBinary scrcpy: URL) -> String? {
        let process = Process()
        process.executableURL = scrcpy
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard let match = output.range(
            of: #"\d+\.\d+(?:\.\d+)?"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(output[match])
    }
}

enum ScrcpyStreamError: LocalizedError {
    case commandFailed(String)
    case failedToLaunch(String)
    case connectionFailed
    case streamEnded
    case unsupportedCodec(UInt32)
    case malformedPacket
    case decoderFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            "Could not prepare the fast Android stream: \(message)"
        case let .failedToLaunch(message):
            "Could not start scrcpy: \(message)"
        case .connectionFailed:
            "Could not connect to the scrcpy video stream."
        case .streamEnded:
            "The scrcpy video stream ended."
        case let .unsupportedCodec(codec):
            "scrcpy returned unsupported video codec 0x\(String(codec, radix: 16))."
        case .malformedPacket:
            "scrcpy returned malformed video data."
        case let .decoderFailed(status):
            "The H.264 decoder failed with status \(status)."
        }
    }
}

struct ScrcpyVideoPacketHeader: Equatable {
    enum Kind: Equatable {
        case session(width: Int, height: Int)
        case media(size: Int, presentationTime: UInt64, isConfig: Bool, isKey: Bool)
    }

    let kind: Kind

    static func parse(_ data: Data) throws -> ScrcpyVideoPacketHeader {
        guard data.count == 12 else { throw ScrcpyStreamError.malformedPacket }
        if data[data.startIndex] & 0x80 != 0 {
            let width = Int(data.uint32BE(at: 4))
            let height = Int(data.uint32BE(at: 8))
            guard width > 0, height > 0 else {
                throw ScrcpyStreamError.malformedPacket
            }
            return ScrcpyVideoPacketHeader(
                kind: .session(width: width, height: height)
            )
        }

        let encodedPTS = data.uint64BE(at: 0)
        let size = Int(data.uint32BE(at: 8))
        guard size > 0, size <= 64 * 1_024 * 1_024 else {
            throw ScrcpyStreamError.malformedPacket
        }
        return ScrcpyVideoPacketHeader(
            kind: .media(
                size: size,
                presentationTime: encodedPTS & ((UInt64(1) << 61) - 1),
                isConfig: encodedPTS & (UInt64(1) << 62) != 0,
                isKey: encodedPTS & (UInt64(1) << 61) != 0
            )
        )
    }
}

/// Binary control messages matching scrcpy's `SC_CONTROL_MSG_TYPE_*` wire format.
enum ScrcpyControlMessage {
    /// `SC_CONTROL_MSG_TYPE_INJECT_KEYCODE`
    static let injectKeycodeType: UInt8 = 0
    /// `SC_CONTROL_MSG_TYPE_INJECT_TEXT`
    static let injectTextType: UInt8 = 1
    /// `SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT`
    static let injectTouchType: UInt8 = 2
    /// `SC_POINTER_ID_GENERIC_FINGER` (`UINT64_C(-2)`)
    static let genericFingerPointerID = UInt64(bitPattern: -2)

    /// Maps a normalized point into the video session's pixel space, clamped
    /// to valid coordinates (the server rejects points outside the frame).
    static func sessionPoint(
        _ normalizedPoint: CGPoint,
        width: UInt16,
        height: UInt16
    ) -> (x: Int32, y: Int32) {
        let x = (min(max(normalizedPoint.x, 0), 1) * CGFloat(width)).rounded()
        let y = (min(max(normalizedPoint.y, 0), 1) * CGFloat(height)).rounded()
        return (
            x: min(Int32(x), Int32(width) - 1),
            y: min(Int32(y), Int32(height) - 1)
        )
    }

    static func injectKeycode(
        action: UInt8,
        keycode: Int32,
        repeatCount: UInt32 = 0,
        metastate: UInt32 = 0
    ) -> Data {
        var data = Data(capacity: 14)
        data.append(injectKeycodeType)
        data.append(action)
        data.appendBE(UInt32(bitPattern: keycode))
        data.appendBE(repeatCount)
        data.appendBE(metastate)
        return data
    }

    static func injectText(_ text: String) -> Data {
        let utf8 = Array(text.utf8.prefix(300))
        var data = Data(capacity: 5 + utf8.count)
        data.append(injectTextType)
        data.appendBE(UInt32(utf8.count))
        data.append(contentsOf: utf8)
        return data
    }

    static func injectTouch(
        action: AndroidMotionAction,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16
    ) -> Data {
        var data = Data(capacity: 32)
        data.append(injectTouchType)
        data.append(action.androidMotionEventAction)
        data.appendBE(genericFingerPointerID)
        data.appendBE(UInt32(bitPattern: x))
        data.appendBE(UInt32(bitPattern: y))
        data.appendBE(screenWidth)
        data.appendBE(screenHeight)
        // Fixed-point u16: 0xFFFF == 1.0 pressure while the finger is down.
        data.appendBE(action == .up ? UInt16(0) : UInt16(0xFFFF))
        data.appendBE(UInt32(0)) // actionButton
        data.appendBE(UInt32(0)) // buttons
        return data
    }
}

extension AndroidMotionAction {
    /// Android `AMOTION_EVENT_ACTION_*` values expected by scrcpy.
    var androidMotionEventAction: UInt8 {
        switch self {
        case .down: 0
        case .up: 1
        case .move: 2
        }
    }
}

private final class ScrcpyStreamWorker: @unchecked Sendable {
    private let process: Process
    private let port: Int
    private let onFrame: @MainActor @Sendable (CVPixelBuffer) -> Void
    private let onFailure: @MainActor @Sendable (Error) -> Void
    private let frameDelivery = LatestValueDelivery<CVPixelBuffer>()
    private let lock = NSLock()
    private let finishedGroup = DispatchGroup()
    private var videoSocketDescriptor: Int32 = -1
    private var controlSocketDescriptor: Int32 = -1
    private var stopped = false
    private var hasStarted = false
    /// Video size announced by the server; updated on rotation. Touch events
    /// must embed exactly this size or the server silently drops them.
    private var sessionWidth: UInt16 = 0
    private var sessionHeight: UInt16 = 0

    init(
        process: Process,
        port: Int,
        onFrame: @escaping @MainActor @Sendable (CVPixelBuffer) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        self.process = process
        self.port = port
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    var hasControlConnection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSocketDescriptor >= 0 && !stopped
    }

    var hasTouchControl: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controlSocketDescriptor >= 0
            && !stopped
            && sessionWidth > 0
            && sessionHeight > 0
    }

    func sendControl(_ payload: Data) {
        lock.lock()
        let descriptor = controlSocketDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return }
        writeControl(payload, to: descriptor)
    }

    func sendTouch(action: AndroidMotionAction, at normalizedPoint: CGPoint) {
        lock.lock()
        let descriptor = controlSocketDescriptor
        let width = sessionWidth
        let height = sessionHeight
        lock.unlock()
        guard descriptor >= 0, width > 0, height > 0 else { return }
        let point = ScrcpyControlMessage.sessionPoint(
            normalizedPoint,
            width: width,
            height: height
        )
        let payload = ScrcpyControlMessage.injectTouch(
            action: action,
            x: point.x,
            y: point.y,
            screenWidth: width,
            screenHeight: height
        )
        writeControl(payload, to: descriptor)
    }

    private func writeControl(_ payload: Data, to descriptor: Int32) {
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < payload.count {
                let sent = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    payload.count - offset,
                    0
                )
                if sent <= 0 { return }
                offset += sent
            }
        }
    }

    func start() {
        lock.lock()
        guard !hasStarted else {
            lock.unlock()
            return
        }
        hasStarted = true
        lock.unlock()

        finishedGroup.enter()
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { finishedGroup.leave() }
            do {
                try run()
            } catch {
                guard !isStopped else { return }
                Task { @MainActor [onFailure] in
                    onFailure(error)
                }
            }
        }
    }

    func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()

        frameDelivery.clear()
        closeSocketsIfNeeded()
        if process.isRunning {
            process.terminate()
        }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                _ = self.finishedGroup.wait(timeout: .now() + 3)
                continuation.resume()
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func closeSocketsIfNeeded() {
        lock.lock()
        let video = videoSocketDescriptor
        let control = controlSocketDescriptor
        videoSocketDescriptor = -1
        controlSocketDescriptor = -1
        lock.unlock()
        for descriptor in [video, control] where descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func adoptVideoSocket(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            return false
        }
        videoSocketDescriptor = descriptor
        return true
    }

    private func adoptControlSocket(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            return false
        }
        controlSocketDescriptor = descriptor
        return true
    }

    private func run() throws {
        let (videoDescriptor, codecData) = try connectSockets()

        defer {
            lock.lock()
            let shouldCloseVideo = videoSocketDescriptor == videoDescriptor
            if shouldCloseVideo {
                videoSocketDescriptor = -1
            }
            let control = controlSocketDescriptor
            controlSocketDescriptor = -1
            lock.unlock()
            if shouldCloseVideo {
                Darwin.shutdown(videoDescriptor, SHUT_RDWR)
                Darwin.close(videoDescriptor)
            }
            if control >= 0 {
                Darwin.shutdown(control, SHUT_RDWR)
                Darwin.close(control)
            }
        }

        let codec = codecData.uint32BE(at: 0)
        guard codec == 0x6832_3634 else {
            throw ScrcpyStreamError.unsupportedCodec(codec)
        }

        let decoder = H264StreamDecoder { [frameDelivery, onFrame] pixelBuffer in
            frameDelivery.submit(pixelBuffer) { buffer in
                Task { @MainActor in
                    onFrame(buffer)
                }
            }
        }
        while !isStopped {
            let header = try ScrcpyVideoPacketHeader.parse(
                readExactly(12, from: videoDescriptor)
            )
            switch header.kind {
            case let .session(width, height):
                lock.lock()
                sessionWidth = UInt16(clamping: width)
                sessionHeight = UInt16(clamping: height)
                lock.unlock()
            case let .media(size, presentationTime, isConfig, isKey):
                let payload = try readExactly(size, from: videoDescriptor)
                try decoder.consume(
                    payload,
                    presentationTime: presentationTime,
                    isConfig: isConfig,
                    isKey: isKey
                )
            }
        }
    }

    /// Opens video then control on the same ADB forward. With `control=true`
    /// the device-side server waits for both accepts before sending codec data.
    private func connectSockets() throws -> (Int32, Data) {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if isStopped { throw CancellationError() }
            do {
                let video = try connectLocalPort()
                guard adoptVideoSocket(video) else {
                    Darwin.close(video)
                    throw CancellationError()
                }

                // ADB forward accepts before the device server is listening.
                // The dummy byte (send_dummy_byte=true) is how we detect a real
                // accept; EOF means retry.
                let dummy = try readExactly(1, from: video)
                guard dummy.first == 0x00 else {
                    throw ScrcpyStreamError.malformedPacket
                }

                let control = try connectLocalPort()
                configureControlSocket(control)
                guard adoptControlSocket(control) else {
                    Darwin.close(control)
                    throw CancellationError()
                }
                startControlDrain(control)

                let codec = try readExactly(4, from: video)
                return (video, codec)
            } catch is CancellationError {
                closeSocketsIfNeeded()
                throw CancellationError()
            } catch {
                closeSocketsIfNeeded()
                if isStopped { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.08)
                continue
            }
        } while ContinuousClock.now < deadline
        throw ScrcpyStreamError.connectionFailed
    }

    private func connectLocalPort() throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ScrcpyStreamError.connectionFailed
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw ScrcpyStreamError.connectionFailed
        }
        return descriptor
    }

    /// Touch messages are only 32 bytes. Disable Nagle buffering so DOWN,
    /// MOVE, and UP reach the device immediately instead of waiting to be
    /// combined into a larger TCP segment.
    private func configureControlSocket(_ descriptor: Int32) {
        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { value in
            _ = Darwin.setsockopt(
                descriptor,
                IPPROTO_TCP,
                TCP_NODELAY,
                value,
                socklen_t(MemoryLayout<Int32>.size)
            )
            _ = Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                value,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }

    /// Discard inbound device messages so a full TCP window cannot stall injects.
    private func startControlDrain(_ descriptor: Int32) {
        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                if received <= 0 { return }
            }
        }
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { bytes in
                Darwin.recv(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset,
                    0
                )
            }
            if received == 0 { throw ScrcpyStreamError.streamEnded }
            if received < 0 {
                if errno == EINTR { continue }
                throw isStopped
                    ? CancellationError()
                    : ScrcpyStreamError.streamEnded
            }
            offset += received
        }
        return data
    }
}

private final class H264StreamDecoder: @unchecked Sendable {
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?

    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    func consume(
        _ payload: Data,
        presentationTime: UInt64,
        isConfig: Bool,
        isKey: Bool
    ) throws {
        let units = ScrcpyH264AnnexB.nalUnits(in: payload)
        var parameterSetsChanged = false
        for unit in units {
            switch unit.first.map({ $0 & 0x1F }) {
            case 7:
                if sequenceParameterSet != unit {
                    sequenceParameterSet = unit
                    parameterSetsChanged = true
                }
            case 8:
                if pictureParameterSet != unit {
                    pictureParameterSet = unit
                    parameterSetsChanged = true
                }
            default:
                break
            }
        }
        if parameterSetsChanged, let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            formatDescription = nil
        }

        if isConfig {
            try configureIfPossible()
            return
        }
        try configureIfPossible()
        guard let session, let formatDescription else { return }

        let sampleData = units.isEmpty
            ? payload
            : ScrcpyH264AnnexB.lengthPrefixedData(from: units)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw ScrcpyStreamError.decoderFailed(status)
        }
        status = sampleData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw ScrcpyStreamError.decoderFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(presentationTime),
                timescale: 1_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw ScrcpyStreamError.decoderFailed(status)
        }
        if !isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
           ) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        var infoFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            throw ScrcpyStreamError.decoderFailed(status)
        }
    }

    private func configureIfPossible() throws {
        guard session == nil,
              let sequenceParameterSet,
              let pictureParameterSet else { return }

        var description: CMFormatDescription?
        let status = sequenceParameterSet.withUnsafeBytes { sequenceBytes in
            pictureParameterSet.withUnsafeBytes { pictureBytes in
                let pointers = [
                    sequenceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    pictureBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let videoDescription = description else {
            throw ScrcpyStreamError.decoderFailed(status)
        }

        let output = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr,
                      let refCon,
                      let imageBuffer else { return }
                let decoder = Unmanaged<H264StreamDecoder>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()
                decoder.deliver(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var createdSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: videoDescription,
            decoderSpecification: nil,
            imageBufferAttributes: output,
            outputCallback: &callback,
            decompressionSessionOut: &createdSession
        )
        guard sessionStatus == noErr, let createdSession else {
            throw ScrcpyStreamError.decoderFailed(sessionStatus)
        }
        VTSessionSetProperty(
            createdSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        formatDescription = videoDescription
        session = createdSession
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        onFrame(pixelBuffer)
    }
}

enum ScrcpyH264AnnexB {
    static func nalUnits(in data: Data) -> [Data] {
        var starts: [(index: Int, length: Int)] = []
        var index = data.startIndex
        while index + 3 <= data.endIndex {
            if index + 4 <= data.endIndex,
               data[index] == 0, data[index + 1] == 0,
               data[index + 2] == 0, data[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if data[index] == 0, data[index + 1] == 0,
                      data[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return [] }

        return starts.enumerated().compactMap { offset, start in
            let payloadStart = start.index + start.length
            let payloadEnd = offset + 1 < starts.count
                ? starts[offset + 1].index
                : data.endIndex
            guard payloadStart < payloadEnd else { return nil }
            return data.subdata(in: payloadStart..<payloadEnd)
        }
    }

    static func lengthPrefixedData(from units: [Data]) -> Data {
        var output = Data()
        output.reserveCapacity(units.reduce(0) { $0 + 4 + $1.count })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }
}

private extension Data {
    func uint32BE(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<start + 4].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    func uint64BE(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return self[start..<start + 8].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }

    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
