import Foundation
import SwiftUI

enum WorkshopSection: String, CaseIterable, Identifiable {
  case workbench = "Workbench"
  case runs = "Runs"
  case compare = "Compare"
  case behavior = "Behavior Lab"
  case extensions = "Extensions"
  case host = "Host"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .workbench: "square.grid.2x2"
    case .runs: "clock.arrow.trianglehead.counterclockwise.rotate.90"
    case .compare: "arrow.left.arrow.right"
    case .behavior: "waveform.path.ecg.rectangle"
    case .extensions: "puzzlepiece.extension"
    case .host: "macstudio"
    }
  }
}

enum WorkshopContentMode: Equatable {
  case live
  case demo
}

enum SetupActivity: String, Equatable {
  case selectingModel = "Selecting model"
  case selectingWorkspace = "Selecting run workspace"
  case inspectingModel = "Inspecting model"
  case preparingRecipe = "Preparing recipe"
}

struct WorkshopDiagnostic: Equatable, Identifiable {
  enum Severity: Equatable { case information, warning, blocker }
  enum RecoveryAction: String, Equatable {
    case chooseModel = "Choose another model"
    case chooseWorkspace = "Choose run workspace"
    case retryInspection = "Inspect again"
    case revealRun = "Reveal run in Finder"
    case openLog = "Open raw log"
  }

  let id: String
  let severity: Severity
  let title: String
  let message: String
  let recovery: RecoveryAction?
}

enum WorkshopSetupState: Equatable {
  case empty
  case loading(SetupActivity)
  case blocked(WorkshopDiagnostic)
  case ready
}

struct LocalModelReference: Equatable {
  let directory: URL
  var displayName: String
  var architecture: String?
  var format: String?
  var sizeBytes: Int64?
  var parameterSummary: String?
  var sourceState: String?
  var supportSummary: String?
  var warnings: [WorkshopDiagnostic] = []
  var visionAdvertised = false
  var mtpAdvertised = false

  var detailLine: String {
    [architecture, parameterSummary, sourceState].compactMap { $0 }.joined(separator: " · ")
  }
}

struct HostSnapshot: Equatable {
  var chip: String
  var unifiedMemory: String
  var availableMemory: String?
  var freeDisk: String
  var operatingSystem: String
  var mlxVersion: String?
  var mlxLMVersion: String?
  var activeWorkloads: [String]
}

enum OptimizationAllocationStrategy: String, Equatable, Hashable {
  case uniform
  case mixedPrecision = "mixed-precision"
}

enum Precision: Int, CaseIterable, Identifiable {
  case four = 4
  case eight = 8

  var id: Int { rawValue }
  var title: String { "\(rawValue)-bit" }
}

struct OptimizationRecipe: Equatable {
  var name: String
  var qualityPriority: Double
  var sizePriority: Double
  var requestedQuantModes: [String]
  var allocationStrategy: OptimizationAllocationStrategy
  var targetBPW: Double
  var klTolerance: Double
  var perModuleOverrides: Bool
  var timeBudgetSeconds: Int
  var contextTargetTokens: Int
  var preserveEmbeddings: Bool
  var preserveOutputHead: Bool
  var protectSensitiveLayers: Bool
  var calibrationSuite: String
  var calibrationDatasetSHA256: String?
  var calibrationSampleBudget: Int
  var calibrationTokenBudget: Int
  var calibrationSeed: Int?

  var contextLength: String {
    get { "\(contextTargetTokens / 1024)K" }
    set {
      let value = newValue.uppercased().replacingOccurrences(of: "K", with: "")
      if let thousands = Int(value) { contextTargetTokens = thousands * 1024 }
    }
  }

