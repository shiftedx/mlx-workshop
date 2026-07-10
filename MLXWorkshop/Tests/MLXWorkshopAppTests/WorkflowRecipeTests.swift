import Foundation
import XCTest

@testable import MLXWorkshopApp

final class WorkflowRecipeTests: XCTestCase {
  func testValidCanonicalRecipePreservesEveryFieldAcrossRoundTrip() throws {
    let recipe = try WorkflowRecipe.decode(fixtureData(named: "valid-recipe"))

    XCTAssertEqual(recipe.schemaVersion, 1)
    XCTAssertEqual(recipe.exactParent, "/absolute/inspected/model")
    XCTAssertEqual(recipe.operations, ["quantize"])
    XCTAssertEqual(recipe.quantModes, ["mxfp4"])
    XCTAssertEqual(recipe.allocation.strategy, "uniform")
    XCTAssertEqual(recipe.allocation.targetBPW, 4.0)
    XCTAssertNil(recipe.allocation.klTolerance)
    XCTAssertFalse(recipe.allocation.perModuleOverrides)
    XCTAssertEqual(recipe.priorities.quality, 0.78)
    XCTAssertEqual(recipe.priorities.size, 0.58)
    XCTAssertEqual(recipe.timeBudgetSeconds, 3600)
    XCTAssertEqual(recipe.contextTargetTokens, 32768)
    XCTAssertEqual(recipe.calibration.identity, "not-applicable")
    XCTAssertNil(recipe.calibration.datasetSHA256)
    XCTAssertEqual(recipe.calibration.sampleBudget, 0)
    XCTAssertEqual(recipe.calibration.tokenBudget, 0)
    XCTAssertNil(recipe.calibration.seed)
    XCTAssertFalse(recipe.protectionRules.preserveEmbeddings)
    XCTAssertFalse(recipe.protectionRules.preserveOutputHead)
    XCTAssertFalse(recipe.protectionRules.protectSensitiveModules)
    XCTAssertEqual(
      recipe.validation.requiredGates,
      ["provenance-structure", "deterministic-language-schema", "parent-parity"])
    XCTAssertEqual(recipe.validation.criticalRegressionsAllowed, 0)

    let encoded = try JSONEncoder().encode(recipe)
    XCTAssertEqual(try WorkflowRecipe.decode(encoded), recipe)
  }

