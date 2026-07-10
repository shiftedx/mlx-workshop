import Foundation

enum JSONLStreamError: Error, Equatable, Sendable {
  case malformedLine(Int)
  case noncontiguousSequence(expected: Int, found: Int)
  case runIDChanged(expected: String, found: String)
}

struct JSONLFinishResult: Equatable, Sendable {
  let events: [WorkflowEvent]
  let recoverableTail: Data?
}

struct JSONLStreamDecoder: Sendable {
  private var buffer = Data()
  private var lineNumber = 0
  private var runID: String?
  private var nextSequence = 1

  mutating func append<Chunk: DataProtocol>(_ chunk: Chunk) throws -> [WorkflowEvent] {
    buffer.append(contentsOf: chunk)
    var events: [WorkflowEvent] = []

    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      lineNumber += 1
      if line.last == 0x0D {
        line.removeLast()
      }
      events.append(try decodeCompleteLine(line, number: lineNumber))
    }
    return events
  }

  mutating func decodeRecoveryJournal(_ journal: Data) throws -> JSONLFinishResult {
    if journal.last == 0x0A {
      buffer.append(journal.dropLast())
    } else {
      buffer.append(journal)
    }
    let streamedEvents = try append(Data())
    let finishResult = try finish(recoveringFinalCorruptTail: true)
    return JSONLFinishResult(
      events: streamedEvents + finishResult.events,
      recoverableTail: finishResult.recoverableTail
    )
  }

  mutating func finish(recoveringFinalCorruptTail: Bool) throws -> JSONLFinishResult {
    guard !buffer.isEmpty else {
      return JSONLFinishResult(events: [], recoverableTail: nil)
    }

    let tail = buffer
    buffer.removeAll(keepingCapacity: false)
    lineNumber += 1

    do {
      _ = try JSONSerialization.jsonObject(with: tail)
    } catch {
      if recoveringFinalCorruptTail {
        return JSONLFinishResult(events: [], recoverableTail: tail)
      }
      throw JSONLStreamError.malformedLine(lineNumber)
    }

    let event = try WorkflowEvent.decode(tail)
    try validateJournalIdentity(of: event)
    return JSONLFinishResult(events: [event], recoverableTail: nil)
  }

  private mutating func decodeCompleteLine(_ line: Data, number: Int) throws -> WorkflowEvent {
    guard !line.isEmpty else {
      throw JSONLStreamError.malformedLine(number)
    }
    do {
      _ = try JSONSerialization.jsonObject(with: line)
    } catch {
      throw JSONLStreamError.malformedLine(number)
    }
    let event = try WorkflowEvent.decode(line)
    try validateJournalIdentity(of: event)
    return event
  }

  private mutating func validateJournalIdentity(of event: WorkflowEvent) throws {
    if let runID, event.runID != runID {
      throw JSONLStreamError.runIDChanged(expected: runID, found: event.runID)
    }
    guard event.sequence == nextSequence else {
      throw JSONLStreamError.noncontiguousSequence(
        expected: nextSequence,
        found: event.sequence
      )
    }
    runID = event.runID
    nextSequence += 1
  }
}
