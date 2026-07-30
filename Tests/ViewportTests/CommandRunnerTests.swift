import XCTest
@testable import Viewport

final class CommandRunnerTests: XCTestCase {
    func testDrainsLargeStandardOutputWithoutDeadlocking() async throws {
        let result = try await CommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: [
                "if=/dev/zero",
                "bs=1024",
                "count=256"
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, 256 * 1_024)
        XCTAssertTrue(result.standardError.contains("bytes transferred"))
    }

    func testCancellationTerminatesTheChildProcess() async {
        let task = Task {
            try await CommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected command cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
