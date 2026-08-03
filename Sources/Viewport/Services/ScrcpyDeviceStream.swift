import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Low-latency Android device video backed by scrcpy's MediaCodec stream.
/// ADB is only used to install the temporary server and open the tunnel; it
/// is not involved in delivering individual frames.
@MainActor
final class ScrcpyDeviceStream {
    private let runner = CommandRunner()
    private var worker: ScrcpyStreamWorker?
    private var forwardedPort: Int?
    private var adb: URL?
    private var serial: String?

    var isAvailable: Bool {
        ScrcpyInstallation.locate() != nil
    }

    func start(
        serial: String,
        profile: CapturePerformanceProfile,
        onFrame: @escaping @MainActor @Sendable (CGImage) -> Void,
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
            "control=false",
            "cleanup=true",
            "tunnel_forward=true",
            "send_device_meta=false",
            "send_dummy_byte=false",
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
            await removeForward(adb: adb, serial: serial, port: port)
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

    func stop() {
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
                await self.removeForward(
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
            await removeForward(
                adb: adb,
                serial: serial,
                port: forwardedPort
            )
        }
    }

    private func removeForward(adb: URL, serial: String, port: Int) async {
        _ = try? await runner.run(
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
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sdkPath = environment["ANDROID_SDK_ROOT"]
            ?? environment["ANDROID_HOME"]
            ?? home.appendingPathComponent("Library/Android/sdk").path
        guard let adb = ExecutableLocator.executable(
            named: "adb",
            candidates: [
                URL(fileURLWithPath: sdkPath)
                    .appendingPathComponent("platform-tools/adb"),
                URL(fileURLWithPath: "/opt/homebrew/bin/adb")
            ]
        ), let scrcpy = ExecutableLocator.executable(
            named: "scrcpy",
            candidates: [
                URL(fileURLWithPath: "/opt/homebrew/bin/scrcpy"),
                URL(fileURLWithPath: "/usr/local/bin/scrcpy")
            ]
        ) else {
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

private final class ScrcpyStreamWorker: @unchecked Sendable {
    private let process: Process
    private let port: Int
    private let onFrame: @MainActor @Sendable (CGImage) -> Void
    private let onFailure: @MainActor @Sendable (Error) -> Void
    private let frameDelivery = ScrcpyFrameDelivery()
    private let lock = NSLock()
    private let finishedGroup = DispatchGroup()
    private var socketDescriptor: Int32 = -1
    private var stopped = false
    private var hasStarted = false

    init(
        process: Process,
        port: Int,
        onFrame: @escaping @MainActor @Sendable (CGImage) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        self.process = process
        self.port = port
        self.onFrame = onFrame
        self.onFailure = onFailure
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
        closeSocketIfNeeded()
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

    private func closeSocketIfNeeded() {
        lock.lock()
        let descriptor = socketDescriptor
        socketDescriptor = -1
        lock.unlock()
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func adoptSocket(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            return false
        }
        socketDescriptor = descriptor
        return true
    }

    private func run() throws {
        let (descriptor, codecData) = try connectWithRetry()

        defer {
            lock.lock()
            let shouldClose = socketDescriptor == descriptor
            if shouldClose {
                socketDescriptor = -1
            }
            lock.unlock()
            if shouldClose {
                Darwin.shutdown(descriptor, SHUT_RDWR)
                Darwin.close(descriptor)
            }
        }

        let codec = codecData.uint32BE(at: 0)
        guard codec == 0x6832_3634 else {
            throw ScrcpyStreamError.unsupportedCodec(codec)
        }

        let converter = ScrcpyFrameConverter()
        let decoder = H264StreamDecoder { [frameDelivery, onFrame] pixelBuffer in
            frameDelivery.submit(pixelBuffer) { buffer in
                guard let image = converter.image(from: buffer) else { return }
                Task { @MainActor in
                    onFrame(image)
                }
            }
        }
        while !isStopped {
            let header = try ScrcpyVideoPacketHeader.parse(
                readExactly(12, from: descriptor)
            )
            switch header.kind {
            case .session:
                continue
            case let .media(size, presentationTime, isConfig, isKey):
                let payload = try readExactly(size, from: descriptor)
                try decoder.consume(
                    payload,
                    presentationTime: presentationTime,
                    isConfig: isConfig,
                    isKey: isKey
                )
            }
        }
    }

    private func connectWithRetry() throws -> (Int32, Data) {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if isStopped { throw CancellationError() }
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw ScrcpyStreamError.connectionFailed
            }
            guard adoptSocket(descriptor) else {
                Darwin.close(descriptor)
                throw CancellationError()
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
            if result == 0 {
                do {
                    // An ADB forward can accept before the device-side server
                    // is listening. Treat an immediate EOF as a startup race
                    // and reconnect instead of abandoning the fast path.
                    let codec = try readExactly(4, from: descriptor)
                    return (descriptor, codec)
                } catch {
                    closeSocketIfNeeded()
                    if isStopped { throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.08)
                    continue
                }
            }
            closeSocketIfNeeded()
            Thread.sleep(forTimeInterval: 0.08)
        } while ContinuousClock.now < deadline
        throw ScrcpyStreamError.connectionFailed
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

private final class ScrcpyFrameConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(image, from: image.extent)
    }
}

private final class ScrcpyFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var deliveryIsScheduled = false

    func submit(
        _ pixelBuffer: CVPixelBuffer,
        convertAndDeliver: @escaping @Sendable (CVPixelBuffer) -> Void
    ) {
        lock.lock()
        latestBuffer = pixelBuffer
        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.deliverLatest(convertAndDeliver)
        }
    }

    func clear() {
        lock.lock()
        latestBuffer = nil
        lock.unlock()
    }

    private func deliverLatest(
        _ convertAndDeliver: @escaping @Sendable (CVPixelBuffer) -> Void
    ) {
        lock.lock()
        let buffer = latestBuffer
        latestBuffer = nil
        lock.unlock()

        if let buffer {
            convertAndDeliver(buffer)
        }

        lock.lock()
        let hasAnotherFrame = latestBuffer != nil
        if !hasAnotherFrame {
            deliveryIsScheduled = false
        }
        lock.unlock()

        if hasAnotherFrame {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.deliverLatest(convertAndDeliver)
            }
        }
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
}
