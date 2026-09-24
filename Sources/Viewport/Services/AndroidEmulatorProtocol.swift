import Foundation

/// gRPC length-prefixed message buffer that advances a read index instead of
/// shifting the front of `Data` on every consume. Compacts only after the
/// consumed prefix exceeds a threshold (64KB or half the buffer).
struct GrpcMessageBuffer {
    private var storage = Data()
    private(set) var consumed = 0
    private let compactionThreshold: Int

    init(compactionThreshold: Int = 64 * 1_024) {
        self.compactionThreshold = max(compactionThreshold, 1)
    }

    var count: Int { storage.count - consumed }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.append(data)
    }

    enum ConsumeError: Error, Equatable {
        case compressedUnsupported
        case invalidLength
    }

    /// Drains every complete uncompressed gRPC message currently buffered.
    mutating func consumeMessages() throws -> [Data] {
        var messages: [Data] = []
        while count >= 5 {
            let base = storage.startIndex + consumed
            let compressed = storage[base]
            let length = Int(storage[base + 1]) << 24
                | Int(storage[base + 2]) << 16
                | Int(storage[base + 3]) << 8
                | Int(storage[base + 4])
            guard compressed == 0 else {
                throw ConsumeError.compressedUnsupported
            }
            guard length >= 0, length < 32 * 1_024 * 1_024 else {
                throw ConsumeError.invalidLength
            }
            guard count >= 5 + length else { break }
            let messageStart = base + 5
            messages.append(
                storage.subdata(in: messageStart..<(messageStart + length))
            )
            consumed += 5 + length
            compactIfNeeded()
        }
        return messages
    }

    mutating func reset() {
        storage.removeAll(keepingCapacity: false)
        consumed = 0
    }

    private mutating func compactIfNeeded() {
        guard consumed > 0 else { return }
        let halfBuffer = storage.count / 2
        guard consumed >= compactionThreshold || consumed >= halfBuffer else {
            return
        }
        storage.removeSubrange(storage.startIndex..<(storage.startIndex + consumed))
        consumed = 0
    }
}

struct HTTP2Frame {
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

struct HTTP2FrameDecoder {
    private var storage = Data()
    private var consumed = 0
    private let compactionThreshold: Int

    init(compactionThreshold: Int = 64 * 1_024) {
        self.compactionThreshold = max(compactionThreshold, 1)
    }

    mutating func push(_ data: Data) -> [HTTP2Frame] {
        guard !data.isEmpty else { return [] }
        storage.append(data)
        var frames: [HTTP2Frame] = []
        while storage.count - consumed >= 9 {
            let base = storage.startIndex + consumed
            let length = Int(storage[base]) << 16
                | Int(storage[base + 1]) << 8
                | Int(storage[base + 2])
            guard storage.count - consumed >= 9 + length else { break }
            let typeRaw = storage[base + 3]
            let flags = storage[base + 4]
            let streamID = UInt32(storage[base + 5] & 0x7F) << 24
                | UInt32(storage[base + 6]) << 16
                | UInt32(storage[base + 7]) << 8
                | UInt32(storage[base + 8])
            let payloadStart = base + 9
            let payload = storage.subdata(
                in: payloadStart..<(payloadStart + length)
            )
            consumed += 9 + length
            compactIfNeeded()
            guard let type = HTTP2Frame.FrameType(rawValue: typeRaw) else {
                continue
            }
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
        return frames
    }

    mutating func reset() {
        storage.removeAll(keepingCapacity: false)
        consumed = 0
    }

    private mutating func compactIfNeeded() {
        guard consumed > 0 else { return }
        let halfBuffer = storage.count / 2
        guard consumed >= compactionThreshold || consumed >= halfBuffer else {
            return
        }
        storage.removeSubrange(
            storage.startIndex..<(storage.startIndex + consumed)
        )
        consumed = 0
    }
}

/// `Image` reply from `streamScreenshot`. `pixels` is empty when the emulator
/// wrote the frame to the MMAP side channel instead.
struct EmulatorImageMessage {
    let width: Int
    let height: Int
    let pixels: Data
}

enum EmulatorProtobuf {
    /// `mmapHandle` requests `ImageTransport.MMAP` (a `file://` URL the
    /// emulator writes RGBA rows into) instead of inline pixel bytes.
    static func imageFormat(
        rgba: Bool,
        width: UInt32,
        height: UInt32,
        mmapHandle: String? = nil
    ) -> Data {
        var data = Data()
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
        if let mmapHandle {
            var transport = Data()
            transport.append(contentsOf: encodeKey(field: 1, wire: 0))
            transport.append(contentsOf: encodeVarint(1))
            let handle = Data(mmapHandle.utf8)
            transport.append(contentsOf: encodeKey(field: 2, wire: 2))
            transport.append(contentsOf: encodeVarint(UInt64(handle.count)))
            transport.append(handle)
            data.append(contentsOf: encodeKey(field: 6, wire: 2))
            data.append(contentsOf: encodeVarint(UInt64(transport.count)))
            data.append(transport)
        }
        return data
    }

    static func touchEvent(
        x: Int32,
        y: Int32,
        identifier: Int32,
        pressed: Bool
    ) -> Data {
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

    static func settingsFrame(
        flags: UInt8,
        initialWindowSize: UInt32? = nil,
        maxFrameSize: UInt32? = nil
    ) -> Data {
        var payload = Data()
        for (identifier, value) in [
            (UInt8(0x04), initialWindowSize),
            (UInt8(0x05), maxFrameSize)
        ] {
            guard let value else { continue }
            payload.append(contentsOf: [
                0x00, identifier,
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
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
        // Emulator 37+ plain `-grpc` accepts unauthenticated localhost calls.
        // Only attach Bearer when discovery / console auth provided a token.
        if !authorization.isEmpty {
            payload.append(literalHeader("authorization", authorization))
        }
        payload.append(literalHeader("user-agent", "viewport-grpc/1.0"))

        var flags: UInt8 = 0x4
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

    static func dataFrame(
        streamID: UInt32,
        payload: Data,
        endStream: Bool
    ) -> Data {
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

    static func parseImage(_ message: Data) -> EmulatorImageMessage? {
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
            case (1, 2):
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
                pixels = message[index..<end]
                index = end
            default:
                index = skip(message, at: index, wire: wire)
            }
        }

        guard width > 0, height > 0 else { return nil }
        return EmulatorImageMessage(
            width: Int(width),
            height: Int(height),
            pixels: pixels
        )
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

    private static func literalHeader(_ name: String, _ value: String) -> Data {
        var data = Data()
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

    private static func readVarint(
        _ data: Data,
        at start: Data.Index
    ) -> (UInt64, Data.Index) {
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

    private static func skip(
        _ data: Data,
        at start: Data.Index,
        wire: Int
    ) -> Data.Index {
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
