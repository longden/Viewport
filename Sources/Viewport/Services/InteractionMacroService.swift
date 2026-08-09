import CoreGraphics
import Foundation

struct CodablePoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct MacroPointerEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var timestamp: TimeInterval
    var source: ViewerSource
    var phase: PointerEventPhase
    var point: CodablePoint
    var duration: TimeInterval?
}

struct InteractionMacro: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var events: [MacroPointerEvent]
}

enum MacroReplayTarget: String, CaseIterable, Identifiable {
    case android
    case iOS
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .android:
            "Android"
        case .iOS:
            "iOS"
        case .both:
            "Both"
        }
    }
}

@MainActor
final class InteractionMacroService: ObservableObject {
    static let maxDraftEvents = 200
    static let maxStoredMacros = 20

    @Published private(set) var macros: [InteractionMacro] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isReplaying = false
    @Published private(set) var draftEventCount = 0

    private let macrosDirectory: URL
    private var recordingStart: Date?
    private var replayTask: Task<Void, Never>?
    private var draftEvents: [MacroPointerEvent] = []
    private var initialLoadTask: Task<Void, Never>?

    init(macrosDirectory: URL? = nil) {
        if let macrosDirectory {
            self.macrosDirectory = macrosDirectory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.macrosDirectory = support
                .appendingPathComponent("Viewport", isDirectory: true)
                .appendingPathComponent("Macros", isDirectory: true)
        }
        // Disk IO off the MainActor; callers that need macros immediately
        // (tests) can await `ensureMacrosLoaded()`.
        let directory = self.macrosDirectory
        initialLoadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                Self.readMacros(from: directory)
            }.value
            guard let self else { return }
            // Merge so a save that raced the initial scan is not wiped.
            var merged = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            for macro in self.macros {
                merged[macro.id] = macro
            }
            self.macros = merged.values.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Waits for the initial directory scan started in `init`.
    func ensureMacrosLoaded() async {
        await initialLoadTask?.value
    }

    func startRecording() {
        guard !isRecording, !isReplaying else { return }
        draftEvents = []
        draftEventCount = 0
        recordingStart = Date()
        isRecording = true
    }

    @discardableResult
    func stopRecording(named name: String) -> InteractionMacro? {
        guard isRecording else { return nil }
        isRecording = false
        defer {
            recordingStart = nil
            draftEventCount = 0
        }

        guard draftEventCount > 0 else { return nil }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let events = draftEvents
        draftEvents = []
        let macro = InteractionMacro(
            id: UUID(),
            name: trimmed.isEmpty ? defaultMacroName() : trimmed,
            createdAt: Date(),
            events: events
        )
        addMacro(macro)
        return macro
    }

    func record(
        source: ViewerSource,
        phase: PointerEventPhase,
        point: CGPoint,
        duration: TimeInterval?
    ) {
        guard isRecording, let recordingStart else { return }
        guard source == .android || source == .iOS else { return }
        guard draftEventCount < Self.maxDraftEvents else { return }

        let event = MacroPointerEvent(
            id: UUID(),
            timestamp: Date().timeIntervalSince(recordingStart),
            source: source,
            phase: phase,
            point: CodablePoint(point),
            duration: duration
        )
        appendDraftEvent(event)
    }

    func replay(
        _ macro: InteractionMacro,
        targets: MacroReplayTarget,
        sessions: [WindowCaptureSession]
    ) {
        cancelReplay()
        guard !sessions.isEmpty else { return }

        isReplaying = true
        let sortedEvents = macro.events.sorted { $0.timestamp < $1.timestamp }
        replayTask = Task {
            var lastTimestamp: TimeInterval = 0
            var activePoints: [ObjectIdentifier: CGPoint] = [:]
            defer {
                for session in sessions {
                    let id = ObjectIdentifier(session)
                    if let point = activePoints[id] {
                        session.endPointer(at: point, duration: 0)
                    }
                }
                isReplaying = false
            }
            for event in sortedEvents {
                let delay = event.timestamp - lastTimestamp
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { break }
                lastTimestamp = event.timestamp
                let point = event.point.cgPoint
                for session in sessions {
                    let id = ObjectIdentifier(session)
                    switch event.phase {
                    case .began:
                        session.beginPointer(at: point)
                        activePoints[id] = point
                    case .moved:
                        session.movePointer(to: point)
                        if activePoints[id] != nil {
                            activePoints[id] = point
                        }
                    case .ended:
                        session.endPointer(
                            at: point,
                            duration: event.duration ?? 0
                        )
                        activePoints[id] = nil
                    }
                }
            }
        }
    }

    /// Convenience for primary-only callers / tests.
    func replay(
        _ macro: InteractionMacro,
        targets: MacroReplayTarget,
        android: WindowCaptureSession,
        iOS: WindowCaptureSession
    ) {
        let sessions: [WindowCaptureSession]
        switch targets {
        case .android:
            sessions = [android]
        case .iOS:
            sessions = [iOS]
        case .both:
            sessions = [android, iOS]
        }
        replay(macro, targets: targets, sessions: sessions)
    }

    func cancelReplay() {
        replayTask?.cancel()
        replayTask = nil
        isReplaying = false
    }

    func delete(_ macro: InteractionMacro) {
        macros.removeAll { $0.id == macro.id }
        let fileURL = fileURL(for: macro.id)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func updateEvents(for macro: InteractionMacro, events: [MacroPointerEvent]) {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else {
            return
        }
        var updated = macro
        updated.events = events
        macros[index] = updated
        persist(updated)
    }

    func rename(_ macro: InteractionMacro, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = macros.firstIndex(where: { $0.id == macro.id }) else {
            return
        }
        var updated = macro
        updated.name = trimmed
        macros[index] = updated
        persist(updated)
    }

    // MARK: - Persistence

    private func appendDraftEvent(_ event: MacroPointerEvent) {
        draftEvents.append(event)
        draftEventCount = draftEvents.count
    }

    private func defaultMacroName() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Macro \(formatter.string(from: Date()))"
    }

    nonisolated private static func readMacros(from directory: URL) -> [InteractionMacro] {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let loaded: [InteractionMacro] = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(InteractionMacro.self, from: data)
            }

        return loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func addMacro(_ macro: InteractionMacro) {
        macros.insert(macro, at: 0)
        persist(macro)
        while macros.count > Self.maxStoredMacros {
            guard let removed = macros.popLast() else { break }
            let fileURL = fileURL(for: removed.id)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persist(_ macro: InteractionMacro) {
        try? FileManager.default.createDirectory(
            at: macrosDirectory,
            withIntermediateDirectories: true
        )
        let url = fileURL(for: macro.id)
        guard let data = try? JSONEncoder().encode(macro) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        macrosDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}
