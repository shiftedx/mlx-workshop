import Foundation
import XCTest

@testable import MLXWorkshopApp

final class RunRepositoryTests: XCTestCase {
  func testAtomicManifestRoundTripPreservesProtocolFields() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let repository = RunRepository(workspaceURL: workspace)
    let manifest = try manifest(runID: "round-trip", state: .planned, sequence: 7)

    try await repository.saveManifest(manifest)
    let loaded = try await repository.loadManifest(runID: "round-trip")

    XCTAssertEqual(loaded, manifest)
    let runDirectory = workspace.appendingPathComponent("round-trip", isDirectory: true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: runDirectory.path)
      .filter { $0 != "run.json" }
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testRelaunchRecoveryReplaysJournalAndReportsCorruptTail() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let repository = RunRepository(workspaceURL: workspace)
    let manifest = try manifest(runID: "fixture-corrupt-tail", state: .created, sequence: 1)
    try await repository.saveManifest(manifest)
    let fixture = try fixtureData(named: "corrupt-tail")
    try fixture.write(
      to: workspace.appendingPathComponent("fixture-corrupt-tail/events.jsonl"),
      options: .atomic
    )

    let recovery = try await repository.recoverRun(runID: "fixture-corrupt-tail")

    XCTAssertEqual(recovery.events.map(\.sequence), [1, 2])
    XCTAssertEqual(recovery.snapshot.state, .interrupted)
    XCTAssertEqual(recovery.snapshot.resumability, .safe)
    XCTAssertEqual(recovery.snapshot.lastSequence, 2)
    XCTAssertTrue(recovery.manifestWasStale)
    XCTAssertNotNil(recovery.recoverableCorruptTail)
  }

  func testUnknownEventRemainsInRecoveredEvidenceButDoesNotChangeState() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let repository = RunRepository(workspaceURL: workspace)
    try await repository.saveManifest(
      manifest(runID: "fixture-unknown-event", state: .created, sequence: 1)
    )
    try fixtureData(named: "unknown-future-event").write(
      to: workspace.appendingPathComponent("fixture-unknown-event/events.jsonl"),
      options: .atomic
    )

    let recovery = try await repository.recoverRun(runID: "fixture-unknown-event")

    XCTAssertEqual(recovery.events.count, 3)
    XCTAssertEqual(recovery.snapshot.unknownEventCount, 1)
    XCTAssertEqual(recovery.snapshot.state, .interrupted)
  }

  func testBatchRecoveryIsolatesMalformedRunsFromHealthyRuns() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let repository = RunRepository(workspaceURL: workspace)

    try await repository.saveManifest(
      manifest(runID: "fixture-pass", state: .created, sequence: 1)
    )
    try fixtureData(named: "pass").write(
      to: workspace.appendingPathComponent("fixture-pass/events.jsonl"),
      options: .atomic
    )

    try await repository.saveManifest(
      manifest(runID: "malformed-run", state: .created, sequence: 1)
    )
    try Data("not-json\n{}".utf8).write(
      to: workspace.appendingPathComponent("malformed-run/events.jsonl"),
      options: .atomic
    )

    let batch = try await repository.recoverAllRuns()

    XCTAssertEqual(batch.runs.map(\.manifest.runID), ["fixture-pass"])
    XCTAssertEqual(batch.failures.map(\.runID), ["malformed-run"])
    XCTAssertFalse(batch.failures[0].message.isEmpty)
  }

  func testRunIDCannotEscapeSelectedWorkspace() async throws {
    let workspace = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let repository = RunRepository(workspaceURL: workspace)

    do {
      _ = try await repository.loadManifest(runID: "../outside")
      XCTFail("Expected invalid run ID")
    } catch {
      XCTAssertEqual(error as? RunRepositoryError, .invalidRunID("../outside"))
    }
  }

  func testSecurityScopedPathPersistsAccessModeAndResolvesBookmark() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try SecurityScopedPath(url: directory, accessMode: .readWrite)

    let encoded = try JSONEncoder().encode(path)
    let restored = try JSONDecoder().decode(SecurityScopedPath.self, from: encoded)
    let access = try restored.resolve()

    XCTAssertEqual(restored.accessMode, .readWrite)
    XCTAssertEqual(access.url.lastPathComponent, directory.lastPathComponent)
  }

  private func manifest(
    runID: String,
    state: WorkflowRunState,
    sequence: Int
  ) throws -> WorkflowRunManifest {
    try WorkflowRunManifest(
      runID: runID,
      state: state,
      resumability: .notApplicable,
      exactParent: "/tmp/immutable-parent",
      createdAt: "2026-07-09T22:00:00.000Z",
      updatedAt: "2026-07-09T22:00:00.000Z",
      lastCommittedSequence: sequence
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
}
