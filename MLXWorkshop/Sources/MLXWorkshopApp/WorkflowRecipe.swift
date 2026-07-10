import Darwin
import Foundation

enum WorkflowFilePath {
  static func canonical(_ url: URL) throws -> String {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    return try url.withUnsafeFileSystemRepresentation { representation in
      guard let representation, let resolved = realpath(representation, nil) else {
        throw CocoaError(.fileNoSuchFile)
      }
      defer { free(resolved) }
      return String(cString: resolved)
    }
  }
}

private struct WorkflowAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

private func workflowStrictContainer<Key>(
  from decoder: Decoder,
  keyedBy type: Key.Type
) throws -> KeyedDecodingContainer<Key>
where Key: CodingKey & CaseIterable, Key.AllCases.Element == Key {
  let rawContainer = try decoder.container(keyedBy: WorkflowAnyCodingKey.self)
  let allowedKeys = Set(Key.allCases.map(\.stringValue))
  let unknownKeys = rawContainer.allKeys.map(\.stringValue).filter { !allowedKeys.contains($0) }
  guard unknownKeys.isEmpty else {
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription:
          "Unknown protocol-v1 key(s): \(unknownKeys.sorted().joined(separator: ", "))."
      )
    )
  }
  return try decoder.container(keyedBy: type)
}

private func workflowSchemaVersion(from decoder: Decoder) throws -> Int {
  let container = try decoder.container(keyedBy: WorkflowAnyCodingKey.self)
  let key = WorkflowAnyCodingKey(stringValue: "schema_version")!
  return try container.decode(Int.self, forKey: key)
}

private func workflowRequiredNullable<Key, Value>(
  _ type: Value.Type,
  forKey key: Key,
  in container: KeyedDecodingContainer<Key>
) throws -> Value?
where Key: CodingKey, Value: Decodable {
  guard container.contains(key) else {
    throw DecodingError.keyNotFound(
      key,
      DecodingError.Context(
        codingPath: container.codingPath,
        debugDescription: "Protocol-v1 requires the nullable \(key.stringValue) field."
      )
    )
  }
  return try container.decodeIfPresent(type, forKey: key)
}

private func workflowRequire(
  _ condition: @autoclosure () -> Bool,
  codingPath: [CodingKey],
  _ description: String
) throws {
  guard condition() else {
    throw DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: codingPath, debugDescription: description)
    )
  }
}

private func workflowHasUniqueValues<Value: Hashable>(_ values: [Value]) -> Bool {
  Set(values).count == values.count
}

private let workflowAllowedOperations = Set([
  "quantize", "abliterate", "vision", "mtplx", "benchmark",
])
private let workflowAllowedQuantModes = Set(["mxfp4", "mxfp8", "affine"])
private let workflowAllowedResourceReasons = Set([
  "duration-estimate-unknown",
  "active-workloads-present",
  "memory-observation-unknown",
  "resource-model-size-unknown",
  "resource-disk-insufficient",
  "resource-memory-insufficient",
])
private let workflowBlockingResourceReasons = Set([
  "resource-model-size-unknown",
  "resource-disk-insufficient",
  "resource-memory-insufficient",
])

struct WorkflowRecipeAllocation: Codable, Equatable, Sendable {
  let strategy: String
  let targetBPW: Double
  let klTolerance: Double?
  let perModuleOverrides: Bool

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case strategy
    case targetBPW = "target_bpw"
    case klTolerance = "kl_tolerance"
    case perModuleOverrides = "per_module_overrides"
  }

  init(
    strategy: String,
    targetBPW: Double,
    klTolerance: Double?,
    perModuleOverrides: Bool
  ) {
    self.strategy = strategy
    self.targetBPW = targetBPW
    self.klTolerance = klTolerance
    self.perModuleOverrides = perModuleOverrides
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    strategy = try container.decode(String.self, forKey: .strategy)
    targetBPW = try container.decode(Double.self, forKey: .targetBPW)
    klTolerance = try workflowRequiredNullable(
      Double.self, forKey: .klTolerance, in: container)
    perModuleOverrides = try container.decode(Bool.self, forKey: .perModuleOverrides)

    try workflowRequire(
      !strategy.isEmpty, codingPath: decoder.codingPath,
      "allocation.strategy must not be empty.")
    try workflowRequire(
      targetBPW.isFinite && (1...16).contains(targetBPW), codingPath: decoder.codingPath,
      "allocation.target_bpw must be between one and sixteen.")
    try workflowRequire(
      klTolerance.map { $0.isFinite && (0...1).contains($0) } ?? true,
      codingPath: decoder.codingPath,
      "allocation.kl_tolerance must be null or between zero and one.")
    try workflowRequire(
      ["uniform", "mixed-precision"].contains(strategy),
      codingPath: decoder.codingPath,
      "allocation.strategy is not recognized by protocol v1.")
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(strategy, forKey: .strategy)
    try container.encode(targetBPW, forKey: .targetBPW)
    try container.encode(klTolerance, forKey: .klTolerance)
    try container.encode(perModuleOverrides, forKey: .perModuleOverrides)
  }
}

