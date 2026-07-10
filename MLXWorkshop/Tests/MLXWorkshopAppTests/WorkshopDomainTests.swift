import Foundation
import XCTest

@testable import MLXWorkshopApp

@MainActor
final class WorkshopDomainTests: XCTestCase {
  @MainActor
  func testLiveNavigationExposesOnlySupportedBetaSurfaces() {
    let live = WorkshopStore(content: .live)
    let demo = WorkshopStore(content: .demo)

    XCTAssertEqual(
      live.availableSections,
      [.workbench, .runs, .compare, .behavior, .extensions, .host])
    XCTAssertEqual(demo.availableSections, WorkshopSection.allCases)
  }

  func testFileImporterCancellationIsNotPresentedAsASelectionFailure() {
    XCTAssertTrue(
      WorkshopFileImport.isCancellation(
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
    XCTAssertFalse(
      WorkshopFileImport.isCancellation(
        NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
  }

  func testModelFolderPickerExplainsWhatFolderQualifies() {
    let configuration = WorkshopFolderPickerConfiguration.forTarget(.model)

    XCTAssertEqual(configuration.title, "Choose a model folder")
    XCTAssertEqual(configuration.prompt, "Choose Model")
    XCTAssertTrue(configuration.message.contains("config.json"))
    XCTAssertTrue(configuration.message.contains(".safetensors"))
    XCTAssertTrue(configuration.canChooseDirectories)
    XCTAssertFalse(configuration.canChooseFiles)
  }

  func testWorkspaceFolderPickerExplainsWhereRunsWillBeWritten() {
    let configuration = WorkshopFolderPickerConfiguration.forTarget(.workspace)

    XCTAssertEqual(configuration.title, "Choose a run workspace")
    XCTAssertEqual(configuration.prompt, "Choose Workspace")
    XCTAssertTrue(configuration.message.contains("writable folder"))
    XCTAssertTrue(configuration.message.contains("model folder"))
    XCTAssertTrue(configuration.canChooseDirectories)
    XCTAssertFalse(configuration.canChooseFiles)
  }

  func testProductionSessionStartsWithoutClaimingModelReadinessOrRunEvidence() {
    let store = WorkshopStore()

    XCTAssertEqual(store.setupState, .empty)
    XCTAssertNil(store.model)
    XCTAssertNil(store.currentRun)
    XCTAssertFalse(store.canPlanRun)
  }

  func testSelectedModelBecomesReadyOnlyAfterInspectionAndWorkspaceSelection() {
    let store = WorkshopStore()
    let workspace = URL(fileURLWithPath: "/tmp/workshop-runs")
    let modelURL = URL(fileURLWithPath: "/tmp/model")

    store.selectRunWorkspace(workspace)
    store.selectModelDirectory(modelURL)

    XCTAssertEqual(store.setupState, .loading(.inspectingModel))
    XCTAssertFalse(store.canPlanRun)

    let inspected = LocalModelReference(
      directory: modelURL, displayName: "model", architecture: "Llama",
      format: "safetensors", supportSummary: "Inspection supported")
    store.apply(.modelInspected(inspected, layers: []))

    XCTAssertEqual(store.setupState, .ready)
    XCTAssertTrue(store.canPlanRun)
  }

  func testUnsupportedInspectionPreservesActionableBlocker() {
    let store = WorkshopStore()
    let blocker = WorkshopDiagnostic(
      id: "adapter-required", severity: .blocker, title: "Adapter required",
      message: "This tensor layout has no validated adapter.", recovery: .chooseModel)

    store.apply(.setupBlocked(blocker))

    XCTAssertEqual(store.setupState, .blocked(blocker))
    XCTAssertFalse(store.canPlanRun)
  }

  func testChoosingWorkspaceAfterInspectionCompletesSetup() {
    let store = WorkshopStore()
    let modelURL = URL(fileURLWithPath: "/tmp/model")
    store.selectModelDirectory(modelURL)
    store.apply(
      .modelInspected(LocalModelReference(directory: modelURL, displayName: "model"), layers: []))

    XCTAssertNotEqual(store.setupState, .ready)
    store.selectRunWorkspace(URL(fileURLWithPath: "/tmp/runs"))

    XCTAssertEqual(store.setupState, .ready)
  }

  func testCancellingWorkspaceSelectionRestoresPreviousSetupState() {
    let store = WorkshopStore()

    store.beginWorkspaceSelection()
    store.cancelWorkspaceSelection()

    XCTAssertEqual(store.setupState, .empty)
  }

  func testEasyAndExpertControlsMutateTheSameRecipe() {
    let store = WorkshopStore(content: .demo)

    store.recipe.qualityPriority = 0.91
    store.expertMode = true
    store.recipe.targetBPW = 5.2
    store.expertMode = false

    XCTAssertEqual(store.recipe.qualityPriority, 0.91)
    XCTAssertEqual(store.recipe.targetBPW, 5.2)
    XCTAssertEqual(store.recipe.name, "Balanced mixed precision")
  }

  func testEveryMaterialControlSerializesIntoTheCanonicalRecipe() throws {
    let store = WorkshopStore()
    store.recipe.qualityPriority = 0.91
    store.recipe.sizePriority = 0.37
    store.recipe.timeBudgetSeconds = 7_200
    store.recipe.contextTargetTokens = 65_536
    store.recipe.allocationStrategy = .mixedPrecision
    store.recipe.targetBPW = 5.2
    store.recipe.klTolerance = 0.08
    store.recipe.perModuleOverrides = true
    store.recipe.calibrationSuite = "agent-code-v1"
    store.recipe.calibrationDatasetSHA256 = String(repeating: "a", count: 64)
    store.recipe.calibrationSampleBudget = 40
    store.recipe.calibrationTokenBudget = 32_768
    store.recipe.calibrationSeed = 42
    store.recipe.preserveEmbeddings = true
    store.recipe.preserveOutputHead = true
    store.recipe.protectSensitiveLayers = true

    let parent = URL(fileURLWithPath: "/tmp")
    let canonical = try store.recipe.workflowRecipe(exactParent: parent)

    XCTAssertEqual(canonical.exactParent, try WorkflowFilePath.canonical(parent))
    XCTAssertEqual(canonical.operations, ["quantize"])
    XCTAssertEqual(canonical.quantModes, ["mxfp4"])
    XCTAssertEqual(canonical.priorities.quality, 0.91)
    XCTAssertEqual(canonical.priorities.size, 0.37)
    XCTAssertEqual(canonical.timeBudgetSeconds, 7_200)
    XCTAssertEqual(canonical.contextTargetTokens, 65_536)
    XCTAssertEqual(canonical.allocation.strategy, "mixed-precision")
    XCTAssertEqual(canonical.allocation.targetBPW, 5.2)
    XCTAssertEqual(canonical.allocation.klTolerance, 0.08)
    XCTAssertTrue(canonical.allocation.perModuleOverrides)
    XCTAssertEqual(canonical.calibration.identity, "agent-code-v1")
    XCTAssertEqual(canonical.calibration.datasetSHA256, String(repeating: "a", count: 64))
    XCTAssertEqual(canonical.calibration.sampleBudget, 40)
    XCTAssertEqual(canonical.calibration.tokenBudget, 32_768)
    XCTAssertEqual(canonical.calibration.seed, 42)
    XCTAssertTrue(canonical.protectionRules.preserveEmbeddings)
    XCTAssertTrue(canonical.protectionRules.preserveOutputHead)
    XCTAssertTrue(canonical.protectionRules.protectSensitiveModules)
    XCTAssertEqual(
      canonical.validation.requiredGates,
      ["provenance-structure", "deterministic-language-schema", "parent-parity"])
    XCTAssertEqual(canonical.validation.criticalRegressionsAllowed, 0)
  }

  func testEasyAndExpertDepthProduceTheSameCanonicalRecipe() throws {
    let store = WorkshopStore()
    let parent = URL(fileURLWithPath: "/tmp")
    let easy = try store.recipe.workflowRecipe(exactParent: parent)

    store.expertMode = true
    let expert = try store.recipe.workflowRecipe(exactParent: parent)

    XCTAssertEqual(easy, expert)
  }

  func testStoreAcceptsEveryProtocolFacingRunStateWithoutInferringQualification() {
    let store = WorkshopStore(content: .demo)

    for state in WorkshopRunState.allCases {
      let run = WorkshopRun(id: "run-1", title: "Test run", state: state)
      store.apply(.runChanged(run))
      XCTAssertEqual(store.currentRun?.state, state)
      XCTAssertFalse(store.currentRun?.isQualified ?? true)
    }
  }

  func testUnknownProgressTotalDoesNotSynthesizePercentage() {
    let progress = RunProgress(completed: 17, total: nil, unit: "tensors")

    XCTAssertNil(progress.fraction)
  }

  func testSnapshotDemoIsExplicitlySeparatedFromProductionState() {
    let demo = WorkshopStore(content: .demo)
    let production = WorkshopStore()

    XCTAssertEqual(demo.contentMode, .demo)
    XCTAssertNotNil(demo.model)
    XCTAssertFalse(demo.layers.isEmpty)
    XCTAssertEqual(demo.currentRun?.statusDetail, "Representative demo — not a local measurement")
    XCTAssertEqual(production.contentMode, .live)
    XCTAssertNil(production.model)
  }

  func testCancellationUsesTrackedCoordinatorSeam() async {
    let store = WorkshopStore(content: .demo)
    let requestID = UUID()
    let coordinator = CancellationRecorder()
    store.apply(
      .runChanged(
        WorkshopRun(
          id: "run-1", requestID: requestID, title: "Running workflow", state: .running)))
    store.bindCancellation(requestID: requestID, coordinator: coordinator)

    await store.requestCancellation()

    XCTAssertEqual(store.currentRun?.state, .cancelling)
    let request = await coordinator.lastRequest
    XCTAssertEqual(request?.runID, "run-1")
    XCTAssertEqual(request?.requestID, requestID)
    XCTAssertEqual(request?.cooperativeGrace, .seconds(5))
  }

  func testRecoveredRunLifecycleActionsAreDerivedOnlyFromJournalState() {
    XCTAssertEqual(
      RunLifecycleAction.recommended(
        state: .completed, resumability: "not-applicable", isQualified: false,
        isTrackedByThisProcess: false),
      .qualify)
    XCTAssertEqual(
      RunLifecycleAction.recommended(
        state: .interrupted, resumability: "safe", isQualified: false,
        isTrackedByThisProcess: false),
      .resume)
    XCTAssertEqual(
      RunLifecycleAction.recommended(
        state: .running, resumability: "unknown", isQualified: false,
        isTrackedByThisProcess: false),
      .cancelRecovered)
    XCTAssertNil(
      RunLifecycleAction.recommended(
        state: .running, resumability: "unknown", isQualified: false,
        isTrackedByThisProcess: true))
    XCTAssertEqual(
      RunLifecycleAction.recommended(
        state: .completed, resumability: "not-applicable", isQualified: true,
        isTrackedByThisProcess: false),
      .stage)
    XCTAssertNil(
      RunLifecycleAction.recommended(
        state: .protocolMismatch, resumability: nil, isQualified: false,
        isTrackedByThisProcess: false))
  }

  func testRunHistoryRecordPreservesAuthoritativeJournalRunID() {
    let record = RunRecord(
      runID: "run-authoritative", number: 1, title: "Run", created: "now",
      duration: "—", state: .completed, summary: "done")

    XCTAssertEqual(record.id, "run-authoritative")
    XCTAssertEqual(record.runID, "run-authoritative")
  }
}

private actor CancellationRecorder: WorkshopCancellationCoordinating {
  struct Request: Sendable {
    let runID: String
    let requestID: UUID
    let cooperativeGrace: Duration
  }

  private(set) var lastRequest: Request?

  func requestCancellation(
    runID: String,
    requestID: UUID,
    cooperativeGrace: Duration,
    terminationGrace: Duration
  ) async throws -> Bool {
    lastRequest = Request(
      runID: runID, requestID: requestID, cooperativeGrace: cooperativeGrace)
    return true
  }
}
