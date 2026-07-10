import Foundation
import XCTest

@testable import MLXWorkshopApp

final class WorkflowCLIClientTests: XCTestCase {
  func testRuntimeLocatorPrefersBundledRuntimeWithoutCheckoutOrShellOverride() throws {
    let resources = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-bundle-\(UUID().uuidString)")
    let runtimeRoot = resources.appendingPathComponent("Runtime")
    try FileManager.default.createDirectory(
      at: runtimeRoot.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: runtimeRoot.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let python = runtimeRoot.appendingPathComponent(".venv/bin/python")
    let cli = runtimeRoot.appendingPathComponent("scripts/mlx_workflow_cli.py")
    try Data("#!/bin/sh\n".utf8).write(to: python)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: python.path)
    try Data("# bundled CLI\n".utf8).write(to: cli)
    defer { try? FileManager.default.removeItem(at: resources) }

    let located = try WorkflowRuntimeLocator.locate(
      environment: [:],
      currentDirectoryURL: URL(fileURLWithPath: "/"),
      bundleResourceURL: resources)

    XCTAssertEqual(located.sourceWorkspaceURL.standardizedFileURL, runtimeRoot.standardizedFileURL)
    XCTAssertEqual(located.pythonURL.standardizedFileURL, python.standardizedFileURL)
    XCTAssertEqual(located.cliURL.standardizedFileURL, cli.standardizedFileURL)
  }

