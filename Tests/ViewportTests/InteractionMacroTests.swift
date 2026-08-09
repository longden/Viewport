import XCTest
@testable import Viewport

final class InteractionMacroTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let macro = InteractionMacro(
            id: UUID(),
            name: "Tap home",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            events: [
                MacroPointerEvent(
                    id: UUID(),
                    timestamp: 0,
                    source: .android,
                    phase: .began,
                    point: CodablePoint(x: 0.5, y: 0.5),
                    duration: nil
                ),
                MacroPointerEvent(
                    id: UUID(),
                    timestamp: 0.12,
                    source: .android,
                    phase: .ended,
                    point: CodablePoint(x: 0.5, y: 0.5),
                    duration: 0.12
                )
            ]
        )

        let data = try JSONEncoder().encode(macro)
        let decoded = try JSONDecoder().decode(InteractionMacro.self, from: data)
        XCTAssertEqual(decoded, macro)
    }

    @MainActor
    func testPersistAndRestoreFromDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewportMacroTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = InteractionMacroService(macrosDirectory: directory)
        service.startRecording()
        service.record(
            source: .iOS,
            phase: .began,
            point: CGPoint(x: 0.2, y: 0.3),
            duration: nil
        )
        service.record(
            source: .iOS,
            phase: .ended,
            point: CGPoint(x: 0.2, y: 0.3),
            duration: 0.08
        )
        let saved = service.stopRecording(named: "Swipe test")
        XCTAssertNotNil(saved)

        let restored = InteractionMacroService(macrosDirectory: directory)
        await restored.ensureMacrosLoaded()
        XCTAssertEqual(restored.macros.count, 1)
        XCTAssertEqual(restored.macros.first?.name, "Swipe test")
        XCTAssertEqual(restored.macros.first?.events.count, 2)
    }

    @MainActor
    func testEventEditAndDelete() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewportMacroTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = InteractionMacroService(macrosDirectory: directory)
        service.startRecording()
        service.record(
            source: .android,
            phase: .began,
            point: CGPoint(x: 0.1, y: 0.2),
            duration: nil
        )
        service.record(
            source: .android,
            phase: .moved,
            point: CGPoint(x: 0.15, y: 0.25),
            duration: nil
        )
        guard let macro = service.stopRecording(named: "Edit me") else {
            return XCTFail("Expected saved macro")
        }

        var events = macro.events
        events[0].point.x = 0.42
        events.removeLast()
        service.updateEvents(for: macro, events: events)

        let updated = service.macros.first { $0.id == macro.id }
        XCTAssertEqual(updated?.events.count, 1)
        XCTAssertEqual(updated?.events.first?.point.x, 0.42)

        service.delete(macro)
        XCTAssertTrue(service.macros.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(macro.id.uuidString).json").path)
        )
    }
}