  init(
    name: String,
    qualityPriority: Double,
    sizePriority: Double,
    requestedQuantModes: [String] = ["mxfp4"],
    allocationStrategy: OptimizationAllocationStrategy = .uniform,
    targetBPW: Double,
    klTolerance: Double,
    perModuleOverrides: Bool = false,
    timeBudgetSeconds: Int = 3_600,
    contextLength: String,
    preserveEmbeddings: Bool,
    preserveOutputHead: Bool,
    protectSensitiveLayers: Bool,
    calibrationSuite: String,
    calibrationDatasetSHA256: String? = nil,
    calibrationSampleBudget: Int = 0,
    calibrationTokenBudget: Int = 0,
    calibrationSeed: Int? = nil
  ) {
    self.name = name
    self.qualityPriority = qualityPriority
    self.sizePriority = sizePriority
    self.requestedQuantModes = requestedQuantModes
    self.allocationStrategy = allocationStrategy
    self.targetBPW = targetBPW
    self.klTolerance = klTolerance
    self.perModuleOverrides = perModuleOverrides
    self.timeBudgetSeconds = timeBudgetSeconds
    let contextValue = contextLength.uppercased().replacingOccurrences(of: "K", with: "")
    contextTargetTokens = (Int(contextValue) ?? 32) * 1024
    self.preserveEmbeddings = preserveEmbeddings
    self.preserveOutputHead = preserveOutputHead
    self.protectSensitiveLayers = protectSensitiveLayers
    self.calibrationSuite = calibrationSuite
    self.calibrationDatasetSHA256 = calibrationDatasetSHA256
    self.calibrationSampleBudget = calibrationSampleBudget
    self.calibrationTokenBudget = calibrationTokenBudget
    self.calibrationSeed = calibrationSeed
  }

  func workflowRecipe(exactParent: URL) throws -> WorkflowRecipe {
    let isUniform = allocationStrategy == .uniform
    return WorkflowRecipe(
      exactParent: try WorkflowFilePath.canonical(exactParent),
      operations: ["quantize"],
      quantModes: requestedQuantModes,
      allocation: WorkflowRecipeAllocation(
        strategy: allocationStrategy.rawValue,
        targetBPW: targetBPW,
        klTolerance: isUniform ? nil : klTolerance,
        perModuleOverrides: perModuleOverrides),
      priorities: WorkflowRecipePriorities(quality: qualityPriority, size: sizePriority),
      timeBudgetSeconds: timeBudgetSeconds,
      contextTargetTokens: contextTargetTokens,
      calibration: WorkflowRecipeCalibration(
        identity: calibrationSuite,
        datasetSHA256: calibrationDatasetSHA256,
        sampleBudget: calibrationSampleBudget,
        tokenBudget: calibrationTokenBudget,
        seed: calibrationSeed),
      protectionRules: WorkflowRecipeProtectionRules(
        preserveEmbeddings: preserveEmbeddings,
        preserveOutputHead: preserveOutputHead,
        protectSensitiveModules: protectSensitiveLayers),
      validation: WorkflowRecipeValidation(
        requiredGates: [
          "provenance-structure", "deterministic-language-schema", "parent-parity",
        ],
        criticalRegressionsAllowed: 0))
  }

  static let unplanned = OptimizationRecipe(
    name: "Uniform MXFP4 baseline", qualityPriority: 0.78, sizePriority: 0.58,
    targetBPW: 4.0, klTolerance: 0.20, contextLength: "32K", preserveEmbeddings: false,
    preserveOutputHead: false, protectSensitiveLayers: false,
    calibrationSuite: "not-applicable")
}

struct CommandInvocationDisclosure: Equatable {
  let executableIdentity: String
  let arguments: [String]
  let redactedDisplay: String
}

struct CommandDisclosure: Equatable {
  let commands: [CommandInvocationDisclosure]

  init(commands: [CommandInvocationDisclosure]) {
    self.commands = commands
  }

  init(executableIdentity: String, arguments: [String], redactedDisplay: String) {
    commands = [
      CommandInvocationDisclosure(
        executableIdentity: executableIdentity,
        arguments: arguments,
        redactedDisplay: redactedDisplay)
    ]
  }

  var executableIdentity: String { commands.first?.executableIdentity ?? "" }
  var arguments: [String] { commands.first?.arguments ?? [] }
  var redactedDisplay: String { commands.first?.redactedDisplay ?? "" }
}

struct PlanBlockerDisclosure: Equatable {
  let code: String
  let message: String
}