struct WorkflowRecipePriorities: Codable, Equatable, Sendable {
  let quality: Double
  let size: Double

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case quality
    case size
  }

  init(quality: Double, size: Double) {
    self.quality = quality
    self.size = size
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    quality = try container.decode(Double.self, forKey: .quality)
    size = try container.decode(Double.self, forKey: .size)
    try workflowRequire(
      quality.isFinite && (0...1).contains(quality), codingPath: decoder.codingPath,
      "priorities.quality must be between zero and one.")
    try workflowRequire(
      size.isFinite && (0...1).contains(size), codingPath: decoder.codingPath,
      "priorities.size must be between zero and one.")
  }
}

struct WorkflowRecipeCalibration: Codable, Equatable, Sendable {
  let identity: String
  let datasetSHA256: String?
  let sampleBudget: Int
  let tokenBudget: Int
  let seed: Int?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case identity
    case datasetSHA256 = "dataset_sha256"
    case sampleBudget = "sample_budget"
    case tokenBudget = "token_budget"
    case seed
  }

  init(
    identity: String,
    datasetSHA256: String?,
    sampleBudget: Int,
    tokenBudget: Int,
    seed: Int?
  ) {
    self.identity = identity
    self.datasetSHA256 = datasetSHA256
    self.sampleBudget = sampleBudget
    self.tokenBudget = tokenBudget
    self.seed = seed
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    identity = try container.decode(String.self, forKey: .identity)
    datasetSHA256 = try workflowRequiredNullable(
      String.self, forKey: .datasetSHA256, in: container)
    sampleBudget = try container.decode(Int.self, forKey: .sampleBudget)
    tokenBudget = try container.decode(Int.self, forKey: .tokenBudget)
    seed = try workflowRequiredNullable(Int.self, forKey: .seed, in: container)

    try workflowRequire(
      !identity.isEmpty, codingPath: decoder.codingPath,
      "calibration.identity must not be empty.")
    try workflowRequire(
      (0...10_000_000).contains(sampleBudget), codingPath: decoder.codingPath,
      "calibration.sample_budget is outside the protocol-v1 range.")
    try workflowRequire(
      (0...10_000_000_000).contains(tokenBudget), codingPath: decoder.codingPath,
      "calibration.token_budget is outside the protocol-v1 range.")
    if let datasetSHA256 {
      try workflowRequire(
        datasetSHA256.count == 64
          && datasetSHA256.allSatisfy { $0.isHexDigit },
        codingPath: decoder.codingPath,
        "calibration.dataset_sha256 must be null or a 64-character hexadecimal digest.")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(identity, forKey: .identity)
    try container.encode(datasetSHA256, forKey: .datasetSHA256)
    try container.encode(sampleBudget, forKey: .sampleBudget)
    try container.encode(tokenBudget, forKey: .tokenBudget)
    try container.encode(seed, forKey: .seed)
  }
}

struct WorkflowRecipeProtectionRules: Codable, Equatable, Sendable {
  let preserveEmbeddings: Bool
  let preserveOutputHead: Bool
  let protectSensitiveModules: Bool

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case preserveEmbeddings = "preserve_embeddings"
    case preserveOutputHead = "preserve_output_head"
    case protectSensitiveModules = "protect_sensitive_modules"
  }

  init(
    preserveEmbeddings: Bool,
    preserveOutputHead: Bool,
    protectSensitiveModules: Bool
  ) {
    self.preserveEmbeddings = preserveEmbeddings
    self.preserveOutputHead = preserveOutputHead
    self.protectSensitiveModules = protectSensitiveModules
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    preserveEmbeddings = try container.decode(Bool.self, forKey: .preserveEmbeddings)
    preserveOutputHead = try container.decode(Bool.self, forKey: .preserveOutputHead)
    protectSensitiveModules = try container.decode(Bool.self, forKey: .protectSensitiveModules)
  }
}

