import Foundation

extension WorkflowCoordinator: WorkshopCancellationCoordinating {}

struct WorkflowPresentationAdapter: WorkshopEventProjecting {
  typealias Event = WorkflowEvent

  func project(_ event: WorkflowEvent) -> WorkshopSessionUpdate? {
    project(event, currentRun: nil)
  }

  func project(_ event: WorkflowEvent, currentRun: WorkshopRun?) -> WorkshopSessionUpdate? {
    guard case .known(let kind) = event.kind else { return nil }
    guard currentRun == nil || currentRun?.id == event.runID else { return nil }
    var run =
      currentRun
      ?? WorkshopRun(
        id: event.runID,
        title: "Local workflow",
        state: .planned
      )
    run.stage = event.stage ?? run.stage

    switch kind {
    case .runCreated:
      return nil
    case .planReady:
      run.state = .planned
      run.statusDetail = "Plan ready"
    case .planBlocked:
      run.state = .blocked
      run.statusDetail = "Plan blocked"
      run.diagnostics.append(diagnostic(from: event, blocker: true))
    case .runState:
      guard let state = event.payload["state"]?.stringValue else { return nil }
      apply(state: WorkflowRunState(rawValue: state), to: &run)
    case .runInterrupted:
      run.state = .interrupted
      run.statusDetail = message(from: event) ?? "The workflow was interrupted."
    case .runCompleted:
      run.state = .completed
      run.statusDetail = message(from: event) ?? "Execution completed; qualification is separate."
      run.isQualified = false
    case .runCancelled:
      run.state = .cancelled
      run.statusDetail = message(from: event) ?? "Cancellation was journaled."
      run.isQualified = false
    case .stageStarted, .stageLog, .stageCompleted:
      if run.state != .cancelling { run.state = .running }
    case .stageProgress:
      if run.state != .cancelling { run.state = .running }
      if let completed = number("completed", in: event) {
        run.progress = RunProgress(
          completed: completed,
          total: number("total", in: event),
          unit: event.payload["unit"]?.stringValue
        )
      }
    case .stageFailed:
      run.state = .failed
      run.statusDetail = message(from: event) ?? "A workflow stage failed."
      run.diagnostics.append(diagnostic(from: event, blocker: true))
      run.isQualified = false
    case .warningRaised, .resourcePressure:
      run.diagnostics.append(diagnostic(from: event, blocker: false))
    case .capabilityReported, .artifactDiscovered, .metricRecorded, .evaluationRecorded,
      .promotionGate:
      return nil
    }

    if let resumability = event.payload["resumability"]?.stringValue {
      run.resumability = resumability
    }
    return .runChanged(run)
  }

  func run(from recovered: RecoveredWorkflowRun) -> WorkshopRun {
    let manifest = recovered.manifest
    let evidenceStage =
      manifest.lastCompletedStage
      ?? manifest.childProcesses.last?.stage
      ?? recovered.events.reversed().compactMap(\.stage).first
    let stdoutLog = evidenceStage.map {
      recovered.runDirectoryURL.appendingPathComponent("logs/\($0).stdout.log")
    }
    let stderrLog = evidenceStage.map {
      recovered.runDirectoryURL.appendingPathComponent("logs/\($0).stderr.log")
    }
    var run = WorkshopRun(
      id: manifest.runID,
      title: manifest.exactParent.map {
        "Workflow from \(URL(fileURLWithPath: $0).lastPathComponent)"
      }
        ?? "Recovered workflow",
      state: presentationState(recovered.effectiveState),
      stage: evidenceStage,
      statusDetail: manifest.terminalReason,
      resumability: recovered.effectiveResumability.rawValue,
      runDirectory: recovered.runDirectoryURL,
      stdoutLog: stdoutLog.flatMap {
        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
      },
      stderrLog: stderrLog.flatMap {
        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
      },
      command: try? CommandDisclosure.load(
        from: recovered.runDirectoryURL.appendingPathComponent("commands.json")),
      diagnostics: manifest.blockers.map {
        WorkshopDiagnostic(
          id: $0.code,
          severity: .blocker,
          title: "Workflow blocker",
          message: $0.message,
          recovery: .openLog
        )
      }
    )
    if recovered.recoverableCorruptTail != nil {
      run.diagnostics.append(
        WorkshopDiagnostic(
          id: "recoverable-corrupt-tail",
          severity: .warning,
          title: "Incomplete final journal line",
          message:
            "The final partial event was ignored. Earlier journal evidence remains available.",
          recovery: .openLog
        ))
    }
    run.isQualified =
      manifest.qualified == true
      && recovered.effectiveState == .completed
      && manifest.blockers.isEmpty
    return run
  }

