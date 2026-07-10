import Foundation

@MainActor
final class WorkshopWorkflowSession: ObservableObject {
  private enum BookmarkKey {
    static let model = "MLXWorkshop.modelBookmark.v1"
    static let workspace = "MLXWorkshop.runWorkspaceBookmark.v1"
  }

  private let defaults: UserDefaults
  private let runtimeOverride: WorkflowCLIRuntime?
  private var client: WorkflowCLIClient?
  private var clientWorkspaceURL: URL?
  private var modelAccess: SecurityScopedAccess?
  private var workspaceAccess: SecurityScopedAccess?
  private var inspectedSelection: String?
  private var pendingPlans: [String: PendingPlan] = [:]
  private var activeRunHandles: [String: WorkflowCLIRunHandle] = [:]
  #if DEBUG
    private var uiTestFixtureMode = false
  #endif

  private struct PendingPlan {
    let planURL: URL
    let planSHA256: String
    let confirmation: RunConfirmation
  }

  init(
    defaults: UserDefaults = .standard,
    runtime: WorkflowCLIRuntime? = nil
  ) {
    self.defaults = defaults
    runtimeOverride = runtime
  }

  #if DEBUG
    func resetPersistenceForUITesting() {
      defaults.removeObject(forKey: BookmarkKey.model)
      defaults.removeObject(forKey: BookmarkKey.workspace)
      client = nil
      clientWorkspaceURL = nil
      modelAccess = nil
      workspaceAccess = nil
      inspectedSelection = nil
      pendingPlans.removeAll()
      activeRunHandles.removeAll()
    }

    func bootstrapForUITesting(
      modelURL: URL,
      workspaceURL: URL,
      into store: WorkshopStore
    ) async {
      uiTestFixtureMode = true
      client = nil
      clientWorkspaceURL = nil
      inspectedSelection = nil
      store.selectRunWorkspace(workspaceURL)
      store.selectModelDirectory(modelURL)
      // UI automation validates interface wiring. Real inspection is exercised by
      // WorkflowCLIClient integration tests; launching that subprocess through an
      // ad-hoc XCTest app can block in macOS open(2) before Python starts.
      store.apply(
        .modelInspected(
          LocalModelReference(
            directory: modelURL, displayName: modelURL.lastPathComponent,
            architecture: "llama", format: "safetensors", sizeBytes: 44 * 1_024,
            parameterSummary: "dense", sourceState: "float-candidate",
            supportSummary: "Conversion supported"),
          layers: []))
      inspectedSelection =
        "\(modelURL.standardizedFileURL.path)|\(workspaceURL.standardizedFileURL.path)"
    }
  #endif

  func selectModel(_ path: SecurityScopedPath, into store: WorkshopStore) async {
    guard store.canChangeSelection else { return }
    do {
      try save(path, key: BookmarkKey.model)
      modelAccess = try path.resolve()
      inspectedSelection = nil
      store.selectModelDirectory(modelAccess?.url ?? URL(fileURLWithPath: path.displayPath))
      await inspectIfReady(store)
    } catch {
      store.selectionFailed(.selectingModel, message: error.localizedDescription)
    }
  }

  func selectWorkspace(_ path: SecurityScopedPath, into store: WorkshopStore) async {
    guard store.canChangeSelection else { return }
    do {
      try save(path, key: BookmarkKey.workspace)
      workspaceAccess = try path.resolve()
      client = nil
      clientWorkspaceURL = nil
      pendingPlans.removeAll()
      store.selectRunWorkspace(workspaceAccess?.url ?? URL(fileURLWithPath: path.displayPath))
      await refreshHost(store)
      await recoverWorkspaceRuns(store)
      await inspectIfReady(store)
    } catch {
      store.selectionFailed(.selectingWorkspace, message: error.localizedDescription)
    }
  }