struct PlanDisclosure: Equatable {
  let runDirectory: String
  let exactParent: String
  let quantModes: [String]
  let evidenceKind: String
  let uncertainty: String
  let estimatedOutputBytes: Int?
  let estimatedTemporaryBytes: Int?
  let requiredFreeDiskBytes: Int?
  let observedFreeDiskBytes: Int
  let estimatedPeakMemoryBytes: Int?
  let observedUnifiedMemoryBytes: Int?
  let estimatedDurationSeconds: Int?
  let timeBudgetSeconds: Int
  let feasibility: String
  let reasonCodes: [String]
  let requiredGates: [String]
  let blockers: [PlanBlockerDisclosure]
}

struct RunConfirmation: Equatable, Identifiable {
  var id: String { runID }
  let runID: String
  let plan: PlanDisclosure
  let command: CommandDisclosure
  let changesWeights: Bool

  var runDirectory: URL { URL(fileURLWithPath: plan.runDirectory, isDirectory: true) }
  var hasActiveWorkloadWarning: Bool {
    plan.reasonCodes.contains("active-workloads-present")
  }
}

struct LayerRecord: Equatable, Identifiable {
  let id = UUID()
  let index: Int
  let name: String
  let kind: String
  var sensitivity: Double
  var precision: Precision
  var sizeDelta: Double
  var klDelta: Double
  var isProtected: Bool
}

struct QualificationGateRecord: Equatable, Identifiable {
  var id: String { name }
  let name: String
  let status: String
  let evidence: [String]
}

struct CandidateRecord: Equatable, Identifiable {
  let id: String
  let runID: String?
  let name: String
  let recipe: String
  let sizeGB: Double?
  let throughput: Double?
  let kl: Double?
  let score: Int?
  let criticalRegressions: Int?
  let status: CandidateStatus
  let exactParent: URL?
  let candidateDirectory: URL?
  let gates: [QualificationGateRecord]
  let evidenceRoot: URL?

  init(
    id: String = UUID().uuidString,
    runID: String? = nil,
    name: String,
    recipe: String,
    sizeGB: Double? = nil,
    throughput: Double? = nil,
    kl: Double? = nil,
    score: Int? = nil,
    criticalRegressions: Int? = nil,
    status: CandidateStatus,
    exactParent: URL? = nil,
    candidateDirectory: URL? = nil,
    gates: [QualificationGateRecord] = [],
    evidenceRoot: URL? = nil
  ) {
    self.id = id
    self.runID = runID
    self.name = name
    self.recipe = recipe
    self.sizeGB = sizeGB
    self.throughput = throughput
    self.kl = kl
    self.score = score
    self.criticalRegressions = criticalRegressions
    self.status = status
    self.exactParent = exactParent
    self.candidateDirectory = candidateDirectory
    self.gates = gates
    self.evidenceRoot = evidenceRoot
  }
}

enum CandidateStatus: String, Equatable {
  case parent = "Parent"
  case qualified = "Qualified"
  case experimental = "Experimental"
  case rejected = "Rejected"

  var color: Color {
    switch self {
    case .parent: WorkshopTheme.secondaryInk
    case .qualified: WorkshopTheme.success
    case .experimental: WorkshopTheme.warning
    case .rejected: WorkshopTheme.danger
    }
  }

  var symbol: String {
    switch self {
    case .parent: "circle.dashed"
    case .qualified: "checkmark.seal.fill"
    case .experimental: "flask.fill"
    case .rejected: "xmark.octagon.fill"
    }
  }
}

enum WorkshopRunState: String, Equatable, CaseIterable {
  case planned = "Planned"
  case blocked = "Blocked"
  case running = "Running"
  case cancelling = "Cancelling"
  case cancelled = "Cancelled"
  case interrupted = "Interrupted"
  case failed = "Failed"
  case completed = "Completed"
  case protocolMismatch = "Protocol mismatch"

  var isActive: Bool { self == .running || self == .cancelling }
  var isTerminal: Bool { [.blocked, .cancelled, .failed, .completed].contains(self) }

  var symbol: String {
    switch self {
    case .planned: "list.bullet.clipboard"
    case .blocked: "exclamationmark.octagon"
    case .running: "waveform.path"
    case .cancelling: "stopwatch"
    case .cancelled: "xmark.circle"
    case .interrupted: "bolt.slash"
    case .failed: "exclamationmark.octagon.fill"
    case .completed: "checkmark.circle"
    case .protocolMismatch: "exclamationmark.triangle.fill"
    }
  }