  func testBundledRuntimeValidationRejectsManifestHashMismatch() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-integrity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let python = root.appendingPathComponent(".venv/bin/python")
    let cli = root.appendingPathComponent("scripts/mlx_workflow_cli.py")
    let manifest = root.appendingPathComponent("runtime-manifest.json")
    let lock = root.deletingLastPathComponent().appendingPathComponent("runtime.lock.json")
    try Data("#!/bin/sh\n".utf8).write(to: python)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    try Data("# cli\n".utf8).write(to: cli)
    try Data("{\"file_count\":0,\"files\":{}}\n".utf8).write(to: manifest)
    try Data(
      "{\"status\":\"bundled-and-verified\",\"manifest\":{\"sha256\":\"wrong\"}}\n".utf8
    ).write(to: lock)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: lock)
    }

    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: root, pythonURL: python, cliURL: cli,
      integrityLockURL: lock, integrityManifestURL: manifest)
    XCTAssertThrowsError(try runtime.validate()) { error in
      guard case WorkflowCLIClientError.runtimeIntegrityFailure = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testRuntimeLocatorFindsWorkspaceFromSwiftPackageDirectory() throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = try WorkflowRuntimeLocator.locate(
      environment: [:],
      currentDirectoryURL: sourceWorkspace.appendingPathComponent("MLXWorkshop"))

    XCTAssertEqual(
      runtime.sourceWorkspaceURL.standardizedFileURL,
      sourceWorkspace.standardizedFileURL)
    XCTAssertEqual(
      runtime.pythonURL.standardizedFileURL,
      sourceWorkspace.appendingPathComponent(".venv/bin/python").standardizedFileURL)
    XCTAssertEqual(
      runtime.cliURL.standardizedFileURL,
      sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py").standardizedFileURL)
  }

  func testInterruptRejectsAnUntrackedRequestWithoutSignallingAProcess() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let runWorkspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-untracked-interrupt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: runWorkspace) }
    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: runWorkspace)

    let interrupted = await client.interruptRun(requestID: UUID())
    XCTAssertFalse(interrupted)
  }

  func testPlansRunsAndRecoversDeterministicSuccessFixtureThroughRealCLI() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py")
    )
    let runWorkspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-swift-cli-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runWorkspace) }

    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: runWorkspace)
    let plan = try await client.planFixture(runID: "swift-fixture", scenario: "success")

    XCTAssertEqual(plan.execution.exitDisposition, .succeeded)
    XCTAssertEqual(plan.execution.events.last?.kind, .known(.planReady))
    XCTAssertTrue(FileManager.default.fileExists(atPath: plan.planURL.path))
    let disclosure = try await client.commandDisclosure(planURL: plan.planURL)
    XCTAssertTrue(disclosure.executableIdentity.hasSuffix("python3.11"))
    XCTAssertEqual(disclosure.arguments.first?.hasSuffix("workflow_fake_stage.py"), true)
    XCTAssertTrue(disclosure.redactedDisplay.contains("workflow_fake_stage.py"))

    let handle = await client.startRun(planURL: plan.planURL)
    let execution = try await handle.value()

    XCTAssertEqual(execution.exitDisposition, .succeeded)
    XCTAssertNil(execution.streamFailure)
    XCTAssertEqual(execution.snapshot.state, .completed)

    let recovered = try await client.recoverRun(runID: "swift-fixture")
    XCTAssertEqual(recovered.effectiveState, .completed)
    XCTAssertFalse(recovered.events.isEmpty)
    XCTAssertEqual(recovered.manifest.lastCommittedSequence, recovered.snapshot.lastSequence)
    XCTAssertEqual(recovered.manifest.state, recovered.snapshot.state)
    XCTAssertEqual(recovered.manifest.resumability, recovered.snapshot.resumability)
    XCTAssertFalse(recovered.manifestWasStale)

    let batch = try await client.recoverAllRuns()
    XCTAssertEqual(batch.runs.map(\.manifest.runID), ["swift-fixture"])
    XCTAssertTrue(batch.failures.isEmpty)
    let history = WorkflowPresentationAdapter().history(from: batch)
    XCTAssertEqual(history.map(\.state), [.completed])
    XCTAssertEqual(history.first?.runDirectory, recovered.runDirectoryURL)
    XCTAssertEqual(history.first?.stdoutLog?.lastPathComponent, "fixture.stdout.log")
    XCTAssertEqual(history.first?.stderrLog?.lastPathComponent, "fixture.stderr.log")
    XCTAssertNotNil(history.first?.command)
    XCTAssertEqual(history.first?.resumability, "not-applicable")
    XCTAssertEqual(history.first?.isQualified, false)
  }

  func testQualifiesCompletedRunAndRecoversQualifiedEvidenceThroughRealCLI() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let runWorkspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-qualify-\(UUID().uuidString)")
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-qualify-parent-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: runWorkspace)
      try? FileManager.default.removeItem(at: parent)
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: runWorkspace)
    let plan = try await client.planFixture(
      runID: "native-qualify", scenario: "success", modelURL: parent)
    _ = try await client.startRun(planURL: plan.planURL).value()

    let execution = try await client.qualifyRun(runID: "native-qualify")
    let recovered = try await client.recoverRun(runID: "native-qualify")

    XCTAssertEqual(execution.exitDisposition, .succeeded)
    XCTAssertNil(execution.streamFailure)
    XCTAssertEqual(recovered.manifest.runID, "native-qualify")
    XCTAssertEqual(recovered.effectiveState, .completed)
    XCTAssertEqual(recovered.manifest.qualified, true)
    XCTAssertTrue(recovered.events.contains { $0.kind == .known(.promotionGate) })
    XCTAssertTrue(WorkflowPresentationAdapter().run(from: recovered).isQualified)
  }

  func testStagesAQualifiedRealCandidateWithoutChangingItsParent() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-stage-\(UUID().uuidString)")
    let runWorkspace = base.appendingPathComponent("runs")
    let stagingRoot = base.appendingPathComponent("staged")
    let model = sourceWorkspace.appendingPathComponent("tests/fixtures/tiny-llama-float")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: runWorkspace)
    let recipe = try OptimizationRecipe.unplanned.workflowRecipe(exactParent: model)
    let plan = try await client.planModel(
      runID: "native-stage", modelURL: model, recipe: recipe)
    _ = try await client.startRun(
      planURL: plan.planURL, expectedPlanSHA256: plan.planSHA256
    ).value()
    _ = try await client.qualifyRun(runID: "native-stage")

    let evidence = try await client.evidence(runID: "native-stage")
    let evidenceEvent = try XCTUnwrap(
      evidence.events.last(where: {
        $0.kind == .known(.evaluationRecorded) && $0.stage == "compare"
      }))
    let candidates = try XCTUnwrap(WorkflowEvidenceProjector().project(evidenceEvent))
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates.last?.status, .qualified)
    XCTAssertNil(candidates.last?.throughput)

    let execution = try await client.stageRun(
      runID: "native-stage", stagingRoot: stagingRoot, stageID: "friend-beta")

    XCTAssertEqual(execution.exitDisposition, .succeeded, execution.process.stderr.text)
    XCTAssertTrue(
      execution.events.contains { event in
        event.kind == .known(.artifactDiscovered)
          && event.payload["kind"] == .string("staged-candidate")
      })
    let stage = stagingRoot.appendingPathComponent("friend-beta")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: stage.appendingPathComponent("staging-manifest.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: stage.appendingPathComponent("model.safetensors").path)
    )
  }

  func testResumesJournalSafeInterruptedRunThroughTrackedHandleWithoutChangingIdentity()
    async throws
  {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let runWorkspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: runWorkspace) }
    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: runWorkspace)
    let plan = try await client.planFixture(
      runID: "native-resume", scenario: "interrupt-once")
    let first = await client.startRun(planURL: plan.planURL)
    let startedMarker = runWorkspace.appendingPathComponent(
      "native-resume/artifacts/.interrupt-once-started")
    try await waitUntilFileExists(startedMarker)
    let didInterrupt = await first.interrupt()
    XCTAssertTrue(didInterrupt)
    _ = try await first.value()
    let interrupted = try await client.recoverRun(runID: "native-resume")
    XCTAssertEqual(interrupted.effectiveState, .interrupted)
    XCTAssertEqual(interrupted.effectiveResumability, .safe)

    let resumedHandle = try await client.resumeRun(runID: "native-resume")
    let resumed = try await resumedHandle.value()
    let recovered = try await client.recoverRun(runID: "native-resume")

    XCTAssertNotEqual(resumedHandle.requestID, first.requestID)
    XCTAssertEqual(resumed.exitDisposition, .succeeded)
    XCTAssertNil(resumed.streamFailure)
    XCTAssertEqual(recovered.manifest.runID, "native-resume")
    XCTAssertEqual(recovered.effectiveState, .completed)
    XCTAssertTrue(
      recovered.events.contains { event in
        event.kind == .known(.runCompleted) && event.payload["resumed"] == .bool(true)
      })
  }

  func testRecoveredRunningRunIsCooperativelyCancelledByItsMarkerAndPolledToTerminal()
    async throws
  {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let runWorkspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-recovered-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: runWorkspace) }
    let launchingClient = try WorkflowCLIClient(
      runtime: runtime, runWorkspaceURL: runWorkspace)
    let plan = try await launchingClient.planFixture(
      runID: "recovered-running", scenario: "cancel")
    let activeHandle = await launchingClient.startRun(planURL: plan.planURL)
    try await waitUntilRunState(
      .running, runID: "recovered-running", client: launchingClient)

    let relaunchedClient = try WorkflowCLIClient(
      runtime: runtime, runWorkspaceURL: runWorkspace)
    let terminal = try await relaunchedClient.cancelRecoveredRun(
      runID: "recovered-running",
      pollInterval: .milliseconds(20),
      timeout: .seconds(5))
    let execution = try await activeHandle.value()

    XCTAssertEqual(terminal.manifest.runID, "recovered-running")
    XCTAssertEqual(terminal.effectiveState, .cancelled)
    XCTAssertEqual(execution.exitDisposition, .cancelledOrInterrupted)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: runWorkspace.appendingPathComponent(
          "recovered-running/cancel.request.json"
        ).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: runWorkspace.appendingPathComponent("cancel.request.json").path))
  }

  func testReviewedPlanDigestRejectsAChangedPlanBeforeRunCreation() async throws {
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
      .appendingPathComponent("mlx-workshop-plan-digest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workspace) }
    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: workspace)
    let plan = try await client.planFixture(runID: "reviewed-plan", scenario: "success")
    var bytes = try Data(contentsOf: plan.planURL)
    bytes.append(0x20)
    try bytes.write(to: plan.planURL, options: .atomic)

    let handle = await client.startRun(
      planURL: plan.planURL,
      expectedPlanSHA256: plan.planSHA256)
    let execution = try await handle.value()

    XCTAssertEqual(execution.exitDisposition, .protocolFailure)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: workspace.appendingPathComponent("reviewed-plan").path))
  }

  func testPlansTheCanonicalNativeRecipeThroughTheRealCLI() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py")
    )
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-native-recipe-\(UUID().uuidString)", isDirectory: true)
    let runWorkspace = base.appendingPathComponent("runs", isDirectory: true)
    let model = base.appendingPathComponent("tiny-llama", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try makeTinyFloatModel(at: model)

    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: runWorkspace)
    let canonical = try OptimizationRecipe.unplanned.workflowRecipe(exactParent: model)
    let result = try await client.planModel(
      runID: "swift-native-recipe", modelURL: model, recipe: canonical)

    XCTAssertEqual(
      result.execution.exitDisposition, .succeeded, result.execution.process.stderr.text)
    XCTAssertNil(result.execution.streamFailure)
    let document = try XCTUnwrap(result.plan)
    XCTAssertEqual(document.recipe, canonical)
    XCTAssertEqual(document.exactParent, canonical.exactParent)
    XCTAssertEqual(document.steps.map(\.kind), ["mlx-lm-convert"])
    XCTAssertEqual(document.resourceEstimate.kind, .estimate)
    XCTAssertTrue(document.resourceEstimate.reasonCodes.contains("duration-estimate-unknown"))
    XCTAssertEqual(try WorkflowPlan.decode(Data(contentsOf: result.planURL)), document)
  }

  func testUnsupportedNativeControlSurvivesIntoTheBlockedPlan() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py")
    )
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-blocked-recipe-\(UUID().uuidString)", isDirectory: true)
    let model = base.appendingPathComponent("tiny-llama", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try makeTinyFloatModel(at: model)
    let client = try WorkflowCLIClient(
      runtime: runtime, runWorkspaceURL: base.appendingPathComponent("runs"))
    var optimization = OptimizationRecipe.unplanned
    optimization.perModuleOverrides = true
    let canonical = try optimization.workflowRecipe(exactParent: model)

    let result = try await client.planModel(
      runID: "swift-unsupported-control", modelURL: model, recipe: canonical)

    XCTAssertEqual(result.execution.exitDisposition, .blocked)
    let document = try XCTUnwrap(result.plan)
    XCTAssertEqual(document.recipe, canonical)
    XCTAssertTrue(document.recipe.allocation.perModuleOverrides)
    XCTAssertEqual(document.blockers.map(\.code), ["recipe-control-unsupported"])
    XCTAssertTrue(document.steps.isEmpty)
  }

  func testRejectsAWorkspaceInsideTheParentBeforeWritingPlanFiles() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-contained-workspace-\(UUID().uuidString)")
    let model = base.appendingPathComponent("tiny-llama", isDirectory: true)
    let nestedWorkspace = model.appendingPathComponent("runs", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try makeTinyFloatModel(at: model)
    try FileManager.default.createDirectory(at: nestedWorkspace, withIntermediateDirectories: true)
    let client = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: nestedWorkspace)
    let canonical = try OptimizationRecipe.unplanned.workflowRecipe(exactParent: model)

    await assertThrowsErrorAsync(
      try await client.planModel(
        runID: "contained-workspace", modelURL: model, recipe: canonical))

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: nestedWorkspace.appendingPathComponent(".plans").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: nestedWorkspace.appendingPathComponent(".recipes").path))
  }

  func testDisclosesEveryCommandForAMultiModeCanonicalPlan() async throws {
    let sourceWorkspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtime = WorkflowCLIRuntime(
      sourceWorkspaceURL: sourceWorkspace,
      pythonURL: sourceWorkspace.appendingPathComponent(".venv/bin/python"),
      cliURL: sourceWorkspace.appendingPathComponent("scripts/mlx_workflow_cli.py"))
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("mlx-workshop-multi-command-\(UUID().uuidString)")
    let model = base.appendingPathComponent("tiny-llama", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try makeTinyFloatModel(at: model)
    let client = try WorkflowCLIClient(
      runtime: runtime, runWorkspaceURL: base.appendingPathComponent("runs"))
    var optimization = OptimizationRecipe.unplanned
    optimization.requestedQuantModes = ["mxfp4", "affine"]
    let canonical = try optimization.workflowRecipe(exactParent: model)

    let result = try await client.planModel(
      runID: "multi-command", modelURL: model, recipe: canonical)
    let disclosure = try await client.commandDisclosure(planURL: result.planURL)

    XCTAssertEqual(result.execution.exitDisposition, .succeeded)
    XCTAssertEqual(disclosure.commands.count, 2)
    XCTAssertEqual(
      disclosure.commands.map { command in
        command.arguments[command.arguments.firstIndex(of: "--q-mode")! + 1]
      },
      ["mxfp4", "affine"])
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

private func waitUntilFileExists(
  _ url: URL,
  timeout: Duration = .seconds(5)
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !FileManager.default.fileExists(atPath: url.path) {
    if clock.now >= deadline {
      throw CocoaError(.fileNoSuchFile)
    }
    try await Task.sleep(for: .milliseconds(20))
  }
}

private func waitUntilRunState(
  _ state: WorkflowRunState,
  runID: String,
  client: WorkflowCLIClient,
  timeout: Duration = .seconds(5)
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if let recovered = try? await client.recoverRun(runID: runID),
      recovered.effectiveState == state
    {
      return
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw CocoaError(.fileReadUnknown)
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected async expression to throw.", file: file, line: line)
  } catch {}
}
