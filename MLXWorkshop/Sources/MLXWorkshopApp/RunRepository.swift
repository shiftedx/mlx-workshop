import Foundation

enum RunRepositoryError: Error, Equatable, Sendable {
  case invalidRunID(String)
  case missingJournal(String)
  case manifestRunIDMismatch(expected: String, found: String)
}

struct WorkflowReplaySnapshot: Equatable, Sendable {
  let state: WorkflowRunState?
  let resumability: WorkflowResumability?
  let lastSequence: Int
  let unknownEventCount: Int
}

struct RecoveredWorkflowRun: Equatable, Sendable {
  let runDirectoryURL: URL
  let manifest: WorkflowRunManifest
  let events: [WorkflowEvent]
  let snapshot: WorkflowReplaySnapshot
  let manifestWasStale: Bool
  let recoverableCorruptTail: Data?

  var effectiveState: WorkflowRunState {
    snapshot.state ?? manifest.state
  }

  var effectiveResumability: WorkflowResumability {
    snapshot.resumability ?? manifest.resumability
  }
}

struct RunRecoveryFailure: Equatable, Sendable {
  let runID: String
  let message: String
}

struct WorkflowRecoveryBatch: Equatable, Sendable {
  let runs: [RecoveredWorkflowRun]
  let failures: [RunRecoveryFailure]
}

actor RunRepository {
  let workspaceURL: URL

  init(workspaceURL: URL) {
    self.workspaceURL = workspaceURL.standardizedFileURL
  }

  func saveManifest(_ manifest: WorkflowRunManifest) throws {
    let runDirectory = try runDirectoryURL(for: manifest.runID)
    try FileManager.default.createDirectory(
      at: runDirectory,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    try data.write(to: runDirectory.appendingPathComponent("run.json"), options: .atomic)
  }

  func loadManifest(runID: String) throws -> WorkflowRunManifest {
    let runDirectory = try runDirectoryURL(for: runID)
    let data = try Data(contentsOf: runDirectory.appendingPathComponent("run.json"))
    let manifest = try JSONDecoder().decode(WorkflowRunManifest.self, from: data)
    guard manifest.runID == runID else {
      throw RunRepositoryError.manifestRunIDMismatch(expected: runID, found: manifest.runID)
    }
    return manifest
  }

  func recoverRun(runID: String) throws -> RecoveredWorkflowRun {
    let runDirectory = try runDirectoryURL(for: runID)
    let manifest = try loadManifest(runID: runID)
    let journalURL = runDirectory.appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: journalURL.path) else {
      throw RunRepositoryError.missingJournal(runID)
    }
    let journal = try Data(contentsOf: journalURL)
    var decoder = JSONLStreamDecoder()
    let finish = try decoder.decodeRecoveryJournal(journal)
    let events = finish.events

    if let journalRunID = events.first?.runID, journalRunID != manifest.runID {
      throw RunRepositoryError.manifestRunIDMismatch(
        expected: manifest.runID,
        found: journalRunID
      )
    }

    let snapshot = WorkflowJournalReducer.replay(events)
    let stale =
      manifest.lastCommittedSequence != snapshot.lastSequence
      || snapshot.state.map { $0 != manifest.state } == true
      || snapshot.resumability.map { $0 != manifest.resumability } == true
    return RecoveredWorkflowRun(
      runDirectoryURL: runDirectory,
      manifest: manifest,
      events: events,
      snapshot: snapshot,
      manifestWasStale: stale,
      recoverableCorruptTail: finish.recoverableTail
    )
  }

  func recoverAllRuns() throws -> WorkflowRecoveryBatch {
    guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
      return WorkflowRecoveryBatch(runs: [], failures: [])
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: workspaceURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    let candidates =
      entries
      .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          && FileManager.default.fileExists(
            atPath: url.appendingPathComponent("run.json").path
          )
          && FileManager.default.fileExists(
            atPath: url.appendingPathComponent("events.jsonl").path
          )
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var runs: [RecoveredWorkflowRun] = []
    var failures: [RunRecoveryFailure] = []
    for candidate in candidates {
      let runID = candidate.lastPathComponent
      do {
        runs.append(try recoverRun(runID: runID))
      } catch {
        failures.append(
          RunRecoveryFailure(runID: runID, message: String(describing: error))
        )
      }
    }
    return WorkflowRecoveryBatch(runs: runs, failures: failures)
  }

  func writeCancellationRequest(runID: String) throws {
    let runDirectory = try runDirectoryURL(for: runID)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let marker: [String: JSONValue] = [
      "schema_version": .number(Double(WorkflowEvent.supportedSchemaVersion)),
      "run_id": .string(runID),
      "requested_at": .string(formatter.string(from: Date())),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(marker).write(
      to: runDirectory.appendingPathComponent("cancel.request.json"),
      options: .atomic
    )
  }

  private func runDirectoryURL(for runID: String) throws -> URL {
    guard !runID.isEmpty,
      runID != ".",
      runID != "..",
      !runID.contains("/"),
      !runID.contains(":")
    else {
      throw RunRepositoryError.invalidRunID(runID)
    }
    return workspaceURL.appendingPathComponent(runID, isDirectory: true)
  }
}

enum WorkflowJournalReducer {
  static func replay(_ events: [WorkflowEvent]) -> WorkflowReplaySnapshot {
    var state: WorkflowRunState?
    var resumability: WorkflowResumability?
    var unknownCount = 0

    for event in events {
      switch event.kind {
      case .unknown:
        unknownCount += 1
      case .known(let type):
        switch type {
        case .runCreated:
          state = declaredState(in: event) ?? .created
        case .runState:
          state = declaredState(in: event) ?? state
        case .runInterrupted:
          state = declaredState(in: event) ?? .interrupted
        case .runCompleted:
          state = declaredState(in: event) ?? .completed
        case .runCancelled:
          state = declaredState(in: event) ?? .cancelled
        case .planBlocked:
          state = declaredState(in: event) ?? .blocked
        default:
          break
        }

        if let value = event.payload["resumability"]?.stringValue,
          let declared = WorkflowResumability(rawValue: value)
        {
          resumability = declared
        }
      }
    }

    return WorkflowReplaySnapshot(
      state: state,
      resumability: resumability,
      lastSequence: events.last?.sequence ?? 0,
      unknownEventCount: unknownCount
    )
  }

  private static func declaredState(in event: WorkflowEvent) -> WorkflowRunState? {
    guard let value = event.payload["state"]?.stringValue else { return nil }
    return WorkflowRunState(rawValue: value)
  }
}
