import XCTest

@testable import MLXWorkshopApp

final class WorkflowSensitivityProjectorTests: XCTestCase {
  func testProjectsMeasuredLayersAndRecommendedAssignment() throws {
    let event = try WorkflowEvent(
      runID: "sensitivity-1", sequence: 1, timestamp: "2026-07-10T12:00:00Z",
      type: "evaluation.recorded", stage: "sensitivity",
      payload: [
        "analysis_path": .string("/tmp/sensitivity.json"),
        "recommended_candidate_id": .string("candidate-a"),
        "analysis": .object([
          "status": .string("supported"),
          "measurements": .array([
            .object([
              "module_id": .string("layer.0.transformer-block"), "precision_id": .string("mxfp4"),
              "delta": .number(0.04),
            ]),
            .object([
              "module_id": .string("layer.0.transformer-block"), "precision_id": .string("mxfp8"),
              "delta": .number(0.01),
            ]),
          ]),
          "candidates": .array([
            .object([
              "candidate_id": .string("candidate-a"),
              "assignments": .array([
                .array([.string("layer.0.transformer-block"), .string("mxfp8")])
              ]),
            ])
          ]),
        ]),
      ])

    let result = try XCTUnwrap(WorkflowSensitivityProjector().project(event))
    XCTAssertEqual(result.layers.count, 1)
    XCTAssertEqual(result.layers[0].precision, .eight)
    XCTAssertEqual(result.layers[0].klDelta, 0.01, accuracy: 0.0001)
    XCTAssertEqual(result.recommendedCandidateID, "candidate-a")
    XCTAssertEqual(result.candidates.first?.assignments["layer.0.transformer-block"], .eight)
    XCTAssertEqual(result.analysisURL.path, "/tmp/sensitivity.json")
  }
}