struct WorkflowRecipeValidation: Codable, Equatable, Sendable {
  let requiredGates: [String]
  let criticalRegressionsAllowed: Int

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case requiredGates = "required_gates"
    case criticalRegressionsAllowed = "critical_regressions_allowed"
  }

  init(requiredGates: [String], criticalRegressionsAllowed: Int) {
    self.requiredGates = requiredGates
    self.criticalRegressionsAllowed = criticalRegressionsAllowed
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    requiredGates = try container.decode([String].self, forKey: .requiredGates)
    criticalRegressionsAllowed = try container.decode(
      Int.self, forKey: .criticalRegressionsAllowed)
    try workflowRequire(
      !requiredGates.isEmpty && requiredGates.allSatisfy { !$0.isEmpty },
      codingPath: decoder.codingPath,
      "validation.required_gates must contain non-empty values.")
    try workflowRequire(
      workflowHasUniqueValues(requiredGates), codingPath: decoder.codingPath,
      "validation.required_gates must not contain duplicates.")
    try workflowRequire(
      (0...1_000_000).contains(criticalRegressionsAllowed), codingPath: decoder.codingPath,
      "validation.critical_regressions_allowed is outside the protocol-v1 range.")
  }
}

public struct WorkflowRecipe: Codable, Equatable, Sendable {
  static let supportedSchemaVersion = 1

  let schemaVersion: Int
  let exactParent: String
  let operations: [String]
  let quantModes: [String]
  let allocation: WorkflowRecipeAllocation
  let priorities: WorkflowRecipePriorities
  let timeBudgetSeconds: Int
  let contextTargetTokens: Int
  let calibration: WorkflowRecipeCalibration
  let protectionRules: WorkflowRecipeProtectionRules
  let validation: WorkflowRecipeValidation

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case exactParent = "exact_parent"
    case operations
    case quantModes = "quant_modes"
    case allocation
    case priorities
    case timeBudgetSeconds = "time_budget_seconds"
    case contextTargetTokens = "context_target_tokens"
    case calibration
    case protectionRules = "protection_rules"
    case validation
  }

  init(
    exactParent: String,
    operations: [String],
    quantModes: [String],
    allocation: WorkflowRecipeAllocation,
    priorities: WorkflowRecipePriorities,
    timeBudgetSeconds: Int,
    contextTargetTokens: Int,
    calibration: WorkflowRecipeCalibration,
    protectionRules: WorkflowRecipeProtectionRules,
    validation: WorkflowRecipeValidation
  ) {
    schemaVersion = Self.supportedSchemaVersion
    self.exactParent = exactParent
    self.operations = operations
    self.quantModes = quantModes
    self.allocation = allocation
    self.priorities = priorities
    self.timeBudgetSeconds = timeBudgetSeconds
    self.contextTargetTokens = contextTargetTokens
    self.calibration = calibration
    self.protectionRules = protectionRules
    self.validation = validation
  }

  public init(from decoder: Decoder) throws {
    let schemaVersion = try workflowSchemaVersion(from: decoder)
    guard schemaVersion == Self.supportedSchemaVersion else {
      throw WorkflowProtocolError.protocolMismatch(
        supported: Self.supportedSchemaVersion,
        found: schemaVersion
      )
    }
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    self.schemaVersion = schemaVersion
    exactParent = try container.decode(String.self, forKey: .exactParent)
    operations = try container.decode([String].self, forKey: .operations)
    quantModes = try container.decode([String].self, forKey: .quantModes)
    allocation = try container.decode(WorkflowRecipeAllocation.self, forKey: .allocation)
    priorities = try container.decode(WorkflowRecipePriorities.self, forKey: .priorities)
    timeBudgetSeconds = try container.decode(Int.self, forKey: .timeBudgetSeconds)
    contextTargetTokens = try container.decode(Int.self, forKey: .contextTargetTokens)
    calibration = try container.decode(WorkflowRecipeCalibration.self, forKey: .calibration)
    protectionRules = try container.decode(
      WorkflowRecipeProtectionRules.self, forKey: .protectionRules)
    validation = try container.decode(WorkflowRecipeValidation.self, forKey: .validation)

    try workflowRequire(
      exactParent.hasPrefix("/"), codingPath: decoder.codingPath,
      "exact_parent must be an absolute path.")
    try workflowRequire(
      !operations.isEmpty && operations.allSatisfy { !$0.isEmpty },
      codingPath: decoder.codingPath,
      "operations must contain non-empty values.")
    try workflowRequire(
      workflowHasUniqueValues(operations), codingPath: decoder.codingPath,
      "operations must not contain duplicates.")
    try workflowRequire(
      Set(operations).isSubset(of: workflowAllowedOperations),
      codingPath: decoder.codingPath,
      "operations contains a value not recognized by protocol v1.")
    try workflowRequire(
      !quantModes.isEmpty && quantModes.allSatisfy { !$0.isEmpty },
      codingPath: decoder.codingPath,
      "quant_modes must contain non-empty values.")
    try workflowRequire(
      workflowHasUniqueValues(quantModes), codingPath: decoder.codingPath,
      "quant_modes must not contain duplicates.")
    try workflowRequire(
      Set(quantModes).isSubset(of: workflowAllowedQuantModes),
      codingPath: decoder.codingPath,
      "quant_modes contains a value not recognized by protocol v1.")
    try workflowRequire(
      (1...31_536_000).contains(timeBudgetSeconds), codingPath: decoder.codingPath,
      "time_budget_seconds is outside the protocol-v1 range.")
    try workflowRequire(
      (1...10_000_000).contains(contextTargetTokens), codingPath: decoder.codingPath,
      "context_target_tokens is outside the protocol-v1 range.")
  }

  public static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Self {
    try decoder.decode(Self.self, from: data)
  }
}

