import XCTest

@testable import MLXWorkshopApp

@MainActor
final class WorkshopStoreTests: XCTestCase {
  func testLiveStoreDoesNotExposeDemoMeasurements() {
    let store = WorkshopStore()

    XCTAssertTrue(store.layers.isEmpty)
    XCTAssertTrue(store.candidates.isEmpty)
    XCTAssertTrue(store.runs.isEmpty)
    XCTAssertTrue(store.behaviorCategories.isEmpty)
  }

  func testProtectedLayerCannotBeDowngraded() throws {
    let store = WorkshopStore(content: .demo)
    let layer = try XCTUnwrap(store.layers.first(where: \.isProtected))

    store.setPrecision(.four, for: layer.id)

    XCTAssertEqual(store.layers.first(where: { $0.id == layer.id })?.precision, .eight)
  }

  func testUnprotectedLayerCanChangePrecision() throws {
    let store = WorkshopStore(content: .demo)
    let layer = try XCTUnwrap(
      store.layers.first(where: { !$0.isProtected && $0.precision == .four }))

    store.setPrecision(.eight, for: layer.id)

    XCTAssertEqual(store.layers.first(where: { $0.id == layer.id })?.precision, .eight)
  }

  func testProtectingLayerAlsoPromotesItToEightBit() throws {
    let store = WorkshopStore(content: .demo)
    let layer = try XCTUnwrap(
      store.layers.first(where: { !$0.isProtected && $0.precision == .four }))

    store.toggleProtection(for: layer.id)

    let updated = try XCTUnwrap(store.layers.first(where: { $0.id == layer.id }))
    XCTAssertTrue(updated.isProtected)
    XCTAssertEqual(updated.precision, .eight)
  }

  func testRunRequestDoesNotMutateRecipe() {
    let store = WorkshopStore(content: .demo)
    let recipe = store.recipeName

    store.apply(.runChanged(WorkshopRun(id: "planned", title: recipe, state: .planned)))
    store.requestRunAction()

    XCTAssertEqual(store.currentRun?.state, .planned)
    XCTAssertEqual(store.recipeName, recipe)
  }

  func testPlanDisclosureAttachesResourcesAndGatesWithoutStartingTheRun() {
    let store = WorkshopStore()
    store.apply(.runChanged(WorkshopRun(id: "planned", title: "Plan", state: .planned)))
    let disclosure = PlanDisclosure(
      runDirectory: "/runs/planned",
      exactParent: "/models/parent",
      quantModes: ["mxfp4"],
      evidenceKind: "estimate",
      uncertainty: "conservative-upper-bound",
      estimatedOutputBytes: 1_000,
      estimatedTemporaryBytes: 2_000,
      requiredFreeDiskBytes: 3_000,
      observedFreeDiskBytes: 4_000,
      estimatedPeakMemoryBytes: 5_000,
      observedUnifiedMemoryBytes: 6_000,
      estimatedDurationSeconds: nil,
      timeBudgetSeconds: 3_600,
      feasibility: "review-required",
      reasonCodes: ["duration-estimate-unknown"],
      requiredGates: ["provenance-structure", "parent-parity"],
      blockers: [])

    store.attachPlanDetails(disclosure, command: nil)

    XCTAssertEqual(store.currentRun?.state, .planned)
    XCTAssertEqual(store.currentRun?.plan, disclosure)
    XCTAssertNil(store.currentRun?.command)
    XCTAssertEqual(store.currentRun?.isQualified, false)
    XCTAssertFalse(store.showInspector)
  }

  func testEditingARecipeInvalidatesItsAttachedPlan() {
    let store = WorkshopStore()
    store.apply(.runChanged(WorkshopRun(id: "planned", title: "Plan", state: .planned)))
    let disclosure = PlanDisclosure(
      runDirectory: "/runs/planned",
      exactParent: "/models/parent",
      quantModes: ["mxfp4"],
      evidenceKind: "estimate",
      uncertainty: "conservative-upper-bound",
      estimatedOutputBytes: 1_000,
      estimatedTemporaryBytes: 2_000,
      requiredFreeDiskBytes: 3_000,
      observedFreeDiskBytes: 4_000,
      estimatedPeakMemoryBytes: 5_000,
      observedUnifiedMemoryBytes: 6_000,
      estimatedDurationSeconds: nil,
      timeBudgetSeconds: 3_600,
      feasibility: "review-required",
      reasonCodes: ["duration-estimate-unknown"],
      requiredGates: ["provenance-structure"],
      blockers: [])
    store.attachPlanDetails(disclosure, command: nil)

    store.recipe.timeBudgetSeconds = 7_200

    XCTAssertNil(store.currentRun)
    XCTAssertTrue(store.canPlanRun == false)
  }

