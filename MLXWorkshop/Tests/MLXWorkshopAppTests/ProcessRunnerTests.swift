import Foundation
import XCTest

@testable import MLXWorkshopApp

final class ProcessRunnerTests: XCTestCase {
  func testDrainsStderrFloodReturnsNonzeroExitAndBoundsRetainedLogs() async throws {
    let runner = ProcessRunner()
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: [
        "-c",
        "import sys; sys.stderr.write('x' * 524288); sys.stderr.flush(); print('stdout-ok'); sys.exit(23)",
      ],
      workingDirectoryURL: FileManager.default.temporaryDirectory,
      environment: ["PYTHONUNBUFFERED": "1"],
      retainedOutputLimitBytes: 4096
    )

    let result = try await runner.run(request)

    XCTAssertEqual(result.exitCode, 23)
    XCTAssertEqual(result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines), "stdout-ok")
    XCTAssertEqual(result.stderr.totalBytes, 524_288)
    XCTAssertLessThanOrEqual(result.stderr.retainedData.count, 4096)
  }

  func testUsesExplicitWorkingDirectoryAndEnvironment() async throws {
    let runner = ProcessRunner()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("marker".utf8).write(to: directory.appendingPathComponent("working-directory-marker"))

    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: [
        "-c", "import os; print(os.getcwd()); print(os.environ.get('WORKSHOP_TEST', 'missing'))",
      ],
      workingDirectoryURL: directory,
      environment: ["WORKSHOP_TEST": "explicit"]
    )

    let result = try await runner.run(request)
    let lines = result.stdout.text.split(separator: "\n").map(String.init)

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: lines[0])
          .appendingPathComponent("working-directory-marker").path
      )
    )
    XCTAssertEqual(lines[1], "explicit")
  }

  func testCancellationTerminatesOnlyTheTrackedChild() async throws {
    let runner = ProcessRunner()
    let request = ProcessRequest(
      id: UUID(),
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: ["-c", "import time; print('ready', flush=True); time.sleep(30)"],
      workingDirectoryURL: FileManager.default.temporaryDirectory,
      environment: ["PYTHONUNBUFFERED": "1"]
    )

    let task = Task { try await runner.run(request) }
    try await Task.sleep(for: .milliseconds(150))
    let cancelled = await runner.cancel(id: request.id, grace: .milliseconds(100))
    XCTAssertTrue(cancelled)
    let result = try await task.value

    XCTAssertTrue(result.cancellationRequested)
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.text.contains("ready"))
  }
}