enum WorkflowResourceEstimateKind: String, Codable, Equatable, Sendable {
  case estimate
}

enum WorkflowResourceFeasibility: String, Codable, Equatable, Sendable {
  case feasible
  case reviewRequired = "review-required"
  case blocked
}

struct WorkflowResourceBasis: Codable, Equatable, Sendable {
  let source: String
  let output: String
  let temporary: String
  let memory: String
  let host: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case source
    case output
    case temporary
    case memory
    case host
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    source = try container.decode(String.self, forKey: .source)
    output = try container.decode(String.self, forKey: .output)
    temporary = try container.decode(String.self, forKey: .temporary)
    memory = try container.decode(String.self, forKey: .memory)
    host = try container.decode(String.self, forKey: .host)
    try workflowRequire(
      source == "inspected-safetensors-shard-bytes"
        && output == "quant-mode-factor-plus-64-mib-per-mode"
        && temporary == "source-bytes-plus-1-gib"
        && memory == "source-bytes-plus-2-gib"
        && host == "planning-time-read-only-snapshot",
      codingPath: decoder.codingPath,
      "resource_estimate.basis does not match the frozen protocol-v1 basis."
    )
  }
}

struct WorkflowResourceEstimate: Codable, Equatable, Sendable {
  private static let outputOverheadBytes = 64 * 1_024 * 1_024
  private static let temporaryOverheadBytes = 1_024 * 1_024 * 1_024
  private static let peakMemoryOverheadBytes = 2 * 1_024 * 1_024 * 1_024
  private static let frozenDiskReserveBytes = 30 * 1_024 * 1_024 * 1_024
  private static let frozenMemoryReserveBytes = 8 * 1_024 * 1_024 * 1_024
  let kind: WorkflowResourceEstimateKind
  let basis: WorkflowResourceBasis
  let uncertainty: String
  let sourceBytes: Int?
  let estimatedOutputBytes: Int?
  let estimatedTemporaryBytes: Int?
  let diskReserveBytes: Int
  let requiredFreeDiskBytes: Int?
  let observedFreeDiskBytes: Int
  let estimatedPeakMemoryBytes: Int?
  let memoryReserveBytes: Int
  let observedUnifiedMemoryBytes: Int?
  let usableUnifiedMemoryBytes: Int?
  let estimatedDurationSeconds: Int?
  let timeBudgetSeconds: Int
  let feasibility: WorkflowResourceFeasibility
  let reasonCodes: [String]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case basis
    case uncertainty
    case sourceBytes = "source_bytes"
    case estimatedOutputBytes = "estimated_output_bytes"
    case estimatedTemporaryBytes = "estimated_temporary_bytes"
    case diskReserveBytes = "disk_reserve_bytes"
    case requiredFreeDiskBytes = "required_free_disk_bytes"
    case observedFreeDiskBytes = "observed_free_disk_bytes"
    case estimatedPeakMemoryBytes = "estimated_peak_memory_bytes"
    case memoryReserveBytes = "memory_reserve_bytes"
    case observedUnifiedMemoryBytes = "observed_unified_memory_bytes"
    case usableUnifiedMemoryBytes = "usable_unified_memory_bytes"
    case estimatedDurationSeconds = "estimated_duration_seconds"
    case timeBudgetSeconds = "time_budget_seconds"
    case feasibility
    case reasonCodes = "reason_codes"
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    kind = try container.decode(WorkflowResourceEstimateKind.self, forKey: .kind)
    basis = try container.decode(WorkflowResourceBasis.self, forKey: .basis)
    uncertainty = try container.decode(String.self, forKey: .uncertainty)
    sourceBytes = try workflowRequiredNullable(Int.self, forKey: .sourceBytes, in: container)
    estimatedOutputBytes = try workflowRequiredNullable(
      Int.self, forKey: .estimatedOutputBytes, in: container)
    estimatedTemporaryBytes = try workflowRequiredNullable(
      Int.self, forKey: .estimatedTemporaryBytes, in: container)
    diskReserveBytes = try container.decode(Int.self, forKey: .diskReserveBytes)
    requiredFreeDiskBytes = try workflowRequiredNullable(
      Int.self, forKey: .requiredFreeDiskBytes, in: container)
    observedFreeDiskBytes = try container.decode(Int.self, forKey: .observedFreeDiskBytes)
    estimatedPeakMemoryBytes = try workflowRequiredNullable(
      Int.self, forKey: .estimatedPeakMemoryBytes, in: container)
    memoryReserveBytes = try container.decode(Int.self, forKey: .memoryReserveBytes)
    observedUnifiedMemoryBytes = try workflowRequiredNullable(
      Int.self, forKey: .observedUnifiedMemoryBytes, in: container)
    usableUnifiedMemoryBytes = try workflowRequiredNullable(
      Int.self, forKey: .usableUnifiedMemoryBytes, in: container)
    estimatedDurationSeconds = try workflowRequiredNullable(
      Int.self, forKey: .estimatedDurationSeconds, in: container)
    timeBudgetSeconds = try container.decode(Int.self, forKey: .timeBudgetSeconds)
    feasibility = try container.decode(WorkflowResourceFeasibility.self, forKey: .feasibility)
    reasonCodes = try container.decode([String].self, forKey: .reasonCodes)

