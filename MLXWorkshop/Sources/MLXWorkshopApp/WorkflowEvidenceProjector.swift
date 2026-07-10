import Foundation

struct WorkflowEvidenceProjector {
  func project(_ event: WorkflowEvent) -> [CandidateRecord]? {
    guard event.kind == .known(.evaluationRecorded), event.stage == "compare",
      let runID = event.payload["run_id"]?.stringValue,
      runID == event.runID,
      let parentPath = event.payload["exact_parent"]?.stringValue,
      let candidatePath = event.payload["candidate"]?.stringValue,
      let parentHash = event.payload["parent_tree_sha256"]?.stringValue,
      let candidateHash = event.payload["candidate_tree_sha256"]?.stringValue,
      case .number(let parentBytes) = event.payload["parent_size_bytes"],
      case .number(let candidateBytes) = event.payload["candidate_size_bytes"],
      case .bool(let qualified) = event.payload["qualified"],
      let classification = event.payload["classification"]?.stringValue,
      let recipe = event.payload["recipe"]?.objectValue
    else { return nil }

    let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
    let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: true)
    let evidenceRoot = candidateURL.deletingLastPathComponent().deletingLastPathComponent()
    let modes = recipe["quant_modes"]?.stringArrayValue ?? []
    let recipeName =
      modes.isEmpty ? "Recorded workflow recipe" : modes.joined(separator: " + ").uppercased()
    let gates = (event.payload["gates"]?.arrayValue ?? []).compactMap {
      value -> QualificationGateRecord? in
      guard let item = value.objectValue,
        let name = item["name"]?.stringValue,
        let status = item["status"]?.stringValue
      else { return nil }
      return QualificationGateRecord(
        name: name, status: status, evidence: item["evidence"]?.stringArrayValue ?? [])
    }

    return [
      CandidateRecord(
        id: "\(runID):parent", runID: runID, name: parentURL.lastPathComponent,
        recipe: "Exact immutable parent · \(parentHash.prefix(12))",
        sizeGB: parentBytes / 1_000_000_000,
        status: .parent, exactParent: parentURL, evidenceRoot: evidenceRoot),
      CandidateRecord(
        id: "\(runID):candidate", runID: runID, name: candidateURL.lastPathComponent,
        recipe: "\(recipeName) · \(candidateHash.prefix(12))",
        sizeGB: candidateBytes / 1_000_000_000,
        status: qualified && classification == "qualified" ? .qualified : .rejected,
        exactParent: parentURL, candidateDirectory: candidateURL, gates: gates,
        evidenceRoot: evidenceRoot),
    ]
  }
}

extension JSONValue {
  fileprivate var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  fileprivate var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  fileprivate var stringArrayValue: [String]? {
    guard let values = arrayValue else { return nil }
    let strings = values.compactMap(\.stringValue)
    return strings.count == values.count ? strings : nil
  }
}