  var color: Color {
    switch self {
    case .planned, .interrupted: WorkshopTheme.warning
    case .blocked: WorkshopTheme.danger
    case .running, .cancelling: WorkshopTheme.sky
    case .cancelled: WorkshopTheme.secondaryInk
    case .failed, .protocolMismatch: WorkshopTheme.danger
    case .completed: WorkshopTheme.secondaryInk
    }
  }
}

struct RunProgress: Equatable {
  let completed: Double
  let total: Double?
  let unit: String?

  var fraction: Double? {
    guard let total, total > 0 else { return nil }
    return min(max(completed / total, 0), 1)
  }
}

struct WorkshopRun: Equatable, Identifiable {
  let id: String
  var requestID: UUID? = nil
  var title: String
  var state: WorkshopRunState
  var stage: String?
  var progress: RunProgress?
  var statusDetail: String?
  var resumability: String?
  var runDirectory: URL?
  var stdoutLog: URL?
  var stderrLog: URL?
  var command: CommandDisclosure?
  var plan: PlanDisclosure?
  var diagnostics: [WorkshopDiagnostic] = []
  var isQualified = false
  var stagedDirectory: URL?
}

enum RunLifecycleAction: Equatable {
  case qualify
  case stage
  case resume
  case cancelRecovered

  static func recommended(
    state: WorkshopRunState,
    resumability: String?,
    isQualified: Bool,
    isTrackedByThisProcess: Bool,
    isStaged: Bool = false
  ) -> Self? {
    switch state {
    case .completed where !isQualified:
      return .qualify
    case .completed where isQualified && !isStaged:
      return .stage
    case .interrupted where resumability == "safe":
      return .resume
    case .running where !isTrackedByThisProcess:
      return .cancelRecovered
    default:
      return nil
    }
  }
}

protocol WorkshopCancellationCoordinating: Sendable {
  func requestCancellation(
    runID: String,
    requestID: UUID,
    cooperativeGrace: Duration,
    terminationGrace: Duration
  ) async throws -> Bool
}

struct RunRecord: Equatable, Identifiable {
  let runID: String
  var id: String { runID }
  let number: Int
  let title: String
  let created: String
  let duration: String
  let state: WorkshopRunState
  let summary: String
  let runDirectory: URL?
  let stdoutLog: URL?
  let stderrLog: URL?
  let command: CommandDisclosure?
  let resumability: String?
  let isQualified: Bool
  let stagedDirectory: URL?

  init(
    runID: String,
    number: Int,
    title: String,
    created: String,
    duration: String,
    state: WorkshopRunState,
    summary: String,
    runDirectory: URL? = nil,
    stdoutLog: URL? = nil,
    stderrLog: URL? = nil,
    command: CommandDisclosure? = nil,
    resumability: String? = nil,
    isQualified: Bool = false,
    stagedDirectory: URL? = nil
  ) {
    self.runID = runID
    self.number = number
    self.title = title
    self.created = created
    self.duration = duration
    self.state = state
    self.summary = summary
    self.runDirectory = runDirectory
    self.stdoutLog = stdoutLog
    self.stderrLog = stderrLog
    self.command = command
    self.resumability = resumability
    self.isQualified = isQualified
    self.stagedDirectory = stagedDirectory
  }
}

struct BehaviorCategory: Equatable, Identifiable {
  let id = UUID()
  let name: String
  let parentRate: Double
  let candidateRate: Double
  let sampleCount: Int
}

/// Domain-level seam for Wave 1B. Its protocol event decoder can map events into these updates
/// without this layer re-declaring or depending on transport envelope types.
enum WorkshopSessionUpdate: Equatable {
  case modelInspected(LocalModelReference, layers: [LayerRecord])
  case setupBlocked(WorkshopDiagnostic)
  case runChanged(WorkshopRun)
  case runHistory([RunRecord])
  case candidates([CandidateRecord])
  case sensitivityMeasured(SensitivityProjection)
  case behaviorEvidence([BehaviorCategory])
  case hostSnapshot(HostSnapshot)
}

protocol WorkshopEventProjecting {
  associatedtype Event
  func project(_ event: Event) -> WorkshopSessionUpdate?
}