    try workflowRequire(
      uncertainty == "conservative-upper-bound", codingPath: decoder.codingPath,
      "resource_estimate.uncertainty must match protocol v1.")
    let nullableModelValues = [
      sourceBytes, estimatedOutputBytes, estimatedTemporaryBytes, requiredFreeDiskBytes,
      estimatedPeakMemoryBytes,
    ]
    let modelValuesAreAllNil = nullableModelValues.allSatisfy { $0 == nil }
    let modelValuesAreAllPresent = nullableModelValues.allSatisfy { $0 != nil }
    try workflowRequire(
      modelValuesAreAllNil || modelValuesAreAllPresent,
      codingPath: decoder.codingPath,
      "Model-derived resource values must be null together or present together.")
    try workflowRequire(
      !modelValuesAreAllNil || reasonCodes.contains("resource-model-size-unknown"),
      codingPath: decoder.codingPath,
      "Null model-derived resource values require resource-model-size-unknown.")
    try workflowRequire(
      modelValuesAreAllNil == reasonCodes.contains("resource-model-size-unknown"),
      codingPath: decoder.codingPath,
      "resource-model-size-unknown must match the nullable model-derived values.")
    try workflowRequire(
      (observedUnifiedMemoryBytes == nil) == (usableUnifiedMemoryBytes == nil),
      codingPath: decoder.codingPath,
      "Observed and usable unified-memory values must be null together.")
    try workflowRequire(
      observedUnifiedMemoryBytes != nil || reasonCodes.contains("memory-observation-unknown"),
      codingPath: decoder.codingPath,
      "Null unified-memory values require memory-observation-unknown.")
    try workflowRequire(
      (observedUnifiedMemoryBytes == nil)
        == reasonCodes.contains("memory-observation-unknown"),
      codingPath: decoder.codingPath,
      "memory-observation-unknown must match the nullable unified-memory values.")
    try workflowRequire(
      estimatedDurationSeconds != nil || reasonCodes.contains("duration-estimate-unknown"),
      codingPath: decoder.codingPath,
      "A null duration requires duration-estimate-unknown.")
    try workflowRequire(
      (estimatedDurationSeconds == nil)
        == reasonCodes.contains("duration-estimate-unknown"),
      codingPath: decoder.codingPath,
      "duration-estimate-unknown must match the nullable duration.")
    let numericValues =
      nullableModelValues.compactMap { $0 }
      + [diskReserveBytes, observedFreeDiskBytes, memoryReserveBytes, timeBudgetSeconds]
      + [observedUnifiedMemoryBytes, usableUnifiedMemoryBytes, estimatedDurationSeconds]
      .compactMap { $0 }
    try workflowRequire(
      numericValues.allSatisfy { $0 >= 0 }, codingPath: decoder.codingPath,
      "Resource byte and second values must be non-negative integers.")
    try workflowRequire(
      reasonCodes.allSatisfy { !$0.isEmpty }, codingPath: decoder.codingPath,
      "resource_estimate.reason_codes must contain non-empty values.")
    try workflowRequire(
      workflowHasUniqueValues(reasonCodes), codingPath: decoder.codingPath,
      "resource_estimate.reason_codes must not contain duplicates.")
    try workflowRequire(
      reasonCodes == reasonCodes.sorted(), codingPath: decoder.codingPath,
      "resource_estimate.reason_codes must be sorted.")
    try workflowRequire(
      Set(reasonCodes).isSubset(of: workflowAllowedResourceReasons),
      codingPath: decoder.codingPath,
      "resource_estimate.reason_codes contains an unrecognized protocol-v1 value.")
    let hasBlockingReason = !Set(reasonCodes).isDisjoint(with: workflowBlockingResourceReasons)
    let expectedFeasibility: WorkflowResourceFeasibility =
      hasBlockingReason ? .blocked : (reasonCodes.isEmpty ? .feasible : .reviewRequired)
    try workflowRequire(
      feasibility == expectedFeasibility, codingPath: decoder.codingPath,
      "resource_estimate.feasibility does not match its reason codes.")
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(basis, forKey: .basis)
    try container.encode(uncertainty, forKey: .uncertainty)
    try container.encode(sourceBytes, forKey: .sourceBytes)
    try container.encode(estimatedOutputBytes, forKey: .estimatedOutputBytes)
    try container.encode(estimatedTemporaryBytes, forKey: .estimatedTemporaryBytes)
    try container.encode(diskReserveBytes, forKey: .diskReserveBytes)
    try container.encode(requiredFreeDiskBytes, forKey: .requiredFreeDiskBytes)
    try container.encode(observedFreeDiskBytes, forKey: .observedFreeDiskBytes)
    try container.encode(estimatedPeakMemoryBytes, forKey: .estimatedPeakMemoryBytes)
    try container.encode(memoryReserveBytes, forKey: .memoryReserveBytes)
    try container.encode(observedUnifiedMemoryBytes, forKey: .observedUnifiedMemoryBytes)
    try container.encode(usableUnifiedMemoryBytes, forKey: .usableUnifiedMemoryBytes)
    try container.encode(estimatedDurationSeconds, forKey: .estimatedDurationSeconds)
    try container.encode(timeBudgetSeconds, forKey: .timeBudgetSeconds)
    try container.encode(feasibility, forKey: .feasibility)
    try container.encode(reasonCodes, forKey: .reasonCodes)
  }

  func validateDerivedValues(
    for recipe: WorkflowRecipe,
    codingPath: [CodingKey]
  ) throws {
    try workflowRequire(
      diskReserveBytes == Self.frozenDiskReserveBytes,
      codingPath: codingPath,
      "resource_estimate.disk_reserve_bytes does not match protocol v1.")
    try workflowRequire(
      memoryReserveBytes == Self.frozenMemoryReserveBytes,
      codingPath: codingPath,
      "resource_estimate.memory_reserve_bytes does not match protocol v1.")

    if let observedUnifiedMemoryBytes {
      try workflowRequire(
        usableUnifiedMemoryBytes
          == max(0, observedUnifiedMemoryBytes - Self.frozenMemoryReserveBytes),
        codingPath: codingPath,
        "resource_estimate.usable_unified_memory_bytes does not match the frozen reserve.")
    }

    if let sourceBytes {
      var expectedOutput = 0
      for mode in recipe.quantModes {
        let factor = mode == "mxfp8" ? 75 : 45
        let product = sourceBytes.multipliedReportingOverflow(by: factor)
        let rounded = product.partialValue.addingReportingOverflow(99)
        try workflowRequire(
          !product.overflow && !rounded.overflow,
          codingPath: codingPath,
          "resource_estimate output arithmetic overflowed.")
        let modeBytes = (rounded.partialValue / 100).addingReportingOverflow(
          Self.outputOverheadBytes)
        let total = expectedOutput.addingReportingOverflow(modeBytes.partialValue)
        try workflowRequire(
          !modeBytes.overflow && !total.overflow,
          codingPath: codingPath,
          "resource_estimate output arithmetic overflowed.")
        expectedOutput = total.partialValue
      }
      let temporary = sourceBytes.addingReportingOverflow(Self.temporaryOverheadBytes)
      let peak = sourceBytes.addingReportingOverflow(Self.peakMemoryOverheadBytes)
      let outputAndTemporary = expectedOutput.addingReportingOverflow(temporary.partialValue)
      let required = outputAndTemporary.partialValue.addingReportingOverflow(
        Self.frozenDiskReserveBytes)
      try workflowRequire(
        !temporary.overflow && !peak.overflow && !outputAndTemporary.overflow
          && !required.overflow,
        codingPath: codingPath,
        "resource_estimate size arithmetic overflowed.")
      try workflowRequire(
        estimatedOutputBytes == expectedOutput
          && estimatedTemporaryBytes == temporary.partialValue
          && requiredFreeDiskBytes == required.partialValue
          && estimatedPeakMemoryBytes == peak.partialValue,
        codingPath: codingPath,
        "resource_estimate derived values do not match protocol v1.")
      try workflowRequire(
        reasonCodes.contains("resource-disk-insufficient")
          == (required.partialValue > observedFreeDiskBytes),
        codingPath: codingPath,
        "resource-disk-insufficient does not match the estimate.")
      if let usableUnifiedMemoryBytes {
        try workflowRequire(
          reasonCodes.contains("resource-memory-insufficient")
            == (peak.partialValue > usableUnifiedMemoryBytes),
          codingPath: codingPath,
          "resource-memory-insufficient does not match the estimate.")
      }
    }
  }
}

