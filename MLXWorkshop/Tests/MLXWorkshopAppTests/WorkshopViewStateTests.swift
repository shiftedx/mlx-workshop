import XCTest

@testable import MLXWorkshopApp

@MainActor
final class WorkshopViewStateTests: XCTestCase {
  func testProtocolCompletionDoesNotImplyQualification() throws {
    let store = WorkshopStore(content: .demo)
    let event = try WorkflowEvent(
      runID: "run-1",
      sequence: 1,
      timestamp: "2026-07-09T22:00:00.000Z",
      type: "run.completed",
      stage: nil,
      payload: [:]
    )

    let update = try XCTUnwrap(WorkflowPresentationAdapter().project(event))
    store.apply(update)

    XCTAssertEqual(store.currentRun?.state, .completed)
    XCTAssertFalse(store.currentRun?.isQualified ?? true)
  }

  func testProtocolProgressWithoutTotalRemainsIndeterminate() throws {
    let event = try WorkflowEvent(
      runID: "run-1",
      sequence: 1,
      timestamp: "2026-07-09T22:00:00.000Z",
      type: "stage.progress",
      stage: "quantize",
      payload: ["completed": .number(17), "total": .null, "unit": .string("tensors")]
    )

    let update = try XCTUnwrap(WorkflowPresentationAdapter().project(event))
    guard case .runChanged(let run) = update else {
      return XCTFail("Expected a run presentation update")
    }

    XCTAssertEqual(run.state, .running)
    XCTAssertNil(run.progress?.fraction)
  }

  func testBlockedPlanCannotStart() throws {
    let store = WorkshopStore(content: .demo)
    let event = try WorkflowEvent(
      runID: "run-1",
      sequence: 1,
      timestamp: "2026-07-09T22:00:00.000Z",
      type: "plan.blocked",
      stage: nil,
      payload: ["code": .string("adapter-required"), "message": .string("No validated adapter")]
    )

    store.apply(try XCTUnwrap(WorkflowPresentationAdapter().project(event)))

    XCTAssertEqual(store.currentRun?.state, .blocked)
    XCTAssertFalse(store.canStartRun)
  }

  func testProtocolMismatchDisablesRecipeMutation() throws {
    let store = WorkshopStore(content: .demo)
    let layer = try XCTUnwrap(store.layers.first(where: { !$0.isProtected }))
    let originalPrecision = layer.precision
    store.apply(
      .runChanged(
        WorkshopRun(id: "run-1", title: "Future workflow", state: .protocolMismatch)))

    store.setPrecision(originalPrecision == .four ? .eight : .four, for: layer.id)

    XCTAssertEqual(store.layers.first(where: { $0.id == layer.id })?.precision, originalPrecision)
    XCTAssertFalse(store.mutatingActionsAllowed)
  }

  func testCapabilityProjectionKeepsUnsupportedModelIdentityAndActionableBlocker() throws {
    let event = try WorkflowEvent(
      runID: "inspect-1",
      sequence: 1,
      timestamp: "2026-07-09T22:00:00.000Z",
      type: "capability.reported",
      stage: "inspect",
      payload: [
        "model": .string("/tmp/unknown-model"),
        "status": .string("pass"),
        "identity": .object([
          "model_type": .string("unknown_fixture"),
          "architecture_kind": .string("dense-or-unknown"),
        ]),
        "source": .object([
          "state": .string("float-candidate"),
          "disk_bytes": .number(4_096),
        ]),
        "routing": .object([
          "conversion": .object([
            "allowed": .bool(false),
            "default": .string("architecture-adapter-required"),
          ])
        ]),
        "warnings": .array([]),
        "failures": .array([]),
      ]
    )

    let projection = try XCTUnwrap(WorkflowCapabilityProjector().project(event))

    XCTAssertEqual(projection.model.displayName, "unknown-model")
    XCTAssertEqual(projection.model.architecture, "unknown_fixture")
    XCTAssertEqual(projection.model.sizeBytes, 4_096)
    XCTAssertEqual(projection.blocker?.id, "adapter-required")
    XCTAssertEqual(projection.blocker?.recovery, .chooseModel)
  }

  func testAlreadyQuantizedModelKeepsInspectionUsableWithoutOfferingRequantization() throws {
    let event = try WorkflowEvent(
      runID: "inspect-quantized",
      sequence: 1,
      timestamp: "2026-07-09T22:00:00.000Z",
      type: "capability.reported",
      stage: "inspect",
      payload: [
        "model": .string("/tmp/quantized-model"),
        "status": .string("pass"),
        "identity": .object(["model_type": .string("qwen3_5")]),
        "source": .object(["state": .string("quantized")]),
        "routing": .object([
          "conversion": .object([
            "allowed": .bool(false),
            "default": .string("do-not-requantize"),
          ])
        ]),
        "warnings": .array([]),
        "failures": .array([]),
      ]
    )

    let projection = try XCTUnwrap(WorkflowCapabilityProjector().project(event))

    XCTAssertNil(projection.blocker)
    XCTAssertEqual(projection.model.warnings.first?.id, "conversion-unavailable")
  }

  func testHostProjectionUsesRecordedFactsAndSanitizedWorkloadLabels() throws {
    let event = try WorkflowEvent(
      runID: "host-check",
      sequence: 1,
      timestamp: "2026-07-09T22:00:00.000Z",
      type: "capability.reported",
      stage: "host",
      payload: [
        "hardware": .object([
          "chip": .string("Apple M4 Max"),
          "unified_memory_bytes": .number(68_719_476_736),
        ]),
        "macos": .object(["version": .string("26.5.1")]),
        "disk": .object(["free_bytes": .number(47_375_835_136)]),
        "versions": .object([
          "mlx": .string("0.31.2"),
          "mlx_lm": .string("0.31.3"),
        ]),
        "active_workloads": .array([
          .object([
            "pid": .number(22_229),
            "kind": .string("mtplx"),
            "process": .string("python"),
          ])
        ]),
      ])

    let snapshot = try XCTUnwrap(WorkflowHostProjector().project(event))

    XCTAssertEqual(snapshot.chip, "Apple M4 Max")
    XCTAssertEqual(snapshot.mlxLMVersion, "0.31.3")
    XCTAssertEqual(snapshot.activeWorkloads, ["MTPLX · PID 22229"])
    XCTAssertFalse(snapshot.freeDisk.isEmpty)
  }
}
