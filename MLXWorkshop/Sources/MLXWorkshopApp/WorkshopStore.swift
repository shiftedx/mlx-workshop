import Combine
import Foundation

@MainActor
final class WorkshopStore: ObservableObject {
  private var modelIsInspected: Bool
  private var cancellationCoordinator: (any WorkshopCancellationCoordinating)?
  let contentMode: WorkshopContentMode
  @Published var section: WorkshopSection = .workbench
  @Published var showInspector: Bool
  @Published var showRunDrawer: Bool
  @Published var showConfirmation = false
  @Published var expertMode = false
  @Published private(set) var setupState: WorkshopSetupState
  @Published private(set) var model: LocalModelReference?
  @Published private(set) var runWorkspace: URL?
  @Published private(set) var currentRun: WorkshopRun?
  @Published private(set) var pendingConfirmation: RunConfirmation?
  @Published var selectedLayerID: LayerRecord.ID?
  @Published var selectedCandidateID: CandidateRecord.ID?
  @Published var recipe: OptimizationRecipe {
    didSet {
      guard recipe != oldValue,
        let run = currentRun,
        run.plan != nil,
        run.state == .planned || run.state == .blocked
      else { return }
      currentRun = nil
      pendingConfirmation = nil
      showConfirmation = false
      showRunDrawer = false
    }
  }
  @Published var layers: [LayerRecord]
  @Published private(set) var candidates: [CandidateRecord]
  @Published private(set) var runs: [RunRecord]
  @Published private(set) var behaviorCategories: [BehaviorCategory]
  @Published private(set) var hostSnapshot: HostSnapshot?
  @Published private(set) var planRequestSequence = 0
  @Published private(set) var planRequestPending = false

  init(content: WorkshopContentMode = .live) {
    contentMode = content
    let fixtures = content == .demo ? WorkshopDemoFixtures.precisionStudio : nil
    showInspector = content == .demo
    showRunDrawer = content == .demo
    setupState = content == .demo ? .ready : .empty
    modelIsInspected = content == .demo
    model = fixtures?.model
    runWorkspace = fixtures?.runWorkspace
    currentRun = fixtures?.currentRun
    pendingConfirmation = nil
    recipe = fixtures?.recipe ?? .unplanned
    layers = fixtures?.layers ?? []
    candidates = fixtures?.candidates ?? []
    runs = fixtures?.runs ?? []
    behaviorCategories = fixtures?.behaviorCategories ?? []
    hostSnapshot = fixtures?.hostSnapshot
    selectedLayerID = layers.first(where: { $0.name == "attn.q_proj" })?.id
    selectedCandidateID = candidates.first(where: { $0.status == .qualified })?.id
  }

  var selectedLayer: LayerRecord? { layers.first(where: { $0.id == selectedLayerID }) }
  var availableSections: [WorkshopSection] {
    contentMode == .demo ? WorkshopSection.allCases : [.workbench, .runs, .host]
  }
  var selectedCandidate: CandidateRecord? {
    candidates.first(where: { $0.id == selectedCandidateID })
  }
  var eightBitCount: Int { layers.filter { $0.precision == .eight }.count }
  var protectedCount: Int { layers.filter(\.isProtected).count }
  var isRunning: Bool { currentRun?.state.isActive == true }
  var runProgress: Double { currentRun?.progress?.fraction ?? 0 }
  var recipeName: String { recipe.name }
  var mutatingActionsAllowed: Bool { currentRun?.state != .protocolMismatch }
  var canChangeSelection: Bool {
    currentRun?.state.isActive != true && !planRequestPending
  }
  var canPlanRun: Bool {
    setupState == .ready && model != nil && runWorkspace != nil && mutatingActionsAllowed
      && !planRequestPending
  }
  var canStartRun: Bool {
    guard canPlanRun else { return false }
    if let state = currentRun?.state, state == .blocked || state.isActive { return false }
    return currentRun?.diagnostics.contains(where: { $0.severity == .blocker }) != true
  }
  var canCancelRun: Bool {
    currentRun?.state == .running
      && currentRun?.requestID != nil
      && cancellationCoordinator != nil
  }

  func beginModelSelection() { setupState = .loading(.selectingModel) }
  func cancelModelSelection() { setupState = model == nil ? .empty : setupState }

  func selectModelDirectory(_ directory: URL) {
    guard canChangeSelection else { return }
    modelIsInspected = false
    model = LocalModelReference(directory: directory, displayName: directory.lastPathComponent)
    setupState = .loading(.inspectingModel)
    layers = []
    candidates = []
    behaviorCategories = []
    currentRun = nil
    pendingConfirmation = nil
    showConfirmation = false
  }

  func beginWorkspaceSelection() { setupState = .loading(.selectingWorkspace) }
  func cancelWorkspaceSelection() {
    if model == nil {
      setupState = .empty
    } else {
      setupState = modelIsInspected ? .ready : .loading(.inspectingModel)
    }
  }

  func selectionFailed(_ activity: SetupActivity, message: String) {
    setupState = .blocked(
      WorkshopDiagnostic(
        id: "selection-\(activity.rawValue)", severity: .warning,
        title: "Could not use that folder", message: message,
        recovery: activity == .selectingModel ? .chooseModel : .chooseWorkspace))
  }