struct WorkflowPlanBlocker: Codable, Equatable, Sendable {
  let code: String
  let message: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case code
    case message
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    code = try container.decode(String.self, forKey: .code)
    message = try container.decode(String.self, forKey: .message)
    try workflowRequire(
      !code.isEmpty && !message.isEmpty, codingPath: decoder.codingPath,
      "Plan blockers require non-empty code and message values.")
  }
}

struct WorkflowPlanStep: Codable, Equatable, Sendable {
  let id: String
  let kind: String
  let displayName: String
  let executable: String
  let arguments: [String]
  let workingDirectory: String
  let environmentKeys: [String]
  let resumability: WorkflowResumability

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case kind
    case displayName = "display_name"
    case executable
    case arguments
    case workingDirectory = "working_directory"
    case environmentKeys = "environment_keys"
    case resumability
  }

  init(from decoder: Decoder) throws {
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(String.self, forKey: .kind)
    displayName = try container.decode(String.self, forKey: .displayName)
    executable = try container.decode(String.self, forKey: .executable)
    arguments = try container.decode([String].self, forKey: .arguments)
    workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    environmentKeys = try container.decode([String].self, forKey: .environmentKeys)
    resumability = try container.decode(WorkflowResumability.self, forKey: .resumability)
  }
}

public struct WorkflowPlan: Codable, Equatable, Sendable {
  static let supportedSchemaVersion = 1

