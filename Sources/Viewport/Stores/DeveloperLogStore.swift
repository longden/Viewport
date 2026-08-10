import Combine
import Foundation

@MainActor
final class DeveloperLogStore: ObservableObject {
    typealias ProcessFactory = (
        URL,
        [String],
        [String: String],
        @escaping StreamingProcess.LinesHandler,
        @escaping StreamingProcess.TerminationHandler
    ) -> any StreamingProcessRunning

    @Published private(set) var displayedEntries: [
        DeveloperLogSource: [DeveloperLogEntry]
    ] = [:]
    @Published private(set) var statuses: [
        DeveloperLogSource: DeveloperLogStreamStatus
    ] = [
        .web: .idle,
        .android: .idle,
        .iOS: .idle,
        .build: .idle
    ]
    @Published private(set) var isPaused = false
    @Published private(set) var retentionLimitBytes: Int
    @Published private(set) var isEnabled = false

    private let toolchains: ToolchainLocator
    private let processFactory: ProcessFactory
    private let maximumEntriesPerSource: Int
    private let defaults: UserDefaults
    private let retentionKey: String

    private var buffers: [DeveloperLogSource: [DeveloperLogEntry]] = [:]
    private var bufferBytes: [DeveloperLogSource: Int] = [:]
    private var nextEntryID: UInt64 = 0
    private var flushTask: Task<Void, Never>?

    private var androidProcess: (any StreamingProcessRunning)?
    private var iOSProcess: (any StreamingProcessRunning)?
    private var androidTarget: String?
    private var iOSTarget: String?
    private var androidIsVisible = false
    private var iOSIsVisible = false
    private var androidGeneration: UInt64 = 0
    private var iOSGeneration: UInt64 = 0

    init(
        toolchains: ToolchainLocator = ToolchainLocator(),
        maximumEntriesPerSource: Int = 5_000,
        maximumBytesPerSource: Int? = nil,
        defaults: UserDefaults = .standard,
        retentionKey: String = "developerLogRetentionBytes",
        processFactory: @escaping ProcessFactory = {
            executable, arguments, environment, onLines, onTermination in
            StreamingProcess(
                executable: executable,
                arguments: arguments,
                environment: environment,
                onLines: onLines,
                onTermination: onTermination
            )
        }
    ) {
        self.toolchains = toolchains
        self.maximumEntriesPerSource = maximumEntriesPerSource
        self.defaults = defaults
        self.retentionKey = retentionKey
        let savedLimit = defaults.integer(forKey: retentionKey)
        let savedRetention = DeveloperLogRetention(rawValue: savedLimit)
        retentionLimitBytes = maximumBytesPerSource
            ?? savedRetention?.rawValue
            ?? DeveloperLogRetention.kilobytes512.rawValue
        self.processFactory = processFactory
    }

    deinit {
        flushTask?.cancel()
        androidProcess?.stop()
        iOSProcess?.stop()
    }

    func entries(for source: DeveloperLogSource) -> [DeveloperLogEntry] {
        displayedEntries[source] ?? []
    }

    func status(for source: DeveloperLogSource) -> DeveloperLogStreamStatus {
        statuses[source] ?? .idle
    }

    func appendWeb(
        level: DeveloperLogLevel,
        message: String,
        timestamp: Date = Date()
    ) {
        guard isEnabled else { return }
        append(
            source: .web,
            level: level,
            messages: [message],
            timestamp: timestamp
        )
    }

    func appendBuild(
        level: DeveloperLogLevel,
        message: String,
        timestamp: Date = Date()
    ) {
        guard isEnabled else { return }
        append(
            source: .build,
            level: level,
            messages: [message],
            timestamp: timestamp
        )
    }

    func setBuildStatus(_ status: DeveloperLogStreamStatus) {
        setStatus(status, for: .build)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        setStatus(enabled ? .streaming : .idle, for: .web)
        if !enabled {
            stopAll()
        }
    }

