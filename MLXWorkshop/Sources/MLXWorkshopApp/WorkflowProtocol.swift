import Foundation

enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

enum WorkflowKnownEventType: String, Codable, CaseIterable, Sendable {
  case runCreated = "run.created"
  case runState = "run.state"
  case runInterrupted = "run.interrupted"
  case runCompleted = "run.completed"
  case runCancelled = "run.cancelled"
  case capabilityReported = "capability.reported"
  case planReady = "plan.ready"
  case planBlocked = "plan.blocked"
  case stageStarted = "stage.started"
  case stageProgress = "stage.progress"
  case stageLog = "stage.log"
  case stageCompleted = "stage.completed"
  case stageFailed = "stage.failed"
  case artifactDiscovered = "artifact.discovered"
  case metricRecorded = "metric.recorded"
  case evaluationRecorded = "evaluation.recorded"
  case promotionGate = "promotion.gate"
  case warningRaised = "warning.raised"
  case resourcePressure = "resource.pressure"
}

enum WorkflowEventKind: Equatable, Sendable {
  case known(WorkflowKnownEventType)
  case unknown(String)
}

enum WorkflowProtocolError: Error, Equatable, Sendable {
  case protocolMismatch(supported: Int, found: Int)
  case invalidTimestamp(String)
}

struct WorkflowEvent: Codable, Equatable, Sendable {
  static let supportedSchemaVersion = 1

  let schemaVersion: Int
  let runID: String
  let sequence: Int
  let timestamp: String
  let rawType: String
  let stage: String?
  let payload: [String: JSONValue]

  var kind: WorkflowEventKind {
    if let known = WorkflowKnownEventType(rawValue: rawType) {
      return .known(known)
    }
    return .unknown(rawType)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case runID = "run_id"
    case sequence
    case timestamp
    case rawType = "type"
    case stage
    case payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == Self.supportedSchemaVersion else {
      throw WorkflowProtocolError.protocolMismatch(
        supported: Self.supportedSchemaVersion,
        found: schemaVersion
      )
    }

    let timestamp = try container.decode(String.self, forKey: .timestamp)
    guard Self.isRFC3339UTCTimestamp(timestamp) else {
      throw WorkflowProtocolError.invalidTimestamp(timestamp)
    }

    self.schemaVersion = schemaVersion
    self.runID = try container.decode(String.self, forKey: .runID)
    self.sequence = try container.decode(Int.self, forKey: .sequence)
    self.timestamp = timestamp
    self.rawType = try container.decode(String.self, forKey: .rawType)
    guard container.contains(.stage) else {
      throw DecodingError.keyNotFound(
        CodingKeys.stage,
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Protocol-v1 envelope is missing required stage field."
        )
      )
    }
    self.stage = try container.decodeIfPresent(String.self, forKey: .stage)
    self.payload = try container.decode([String: JSONValue].self, forKey: .payload)
  }

  init(
    schemaVersion: Int = Self.supportedSchemaVersion,
    runID: String,
    sequence: Int,
    timestamp: String,
    type: String,
    stage: String?,
    payload: [String: JSONValue]
  ) throws {
    guard schemaVersion == Self.supportedSchemaVersion else {
      throw WorkflowProtocolError.protocolMismatch(
        supported: Self.supportedSchemaVersion,
        found: schemaVersion
      )
    }
    guard Self.isRFC3339UTCTimestamp(timestamp) else {
      throw WorkflowProtocolError.invalidTimestamp(timestamp)
    }
    self.schemaVersion = schemaVersion
    self.runID = runID
    self.sequence = sequence
    self.timestamp = timestamp
    self.rawType = type
    self.stage = stage
    self.payload = payload
  }

  static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Self {
    try decoder.decode(Self.self, from: data)
  }

  private static func isRFC3339UTCTimestamp(_ value: String) -> Bool {
    guard value.hasSuffix("Z") else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
  }
}

enum WorkflowRunState: String, Codable, CaseIterable, Sendable {
  case created
  case planned
  case blocked
  case running
  case cancelling
  case cancelled
  case interrupted
  case failed
  case completed
}

