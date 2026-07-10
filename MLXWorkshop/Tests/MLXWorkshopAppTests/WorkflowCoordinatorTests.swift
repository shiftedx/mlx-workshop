import Foundation
import XCTest

@testable import MLXWorkshopApp

final class WorkflowCoordinatorTests: XCTestCase {
  func testExecuteDecodesEventsAndMapsSuccessfulExit() async throws {
    let (coordinator, workspace) = try makeCoordinator()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let request = processRequest(output: try fixtureData(named: "pass"), exitCode: 0)

    let execution = try await coordinator.execute(request)

    XCTAssertEqual(execution.exitDisposition, .succeeded)
    XCTAssertNil(execution.streamFailure)
    XCTAssertEqual(execution.events.count, 12)
    XCTAssertEqual(execution.snapshot.state, .completed)
    XCTAssertTrue(execution.protocolMutationIsAllowed)
  }

  func testNonzeroExecutionFailureStillReturnsJournalEvidence() async throws {
    let (coordinator, workspace) = try makeCoordinator()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let request = processRequest(output: try fixtureData(named: "failed"), exitCode: 5)

    let execution = try await coordinator.execute(request)

    XCTAssertEqual(execution.exitDisposition, .executionFailure)
    XCTAssertEqual(execution.snapshot.state, .failed)
    XCTAssertEqual(execution.events.count, 4)
  }

  func testFutureSchemaDisablesProtocolMutation() async throws {
    let (coordinator, workspace) = try makeCoordinator()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let request = processRequest(output: try fixtureData(named: "future-schema"), exitCode: 4)

    let execution = try await coordinator.execute(request)

    XCTAssertEqual(
      execution.streamFailure,
      .protocolMismatch(supported: 1, found: 2)
    )
    XCTAssertEqual(execution.exitDisposition, .protocolFailure)
    XCTAssertFalse(execution.protocolMutationIsAllowed)
  }

  func testCancellationMapsToCancelledDisposition() async throws {
    let (coordinator, workspace) = try makeCoordinator()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let runID = "cooperative-cancel"
    let runDirectory = workspace.appendingPathComponent(runID, isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let marker = runDirectory.appendingPathComponent("cancel.request.json").path
    let request = ProcessRequest(
      id: UUID(),
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: [
        "-c",
        "import os,sys,time; marker=sys.argv[1];\nwhile not os.path.exists(marker): time.sleep(0.02)\nsys.exit(6)",
        marker,
      ],
      workingDirectoryURL: workspace,
      environment: [:]
    )

    let task = Task { try await coordinator.execute(request) }
    try await Task.sleep(for: .milliseconds(150))
    let cancelled = try await coordinator.requestCancellation(
      runID: runID,
      requestID: request.id,
      cooperativeGrace: .milliseconds(200),
      terminationGrace: .milliseconds(100)
    )
    XCTAssertTrue(cancelled)
    let execution = try await task.value

    XCTAssertEqual(execution.exitDisposition, .cancelledOrInterrupted)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
  }

  func testStageLogFloodRetainsABoundedTailWithoutBlockingTerminalState() async throws {
    let (coordinator, workspace) = try makeCoordinator()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let runID = "bounded-live-logs"
    var lines = [
      eventLine(runID: runID, sequence: 1, type: "run.created", stage: nil),
      eventLine(
        runID: runID, sequence: 2, type: "run.state", stage: nil,
        payload: ["state": "running", "resumability": "unsafe"]),
    ]
    for sequence in 3...1002 {
      lines.append(
        eventLine(
          runID: runID, sequence: sequence, type: "stage.log", stage: "fixture",
          payload: ["stream": "stdout", "message": "line-\(sequence)"]))
    }
    lines.append(
      eventLine(
        runID: runID, sequence: 1003, type: "run.completed", stage: nil,
        payload: ["state": "completed", "resumability": "not-applicable"]))
    let request = processRequest(
      output: Data((lines.joined(separator: "\n") + "\n").utf8), exitCode: 0)

    let execution = try await coordinator.execute(request)

    XCTAssertNil(execution.streamFailure)
    XCTAssertEqual(execution.snapshot.state, .completed)
    XCTAssertEqual(
      execution.events.filter { $0.kind == .known(.stageLog) }.count,
      256)
    XCTAssertEqual(execution.events.last?.kind, .known(.runCompleted))
  }

  private func makeCoordinator() throws -> (WorkflowCoordinator, URL) {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return (
      WorkflowCoordinator(
        processRunner: ProcessRunner(),
        runRepository: RunRepository(workspaceURL: workspace)
      ),
      workspace
    )
  }

  private func processRequest(output: Data, exitCode: Int32) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: [
        "-c",
        "import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.argv[1])); sys.stdout.flush(); sys.exit(int(sys.argv[2]))",
        output.base64EncodedString(),
        String(exitCode),
      ],
      workingDirectoryURL: FileManager.default.temporaryDirectory,
      environment: ["PYTHONUNBUFFERED": "1"]
    )
  }

  private func fixtureData(named name: String) throws -> Data {
    let workspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try Data(
      contentsOf: workspace.appendingPathComponent("tests/fixtures/protocol/v1/\(name).jsonl")
    )
  }

  private func eventLine(
    runID: String,
    sequence: Int,
    type: String,
    stage: String?,
    payload: [String: String] = [:]
  ) -> String {
    let object: [String: Any] = [
      "schema_version": 1,
      "run_id": runID,
      "sequence": sequence,
      "timestamp": "2026-07-09T22:00:00.000Z",
      "type": type,
      "stage": stage as Any,
      "payload": payload,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
