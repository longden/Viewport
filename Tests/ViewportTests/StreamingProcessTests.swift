import XCTest
@testable import Viewport

final class StreamingProcessTests: XCTestCase {
    func testStreamsLinesBeforeProcessExit() throws {
        let linesExpectation = expectation(description: "Received lines")
        linesExpectation.assertForOverFulfill = false
        let terminationExpectation = expectation(description: "Terminated")
        let received = LockedLines()
        let process = StreamingProcess(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["one\ntwo\n"],
            onLines: { output, lines in
                guard output == .standardOutput else { return }
                received.append(lines)
                linesExpectation.fulfill()
            },
            onTermination: { code in
                XCTAssertEqual(code, 0)
                terminationExpectation.fulfill()
            }
        )

        try process.start()
        wait(for: [linesExpectation, terminationExpectation], timeout: 2)

        XCTAssertEqual(received.value, ["one", "two"])
    }

    func testStopTerminatesLongRunningProcess() throws {
        let process = StreamingProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            onLines: { _, _ in },
            onTermination: { _ in }
        )

        try process.start()
        process.stop()
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func append(_ newLines: [String]) {
        lock.lock()
        lines.append(contentsOf: newLines)
        lock.unlock()
    }
}
