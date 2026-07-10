import Foundation

struct WorkflowCapabilityProjection: Equatable {
  let model: LocalModelReference
  let blocker: WorkshopDiagnostic?
}

struct WorkflowCapabilityProjector {
  func project(_ event: WorkflowEvent) -> WorkflowCapabilityProjection? {
    guard event.kind == .known(.capabilityReported), event.stage == "inspect",
      let modelPath = event.payload["model"]?.stringValue
    else { return nil }

    let identity = event.payload["identity"]?.objectValue ?? [:]
    let source = event.payload["source"]?.objectValue ?? [:]
    let routing = event.payload["routing"]?.objectValue ?? [:]
    let capabilities = event.payload["capabilities"]?.objectValue ?? [:]
    let conversion = routing["conversion"]?.objectValue ?? [:]
    let route = conversion["default"]?.stringValue
    let conversionAllowed = conversion["allowed"]?.boolValue
    let status = event.payload["status"]?.stringValue
    let failures = event.payload["failures"]?.stringArrayValue ?? []
    let warnings = event.payload["warnings"]?.stringArrayValue ?? []
    let directory = URL(fileURLWithPath: modelPath, isDirectory: true).standardizedFileURL

    var warningDiagnostics = warnings.enumerated().map { index, message in
      WorkshopDiagnostic(
        id: "inspection-warning-\(index)", severity: .warning,
        title: "Inspection warning", message: message, recovery: .retryInspection)
    }
    let supportSummary: String
    if conversionAllowed == true {
      supportSummary = "Conversion supported"
    } else if let route {
      supportSummary = route
    } else {
      supportSummary = "Capabilities inspected"
    }

    let model = LocalModelReference(
      directory: directory,
      displayName: directory.lastPathComponent,
      architecture: identity["model_type"]?.stringValue,
      format: "safetensors",
      sizeBytes: source["disk_bytes"]?.int64Value,
      parameterSummary: identity["architecture_kind"]?.stringValue,
      sourceState: source["state"]?.stringValue,
      supportSummary: supportSummary,
      warnings: warningDiagnostics
    )

    let blocker: WorkshopDiagnostic?
    if status == "fail" || !failures.isEmpty {
      blocker = WorkshopDiagnostic(
        id: "inspection-failed", severity: .blocker,
        title: "Model inspection failed",
        message: failures.first ?? "The model directory could not be inspected.",
        recovery: .retryInspection)
    } else if conversionAllowed == false, route?.contains("adapter-required") == true {
      blocker = WorkshopDiagnostic(
        id: "adapter-required", severity: .blocker,
        title: "Architecture adapter required",
        message:
          "This model was inspected, but its tensor semantics do not have a validated adapter. The source remains unchanged.",
        recovery: .chooseModel)
    } else {
      blocker = nil
      if conversionAllowed == false {
        warningDiagnostics.append(
          WorkshopDiagnostic(
            id: "conversion-unavailable", severity: .information,
            title: "Conversion is unavailable",
            message:
              "This source will not be requantized. Other inspected operations may still be available.",
            recovery: nil))
      }
    }
    var projectedModel = model
    projectedModel.warnings = warningDiagnostics
    projectedModel.visionAdvertised = capabilities["vision"]?.boolValue == true
    let mtpLayers = capabilities["mtp_layers_advertised"]?.int64Value ?? 0
    projectedModel.mtpAdvertised = capabilities["mtp_sidecar"]?.boolValue == true || mtpLayers > 0
    return WorkflowCapabilityProjection(model: projectedModel, blocker: blocker)
  }
}

extension JSONValue {
  fileprivate var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  fileprivate var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  fileprivate var int64Value: Int64? {
    guard case .number(let value) = self,
      value.isFinite,
      value >= Double(Int64.min),
      value <= Double(Int64.max)
    else { return nil }
    return Int64(value)
  }

  fileprivate var stringArrayValue: [String]? {
    guard case .array(let values) = self else { return nil }
    return values.compactMap(\.stringValue)
  }
}
