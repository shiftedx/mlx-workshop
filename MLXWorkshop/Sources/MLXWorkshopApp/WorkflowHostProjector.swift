import Foundation

struct WorkflowHostProjector {
  func project(_ event: WorkflowEvent) -> HostSnapshot? {
    guard event.kind == .known(.capabilityReported), event.stage == "host" else { return nil }
    let hardware = object(event.payload["hardware"])
    let macos = object(event.payload["macos"])
    let disk = object(event.payload["disk"])
    let versions = object(event.payload["versions"])
    guard let chip = string(hardware["chip"]),
      let memory = integer(hardware["unified_memory_bytes"]),
      let freeDisk = integer(disk["free_bytes"])
    else { return nil }

    let workloads = array(event.payload["active_workloads"]).compactMap { item -> String? in
      let value = object(item)
      guard let kind = string(value["kind"]), let pid = integer(value["pid"]) else { return nil }
      return "\(displayName(kind)) · PID \(pid)"
    }
    let version = string(macos["version"]) ?? "Unreported"
    return HostSnapshot(
      chip: chip,
      unifiedMemory: ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory),
      availableMemory: nil,
      freeDisk: ByteCountFormatter.string(fromByteCount: freeDisk, countStyle: .file),
      operatingSystem: "macOS \(version)",
      mlxVersion: string(versions["mlx"]),
      mlxLMVersion: string(versions["mlx_lm"]),
      activeWorkloads: workloads)
  }

  private func object(_ value: JSONValue?) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
  }

  private func array(_ value: JSONValue?) -> [JSONValue] {
    guard case .array(let array) = value else { return [] }
    return array
  }

  private func string(_ value: JSONValue?) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
  }

  private func integer(_ value: JSONValue?) -> Int64? {
    guard case .number(let number) = value, number.isFinite else { return nil }
    return Int64(number)
  }

  private func displayName(_ kind: String) -> String {
    switch kind {
    case "mtplx": "MTPLX"
    case "mlx-lm": "MLX-LM"
    case "mlx-vlm": "MLX-VLM"
    case "lm-studio": "LM Studio"
    default: kind
    }
  }
}