    func setRetentionLimit(_ retention: DeveloperLogRetention) {
        guard retentionLimitBytes != retention.rawValue else { return }
        retentionLimitBytes = retention.rawValue
        defaults.set(retention.rawValue, forKey: retentionKey)
        for source in DeveloperLogSource.allCases {
            trimBuffer(for: source)
        }
        publishBuffers()
    }

    func updateAndroidDevice(id: String?, isVisible: Bool) {
        let shouldRun = isVisible && isEnabled
        let target = shouldRun ? id : nil
        let unchangedAndHealthy = target == androidTarget
            && shouldRun == androidIsVisible
            && (target == nil || androidProcess != nil)
        guard !unchangedAndHealthy else {
            return
        }
        androidTarget = target
        androidIsVisible = shouldRun
        androidGeneration &+= 1
        let generation = androidGeneration
        androidProcess?.stop()
        androidProcess = nil

        guard shouldRun else {
            setStatus(.idle, for: .android)
            return
        }
        guard let id else {
            setStatus(.unavailable("No Android device selected"), for: .android)
            return
        }
        guard let adb = toolchains.adb else {
            setStatus(.unavailable("adb is not installed"), for: .android)
            return
        }

        setStatus(.connecting, for: .android)
        let process = processFactory(
            adb,
            ["-s", id, "logcat", "-v", "threadtime", "-T", "1"],
            [:],
            { [weak self] output, lines in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == self.androidGeneration else { return }
                    self.append(
                        source: .android,
                        level: output == .standardError ? .error : .info,
                        messages: lines
                    )
                }
            },
            { [weak self] code in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == self.androidGeneration else { return }
                    self.androidProcess = nil
                    self.setStatus(
                        .failed("logcat exited with code \(code)"),
                        for: .android
                    )
                }
            }
        )
        androidProcess = process
        do {
            try process.start()
            setStatus(.streaming, for: .android)
        } catch {
            androidProcess = nil
            setStatus(.failed(error.localizedDescription), for: .android)
        }
    }

    func updateIOSDevice(_ device: StreamedDevice?, isVisible: Bool) {
        let shouldRun = isVisible && isEnabled
        let target = shouldRun ? device?.id : nil
        let unchangedAndHealthy = target == iOSTarget
            && shouldRun == iOSIsVisible
            && (target == nil || iOSProcess != nil)
        guard !unchangedAndHealthy else {
            return
        }
        iOSTarget = target
        iOSIsVisible = shouldRun
        iOSGeneration &+= 1
        let generation = iOSGeneration
        iOSProcess?.stop()
        iOSProcess = nil

        guard shouldRun else {
            setStatus(.idle, for: .iOS)
            return
        }
        guard let device else {
            setStatus(.unavailable("No iOS Simulator selected"), for: .iOS)
            return
        }
        guard device.kind == .iOSSimulator else {
            setStatus(
                .unavailable("Logs are unavailable for USB iOS devices"),
                for: .iOS
            )
            return
        }

        setStatus(.connecting, for: .iOS)
        let command = toolchains.simctlCommand([
            "spawn", device.id,
            "log", "stream",
            "--style", "compact",
            "--level", "debug"
        ])
        let process = processFactory(
            command.executable,
            command.arguments,
            toolchains.developerEnvironment,
            { [weak self] output, lines in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == self.iOSGeneration else { return }
                    self.append(
                        source: .iOS,
                        level: output == .standardError ? .error : .info,
                        messages: lines
                    )
                }
            },
            { [weak self] code in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == self.iOSGeneration else { return }
                    self.iOSProcess = nil
                    self.setStatus(
                        .failed("Simulator log stream exited with code \(code)"),
                        for: .iOS
                    )
                }
            }
        )
        iOSProcess = process
        do {
            try process.start()
            setStatus(.streaming, for: .iOS)
        } catch {
            iOSProcess = nil
            setStatus(.failed(error.localizedDescription), for: .iOS)
        }
    }

    func togglePaused() {
        isPaused.toggle()
        if !isPaused {
            publishBuffers()
        }
    }

    func clear(_ source: DeveloperLogSource) {
        buffers[source] = []
        bufferBytes[source] = 0
        displayedEntries[source] = []
    }

    func stopAll() {
        androidGeneration &+= 1
        iOSGeneration &+= 1
        androidProcess?.stop()
        iOSProcess?.stop()
        androidProcess = nil
        iOSProcess = nil
        androidTarget = nil
        iOSTarget = nil
        androidIsVisible = false
        iOSIsVisible = false
        setStatus(.idle, for: .android)
        setStatus(.idle, for: .iOS)
    }

    /// Recent log lines across sources for bug-report export.
    func exportRecentLines(limitPerSource: Int = 400) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for source in DeveloperLogSource.allCases {
            let entries = Array((buffers[source] ?? []).suffix(limitPerSource))
            guard !entries.isEmpty else { continue }
            lines.append("--- \(source.title) ---")
            for entry in entries {
                lines.append(
                    "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
                )
            }
        }
        if lines.isEmpty {
            return "(no log lines captured — enable Device logs before reproducing)"
        }
        return lines.joined(separator: "\n")
    }

    private func append(
        source: DeveloperLogSource,
        level: DeveloperLogLevel,
        messages: [String],
        timestamp: Date = Date()
    ) {
        guard isEnabled else { return }
        let sanitized = messages
            .map(Self.sanitize)
            .filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return }

        var entries = buffers[source] ?? []
        var bytes = bufferBytes[source] ?? 0
        for message in sanitized {
            nextEntryID &+= 1
            entries.append(
                DeveloperLogEntry(
                    id: nextEntryID,
                    timestamp: timestamp,
                    source: source,
                    level: inferredLevel(from: message, fallback: level),
                    message: message
                )
            )
            bytes += message.utf8.count
        }

        buffers[source] = entries
        bufferBytes[source] = max(bytes, 0)
        trimBuffer(for: source)
        schedulePublish()
    }

    private func trimBuffer(for source: DeveloperLogSource) {
        var entries = buffers[source] ?? []
        var bytes = bufferBytes[source] ?? 0
        var removeCount = max(entries.count - maximumEntriesPerSource, 0)
        var removedBytes = entries.prefix(removeCount).reduce(0) {
            $0 + $1.message.utf8.count
        }
        while bytes - removedBytes > retentionLimitBytes,
              removeCount < entries.count {
            removedBytes += entries[removeCount].message.utf8.count
            removeCount += 1
        }
        if removeCount > 0 {
            entries.removeFirst(removeCount)
            bytes -= removedBytes
        }
        buffers[source] = entries
        bufferBytes[source] = max(bytes, 0)
    }

    private func schedulePublish() {
        guard !isPaused, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.publishBuffers()
        }
    }

    private func publishBuffers() {
        guard !isPaused else { return }
        displayedEntries = buffers
    }

    private func setStatus(
        _ status: DeveloperLogStreamStatus,
        for source: DeveloperLogSource
    ) {
        statuses[source] = status
    }

    private func inferredLevel(
        from message: String,
        fallback: DeveloperLogLevel
    ) -> DeveloperLogLevel {
        let lowercase = message.lowercased()
        if lowercase.contains(" error ")
            || lowercase.contains(" fault ")
            || lowercase.contains(" e/") {
            return .error
        }
        if lowercase.contains(" warning ")
            || lowercase.contains(" warn ")
            || lowercase.contains(" w/") {
            return .warning
        }
        if lowercase.contains(" debug ") || lowercase.contains(" d/") {
            return .debug
        }
        return fallback
    }

    private nonisolated static func sanitize(_ message: String) -> String {
        let scalars = message.unicodeScalars.map { scalar -> Character in
            if scalar == "\t" || scalar.value >= 0x20 {
                return Character(scalar)
            }
            return "�"
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