  func restore(into store: WorkshopStore) async {
    do {
      if let workspacePath = try load(key: BookmarkKey.workspace) {
        workspaceAccess = try workspacePath.resolve()
        if let workspaceAccess {
          store.selectRunWorkspace(workspaceAccess.url)
          await refreshHost(store)
          await recoverWorkspaceRuns(store)
        }
      }
      if let modelPath = try load(key: BookmarkKey.model) {
        modelAccess = try modelPath.resolve()
        if let modelAccess { store.selectModelDirectory(modelAccess.url) }
      }
      await inspectIfReady(store)
    } catch {
      defaults.removeObject(forKey: BookmarkKey.model)
      defaults.removeObject(forKey: BookmarkKey.workspace)
      store.apply(
        .setupBlocked(
          WorkshopDiagnostic(
            id: "bookmark-stale", severity: .warning,
            title: "Choose the folders again",
            message:
              "A saved model or workspace permission is no longer valid. Select both folders again to continue.",
            recovery: .chooseModel)))
    }
  }

  func inspectIfReady(_ store: WorkshopStore) async {
    guard let modelURL = store.model?.directory,
      let workspaceURL = store.runWorkspace
    else { return }
    let selection = "\(modelURL.standardizedFileURL.path)|\(workspaceURL.standardizedFileURL.path)"
    guard inspectedSelection != selection else { return }

    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let runID = "inspect-\(UUID().uuidString.lowercased())"
      let execution = try await client.inspect(modelURL: modelURL, runID: runID)
      guard execution.streamFailure == nil else {
        store.apply(execution)
        return
      }
      guard let event = execution.events.last(where: { $0.kind == .known(.capabilityReported) }),
        let projection = WorkflowCapabilityProjector().project(event)
      else {
        store.apply(
          .setupBlocked(
            WorkshopDiagnostic(
              id: "inspection-evidence-missing", severity: .blocker,
              title: "Inspection evidence is missing",
              message: "The local inspector did not return a protocol-v1 capability report.",
              recovery: .retryInspection)))
        return
      }

      store.apply(.modelInspected(projection.model, layers: []))
      if let blocker = projection.blocker {
        store.apply(.setupBlocked(blocker))
      } else {
        inspectedSelection = selection
      }
    } catch {
      store.apply(
        .setupBlocked(
          WorkshopDiagnostic(
            id: "inspection-launch-failed", severity: .blocker,
            title: "Could not run the local inspector",
            message: error.localizedDescription,
            recovery: .retryInspection)))
    }
  }

  func planSelectedModel(_ store: WorkshopStore) async {
    defer { store.finishPlanRequest() }
    #if DEBUG
      if uiTestFixtureMode {
        presentUITestPlan(store)
        return
      }
    #endif
    guard let modelURL = store.model?.directory,
      let workspaceURL = store.runWorkspace
    else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let runID = "run-\(UUID().uuidString.lowercased())"
      let recipe = try store.recipe.workflowRecipe(exactParent: modelURL)
      let plan = try await client.planModel(
        runID: runID,
        modelURL: modelURL,
        recipe: recipe)
      store.apply(plan.execution)
      guard let document = plan.plan else { return }
      guard plan.execution.streamFailure == nil else { return }
      if !document.blockers.isEmpty
        || document.resourceEstimate.feasibility == .blocked
        || document.steps.isEmpty
      {
        store.attachPlanDetails(document.disclosure, command: nil, runID: document.runID)
        return
      }
      guard plan.execution.exitDisposition == .succeeded else { return }
      let command = try await client.commandDisclosure(planURL: plan.planURL)
      let confirmation = RunConfirmation(
        runID: document.runID,
        plan: document.disclosure,
        command: command,
        changesWeights: true)
      store.attachPlanDetails(document.disclosure, command: command, runID: document.runID)
      pendingPlans[document.runID] = PendingPlan(
        planURL: plan.planURL.standardizedFileURL,
        planSHA256: plan.planSHA256,
        confirmation: confirmation)
      store.presentConfirmation(confirmation)
    } catch {
      store.apply(
        .runChanged(
          WorkshopRun(
            id: "plan-error", title: "Local workflow plan", state: .failed,
            statusDetail: error.localizedDescription,
            diagnostics: [
              WorkshopDiagnostic(
                id: "plan-launch-failed", severity: .blocker,
                title: "Could not create the plan",
                message: error.localizedDescription,
                recovery: .openLog)
            ])))
    }
  }

  func planFixture(
    runID: String,
    scenario: String,
    into store: WorkshopStore
  ) async {
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let selectedModel = store.model?.directory
      let fixtureParent = selectedModel.flatMap { url in
        FileManager.default.fileExists(atPath: url.path) ? url : nil
      }
      let result = try await client.planFixture(
        runID: runID,
        scenario: scenario,
        modelURL: fixtureParent)
      store.apply(result.execution)
      guard result.execution.streamFailure == nil else { return }
      let disclosure = try await client.fixturePlanDisclosure(planURL: result.planURL)
      guard result.execution.exitDisposition == .succeeded,
        disclosure.blockers.isEmpty
      else {
        store.attachPlanDetails(disclosure, command: nil, runID: runID)
        return
      }
      let command = try await client.commandDisclosure(planURL: result.planURL)
      let confirmation = RunConfirmation(
        runID: runID,
        plan: disclosure,
        command: command,
        changesWeights: false)
      store.attachPlanDetails(disclosure, command: command, runID: runID)
      pendingPlans[runID] = PendingPlan(
        planURL: result.planURL.standardizedFileURL,
        planSHA256: result.planSHA256,
        confirmation: confirmation)
      store.presentConfirmation(confirmation)
    } catch {
      store.apply(
        .runChanged(
          WorkshopRun(
            id: runID,
            title: "Deterministic fixture plan",
            state: .failed,
            statusDetail: error.localizedDescription)))
    }
  }

  func confirmPendingRun(_ store: WorkshopStore) async {
    #if DEBUG
      if uiTestFixtureMode, let confirmation = store.pendingConfirmation {
        store.confirmationDidStart()
        let run = WorkshopRun(
          id: confirmation.runID, title: "MXFP4 quantization", state: .completed,
          stage: "quantize-mxfp4", statusDetail: "Optimized copy created — verification required",
          runDirectory: confirmation.runDirectory)
        store.apply(.runChanged(run))
        store.apply(.runHistory([uiTestRecord(run)]))
        return
      }
    #endif
    guard let confirmation = store.pendingConfirmation,
      let pending = pendingPlans[confirmation.runID],
      pending.confirmation == confirmation,
      confirmation.plan.blockers.isEmpty,
      let workspaceURL = store.runWorkspace
    else { return }

    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      pendingPlans[confirmation.runID] = nil
      store.confirmationDidStart()
      let adapter = WorkflowPresentationAdapter()
      let retainedModelAccess = modelAccess
      let retainedWorkspaceAccess = workspaceAccess
      let handle = await client.startRun(
        planURL: pending.planURL,
        expectedPlanSHA256: pending.planSHA256
      ) { event in
        await MainActor.run {
          if let update = adapter.project(event, currentRun: store.currentRun) {
            store.apply(update)
          }
        }
      }
      activeRunHandles[confirmation.runID] = handle
      store.bindCancellation(requestID: handle.requestID, coordinator: handle.coordinator)
      let execution = try await handle.value()
      activeRunHandles[confirmation.runID] = nil
      if execution.streamFailure != nil || execution.exitDisposition == .protocolFailure {
        store.apply(execution)
      } else {
        do {
          store.apply(try await client.recoverRun(runID: confirmation.runID))
          await recoverWorkspaceRuns(store)
        } catch {
          store.apply(execution)
        }
      }
      _ = (retainedModelAccess, retainedWorkspaceAccess)
    } catch {
      activeRunHandles[confirmation.runID] = nil
      var run =
        store.currentRun
        ?? WorkshopRun(
          id: confirmation.runID,
          title: "Local workflow",
          state: .failed)
      run.state = .failed
      run.statusDetail = error.localizedDescription
      run.isQualified = false
      store.apply(.runChanged(run))
    }
  }

  @discardableResult
  func interruptRunningRun(_ store: WorkshopStore) async -> Bool {
    guard let run = store.currentRun,
      run.state == .running,
      let handle = activeRunHandles[run.id]
    else { return false }
    return await handle.interrupt()
  }

  func declinePendingRun(_ store: WorkshopStore) {
    store.declineConfirmation()
  }

  func qualifyRun(runID: String, into store: WorkshopStore) async {
    #if DEBUG
      if uiTestFixtureMode, var run = store.currentRun, run.id == runID {
        run.isQualified = true
        run.statusDetail = "Verified against the exact parent"
        store.apply(.runChanged(run))
        store.apply(.runHistory([uiTestRecord(run)]))
        let parentURL = store.model?.directory
        let evidenceRoot = run.runDirectory ?? store.runWorkspace ?? parentURL
        let candidateURL = evidenceRoot?.appendingPathComponent(
          "artifacts/model-mxfp4", isDirectory: true)
        let evidence = [
          QualificationGateRecord(
            name: "Model reload", status: "passed",
            evidence: ["The optimized copy reloaded successfully."]),
          QualificationGateRecord(
            name: "Exact parent", status: "passed",
            evidence: ["The recorded parent fingerprint matches this model."]),
          QualificationGateRecord(
            name: "Output structure", status: "passed",
            evidence: ["The optimized copy contains the required model files."]),
        ]
        store.apply(
          .candidates([
            CandidateRecord(
              id: "ui-test-parent", name: "Original model", recipe: "Exact parent",
              sizeGB: 0.00004, status: .parent, exactParent: parentURL,
              candidateDirectory: parentURL, evidenceRoot: evidenceRoot),
            CandidateRecord(
              id: "ui-test-candidate", runID: run.id, name: "Optimized copy",
              recipe: store.recipeName, sizeGB: 0.00002, status: .qualified,
              exactParent: parentURL, candidateDirectory: candidateURL, gates: evidence,
              evidenceRoot: evidenceRoot),
          ]))
        return
      }
    #endif
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let execution = try await client.qualifyRun(runID: runID)
      if execution.streamFailure != nil || execution.exitDisposition == .protocolFailure {
        store.apply(execution)
        return
      }
      let recovered = try await client.recoverRun(runID: runID)
      store.apply(recovered)
      await recoverWorkspaceRuns(store)
    } catch {
      applyLifecycleFailure(error, runID: runID, into: store)
    }
  }

  func analyzeSensitivity(_ store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace, let modelURL = store.model?.directory else {
      return
    }
    store.beginSensitivityAnalysis()
    defer { store.finishSensitivityAnalysis() }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let runID = "sensitivity-\(UUID().uuidString.lowercased())"
      let execution = try await client.analyzeSensitivity(modelURL: modelURL, runID: runID)
      guard execution.exitDisposition == .succeeded, execution.streamFailure == nil,
        let event = execution.events.last(where: {
          $0.kind == .known(.evaluationRecorded) && $0.stage == "sensitivity"
        }), let projection = WorkflowSensitivityProjector().project(event)
      else { return }
      store.apply(.sensitivityMeasured(projection))
      store.expertMode = true
      store.showInspector = true
    } catch {
      store.finishSensitivityAnalysis()
    }
  }

  func materializeMixedCandidate(_ store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace,
      let analysisURL = store.sensitivityAnalysisURL,
      let candidateID = store.sensitivityCandidateID
    else { return }
    let runID = "mixed-\(UUID().uuidString.lowercased())"
    let output = workspaceURL.appendingPathComponent("mixed-candidates/\(runID)", isDirectory: true)
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let execution = try await client.materializeMixed(
        analysisURL: analysisURL, candidateID: candidateID, outputURL: output, runID: runID)
      guard execution.exitDisposition == .succeeded, execution.streamFailure == nil else {
        store.apply(execution)
        return
      }
      store.apply(
        .runChanged(
          WorkshopRun(
            id: runID, title: "Measured mixed-precision candidate", state: .completed,
            stage: "materialize-mixed",
            statusDetail: "Candidate created — verification is still required",
            runDirectory: output, isQualified: false)))
    } catch {
      applyLifecycleFailure(error, runID: runID, into: store)
    }
  }

  func planBehaviorExperiment(_ store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace, let modelURL = store.model?.directory else {
      return
    }
    let runID = "behavior-\(UUID().uuidString.lowercased())"
    do {
      let execution = try await workflowClient(workspaceURL: workspaceURL)
        .planBehavior(modelURL: modelURL, runID: runID)
      store.apply(execution)
      if execution.exitDisposition == .succeeded,
        let event = execution.events.last(where: {
          $0.kind == .known(.planReady) && $0.stage == "behavior-plan"
        }), let path = event.payload["contract_path"]?.stringValue
      {
        store.setBehaviorContract(URL(fileURLWithPath: path))
      } else {
        store.setBehaviorContract(nil)
      }
    } catch {
      applyLifecycleFailure(error, runID: runID, into: store)
    }
  }

  func runBehaviorExperiment(_ store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace, let contractURL = store.behaviorContractURL else {
      return
    }
    store.setBehaviorExperimentRunning(true)
    defer { store.setBehaviorExperimentRunning(false) }
    do {
      let execution = try await workflowClient(workspaceURL: workspaceURL)
        .runBehavior(contractURL: contractURL)
      store.apply(execution)
      guard
        let event = execution.events.last(where: {
          $0.kind == .known(.evaluationRecorded) && $0.stage == "behavior-held-out"
        }), case .array(let values) = event.payload["categories"]
      else { return }
      let categories = values.compactMap { value -> BehaviorCategory? in
        guard case .object(let item) = value,
          let name = item["name"]?.stringValue,
          case .number(let parent) = item["parent_rate"],
          case .number(let candidate) = item["candidate_rate"],
          case .number(let count) = item["sample_count"]
        else { return nil }
        return BehaviorCategory(
          name: name, parentRate: parent, candidateRate: candidate,
          sampleCount: Int(count))
      }
      store.apply(.behaviorEvidence(categories))
    } catch {
      store.setBehaviorExperimentRunning(false)
    }
  }

  func inspectMTPExtension(_ store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace, let modelURL = store.model?.directory else {
      return
    }
    store.beginExtensionCheck()
    defer { store.finishExtensionCheck() }
    do {
      let execution = try await workflowClient(workspaceURL: workspaceURL).inspectMTP(
        modelURL: modelURL, runID: "mtp-\(UUID().uuidString.lowercased())")
      guard
        let event = execution.events.last(where: {
          $0.kind == .known(.capabilityReported) && $0.stage == "mtp-inspect"
        }), case .object(let report) = event.payload["report"],
        case .object(let compatibility) = report["compatibility"]
      else { return }
      let supported = event.payload["supported"] == .bool(true)
      let message =
        compatibility["message"]?.stringValue
        ?? (supported ? "MTPLX reports this model can run." : "MTPLX did not approve this model.")
      store.setMTPCheckMessage(message)
    } catch {
      store.setMTPCheckMessage(error.localizedDescription)
    }
  }

  func runVisionSmoke(imageURL: URL, store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace, let modelURL = store.model?.directory else {
      return
    }
    store.beginExtensionCheck()
    defer { store.finishExtensionCheck() }
    do {
      let execution = try await workflowClient(workspaceURL: workspaceURL).visionSmoke(
        modelURL: modelURL, imageURL: imageURL,
        runID: "vision-\(UUID().uuidString.lowercased())")
      if let event = execution.events.last(where: { $0.stage == "vision-smoke" }) {
        store.setVisionCheckMessage(
          event.payload["response"]?.stringValue
            ?? event.payload["reason"]?.stringValue
            ?? "Vision check finished with \(event.payload["state"]?.stringValue ?? "unknown") state."
        )
      }
    } catch {
      store.setVisionCheckMessage(error.localizedDescription)
    }
  }

  func stageRun(runID: String, into store: WorkshopStore) async {
    #if DEBUG
      if uiTestFixtureMode, let workspace = store.runWorkspace {
        let directory = workspace.appendingPathComponent("staged-candidates/\(runID)")
        store.markStaged(runID: runID, directory: directory)
        return
      }
    #endif
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let stagingRoot = workspaceURL.appendingPathComponent("staged-candidates", isDirectory: true)
      try FileManager.default.createDirectory(
        at: stagingRoot, withIntermediateDirectories: true)
      let execution = try await client.stageRun(
        runID: runID, stagingRoot: stagingRoot, stageID: runID)
      guard execution.exitDisposition == .succeeded,
        execution.streamFailure == nil,
        let event = execution.events.last(where: {
          $0.kind == .known(.artifactDiscovered)
            && $0.payload["kind"] == .string("staged-candidate")
        }),
        let path = event.payload["staging_directory"]?.stringValue
      else {
        applyLifecycleFailure(
          WorkflowCLIClientError.missingRuntimeFile(
            "The staging command did not return a verified destination."),
          runID: runID,
          into: store)
        return
      }
      store.markStaged(runID: runID, directory: URL(fileURLWithPath: path, isDirectory: true))
      await recoverWorkspaceRuns(store)
    } catch {
      applyLifecycleFailure(error, runID: runID, into: store)
    }
  }

  func resumeRun(runID: String, into store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let recovered = try await client.recoverRun(runID: runID)
      store.apply(recovered)
      let adapter = WorkflowPresentationAdapter()
      let retainedModelAccess = modelAccess
      let retainedWorkspaceAccess = workspaceAccess
      let handle = try await client.resumeRun(runID: runID) { event in
        await MainActor.run {
          if let update = adapter.project(event, currentRun: store.currentRun) {
            store.apply(update)
          }
        }
      }
      activeRunHandles[runID] = handle
      store.bindCancellation(requestID: handle.requestID, coordinator: handle.coordinator)
      let execution = try await handle.value()
      activeRunHandles[runID] = nil
      if execution.streamFailure != nil || execution.exitDisposition == .protocolFailure {
        store.apply(execution)
      } else {
        store.apply(try await client.recoverRun(runID: runID))
        await recoverWorkspaceRuns(store)
      }
      _ = (retainedModelAccess, retainedWorkspaceAccess)
    } catch {
      activeRunHandles[runID] = nil
      applyLifecycleFailure(error, runID: runID, into: store)
    }
  }

  func requestRecoveredCancellation(runID: String, into store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let recovered = try await client.recoverRun(runID: runID)
      store.apply(recovered)
      if var run = store.currentRun, run.id == runID {
        run.state = .cancelling
        run.statusDetail = "Cooperative cancellation requested"
        store.apply(.runChanged(run))
      }
      let terminal = try await client.cancelRecoveredRun(runID: runID)
      store.apply(terminal)
      await recoverWorkspaceRuns(store)
    } catch {
      applyLifecycleFailure(error, runID: runID, into: store)
    }
  }

  func refreshHost(_ store: WorkshopStore) async {
    #if DEBUG
      if uiTestFixtureMode {
        store.apply(
          .hostSnapshot(
            HostSnapshot(
              chip: "Apple Silicon", unifiedMemory: "64 GiB", availableMemory: "Measured",
              freeDisk: "Measured", operatingSystem: "macOS", mlxVersion: "0.31.2",
              mlxLMVersion: "0.31.3", activeWorkloads: [])))
        return
      }
    #endif
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let execution = try await client.host(runID: "host-\(UUID().uuidString.lowercased())")
      guard execution.streamFailure == nil,
        let event = execution.events.last(where: {
          $0.kind == .known(.capabilityReported) && $0.stage == "host"
        }),
        let snapshot = WorkflowHostProjector().project(event)
      else { return }
      store.apply(.hostSnapshot(snapshot))
    } catch {
      // Host evidence is useful but non-blocking for model inspection. The Host view
      // remains explicitly empty rather than presenting inferred values.
    }
  }

  func recoverWorkspaceRuns(_ store: WorkshopStore) async {
    guard let workspaceURL = store.runWorkspace else { return }
    do {
      let client = try workflowClient(workspaceURL: workspaceURL)
      let batch = try await client.recoverAllRuns()
      let history = WorkflowPresentationAdapter().history(from: batch)
      store.apply(.runHistory(history))
      var candidates: [CandidateRecord] = []
      for run in history where run.state == .completed && run.isQualified {
        do {
          let execution = try await client.evidence(runID: run.runID)
          guard execution.exitDisposition == .succeeded,
            execution.streamFailure == nil,
            let event = execution.events.last(where: {
              $0.kind == .known(.evaluationRecorded) && $0.stage == "compare"
            }),
            let projected = WorkflowEvidenceProjector().project(event)
          else { continue }
          candidates.append(contentsOf: projected)
        } catch {
          // A run without revalidated comparison evidence remains in Runs, but is
          // intentionally omitted from Compare rather than receiving inferred facts.
        }
      }
      store.apply(.candidates(candidates))
    } catch {
      // Recovery is isolated from model inspection. A workspace-level enumeration
      // failure leaves history empty instead of inventing run state.
      store.apply(.runHistory([]))
      store.apply(.candidates([]))
    }
  }

  private func workflowClient(workspaceURL: URL) throws -> WorkflowCLIClient {
    let normalized = workspaceURL.standardizedFileURL
    if let client, clientWorkspaceURL == normalized { return client }
    let runtime = try runtimeOverride ?? WorkflowRuntimeLocator.locate()
    let newClient = try WorkflowCLIClient(runtime: runtime, runWorkspaceURL: normalized)
    client = newClient
    clientWorkspaceURL = normalized
    return newClient
  }

  #if DEBUG
    private func presentUITestPlan(_ store: WorkshopStore) {
      guard let model = store.model?.directory, let workspace = store.runWorkspace else { return }
      let runID = "ui-run-\(UUID().uuidString.lowercased())"
      let runDirectory = workspace.appendingPathComponent(runID, isDirectory: true)
      let disclosure = PlanDisclosure(
        runDirectory: runDirectory.path, exactParent: model.path, quantModes: ["mxfp4"],
        evidenceKind: "deterministic-ui-fixture", uncertainty: "UI automation fixture",
        estimatedOutputBytes: 20_000, estimatedTemporaryBytes: 44_000,
        requiredFreeDiskBytes: 1_000_000, observedFreeDiskBytes: 10_000_000,
        estimatedPeakMemoryBytes: 1_000_000, observedUnifiedMemoryBytes: 64_000_000_000,
        estimatedDurationSeconds: 1, timeBudgetSeconds: 3_600,
        feasibility: "pass", reasonCodes: [],
        requiredGates: ["provenance-structure", "deterministic-language-schema", "parent-parity"],
        blockers: [])
      let command = CommandDisclosure(
        executableIdentity: "/bundled/python", arguments: ["mlx_lm", "convert"],
        redactedDisplay: "mlx_lm convert <model> <workspace>")
      let confirmation = RunConfirmation(
        runID: runID, plan: disclosure, command: command, changesWeights: true)
      store.apply(
        .runChanged(
          WorkshopRun(
            id: runID, title: "MXFP4 quantization plan", state: .planned,
            statusDetail: "Plan ready", runDirectory: runDirectory)))
      store.attachPlanDetails(disclosure, command: command, runID: runID)
      store.presentConfirmation(confirmation)
    }

    private func uiTestRecord(_ run: WorkshopRun) -> RunRecord {
      RunRecord(
        runID: run.id, number: 1, title: run.title, created: "Now", duration: "1s",
        state: run.state,
        summary: run.isQualified
          ? (run.stagedDirectory == nil
            ? "Run state: qualified"
            : "Run state: qualified and staged as an immutable local release record")
          : "Run state: completed; verification required",
        runDirectory: run.runDirectory, stdoutLog: run.stdoutLog, stderrLog: run.stderrLog,
        command: run.command, resumability: run.resumability, isQualified: run.isQualified,
        stagedDirectory: run.stagedDirectory)
    }
  #endif

  private func applyLifecycleFailure(_ error: Error, runID: String, into store: WorkshopStore) {
    var run =
      store.currentRun?.id == runID
      ? store.currentRun!
      : WorkshopRun(id: runID, title: "Local workflow", state: .failed)
    run.state = .failed
    run.statusDetail = error.localizedDescription
    run.isQualified = false
    store.apply(.runChanged(run))
  }

  private func save(_ path: SecurityScopedPath, key: String) throws {
    defaults.set(try JSONEncoder().encode(path), forKey: key)
  }

  private func load(key: String) throws -> SecurityScopedPath? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try JSONDecoder().decode(SecurityScopedPath.self, from: data)
  }
}
