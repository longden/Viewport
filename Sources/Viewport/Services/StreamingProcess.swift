import Darwin
import Foundation

enum StreamingProcessOutput {
    case standardOutput
    case standardError
}

protocol StreamingProcessRunning: AnyObject {
    func start() throws
    func stop()
}

struct LogLineDecoder {
    private var storage = Data()
    private var consumed = 0
    private var discardingOversizedLine = false
    let maximumLineBytes: Int
    private let compactionThreshold: Int

    /// Unconsumed buffered bytes (for tests / debugging).
    var bufferedData: Data {
        Data(storage[(storage.startIndex + consumed)..<storage.endIndex])
    }

    /// Bytes already consumed but not yet compacted (for tests).
    var consumedByteCount: Int { consumed }

    init(
        maximumLineBytes: Int = 64 * 1_024,
        compactionThreshold: Int = 64 * 1_024
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.compactionThreshold = max(compactionThreshold, 1)
    }

    mutating func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        storage.append(data)
        var lines: [String] = []

        while let newline = firstNewlineIndex() {
            let lineStart = storage.startIndex + consumed
            let lineData = Data(storage[lineStart..<newline])
            consumed = storage.distance(from: storage.startIndex, to: newline) + 1
            compactIfNeeded()
            if discardingOversizedLine {
                discardingOversizedLine = false
                continue
            }
            if lineData.count > maximumLineBytes {
                lines.append(
                    decode(Data(lineData.prefix(maximumLineBytes))) + " …"
                )
            } else {
                lines.append(decode(lineData))
            }
        }

        if unconsumedCount > maximumLineBytes {
            lines.append(decode(Data(unconsumedPrefix(maximumLineBytes))) + " …")
            storage.removeAll(keepingCapacity: true)
            consumed = 0
            discardingOversizedLine = true
        }
        return lines
    }

    mutating func finish() -> [String] {
        let pending = bufferedData
        guard !pending.isEmpty, !discardingOversizedLine else {
            storage.removeAll()
            consumed = 0
            discardingOversizedLine = false
            return []
        }
        let line = decode(pending)
        storage.removeAll()
        consumed = 0
        return [line]
    }

    private var unconsumedCount: Int { storage.count - consumed }

    private func firstNewlineIndex() -> Data.Index? {
        let range = (storage.startIndex + consumed)..<storage.endIndex
        return storage[range].firstIndex(of: 0x0A)
    }

    private func unconsumedPrefix(_ maxCount: Int) -> Data {
        let start = storage.startIndex + consumed
        let end = storage.index(
            start,
            offsetBy: maxCount,
            limitedBy: storage.endIndex
        ) ?? storage.endIndex
        return storage[start..<end]
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

    private func decode(_ data: Data) -> String {
        var line = data
        if line.last == 0x0D {
            line.removeLast()
        }
        return String(decoding: line, as: UTF8.self)
            .replacingOccurrences(of: "\u{0}", with: "�")
    }
}

final class StreamingProcess: StreamingProcessRunning, @unchecked Sendable {
    typealias LinesHandler = @Sendable (
        StreamingProcessOutput,
        [String]
    ) -> Void
    typealias TerminationHandler = @Sendable (Int32) -> Void

    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let lock = NSLock()
    private let onLines: LinesHandler
    private let onTermination: TerminationHandler

    private var outputDecoder = LogLineDecoder()
    private var errorDecoder = LogLineDecoder()
    private var hasStarted = false
    private var hasStopped = false
    private var hasTerminated = false

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        onLines: @escaping LinesHandler,
        onTermination: @escaping TerminationHandler
    ) {
        self.onLines = onLines
        self.onTermination = onTermination
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    deinit {
        stop()
    }

    func start() throws {
        lock.lock()
        guard !hasStarted, !hasStopped else {
            lock.unlock()
            throw CommandRunnerError.failedToLaunch(
                "The streaming process cannot be started again."
            )
        }
        hasStarted = true
        lock.unlock()

        standardOutput.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            self?.consume(
                handle.availableData,
                output: .standardOutput
            )
        }
        standardError.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            self?.consume(
                handle.availableData,
                output: .standardError
            )
        }
        process.terminationHandler = { [weak self] process in
            self?.didTerminate(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stopReading()
            lock.lock()
            hasStopped = true
            lock.unlock()
            throw CommandRunnerError.failedToLaunch(error.localizedDescription)
        }
    }

    func stop() {
        lock.lock()
        guard !hasStopped else {
            lock.unlock()
            return
        }
        hasStopped = true
        let isRunning = process.isRunning
        let pid = process.processIdentifier
        lock.unlock()

        stopReading()
        guard isRunning else { return }
        process.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 0.5
        ) { [weak process] in
            guard let process, process.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    private func consume(_ data: Data, output: StreamingProcessOutput) {
        lock.lock()
        guard !hasStopped else {
            lock.unlock()
            return
        }
        let lines: [String]
        switch output {
        case .standardOutput:
            lines = data.isEmpty
                ? outputDecoder.finish()
                : outputDecoder.append(data)
        case .standardError:
            lines = data.isEmpty
                ? errorDecoder.finish()
                : errorDecoder.append(data)
        }
        lock.unlock()

        if !lines.isEmpty {
            onLines(output, lines)
        }
    }

    private func didTerminate(status: Int32) {
        lock.lock()
        guard !hasTerminated else {
            lock.unlock()
            return
        }
        hasTerminated = true
        let outputLines = outputDecoder.finish()
        let errorLines = errorDecoder.finish()
        lock.unlock()

        stopReading()
        if !outputLines.isEmpty {
            onLines(.standardOutput, outputLines)
        }
        if !errorLines.isEmpty {
            onLines(.standardError, errorLines)
        }
        onTermination(status)
    }

    private func stopReading() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }
}