  let schemaVersion: Int
  let runID: String
  let createdAt: String
  let workspace: String
  let runDirectory: String
  let exactParent: String
  let capabilities: [String: JSONValue]
  let recipe: WorkflowRecipe
  let resourceEstimate: WorkflowResourceEstimate
  let blockers: [WorkflowPlanBlocker]
  let steps: [WorkflowPlanStep]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case runID = "run_id"
    case createdAt = "created_at"
    case workspace
    case runDirectory = "run_directory"
    case exactParent = "exact_parent"
    case capabilities
    case recipe
    case resourceEstimate = "resource_estimate"
    case blockers
    case steps
  }

  public init(from decoder: Decoder) throws {
    let schemaVersion = try workflowSchemaVersion(from: decoder)
    guard schemaVersion == Self.supportedSchemaVersion else {
      throw WorkflowProtocolError.protocolMismatch(
        supported: Self.supportedSchemaVersion,
        found: schemaVersion
      )
    }
    let container = try workflowStrictContainer(from: decoder, keyedBy: CodingKeys.self)
    self.schemaVersion = schemaVersion
    runID = try container.decode(String.self, forKey: .runID)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    workspace = try container.decode(String.self, forKey: .workspace)
    runDirectory = try container.decode(String.self, forKey: .runDirectory)
    exactParent = try container.decode(String.self, forKey: .exactParent)
    capabilities = try container.decode([String: JSONValue].self, forKey: .capabilities)
    recipe = try container.decode(WorkflowRecipe.self, forKey: .recipe)
    resourceEstimate = try container.decode(
      WorkflowResourceEstimate.self, forKey: .resourceEstimate)
    blockers = try container.decode([WorkflowPlanBlocker].self, forKey: .blockers)
    steps = try container.decode([WorkflowPlanStep].self, forKey: .steps)

    try resourceEstimate.validateDerivedValues(for: recipe, codingPath: decoder.codingPath)

    try workflowRequire(
      exactParent == recipe.exactParent, codingPath: decoder.codingPath,
      "The plan and recipe exact_parent values must match.")
    try workflowRequire(
      resourceEstimate.timeBudgetSeconds == recipe.timeBudgetSeconds,
      codingPath: decoder.codingPath,
      "The resource estimate must preserve the recipe time budget.")
    try workflowRequire(
      blockers.isEmpty || steps.isEmpty, codingPath: decoder.codingPath,
      "A blocked plan must not contain executable steps.")
    try workflowRequire(
      resourceEstimate.feasibility != .blocked || steps.isEmpty,
      codingPath: decoder.codingPath,
      "A resource-blocked plan must not contain executable steps.")
    let blockerCodes = Set(blockers.map(\.code))
    let resourceBlockerCodes = Set(resourceEstimate.reasonCodes)
      .intersection(workflowBlockingResourceReasons)
    try workflowRequire(
      resourceBlockerCodes.isSubset(of: blockerCodes),
      codingPath: decoder.codingPath,
      "Each blocking resource reason must also be a plan blocker.")
  }

  public static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Self {
    try decoder.decode(Self.self, from: data)
  }

  var disclosure: PlanDisclosure {
    PlanDisclosure(
      runDirectory: runDirectory,
      exactParent: exactParent,
      quantModes: recipe.quantModes,
      evidenceKind: resourceEstimate.kind.rawValue,
      uncertainty: resourceEstimate.uncertainty,
      estimatedOutputBytes: resourceEstimate.estimatedOutputBytes,
      estimatedTemporaryBytes: resourceEstimate.estimatedTemporaryBytes,
      requiredFreeDiskBytes: resourceEstimate.requiredFreeDiskBytes,
      observedFreeDiskBytes: resourceEstimate.observedFreeDiskBytes,
      estimatedPeakMemoryBytes: resourceEstimate.estimatedPeakMemoryBytes,
      observedUnifiedMemoryBytes: resourceEstimate.observedUnifiedMemoryBytes,
      estimatedDurationSeconds: resourceEstimate.estimatedDurationSeconds,
      timeBudgetSeconds: resourceEstimate.timeBudgetSeconds,
      feasibility: resourceEstimate.feasibility.rawValue,
      reasonCodes: resourceEstimate.reasonCodes,
      requiredGates: recipe.validation.requiredGates,
      blockers: blockers.map { PlanBlockerDisclosure(code: $0.code, message: $0.message) })
  }
}
