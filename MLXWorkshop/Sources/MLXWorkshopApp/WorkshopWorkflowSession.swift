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
      client = nil
      clientWorkspaceURL = nil
      inspectedSelection = nil
      store.selectRunWorkspace(workspaceURL)
      store.selectModelDirectory(modelURL)
      await refreshHost(store)
      await recoverWorkspaceRuns(store)
      await inspectIfReady(store)
    }
  #endif

  func selectModel(_ url: URL, into store: WorkshopStore) async {
    guard store.canChangeSelection else { return }
    do {
      let path = try SecurityScopedPath(url: url, accessMode: .readOnly)
      try save(path, key: BookmarkKey.model)
      modelAccess = try path.resolve()
      inspectedSelection = nil
      store.selectModelDirectory(modelAccess?.url ?? url)
      await inspectIfReady(store)
    } catch {
      store.selectionFailed(.selectingModel, message: error.localizedDescription)
    }
  }

  func selectWorkspace(_ url: URL, into store: WorkshopStore) async {
    guard store.canChangeSelection else { return }
    do {
      let path = try SecurityScopedPath(url: url, accessMode: .readWrite)
      try save(path, key: BookmarkKey.workspace)
      workspaceAccess = try path.resolve()
      client = nil
      clientWorkspaceURL = nil
      pendingPlans.removeAll()
      store.selectRunWorkspace(workspaceAccess?.url ?? url)
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
      store.apply(.runHistory(WorkflowPresentationAdapter().history(from: batch)))
    } catch {
      // Recovery is isolated from model inspection. A workspace-level enumeration
      // failure leaves history empty instead of inventing run state.
      store.apply(.runHistory([]))
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