  func history(from batch: WorkflowRecoveryBatch) -> [RunRecord] {
    let recovered = batch.runs.enumerated().map { offset, item in
      let run = run(from: item)
      return RunRecord(
        runID: item.manifest.runID,
        number: offset + 1,
        title: run.title,
        created: item.manifest.createdAt,
        duration: "—",
        state: run.state,
        summary:
          "\(item.events.count) events · resumability \(item.effectiveResumability.rawValue)",
        runDirectory: item.runDirectoryURL,
        stdoutLog: run.stdoutLog,
        stderrLog: run.stderrLog,
        command: run.command,
        resumability: run.resumability,
        isQualified: run.isQualified
      )
    }
    let failures = batch.failures.enumerated().map { offset, failure in
      RunRecord(
        runID: failure.runID,
        number: recovered.count + offset + 1,
        title: failure.runID,
        created: "Recovery failed",
        duration: "—",
        state: .protocolMismatch,
        summary: failure.message
      )
    }
    return recovered + failures
  }

  private func apply(state: WorkflowRunState?, to run: inout WorkshopRun) {
    guard let state else { return }
    run.state = presentationState(state)
    if state == .blocked {
      run.statusDetail = "The plan is blocked."
      run.diagnostics.append(
        WorkshopDiagnostic(
          id: "plan-blocked",
          severity: .blocker,
          title: "Plan blocked",
          message: "Resolve the workflow blocker before starting execution.",
          recovery: .openLog
        ))
    }
    if state == .completed || state == .failed || state == .cancelled {
      run.isQualified = false
    }
  }

  private func presentationState(_ state: WorkflowRunState) -> WorkshopRunState {
    switch state {
    case .created, .planned: .planned
    case .blocked: .blocked
    case .running: .running
    case .cancelling: .cancelling
    case .cancelled: .cancelled
    case .interrupted: .interrupted
    case .failed: .failed
    case .completed: .completed
    }
  }

  private func number(_ key: String, in event: WorkflowEvent) -> Double? {
    guard case .number(let value) = event.payload[key] else { return nil }
    return value
  }

  private func message(from event: WorkflowEvent) -> String? {
    event.payload["message"]?.stringValue
      ?? event.payload["reason"]?.stringValue
  }

  private func diagnostic(from event: WorkflowEvent, blocker: Bool) -> WorkshopDiagnostic {
    WorkshopDiagnostic(
      id: event.payload["code"]?.stringValue ?? "\(event.rawType)-\(event.sequence)",
      severity: blocker ? .blocker : .warning,
      title: blocker ? "Workflow blocked" : "Workflow warning",
      message: message(from: event) ?? "See the raw run evidence for details.",
      recovery: .openLog
    )
  }
}

@MainActor
extension WorkshopStore {
  func apply(_ execution: WorkflowExecution) {
    let adapter = WorkflowPresentationAdapter()
    for event in execution.events {
      if let update = adapter.project(event, currentRun: currentRun) {
        apply(update)
      }
    }

    if execution.exitDisposition == .protocolFailure
      || execution.streamFailure?.isProtocolMismatch == true
    {
      applyProtocolMismatch("The local workflow uses an unsupported protocol version.")
    } else if execution.streamFailure != nil {
      applyExecutionFailure("The event stream is corrupt. Open the raw journal before retrying.")
    } else if execution.exitDisposition == .executionFailure {
      applyExecutionFailure("The local workflow exited with an execution failure.")
    }
  }

  func apply(_ recovered: RecoveredWorkflowRun) {
    apply(.runChanged(WorkflowPresentationAdapter().run(from: recovered)))
  }

  private func applyProtocolMismatch(_ message: String) {
    var run =
      currentRun
      ?? WorkshopRun(id: "unknown-run", title: "Local workflow", state: .protocolMismatch)
    run.state = .protocolMismatch
    run.statusDetail = message
    run.isQualified = false
    apply(.runChanged(run))
  }

  private func applyExecutionFailure(_ message: String) {
    var run = currentRun ?? WorkshopRun(id: "unknown-run", title: "Local workflow", state: .failed)
    guard !run.state.isTerminal else { return }
    run.state = .failed
    run.statusDetail = message
    run.isQualified = false
    apply(.runChanged(run))
  }
}

extension WorkflowStreamFailure {
  fileprivate var isProtocolMismatch: Bool {
    if case .protocolMismatch = self { return true }
    return false
  }
}
