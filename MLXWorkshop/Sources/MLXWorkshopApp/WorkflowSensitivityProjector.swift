import Foundation

struct SensitivityProjection: Equatable {
  let layers: [LayerRecord]
  let analysisURL: URL
  let recommendedCandidateID: String
  let candidates: [SensitivityCandidateRecord]
}

struct SensitivityCandidateRecord: Equatable {
  let id: String
  let assignments: [String: Precision]
}

struct WorkflowSensitivityProjector {
  func project(_ event: WorkflowEvent) -> SensitivityProjection? {
    guard event.kind == .known(.evaluationRecorded), event.stage == "sensitivity",
      let analysisPath = event.payload["analysis_path"]?.stringValue,
      let recommendedID = event.payload["recommended_candidate_id"]?.stringValue,
      case .object(let analysis) = event.payload["analysis"],
      analysis["status"]?.stringValue == "supported",
      case .array(let measurements) = analysis["measurements"],
      case .array(let candidates) = analysis["candidates"]
    else { return nil }

    var deltaByModule: [String: [String: Double]] = [:]
    for value in measurements {
      guard case .object(let item) = value,
        let module = item["module_id"]?.stringValue,
        let precision = item["precision_id"]?.stringValue,
        case .number(let delta) = item["delta"]
      else { continue }
      deltaByModule[module, default: [:]][precision] = delta
    }
    let projectedCandidates = candidates.compactMap { value -> (String, [String: String])? in
      guard case .object(let item) = value,
        let candidateID = item["candidate_id"]?.stringValue,
        case .array(let assignmentValues) = item["assignments"]
      else { return nil }
      var assignments: [String: String] = [:]
      for assignment in assignmentValues {
        guard case .array(let pair) = assignment, pair.count == 2,
          let module = pair[0].stringValue, let precision = pair[1].stringValue
        else { return nil }
        assignments[module] = precision
      }
      return (candidateID, assignments)
    }
    let recommended = projectedCandidates.first(where: { $0.0 == recommendedID })?.1
    guard let recommended, !deltaByModule.isEmpty else { return nil }
    let maximum = deltaByModule.values.flatMap(\.values).max() ?? 1
    let layers = deltaByModule.keys.sorted().compactMap { module -> LayerRecord? in
      guard let suffix = module.split(separator: ".").dropFirst().first,
        let index = Int(suffix), let deltas = deltaByModule[module]
      else { return nil }
      let precision: Precision = recommended[module] == "mxfp8" ? .eight : .four
      let delta = deltas[precision == .eight ? "mxfp8" : "mxfp4"] ?? 0
      return LayerRecord(
        index: index, name: module, kind: "Measured transformer block",
        sensitivity: maximum > 0 ? (deltas["mxfp4"] ?? delta) / maximum : 0,
        precision: precision, sizeDelta: precision == .eight ? -50 : -75,
        klDelta: delta, isProtected: precision == .eight)
    }
    return SensitivityProjection(
      layers: layers, analysisURL: URL(fileURLWithPath: analysisPath),
      recommendedCandidateID: recommendedID,
      candidates: projectedCandidates.map { candidateID, assignments in
        SensitivityCandidateRecord(
          id: candidateID,
          assignments: assignments.mapValues { $0 == "mxfp8" ? .eight : .four })
      })
  }
}