  func testPassPlanPreservesEstimateAndStructuredExecutableStep() throws {
    let plan = try WorkflowPlan.decode(fixtureData(named: "pass-plan"))

    XCTAssertTrue(plan.blockers.isEmpty)
    XCTAssertEqual(plan.steps.count, 1)
    XCTAssertEqual(plan.steps[0].id, "quantize-mxfp4")
    XCTAssertEqual(plan.steps[0].kind, "mlx-lm-convert")
    XCTAssertEqual(plan.steps[0].displayName, "Quantize mxfp4")
    XCTAssertEqual(plan.steps[0].executable, "/workspace/.venv/bin/python")
    XCTAssertEqual(
      Array(plan.steps[0].arguments.prefix(4)), ["-m", "mlx_lm", "convert", "--hf-path"])
    XCTAssertEqual(plan.steps[0].workingDirectory, "/workspace")
    XCTAssertEqual(plan.steps[0].environmentKeys, ["HOME", "PATH", "TMPDIR"])
    XCTAssertEqual(plan.steps[0].resumability, .unsafe)
    XCTAssertEqual(plan.resourceEstimate.kind, .estimate)
    XCTAssertEqual(plan.resourceEstimate.feasibility, .reviewRequired)
    XCTAssertEqual(plan.resourceEstimate.uncertainty, "conservative-upper-bound")
    XCTAssertEqual(plan.resourceEstimate.sourceBytes, 1024)
    XCTAssertEqual(plan.resourceEstimate.estimatedOutputBytes, 67_109_325)
    XCTAssertEqual(plan.resourceEstimate.estimatedTemporaryBytes, 1_073_742_848)
    XCTAssertEqual(plan.resourceEstimate.diskReserveBytes, 32_212_254_720)
    XCTAssertEqual(plan.resourceEstimate.requiredFreeDiskBytes, 33_353_106_893)
    XCTAssertEqual(plan.resourceEstimate.observedFreeDiskBytes, 57_982_058_496)
    XCTAssertEqual(plan.resourceEstimate.estimatedPeakMemoryBytes, 2_147_484_672)
    XCTAssertEqual(plan.resourceEstimate.memoryReserveBytes, 8_589_934_592)
    XCTAssertEqual(plan.resourceEstimate.observedUnifiedMemoryBytes, 68_719_476_736)
    XCTAssertEqual(plan.resourceEstimate.usableUnifiedMemoryBytes, 60_129_542_144)
    XCTAssertNil(plan.resourceEstimate.estimatedDurationSeconds)
    XCTAssertEqual(plan.resourceEstimate.timeBudgetSeconds, 3600)
    XCTAssertEqual(plan.resourceEstimate.reasonCodes, ["duration-estimate-unknown"])
    XCTAssertEqual(
      plan.resourceEstimate.basis.source, "inspected-safetensors-shard-bytes")
    XCTAssertEqual(
      plan.resourceEstimate.basis.output, "quant-mode-factor-plus-64-mib-per-mode")
    XCTAssertEqual(plan.resourceEstimate.basis.temporary, "source-bytes-plus-1-gib")
    XCTAssertEqual(plan.resourceEstimate.basis.memory, "source-bytes-plus-2-gib")
    XCTAssertEqual(plan.resourceEstimate.basis.host, "planning-time-read-only-snapshot")

    let encoded = try JSONEncoder().encode(plan)
    XCTAssertEqual(try WorkflowPlan.decode(encoded), plan)
  }

  func testPlanProjectsParentResourcesGatesAndBlockersWithoutRelabelingEstimates() throws {
    let plan = try WorkflowPlan.decode(fixtureData(named: "pass-plan"))

    let disclosure = plan.disclosure

    XCTAssertEqual(disclosure.exactParent, "/absolute/inspected/model")
    XCTAssertEqual(disclosure.evidenceKind, "estimate")
    XCTAssertEqual(disclosure.uncertainty, "conservative-upper-bound")
    XCTAssertEqual(disclosure.estimatedOutputBytes, 67_109_325)
    XCTAssertEqual(disclosure.estimatedTemporaryBytes, 1_073_742_848)
    XCTAssertEqual(disclosure.requiredFreeDiskBytes, 33_353_106_893)
    XCTAssertEqual(disclosure.observedFreeDiskBytes, 57_982_058_496)
    XCTAssertEqual(disclosure.estimatedPeakMemoryBytes, 2_147_484_672)
    XCTAssertEqual(disclosure.timeBudgetSeconds, 3_600)
    XCTAssertNil(disclosure.estimatedDurationSeconds)
    XCTAssertEqual(disclosure.feasibility, "review-required")
    XCTAssertEqual(disclosure.reasonCodes, ["duration-estimate-unknown"])
    XCTAssertEqual(
      disclosure.requiredGates,
      ["provenance-structure", "deterministic-language-schema", "parent-parity"])
    XCTAssertTrue(disclosure.blockers.isEmpty)
  }

  func testInsufficientResourcePlanKeepsStableBlockerAndNoSteps() throws {
    let plan = try WorkflowPlan.decode(fixtureData(named: "insufficient-resource-plan"))

    XCTAssertEqual(plan.resourceEstimate.kind, .estimate)
    XCTAssertEqual(plan.resourceEstimate.feasibility, .blocked)
    XCTAssertEqual(
      plan.resourceEstimate.reasonCodes,
      ["duration-estimate-unknown", "resource-disk-insufficient"])
    XCTAssertEqual(plan.blockers.map(\.code), ["resource-disk-insufficient"])
    XCTAssertTrue(plan.steps.isEmpty)
  }