enum WorkflowResumability: String, Codable, CaseIterable, Sendable {
  case notApplicable = "not-applicable"
  case safe
  case unsafe
  case unknown
}

struct WorkflowBlocker: Codable, Equatable, Sendable {
  let code: String
  let message: String
}

struct WorkflowChildProcess: Codable, Equatable, Sendable {
  let pid: Int32
  let stage: String
  let launchedAt: String
  let signal: String?

  private enum CodingKeys: String, CodingKey {
    case pid
    case stage
    case launchedAt = "launched_at"
    case signal
  }
}

struct WorkflowRunManifest: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let runID: String
  var state: WorkflowRunState
  var resumability: WorkflowResumability
  let exactParent: String?
  let createdAt: String
  var updatedAt: String
  var lastCommittedSequence: Int
  var blockers: [WorkflowBlocker]
  var terminalReason: String?
  var lastCompletedStage: String?
  var childProcesses: [WorkflowChildProcess]
  var qualified: Bool?
  var cancellation: JSONValue?

  init(
    schemaVersion: Int = WorkflowEvent.supportedSchemaVersion,
    runID: String,
    state: WorkflowRunState,
    resumability: WorkflowResumability,
    exactParent: String?,
    createdAt: String,
    updatedAt: String,
    lastCommittedSequence: Int,
    blockers: [WorkflowBlocker] = [],
    terminalReason: String? = nil,
    lastCompletedStage: String? = nil,
    childProcesses: [WorkflowChildProcess] = [],
    qualified: Bool? = nil,
    cancellation: JSONValue? = nil
  ) throws {
    guard schemaVersion == WorkflowEvent.supportedSchemaVersion else {
      throw WorkflowProtocolError.protocolMismatch(
        supported: WorkflowEvent.supportedSchemaVersion,
        found: schemaVersion
      )
    }
    self.schemaVersion = schemaVersion
    self.runID = runID
    self.state = state
    self.resumability = resumability
    self.exactParent = exactParent
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastCommittedSequence = lastCommittedSequence
    self.blockers = blockers
    self.terminalReason = terminalReason
    self.lastCompletedStage = lastCompletedStage
    self.childProcesses = childProcesses
    self.qualified = qualified
    self.cancellation = cancellation
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case runID = "run_id"
    case state
    case resumability
    case exactParent = "exact_parent"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case lastCommittedSequence = "last_committed_sequence"
    case blockers
    case terminalReason = "terminal_reason"
    case lastCompletedStage = "last_completed_stage"
    case childProcesses = "child_processes"
    case qualified
    case cancellation
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == WorkflowEvent.supportedSchemaVersion else {
      throw WorkflowProtocolError.protocolMismatch(
        supported: WorkflowEvent.supportedSchemaVersion,
        found: schemaVersion
      )
    }
    self.schemaVersion = schemaVersion
    self.runID = try container.decode(String.self, forKey: .runID)
    self.state = try container.decode(WorkflowRunState.self, forKey: .state)
    self.resumability = try container.decode(WorkflowResumability.self, forKey: .resumability)
    self.exactParent = try container.decodeIfPresent(String.self, forKey: .exactParent)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    self.updatedAt = try container.decode(String.self, forKey: .updatedAt)
    self.lastCommittedSequence = try container.decode(Int.self, forKey: .lastCommittedSequence)
    self.blockers = try container.decodeIfPresent([WorkflowBlocker].self, forKey: .blockers) ?? []
    self.terminalReason = try container.decodeIfPresent(String.self, forKey: .terminalReason)
    self.lastCompletedStage = try container.decodeIfPresent(
      String.self, forKey: .lastCompletedStage)
    self.childProcesses =
      try container.decodeIfPresent([WorkflowChildProcess].self, forKey: .childProcesses) ?? []
    self.qualified = try container.decodeIfPresent(Bool.self, forKey: .qualified)
    self.cancellation = try container.decodeIfPresent(JSONValue.self, forKey: .cancellation)
  }
}
