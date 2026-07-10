import XCTest

@testable import MLXWorkshopApp

final class WorkflowEvidenceProjectorTests: XCTestCase {
  func testProjectsOnlyRecordedParentRelativeEvidence() throws {
    let event = try WorkflowEvent(
      runID: "run-verified", sequence: 1, timestamp: "2026-07-10T12:00:00Z",
      type: "evaluation.recorded", stage: "compare",
      payload: [
        "run_id": .string("run-verified"),
        "exact_parent": .string("/tmp/parent"),
        "candidate": .string("/tmp/run-verified/artifacts/model-mxfp4"),
        "parent_tree_sha256": .string("parent-hash"),
        "candidate_tree_sha256": .string("candidate-hash"),
        "parent_size_bytes": .number(2_000_000_000),
        "candidate_size_bytes": .number(1_000_000_000),
        "qualified": .bool(true),
        "classification": .string("qualified"),
        "recipe": .object(["quant_modes": .array([.string("mxfp4")])]),
        "gates": .array([
          .object([
            "name": .string("provenance-structure"),
            "status": .string("passed"),
            "evidence": .array([.string("evidence/provenance.json")]),
          ])
        ]),
      ])

    let candidates = try XCTUnwrap(WorkflowEvidenceProjector().project(event))

    XCTAssertEqual(candidates.map(\.id), ["run-verified:parent", "run-verified:candidate"])
    XCTAssertEqual(try XCTUnwrap(candidates[0].sizeGB), 2.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(candidates[1].sizeGB), 1.0, accuracy: 0.0001)
    XCTAssertNil(candidates[1].throughput)
    XCTAssertNil(candidates[1].kl)
    XCTAssertNil(candidates[1].score)
    XCTAssertEqual(candidates[1].gates.first?.name, "provenance-structure")
    XCTAssertEqual(candidates[1].gates.first?.evidence, ["evidence/provenance.json"])
  }

  func testRejectsIncompleteOrNonCompareEvents() throws {
    let event = try WorkflowEvent(
      runID: "run-1", sequence: 1, timestamp: "2026-07-10T12:00:00Z",
      type: "metric.recorded", stage: "compare", payload: [:])
    XCTAssertNil(WorkflowEvidenceProjector().project(event))
  }
}