  func testUnsupportedControlIsPreservedWithoutBecomingExecutable() throws {
    let plan = try WorkflowPlan.decode(fixtureData(named: "unsupported-control-plan"))

    XCTAssertTrue(plan.recipe.allocation.perModuleOverrides)
    XCTAssertEqual(plan.blockers.map(\.code), ["recipe-control-unsupported"])
    XCTAssertEqual(plan.resourceEstimate.feasibility, .reviewRequired)
    XCTAssertEqual(plan.resourceEstimate.reasonCodes, ["duration-estimate-unknown"])
    XCTAssertTrue(plan.steps.isEmpty)

    let encoded = try JSONEncoder().encode(plan)
    XCTAssertEqual(try WorkflowPlan.decode(encoded), plan)
  }

  func testMalformedRecipeFixturesRejectUnknownWrongAndDuplicateValues() throws {
    for name in [
      "malformed-recipe-unknown-field",
      "malformed-recipe-wrong-type",
      "malformed-recipe-duplicate-value",
    ] {
      XCTAssertThrowsError(
        try WorkflowRecipe.decode(fixtureData(named: name)),
        "Expected \(name) to fail closed."
      )
    }
  }

  func testPlanRejectsUnknownKeysAndMalformedResourceShape() throws {
    let fixture = try fixtureData(named: "pass-plan")
    var unknownPlan = try XCTUnwrap(
      JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    unknownPlan["presentation_label"] = "not protocol"
    XCTAssertThrowsError(
      try WorkflowPlan.decode(JSONSerialization.data(withJSONObject: unknownPlan)))

    var missingNullable = try XCTUnwrap(
      JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    var resource = try XCTUnwrap(missingNullable["resource_estimate"] as? [String: Any])
    resource.removeValue(forKey: "estimated_duration_seconds")
    missingNullable["resource_estimate"] = resource
    XCTAssertThrowsError(
      try WorkflowPlan.decode(JSONSerialization.data(withJSONObject: missingNullable)))

    var partialNullGroup = try XCTUnwrap(
      JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    resource = try XCTUnwrap(partialNullGroup["resource_estimate"] as? [String: Any])
    resource["source_bytes"] = NSNull()
    partialNullGroup["resource_estimate"] = resource
    XCTAssertThrowsError(
      try WorkflowPlan.decode(JSONSerialization.data(withJSONObject: partialNullGroup)))

    var badFormula = try XCTUnwrap(
      JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    resource = try XCTUnwrap(badFormula["resource_estimate"] as? [String: Any])
    resource["estimated_output_bytes"] = 1
    badFormula["resource_estimate"] = resource
    XCTAssertThrowsError(
      try WorkflowPlan.decode(JSONSerialization.data(withJSONObject: badFormula)))

    var badReserve = try XCTUnwrap(
      JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    resource = try XCTUnwrap(badReserve["resource_estimate"] as? [String: Any])
    resource["disk_reserve_bytes"] = 0
    badReserve["resource_estimate"] = resource
    XCTAssertThrowsError(
      try WorkflowPlan.decode(JSONSerialization.data(withJSONObject: badReserve)))
  }

  func testFutureRecipeReportsProtocolMismatch() throws {
    XCTAssertThrowsError(try WorkflowRecipe.decode(fixtureData(named: "future-recipe"))) {
      error in
      XCTAssertEqual(
        error as? WorkflowProtocolError,
        .protocolMismatch(supported: 1, found: 2)
      )
    }
  }

  private func fixtureData(named name: String) throws -> Data {
    let workspace = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try Data(
      contentsOf: workspace.appendingPathComponent("tests/fixtures/recipe/v1/\(name).json")
    )
  }
}