  func testConfirmationCanBeDeclinedAndReopenedWithoutStarting() {
    let store = WorkshopStore()
    let modelURL = URL(fileURLWithPath: "/tmp/model")
    store.selectRunWorkspace(URL(fileURLWithPath: "/tmp/runs"))
    store.selectModelDirectory(modelURL)
    store.apply(
      .modelInspected(LocalModelReference(directory: modelURL, displayName: "model"), layers: []))
    store.apply(.runChanged(WorkshopRun(id: "planned", title: "Plan", state: .planned)))
    let disclosure = PlanDisclosure(
      runDirectory: "/runs/planned",
      exactParent: "/models/parent",
      quantModes: ["mxfp4"],
      evidenceKind: "estimate",
      uncertainty: "conservative-upper-bound",
      estimatedOutputBytes: 1_000,
      estimatedTemporaryBytes: 2_000,
      requiredFreeDiskBytes: 3_000,
      observedFreeDiskBytes: 4_000,
      estimatedPeakMemoryBytes: 5_000,
      observedUnifiedMemoryBytes: 6_000,
      estimatedDurationSeconds: nil,
      timeBudgetSeconds: 3_600,
      feasibility: "review-required",
      reasonCodes: ["active-workloads-present", "duration-estimate-unknown"],
      requiredGates: ["provenance-structure"],
      blockers: [])
    let command = CommandDisclosure(
      executableIdentity: "/tool/mlx_lm.convert", arguments: ["--model", "/models/parent"],
      redactedDisplay: "/tool/mlx_lm.convert --model /models/parent")
    let confirmation = RunConfirmation(
      runID: "planned", plan: disclosure, command: command, changesWeights: true)

    store.presentConfirmation(confirmation)
    XCTAssertTrue(store.showConfirmation)
    XCTAssertEqual(store.pendingConfirmation, confirmation)

    store.declineConfirmation()
    XCTAssertFalse(store.showConfirmation)
    XCTAssertEqual(store.pendingConfirmation, confirmation)
    XCTAssertEqual(store.currentRun?.state, .planned)

    store.requestRunAction()
    XCTAssertTrue(store.showConfirmation)
  }

  func testWorkspaceChangeInvalidatesReviewedPlanAndActiveRunRejectsSelectionChange() {
    let store = WorkshopStore()
    let firstWorkspace = URL(fileURLWithPath: "/tmp/runs-a")
    let secondWorkspace = URL(fileURLWithPath: "/tmp/runs-b")
    store.selectRunWorkspace(firstWorkspace)
    store.apply(.runChanged(WorkshopRun(id: "planned", title: "Plan", state: .planned)))

    store.selectRunWorkspace(secondWorkspace)

    XCTAssertEqual(store.runWorkspace, secondWorkspace)
    XCTAssertNil(store.currentRun)
    XCTAssertNil(store.pendingConfirmation)

    store.apply(.runChanged(WorkshopRun(id: "running", title: "Run", state: .running)))
    store.selectRunWorkspace(firstWorkspace)

    XCTAssertEqual(store.runWorkspace, secondWorkspace)
    XCTAssertEqual(store.currentRun?.state, .running)
    XCTAssertFalse(store.canChangeSelection)
  }

  func testRapidPlanRequestsCollapseToOneInFlightRequest() {
    let store = WorkshopStore()
    let modelURL = URL(fileURLWithPath: "/tmp/model")
    store.selectRunWorkspace(URL(fileURLWithPath: "/tmp/runs"))
    store.selectModelDirectory(modelURL)
    store.apply(
      .modelInspected(LocalModelReference(directory: modelURL, displayName: "model"), layers: []))

    store.requestRunAction()
    store.requestRunAction()

    XCTAssertEqual(store.planRequestSequence, 1)
    XCTAssertTrue(store.planRequestPending)
    XCTAssertFalse(store.canStartRun)
    store.finishPlanRequest()
    XCTAssertFalse(store.planRequestPending)
  }

  func testPlanDisclosureCannotAttachToADifferentRunIdentity() {
    let store = WorkshopStore()
    store.apply(.runChanged(WorkshopRun(id: "run-a", title: "Plan", state: .planned)))
    let disclosure = PlanDisclosure(
      runDirectory: "/runs/run-b",
      exactParent: "/models/parent",
      quantModes: ["mxfp4"],
      evidenceKind: "estimate",
      uncertainty: "conservative-upper-bound",
      estimatedOutputBytes: 1,
      estimatedTemporaryBytes: 1,
      requiredFreeDiskBytes: 1,
      observedFreeDiskBytes: 1,
      estimatedPeakMemoryBytes: 1,
      observedUnifiedMemoryBytes: 1,
      estimatedDurationSeconds: nil,
      timeBudgetSeconds: 1,
      feasibility: "review-required",
      reasonCodes: [],
      requiredGates: [],
      blockers: [])

    store.attachPlanDetails(disclosure, command: nil, runID: "run-b")

    XCTAssertNil(store.currentRun?.plan)
  }
}
