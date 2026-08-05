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
    private(set) var bufferedData = Data()
    private var discardingOversizedLine = false
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 64 * 1_024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        bufferedData.append(data)
        var lines: [String] = []

        while let newline = bufferedData.firstIndex(of: 0x0A) {
            let lineData = Data(bufferedData[..<newline])
            bufferedData.removeSubrange(...newline)
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

        if bufferedData.count > maximumLineBytes {
            lines.append(decode(Data(bufferedData.prefix(maximumLineBytes))) + " …")
            bufferedData.removeAll(keepingCapacity: true)
            discardingOversizedLine = true
        }
        return lines
    }

    mutating func finish() -> [String] {
        guard !bufferedData.isEmpty, !discardingOversizedLine else {
            bufferedData.removeAll()
            discardingOversizedLine = false
            return []
        }
        let line = decode(bufferedData)
        bufferedData.removeAll()
        return [line]
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
