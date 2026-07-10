import Foundation
import XCTest

@testable import MLXWorkshopApp

final class JSONLStreamDecoderTests: XCTestCase {
  func testSplitReadsAndMultipleLinesProduceCompleteOrderedEvents() throws {
    var decoder = JSONLStreamDecoder()
    let first = Data(
      #"{"schema_version":1,"run_id":"split","sequence":1,"timestamp":"2026-07-09T22:00:00.000Z","type":"run.created","stage":null,"payload":{}}"#
        .utf8
    )
    let second = Data(
      #"{"schema_version":1,"run_id":"split","sequence":2,"timestamp":"2026-07-09T22:00:00.100Z","type":"stage.progress","stage":"fixture","payload":{"completed":1,"total":null}}"#
        .utf8
    )
    let combined = first + Data([0x0A]) + second + Data([0x0A])

    XCTAssertTrue(try decoder.append(combined.prefix(37)).isEmpty)
    let events = try decoder.append(combined.dropFirst(37))

    XCTAssertEqual(events.map(\.sequence), [1, 2])
    XCTAssertEqual(try decoder.finish(recoveringFinalCorruptTail: false).recoverableTail, nil)
  }

  func testUnknownV1EventIsPreservedAndAdvancesSequence() throws {
    var decoder = JSONLStreamDecoder()
    let data = try fixtureData(named: "unknown-future-event")

    let events = try decoder.append(data)
    _ = try decoder.finish(recoveringFinalCorruptTail: false)

    XCTAssertEqual(events.count, 3)
    XCTAssertEqual(events[1].kind, .unknown("stage.telemetry-from-a-future-v1-writer"))
    XCTAssertEqual(events[2].sequence, 3)
  }

  func testFutureSchemaProducesExplicitMismatch() throws {
    var decoder = JSONLStreamDecoder()

    XCTAssertThrowsError(try decoder.append(fixtureData(named: "future-schema"))) { error in
      XCTAssertEqual(
        error as? WorkflowProtocolError,
        .protocolMismatch(supported: 1, found: 2)
      )
    }
  }

  func testRecoveryToleratesOnlyFinalMalformedJSONFragment() throws {
    var decoder = JSONLStreamDecoder()
    let data = try fixtureData(named: "corrupt-tail")

    let finish = try decoder.decodeRecoveryJournal(data)

    XCTAssertEqual(finish.events.map(\.sequence), [1, 2])
    XCTAssertNotNil(finish.recoverableTail)
  }

  func testMalformedCompleteLineIsJournalCorruption() throws {
    var decoder = JSONLStreamDecoder()
    let line1 =
      #"{"schema_version":1,"run_id":"bad","sequence":1,"timestamp":"2026-07-09T22:00:00.000Z","type":"run.created","stage":null,"payload":{}}"#
    let line3 =
      #"{"schema_version":1,"run_id":"bad","sequence":3,"timestamp":"2026-07-09T22:00:00.200Z","type":"run.completed","stage":null,"payload":{}}"#

    XCTAssertThrowsError(try decoder.append(Data("\(line1)\nnot-json\n\(line3)\n".utf8))) {
      error in
      guard case JSONLStreamError.malformedLine(let line) = error else {
        return XCTFail("Expected malformed line, got \(error)")
      }
      XCTAssertEqual(line, 2)
    }
  }

  func testSequenceGapIsJournalCorruption() throws {
    var decoder = JSONLStreamDecoder()
    let line1 =
      #"{"schema_version":1,"run_id":"gap","sequence":1,"timestamp":"2026-07-09T22:00:00.000Z","type":"run.created","stage":null,"payload":{}}"#
    let line3 =
      #"{"schema_version":1,"run_id":"gap","sequence":3,"timestamp":"2026-07-09T22:00:00.200Z","type":"run.completed","stage":null,"payload":{}}"#

    XCTAssertThrowsError(try decoder.append(Data("\(line1)\n\(line3)\n".utf8))) { error in
      XCTAssertEqual(
        error as? JSONLStreamError,
        .noncontiguousSequence(expected: 2, found: 3)
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
      contentsOf: workspace.appendingPathComponent("tests/fixtures/protocol/v1/\(name).jsonl")
    )
  }
}
