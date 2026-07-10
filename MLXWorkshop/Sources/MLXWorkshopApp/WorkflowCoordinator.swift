import Foundation

enum WorkflowCoordinatorError: Error, Equatable, Sendable {
  case runIsNotRunning(String)
  case recoveryTimedOut(String)
}

enum WorkflowExitDisposition: Equatable, Sendable {
  case succeeded
  case invalidInput
  case blocked
  case protocolFailure
  case executionFailure
  case cancelledOrInterrupted
  case unexpected(Int32)

  init(exitCode: Int32, cancellationRequested: Bool) {
    if cancellationRequested {
      self = .cancelledOrInterrupted
      return
    }
    switch exitCode {
    case 0: self = .succeeded
    case 2: self = .invalidInput
    case 3: self = .blocked
    case 4: self = .protocolFailure
    case 5: self = .executionFailure
    case 6: self = .cancelledOrInterrupted
    default: self = .unexpected(exitCode)
    }
  }
}

enum WorkflowStreamFailure: Error, Equatable, Sendable {
  case protocolMismatch(supported: Int, found: Int)
  case invalidTimestamp(String)
  case malformedLine(Int)
  case noncontiguousSequence(expected: Int, found: Int)
  case runIDChanged(expected: String, found: String)
  case invalidEvent(String)

  init(_ error: Error) {
    if let error = error as? WorkflowProtocolError {
      switch error {
      case .protocolMismatch(let supported, let found):
        self = .protocolMismatch(supported: supported, found: found)
      case .invalidTimestamp(let timestamp):
        self = .invalidTimestamp(timestamp)
      }
    } else if let error = error as? JSONLStreamError {
      switch error {
      case .malformedLine(let line): self = .malformedLine(line)
      case .noncontiguousSequence(let expected, let found):
        self = .noncontiguousSequence(expected: expected, found: found)
      case .runIDChanged(let expected, let found):
        self = .runIDChanged(expected: expected, found: found)
      }
    } else {
      self = .invalidEvent(String(describing: error))
    }
  }
}

struct WorkflowExecution: Equatable, Sendable {
  let process: ProcessRunResult
  let events: [WorkflowEvent]
  let snapshot: WorkflowReplaySnapshot
  let exitDisposition: WorkflowExitDisposition
  let streamFailure: WorkflowStreamFailure?

  var protocolMutationIsAllowed: Bool {
    streamFailure == nil && exitDisposition != .protocolFailure
  }
}