  func selectRunWorkspace(_ directory: URL) {
    guard canChangeSelection else { return }
    let changed = runWorkspace?.standardizedFileURL != directory.standardizedFileURL
    runWorkspace = directory
    if changed {
      currentRun = nil
      pendingConfirmation = nil
      showConfirmation = false
      showRunDrawer = false
      planRequestPending = false
    }
    if model == nil {
      setupState = .empty
    } else {
      setupState = modelIsInspected ? .ready : .loading(.inspectingModel)
    }
  }

  func apply(_ update: WorkshopSessionUpdate) {
    switch update {
    case .modelInspected(let model, let layers):
      modelIsInspected = true
      self.model = model
      self.layers = layers
      selectedLayerID = layers.first?.id
      setupState =
        runWorkspace == nil
        ? .blocked(
          WorkshopDiagnostic(
            id: "workspace-required", severity: .information,
            title: "Choose a run workspace",
            message: "Runs are written to a new immutable directory in a workspace you select.",
            recovery: .chooseWorkspace))
        : .ready
    case .setupBlocked(let diagnostic):
      setupState = .blocked(diagnostic)
    case .runChanged(let run):
      currentRun = run
      showRunDrawer = true
    case .runHistory(let runs):
      self.runs = runs
    case .candidates(let candidates):
      self.candidates = candidates
      selectedCandidateID = candidates.first?.id
    case .behaviorEvidence(let evidence):
      behaviorCategories = evidence
    case .hostSnapshot(let snapshot):
      hostSnapshot = snapshot
    }
  }

  func requestRunAction() {
    guard canStartRun else { return }
    if currentRun?.state == .planned {
      if pendingConfirmation != nil {
        showConfirmation = true
      } else {
        showInspector = true
      }
    } else {
      currentRun = nil
      pendingConfirmation = nil
      showConfirmation = false
      planRequestPending = true
      planRequestSequence += 1
    }
  }

  func finishPlanRequest() {
    planRequestPending = false
  }

  func attachPlanDetails(
    _ disclosure: PlanDisclosure,
    command: CommandDisclosure?,
    runID: String? = nil
  ) {
    guard var run = currentRun,
      runID == nil || run.id == runID,
      run.state == .planned || run.state == .blocked
    else { return }
    run.command = command
    run.plan = disclosure
    let mode = disclosure.quantModes.joined(separator: ", ").uppercased()
    run.title = "\(mode) quantization plan"
    run.statusDetail =
      run.state == .blocked
      ? "Plan blocked — review the preserved controls and diagnostics"
      : "Plan ready — review estimates, gates, and the exact command"
    currentRun = run
    showRunDrawer = true
    showInspector = true
  }

  func presentConfirmation(_ confirmation: RunConfirmation) {
    guard currentRun?.id == confirmation.runID,
      currentRun?.state == .planned,
      confirmation.plan.blockers.isEmpty,
      !confirmation.command.commands.isEmpty
    else { return }
    pendingConfirmation = confirmation
    showConfirmation = true
  }

  func declineConfirmation() {
    showConfirmation = false
  }

  func confirmationDidStart() {
    showConfirmation = false
    pendingConfirmation = nil
  }

  func bindCancellation(
    requestID: UUID,
    coordinator: any WorkshopCancellationCoordinating
  ) {
    cancellationCoordinator = coordinator
    currentRun?.requestID = requestID
  }

  func requestCancellation() async {
    guard var run = currentRun,
      run.state == .running,
      let requestID = run.requestID,
      let cancellationCoordinator
    else { return }
    run.state = .cancelling
    run.statusDetail = "Requesting cooperative cancellation"
    currentRun = run

    do {
      let accepted = try await cancellationCoordinator.requestCancellation(
        runID: run.id,
        requestID: requestID,
        cooperativeGrace: .seconds(5),
        terminationGrace: .seconds(2)
      )
      if !accepted {
        restoreRunningAfterCancellationFailure("The tracked process is no longer active.")
      }
    } catch {
      restoreRunningAfterCancellationFailure(
        "Could not write the cooperative cancellation request: \(error.localizedDescription)")
    }
  }

  private func restoreRunningAfterCancellationFailure(_ message: String) {
    guard var run = currentRun, run.state == .cancelling else { return }
    run.state = .running
    run.statusDetail = message
    run.diagnostics.append(
      WorkshopDiagnostic(
        id: "cancellation-request-failed", severity: .warning,
        title: "Cancellation was not requested", message: message, recovery: .openLog))
    currentRun = run
  }

  func setPrecision(_ precision: Precision, for id: LayerRecord.ID) {
    guard mutatingActionsAllowed,
      let index = layers.firstIndex(where: { $0.id == id }),
      !layers[index].isProtected
    else {
      return
    }
    layers[index].precision = precision
  }

  func toggleProtection(for id: LayerRecord.ID) {
    guard mutatingActionsAllowed, let index = layers.firstIndex(where: { $0.id == id }) else {
      return
    }
    layers[index].isProtected.toggle()
    if layers[index].isProtected { layers[index].precision = .eight }
  }
}
