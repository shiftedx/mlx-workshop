import Foundation
import XCTest

@testable import MLXWorkshopApp

@MainActor
final class WorkshopWorkflowSessionTests: XCTestCase {
  func testFixturePlanningPresentsConfirmationWithoutCreatingRunDirectory() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }

    await harness.session.planFixture(
      runID: "session-plan-only", scenario: "success", into: harness.store)

    XCTAssertEqual(harness.store.currentRun?.state, .planned)
    XCTAssertEqual(harness.store.pendingConfirmation?.runID, "session-plan-only")
    XCTAssertEqual(
      harness.store.pendingConfirmation?.plan.evidenceKind,
      "deterministic-fixture-not-measured")
    XCTAssertEqual(harness.store.pendingConfirmation?.changesWeights, false)
    XCTAssertTrue(harness.store.showConfirmation)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent("session-plan-only").path))
  }

  func testDecliningFixtureConfirmationKeepsReviewedPlanButCreatesNoRunDirectory() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    await harness.session.planFixture(
      runID: "session-decline", scenario: "success", into: harness.store)

    harness.session.declinePendingRun(harness.store)

    XCTAssertFalse(harness.store.showConfirmation)
    XCTAssertEqual(harness.store.pendingConfirmation?.runID, "session-decline")
    XCTAssertEqual(harness.store.currentRun?.state, .planned)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent("session-decline").path))
    harness.store.requestRunAction()
    XCTAssertTrue(harness.store.showConfirmation)
  }

  func testConfirmedSuccessStreamsAndRecoversJournalWithoutQualification() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    await harness.session.planFixture(
      runID: "session-success", scenario: "success", into: harness.store)

    await harness.session.confirmPendingRun(harness.store)

    XCTAssertNil(harness.store.pendingConfirmation)
    XCTAssertEqual(harness.store.currentRun?.state, .completed)
    XCTAssertEqual(harness.store.currentRun?.isQualified, false)
    XCTAssertEqual(harness.store.runs.map(\.state), [.completed])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent("session-success/events.jsonl").path))

    let relaunchedStore = WorkshopStore()
    relaunchedStore.selectRunWorkspace(harness.workspace)
    let relaunchedSession = WorkshopWorkflowSession(runtime: harness.runtime)
    await relaunchedSession.recoverWorkspaceRuns(relaunchedStore)

    XCTAssertEqual(relaunchedStore.runs.map(\.state), [.completed])
  }

  func testQualifyRunRecoversQualifiedStateAndEvidenceWithoutChangingRunIdentity()
    async throws
  {
    let harness = try makeHarness()
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-session-parent-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: harness.workspace)
      try? FileManager.default.removeItem(at: parent)
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    harness.store.selectModelDirectory(parent)
    harness.store.apply(
      .modelInspected(
        LocalModelReference(directory: parent, displayName: parent.lastPathComponent), layers: []))
    await harness.session.planFixture(
      runID: "session-qualify", scenario: "success", into: harness.store)
    await harness.session.confirmPendingRun(harness.store)

    await harness.session.qualifyRun(runID: "session-qualify", into: harness.store)

    XCTAssertEqual(harness.store.currentRun?.id, "session-qualify")
    XCTAssertEqual(harness.store.currentRun?.state, .completed)
    XCTAssertEqual(harness.store.currentRun?.isQualified, true)
    XCTAssertEqual(harness.store.runs.first?.isQualified, true)
  }

  func testConfirmedCancellationIsObservedAndRecoveredAsCancelled() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    await harness.session.planFixture(
      runID: "session-cancel", scenario: "cancel", into: harness.store)

    let execution = Task { @MainActor in
      await harness.session.confirmPendingRun(harness.store)
    }
    try await waitUntil {
      harness.store.currentRun?.state == .running && harness.store.canCancelRun
    }
    XCTAssertEqual(harness.store.currentRun?.state, .running)
    await harness.store.requestCancellation()
    await execution.value

    XCTAssertEqual(harness.store.currentRun?.state, .cancelled)
    XCTAssertEqual(harness.store.currentRun?.stage, "fixture")
    XCTAssertEqual(harness.store.currentRun?.isQualified, false)
    XCTAssertEqual(
      harness.store.currentRun?.stdoutLog?.lastPathComponent,
      "fixture.stdout.log")
    XCTAssertEqual(
      harness.store.currentRun?.stderrLog?.lastPathComponent,
      "fixture.stderr.log")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent("session-cancel/cancel.request.json").path)
    )

    let relaunchedStore = WorkshopStore()
    relaunchedStore.selectRunWorkspace(harness.workspace)
    let relaunchedSession = WorkshopWorkflowSession(runtime: harness.runtime)
    await relaunchedSession.recoverWorkspaceRuns(relaunchedStore)

    XCTAssertEqual(relaunchedStore.runs.map(\.state), [.cancelled])
  }

  func testBlockedFixtureCannotReachConfirmationOrStartRun() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }

    await harness.session.planFixture(
      runID: "session-blocked", scenario: "block", into: harness.store)

    XCTAssertEqual(harness.store.currentRun?.state, .blocked)
    XCTAssertFalse(harness.store.currentRun?.plan?.blockers.isEmpty ?? true)
    XCTAssertNil(harness.store.pendingConfirmation)
    XCTAssertFalse(harness.store.showConfirmation)
    await harness.session.confirmPendingRun(harness.store)
    XCTAssertEqual(harness.store.currentRun?.state, .blocked)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent("session-blocked").path))
  }

  func testConfirmedInterruptionIsRecoveredFromJournal() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    await harness.session.planFixture(
      runID: "session-interrupted", scenario: "interrupt-once", into: harness.store)

    let execution = Task { @MainActor in
      await harness.session.confirmPendingRun(harness.store)
    }
    try await waitUntil { harness.store.currentRun?.state == .running }
    let interruptionMarker = harness.workspace.appendingPathComponent(
      "session-interrupted/artifacts/.interrupt-once-started")
    try await waitUntil {
      FileManager.default.fileExists(atPath: interruptionMarker.path)
    }
    let interrupted = await harness.session.interruptRunningRun(harness.store)
    XCTAssertTrue(interrupted)
    await execution.value

    XCTAssertEqual(harness.store.currentRun?.state, .interrupted)
    XCTAssertEqual(harness.store.currentRun?.stage, "fixture")
    XCTAssertEqual(harness.store.currentRun?.resumability, "safe")
    XCTAssertEqual(harness.store.currentRun?.isQualified, false)

    let relaunchedStore = WorkshopStore()
    relaunchedStore.selectRunWorkspace(harness.workspace)
    let relaunchedSession = WorkshopWorkflowSession(runtime: harness.runtime)
    await relaunchedSession.recoverWorkspaceRuns(relaunchedStore)

    XCTAssertEqual(relaunchedStore.runs.map(\.state), [.interrupted])
  }

  func testResumeRunUsesTrackedHandleAndRecoversSameRunAsCompleted() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    await harness.session.planFixture(
      runID: "session-resume", scenario: "interrupt-once", into: harness.store)
    let execution = Task { @MainActor in
      await harness.session.confirmPendingRun(harness.store)
    }
    try await waitUntil { harness.store.currentRun?.state == .running }
    let interruptionMarker = harness.workspace.appendingPathComponent(
      "session-resume/artifacts/.interrupt-once-started")
    try await waitUntil {
      FileManager.default.fileExists(atPath: interruptionMarker.path)
    }
    let interrupted = await harness.session.interruptRunningRun(harness.store)
    XCTAssertTrue(interrupted)
    await execution.value
    XCTAssertEqual(harness.store.currentRun?.state, .interrupted)

    await harness.session.resumeRun(runID: "session-resume", into: harness.store)

    XCTAssertEqual(harness.store.currentRun?.id, "session-resume")
    XCTAssertEqual(harness.store.currentRun?.state, .completed)
    XCTAssertEqual(harness.store.currentRun?.isQualified, false)
    XCTAssertEqual(harness.store.runs.map(\.state), [.completed])
  }

  func testRequestRecoveredCancellationTargetsRunMarkerAndPollsToCancelled() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    let launchingClient = try WorkflowCLIClient(
      runtime: harness.runtime, runWorkspaceURL: harness.workspace)
    let plan = try await launchingClient.planFixture(
      runID: "session-recovered-cancel", scenario: "cancel")
    let handle = await launchingClient.startRun(planURL: plan.planURL)
    try await waitUntil {
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent(
          "session-recovered-cancel/artifacts/.interrupt-once-started"
        ).path)
    }

    await harness.session.requestRecoveredCancellation(
      runID: "session-recovered-cancel", into: harness.store)
    _ = try await handle.value()

    XCTAssertEqual(harness.store.currentRun?.id, "session-recovered-cancel")
    XCTAssertEqual(harness.store.currentRun?.state, .cancelled)
    XCTAssertEqual(harness.store.runs.map(\.state), [.cancelled])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent(
          "session-recovered-cancel/cancel.request.json"
        ).path))
  }

  func testRealPlanningAttachesExactDecodedPlanAndCommandWithoutStarting() async throws {
    let harness = try makeHarness()
    let model = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-session-model-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: harness.workspace)
      try? FileManager.default.removeItem(at: model)
    }
    try makeTinyFloatModel(at: model)
    harness.store.selectModelDirectory(model)
    harness.store.apply(
      .modelInspected(
        LocalModelReference(directory: model, displayName: model.lastPathComponent), layers: []))

    await harness.session.planSelectedModel(harness.store)

    let confirmation = try XCTUnwrap(harness.store.pendingConfirmation)
    let planURL = harness.workspace.appendingPathComponent(
      ".plans/\(confirmation.runID).plan.json")
    let decodedPlan = try WorkflowPlan.decode(Data(contentsOf: planURL))
    let client = try WorkflowCLIClient(
      runtime: harness.runtime, runWorkspaceURL: harness.workspace)
    let decodedCommand = try await client.commandDisclosure(planURL: planURL)
    XCTAssertEqual(confirmation.plan, decodedPlan.disclosure)
    XCTAssertEqual(confirmation.command, decodedCommand)
    XCTAssertTrue(confirmation.changesWeights)
    XCTAssertEqual(harness.store.currentRun?.state, .planned)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent(confirmation.runID).path))
  }

  func testConfirmDoesNothingWhenSessionHasNoExactPendingPlan() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.workspace) }
    let plan = PlanDisclosure(
      runDirectory: harness.workspace.appendingPathComponent("not-recorded").path,
      exactParent: "deterministic-fixture://missing-plan",
      quantModes: ["fixture-only"],
      evidenceKind: "deterministic-fixture-not-measured",
      uncertainty: "fixture-values-not-measured",
      estimatedOutputBytes: nil,
      estimatedTemporaryBytes: nil,
      requiredFreeDiskBytes: nil,
      observedFreeDiskBytes: 0,
      estimatedPeakMemoryBytes: nil,
      observedUnifiedMemoryBytes: nil,
      estimatedDurationSeconds: nil,
      timeBudgetSeconds: 0,
      feasibility: "fixture-only",
      reasonCodes: [],
      requiredGates: ["fixture-only-no-qualification"],
      blockers: [])
    let command = CommandDisclosure(
      executableIdentity: "/deterministic-fixture/tool",
      arguments: ["--fixture-only"],
      redactedDisplay: "/deterministic-fixture/tool --fixture-only")
    harness.store.apply(
      .runChanged(
        WorkshopRun(id: "not-recorded", title: "Missing plan", state: .planned)))
    harness.store.presentConfirmation(
      RunConfirmation(
        runID: "not-recorded", plan: plan, command: command, changesWeights: false))

    await harness.session.confirmPendingRun(harness.store)

    XCTAssertEqual(harness.store.currentRun?.state, .planned)
    XCTAssertNotNil(harness.store.pendingConfirmation)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: harness.workspace.appendingPathComponent("not-recorded").path))
  }

  private func makeHarness() throws -> (
    session: WorkshopWorkflowSession, store: WorkshopStore, workspace: URL,
    runtime: WorkflowCLIRuntime
  ) {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-session-\(UUID().uuidString)", isDirectory: true)
    let store = WorkshopStore()
    let fixtureModel = URL(fileURLWithPath: "/deterministic-fixture/model", isDirectory: true)
    store.selectModelDirectory(fixtureModel)
    store.selectRunWorkspace(workspace)
    store.apply(
      .modelInspected(
        LocalModelReference(directory: fixtureModel, displayName: "fixture-model"), layers: []))
    return (
      WorkshopWorkflowSession(
        defaults: UserDefaults(suiteName: "WorkshopWorkflowSessionTests-\(UUID().uuidString)")!,
        runtime: runtime),
      store,
      workspace,
      runtime
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      guard clock.now < deadline else {
        XCTFail("Timed out waiting for session state.")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeTinyFloatModel(at model: URL) throws {
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    let config: [String: Any] = [
      "model_type": "llama",
      "architectures": ["LlamaForCausalLM"],
      "hidden_size": 2,
      "num_hidden_layers": 1,
    ]
    try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
      .write(to: model.appendingPathComponent("config.json"))

    let tensorName = "model.layers.0.self_attn.o_proj.weight"
    let header: [String: Any] = [
      tensorName: [
        "dtype": "F32",
        "shape": [2, 2],
        "data_offsets": [0, 16],
      ]
    ]
    let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    var headerLength = UInt64(headerData.count).littleEndian
    var safetensors = withUnsafeBytes(of: &headerLength) { Data($0) }
    safetensors.append(headerData)
    safetensors.append(Data(repeating: 0, count: 16))
    let shardName = "model-00001-of-00001.safetensors"
    try safetensors.write(to: model.appendingPathComponent(shardName))
    let index: [String: Any] = ["weight_map": [tensorName: shardName]]
    try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
      .write(to: model.appendingPathComponent("model.safetensors.index.json"))
  }
}