actor WorkflowCoordinator {
  typealias EventHandler = @Sendable (WorkflowEvent) async -> Void

  private let processRunner: ProcessRunner
  private let runRepository: RunRepository

  init(processRunner: ProcessRunner, runRepository: RunRepository) {
    self.processRunner = processRunner
    self.runRepository = runRepository
  }

  func execute(
    _ request: ProcessRequest,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowExecution {
    let collector = WorkflowLiveEventCollector(onEvent: onEvent)
    let result = try await processRunner.run(request) { chunk in
      guard chunk.stream == .stdout else { return }
      await collector.consume(chunk.data)
    }
    await collector.finish()
    let collected = await collector.result()
    return WorkflowExecution(
      process: result,
      events: collected.events,
      snapshot: WorkflowJournalReducer.replay(collected.events),
      exitDisposition: WorkflowExitDisposition(
        exitCode: result.exitCode,
        cancellationRequested: result.cancellationRequested
      ),
      streamFailure: collected.failure
    )
  }

  func executeContinuation(
    _ request: ProcessRequest,
    runID: String,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowExecution {
    let recovered = try await runRepository.recoverRun(runID: runID)
    let journal = try Data(
      contentsOf: recovered.runDirectoryURL.appendingPathComponent("events.jsonl"))
    let collector = WorkflowLiveEventCollector(onEvent: onEvent)
    await collector.bootstrap(journal)
    if let failure = await collector.result().failure {
      throw failure
    }
    let result = try await processRunner.run(request) { chunk in
      guard chunk.stream == .stdout else { return }
      await collector.consume(chunk.data)
    }
    await collector.finish()
    let collected = await collector.result()
    return WorkflowExecution(
      process: result,
      events: collected.events,
      snapshot: WorkflowJournalReducer.replay(collected.events),
      exitDisposition: WorkflowExitDisposition(
        exitCode: result.exitCode,
        cancellationRequested: result.cancellationRequested
      ),
      streamFailure: collected.failure
    )
  }

  @discardableResult
  func cancel(requestID: UUID, grace: Duration = .seconds(2)) async -> Bool {
    await processRunner.cancel(id: requestID, grace: grace)
  }

  @discardableResult
  func interrupt(requestID: UUID) async -> Bool {
    await processRunner.interrupt(id: requestID)
  }

  @discardableResult
  func requestCancellation(
    runID: String,
    requestID: UUID,
    cooperativeGrace: Duration = .seconds(5),
    terminationGrace: Duration = .seconds(2)
  ) async throws -> Bool {
    guard await processRunner.activeProcessIDs().contains(requestID) else { return false }
    try await runRepository.writeCancellationRequest(runID: runID)
    try? await Task.sleep(for: cooperativeGrace)
    _ = terminationGrace
    // The Python executor owns its recorded conversion child and journals the
    // signal it sends. Killing only the tracked CLI wrapper here could orphan that
    // separately-sessioned child, so an accepted marker remains cooperative.
    return true
  }

  func recoverRun(runID: String) async throws -> RecoveredWorkflowRun {
    try await runRepository.recoverRun(runID: runID)
  }

  func recoverAllRuns() async throws -> WorkflowRecoveryBatch {
    try await runRepository.recoverAllRuns()
  }

  func cancelRecoveredRun(
    runID: String,
    pollInterval: Duration = .milliseconds(100),
    timeout: Duration = .seconds(15)
  ) async throws -> RecoveredWorkflowRun {
    var recovered = try await runRepository.recoverRun(runID: runID)
    guard recovered.effectiveState == .running || recovered.effectiveState == .cancelling else {
      throw WorkflowCoordinatorError.runIsNotRunning(runID)
    }
    if recovered.effectiveState == .running {
      try await runRepository.writeCancellationRequest(runID: runID)
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      try await Task.sleep(for: pollInterval)
      recovered = try await runRepository.recoverRun(runID: runID)
      switch recovered.effectiveState {
      case .cancelled, .completed, .failed, .blocked:
        return recovered
      case .created, .planned, .running, .cancelling, .interrupted:
        continue
      }
    }
    throw WorkflowCoordinatorError.recoveryTimedOut(runID)
  }
}

private actor WorkflowLiveEventCollector {
  typealias EventHandler = @Sendable (WorkflowEvent) async -> Void
  private static let retainedStageLogLimit = 256

  private var decoder = JSONLStreamDecoder()
  private var events: [WorkflowEvent] = []
  private var retainedStageLogCount = 0
  private var failure: WorkflowStreamFailure?
  private let onEvent: EventHandler

  init(onEvent: @escaping EventHandler) {
    self.onEvent = onEvent
  }

  func bootstrap(_ journal: Data) async {
    guard failure == nil else { return }
    do {
      let decoded = try decoder.append(journal)
      let finish = try decoder.finish(recoveringFinalCorruptTail: false)
      await retainAndDeliver(decoded + finish.events, deliver: false)
    } catch {
      failure = WorkflowStreamFailure(error)
    }
  }

  func consume(_ data: Data) async {
    guard failure == nil else { return }
    do {
      let decoded = try decoder.append(data)
      await retainAndDeliver(decoded)
    } catch {
      failure = WorkflowStreamFailure(error)
    }
  }

  func finish() async {
    guard failure == nil else { return }
    do {
      let result = try decoder.finish(recoveringFinalCorruptTail: false)
      await retainAndDeliver(result.events)
    } catch {
      failure = WorkflowStreamFailure(error)
    }
  }

  func result() -> (events: [WorkflowEvent], failure: WorkflowStreamFailure?) {
    (events, failure)
  }

  private func retainAndDeliver(_ decoded: [WorkflowEvent], deliver: Bool = true) async {
    for event in decoded {
      if event.kind == .known(.stageLog) {
        events.append(event)
        retainedStageLogCount += 1
        if retainedStageLogCount > Self.retainedStageLogLimit,
          let oldestLog = events.firstIndex(where: { $0.kind == .known(.stageLog) })
        {
          events.remove(at: oldestLog)
          retainedStageLogCount -= 1
        }
        // Raw stdout/stderr files are the authoritative logs. Avoid serializing a
        // potentially unbounded log flood through the MainActor presentation path.
        continue
      }
      events.append(event)
      if deliver { await onEvent(event) }
    }
  }
}
