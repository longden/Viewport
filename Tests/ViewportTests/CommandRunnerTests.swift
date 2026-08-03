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

    func testTimeoutTerminatesTheChildProcess() async {
        do {
            _ = try await CommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 0.05
            )
            XCTFail("Expected command timeout")
        } catch let error as CommandRunnerError {
            guard case .timedOut = error else {
                XCTFail("Expected timeout, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }
    }

    func testRepeatedFastExitDoesNotLoseCompletion() async throws {
        let runner = CommandRunner()

        for _ in 0..<50 {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: []
            )
            XCTAssertEqual(result.exitCode, 0)
        }
    }

    func testCancelAfterFastExitStillCompletes() async {
        for _ in 0..<20 {
            let task = Task {
                try await CommandRunner().run(
                    executable: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: []
                )
            }
            task.cancel()
            do {
                _ = try await task.value
            } catch is CancellationError {
                // Expected when cancellation wins the race.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
