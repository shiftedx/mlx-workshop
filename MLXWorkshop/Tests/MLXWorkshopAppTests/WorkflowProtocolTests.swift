import Foundation
import XCTest

@testable import MLXWorkshopApp

final class WorkflowProtocolTests: XCTestCase {
  func testDecodesCommandDisclosureWithoutParsingShellText() throws {
    let data = Data(
      """
      {"schema_version":1,"commands":[{"stage":"quantize-mxfp4","kind":"mlx-lm-convert","executable":"/tool/mlx_lm.convert","executable_sha256":"abc","arguments":["--model","/models/parent"],"working_directory":"/workspace","environment_keys":["HOME"],"redacted_display":"/tool/mlx_lm.convert --model /models/parent"}]}
      """.utf8)

    let disclosure = try CommandDisclosure.decodeCommandsFile(data)

    XCTAssertEqual(disclosure.executableIdentity, "/tool/mlx_lm.convert")
    XCTAssertEqual(disclosure.arguments, ["--model", "/models/parent"])
    XCTAssertEqual(
      disclosure.redactedDisplay,
      "/tool/mlx_lm.convert --model /models/parent")
  }

  func testCommandDisclosurePreservesEveryStructuredCommand() throws {
    let data = Data(
      """
      {"schema_version":1,"commands":[{"executable":"/tool/mlx_lm.convert","arguments":["--q-mode","mxfp4"],"redacted_display":"mxfp4"},{"executable":"/tool/mlx_lm.convert","arguments":["--q-mode","affine"],"redacted_display":"affine"}]}
      """.utf8)

    let disclosure = try CommandDisclosure.decodeCommandsFile(data)

    XCTAssertEqual(disclosure.commands.count, 2)
    XCTAssertEqual(
      disclosure.commands.map(\.arguments),
      [
        ["--q-mode", "mxfp4"], ["--q-mode", "affine"],
      ])
  }

  func testDecodesFrozenV1EnvelopeWithoutDiscardingPayload() throws {
    let data = Data(
      #"{"schema_version":1,"run_id":"run-1","sequence":1,"timestamp":"2026-07-09T22:00:00.000Z","type":"stage.progress","stage":"quantize","payload":{"completed":17,"total":100,"unit":"tensors"}}"#
        .utf8
    )

    let event = try WorkflowEvent.decode(data)

    XCTAssertEqual(event.schemaVersion, 1)
    XCTAssertEqual(event.runID, "run-1")
    XCTAssertEqual(event.sequence, 1)
    XCTAssertEqual(event.kind, .known(.stageProgress))
    XCTAssertEqual(event.stage, "quantize")
    XCTAssertEqual(event.payload["completed"], .number(17))
    XCTAssertEqual(event.payload["unit"], .string("tensors"))
  }

  func testMissingRequiredStageFieldIsCorruptRatherThanNull() throws {
    let data = Data(
      #"{"schema_version":1,"run_id":"run-1","sequence":1,"timestamp":"2026-07-09T22:00:00.000Z","type":"run.created","payload":{}}"#
        .utf8
    )

    XCTAssertThrowsError(try WorkflowEvent.decode(data))
  }

  func testDecodesCLIRunManifestWithStructuredChildProcess() throws {
    let data = Data(
      #"{"schema_version":1,"run_id":"run-1","state":"running","resumability":"unsafe","exact_parent":"/tmp/parent","created_at":"2026-07-09T22:00:00.000Z","updated_at":"2026-07-09T22:00:01.000Z","last_committed_sequence":4,"blockers":[],"terminal_reason":null,"last_completed_stage":null,"child_processes":[{"pid":4242,"stage":"fixture","launched_at":"2026-07-09T22:00:00.500Z","signal":null}],"qualified":false,"cancellation":null}"#
        .utf8
    )

    let manifest = try JSONDecoder().decode(WorkflowRunManifest.self, from: data)

    XCTAssertEqual(manifest.childProcesses.count, 1)
    XCTAssertEqual(manifest.childProcesses[0].pid, 4242)
    XCTAssertEqual(manifest.childProcesses[0].stage, "fixture")
  }
}
