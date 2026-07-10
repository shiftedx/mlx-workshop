import CryptoKit
import Foundation

enum WorkflowCLIClientError: Error, Equatable, Sendable {
  case missingRuntimeFile(String)
  case runtimeIntegrityFailure(String)
  case invalidRunID(String)
  case invalidPathRelationship(String)
  case runNotSafelyResumable(String)
}

struct WorkflowCLIRuntime: Equatable, Sendable {
  let sourceWorkspaceURL: URL
  let pythonURL: URL
  let cliURL: URL
  let integrityLockURL: URL?
  let integrityManifestURL: URL?

  init(
    sourceWorkspaceURL: URL,
    pythonURL: URL,
    cliURL: URL,
    integrityLockURL: URL? = nil,
    integrityManifestURL: URL? = nil
  ) {
    self.sourceWorkspaceURL = sourceWorkspaceURL
    self.pythonURL = pythonURL
    self.cliURL = cliURL
    self.integrityLockURL = integrityLockURL
    self.integrityManifestURL = integrityManifestURL
  }

  func validate(fileManager: FileManager = .default) throws {
    guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
      throw WorkflowCLIClientError.missingRuntimeFile(pythonURL.path)
    }
    guard fileManager.fileExists(atPath: cliURL.path) else {
      throw WorkflowCLIClientError.missingRuntimeFile(cliURL.path)
    }
    try validateIntegrity(fileManager: fileManager)
  }

  private func validateIntegrity(fileManager: FileManager) throws {
    guard integrityLockURL != nil || integrityManifestURL != nil else { return }
    guard let lockURL = integrityLockURL, let manifestURL = integrityManifestURL else {
      throw WorkflowCLIClientError.runtimeIntegrityFailure(
        "The bundled runtime integrity metadata is incomplete.")
    }
    do {
      let decoder = JSONDecoder()
      let lock = try decoder.decode(RuntimeLock.self, from: Data(contentsOf: lockURL))
      let manifestData = try Data(contentsOf: manifestURL)
      let manifest = try decoder.decode(RuntimeManifest.self, from: manifestData)
      guard lock.status == "bundled-and-verified" else {
        throw WorkflowCLIClientError.runtimeIntegrityFailure(
          "The bundled runtime is not marked verified.")
      }
      guard Self.sha256(manifestData) == lock.manifest.sha256 else {
        throw WorkflowCLIClientError.runtimeIntegrityFailure(
          "The bundled runtime manifest hash does not match its lock.")
      }
      guard manifest.fileCount == manifest.files.count,
        lock.manifest.fileCount == nil || lock.manifest.fileCount == manifest.fileCount
      else {
        throw WorkflowCLIClientError.runtimeIntegrityFailure(
          "The bundled runtime manifest file count is inconsistent.")
      }
      guard let criticalFiles = lock.criticalFiles, !criticalFiles.isEmpty else {
        throw WorkflowCLIClientError.runtimeIntegrityFailure(
          "The bundled runtime lock has no critical file set.")
      }
      let root = sourceWorkspaceURL.standardizedFileURL
      for (relativePath, expectedHash) in criticalFiles {
        guard !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains("..")
        else {
          throw WorkflowCLIClientError.runtimeIntegrityFailure(
            "The bundled runtime manifest contains an unsafe path.")
        }
        guard manifest.files[relativePath] == expectedHash else {
          throw WorkflowCLIClientError.runtimeIntegrityFailure(
            "The bundled runtime manifest disagrees with the critical file lock.")
        }
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/"),
          fileManager.fileExists(atPath: fileURL.path),
          Self.sha256(try Data(contentsOf: fileURL)) == expectedHash
        else {
          throw WorkflowCLIClientError.runtimeIntegrityFailure(
            "Bundled runtime integrity check failed for \(relativePath).")
        }
      }
    } catch let error as WorkflowCLIClientError {
      throw error
    } catch {
      throw WorkflowCLIClientError.runtimeIntegrityFailure(error.localizedDescription)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct RuntimeLock: Decodable {
    let status: String
    let manifest: ManifestReference
    let criticalFiles: [String: String]?

    enum CodingKeys: String, CodingKey {
      case status
      case manifest
      case criticalFiles = "critical_files"
    }
  }

  private struct ManifestReference: Decodable {
    let sha256: String
    let fileCount: Int?

    enum CodingKeys: String, CodingKey {
      case sha256
      case fileCount = "file_count"
    }
  }

  private struct RuntimeManifest: Decodable {
    let fileCount: Int
    let files: [String: String]

    enum CodingKeys: String, CodingKey {
      case fileCount = "file_count"
      case files
    }
  }
}

enum WorkflowRuntimeLocator {
  static func locate(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true),
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    fileManager: FileManager = .default
  ) throws -> WorkflowCLIRuntime {
    var candidates: [URL] = []
    if let bundleResourceURL {
      candidates.append(bundleResourceURL.appendingPathComponent("Runtime", isDirectory: true))
    }
    if let override = environment["MLX_WORKSPACE"], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: override, isDirectory: true))
    }
    var ancestor = currentDirectoryURL.standardizedFileURL
    for _ in 0..<8 {
      candidates.append(ancestor)
      let parent = ancestor.deletingLastPathComponent()
      if parent == ancestor { break }
      ancestor = parent
    }

    for candidate in candidates {
      let isBundled =
        candidate.lastPathComponent == "Runtime"
        && candidate.deletingLastPathComponent().standardizedFileURL
          == bundleResourceURL?.standardizedFileURL
      let runtime = WorkflowCLIRuntime(
        sourceWorkspaceURL: candidate,
        pythonURL: candidate.appendingPathComponent(".venv/bin/python"),
        cliURL: candidate.appendingPathComponent("scripts/mlx_workflow_cli.py"),
        integrityLockURL: isBundled
          ? candidate.deletingLastPathComponent().appendingPathComponent("runtime.lock.json") : nil,
        integrityManifestURL: isBundled
          ? candidate.appendingPathComponent("runtime-manifest.json") : nil
      )
      if fileManager.isExecutableFile(atPath: runtime.pythonURL.path),
        fileManager.fileExists(atPath: runtime.cliURL.path)
      {
        return runtime
      }
    }
    throw WorkflowCLIClientError.missingRuntimeFile(
      "Set MLX_WORKSPACE to a folder containing .venv/bin/python and scripts/mlx_workflow_cli.py."
    )
  }
}

struct WorkflowCLIPlanResult: Sendable {
  let planURL: URL
  let planSHA256: String
  let execution: WorkflowExecution
  let plan: WorkflowPlan?
}

struct WorkflowCLIRunHandle: Sendable {
  let requestID: UUID
  let coordinator: WorkflowCoordinator
  private let task: Task<WorkflowExecution, Error>

  fileprivate init(
    requestID: UUID,
    coordinator: WorkflowCoordinator,
    task: Task<WorkflowExecution, Error>
  ) {
    self.requestID = requestID
    self.coordinator = coordinator
    self.task = task
  }

  func value() async throws -> WorkflowExecution {
    try await task.value
  }

  func interrupt() async -> Bool {
    await coordinator.interrupt(requestID: requestID)
  }
}

actor WorkflowCLIClient {
  typealias EventHandler = @Sendable (WorkflowEvent) async -> Void

  let runtime: WorkflowCLIRuntime
  let runWorkspaceURL: URL
  let coordinator: WorkflowCoordinator
  private let environment: [String: String]

  init(
    runtime: WorkflowCLIRuntime,
    runWorkspaceURL: URL,
    processInfo: ProcessInfo = .processInfo,
    fileManager: FileManager = .default
  ) throws {
    try runtime.validate(fileManager: fileManager)
    guard runWorkspaceURL.isFileURL else {
      throw WorkflowCLIClientError.missingRuntimeFile(runWorkspaceURL.absoluteString)
    }
    try fileManager.createDirectory(
      at: runWorkspaceURL,
      withIntermediateDirectories: true
    )
    self.runtime = runtime
    self.runWorkspaceURL = runWorkspaceURL.standardizedFileURL
    coordinator = WorkflowCoordinator(
      processRunner: ProcessRunner(),
      runRepository: RunRepository(workspaceURL: runWorkspaceURL)
    )

    let inherited = processInfo.environment
    var explicitEnvironment: [String: String] = [
      "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
      "PYTHONDONTWRITEBYTECODE": "1",
      "PYTHONUNBUFFERED": "1",
      "MLX_WORKSPACE": runtime.sourceWorkspaceURL.path,
    ]
    for key in ["HOME", "TMPDIR"] {
      if let value = inherited[key] { explicitEnvironment[key] = value }
    }
    environment = explicitEnvironment
  }

  func inspect(
    modelURL: URL,
    runID: String,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowExecution {
    try validate(runID: runID)
    let request = makeRequest(
      arguments: [
        runtime.cliURL.path,
        "--machine",
        "inspect",
        "--model",
        try WorkflowFilePath.canonical(modelURL),
        "--run-id",
        runID,
      ])
    return try await coordinator.execute(request, onEvent: onEvent)
  }

  func host(
    runID: String,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowExecution {
    try validate(runID: runID)
    let request = makeRequest(
      arguments: [
        runtime.cliURL.path,
        "--machine",
        "host",
        "--workspace",
        runWorkspaceURL.path,
        "--run-id",
        runID,
      ])
    return try await coordinator.execute(request, onEvent: onEvent)
  }

  func planFixture(
    runID: String,
    scenario: String,
    modelURL: URL? = nil,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowCLIPlanResult {
    try validate(runID: runID)
    let planURL = try planOutputURL(runID: runID)
    var arguments = [
      runtime.cliURL.path,
      "--machine",
      "plan",
      "--workspace",
      runWorkspaceURL.path,
      "--run-id",
      runID,
      "--fixture-scenario",
      scenario,
      "--output",
      planURL.path,
    ]
    if let modelURL {
      arguments.append(contentsOf: ["--model", try WorkflowFilePath.canonical(modelURL)])
    }
    let request = makeRequest(arguments: arguments)
    let execution = try await coordinator.execute(request, onEvent: onEvent)
    return WorkflowCLIPlanResult(
      planURL: planURL,
      planSHA256: try Self.sha256(of: planURL),
      execution: execution,
      plan: nil)
  }

  func planModel(
    runID: String,
    modelURL: URL,
    recipe: WorkflowRecipe,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowCLIPlanResult {
    try validate(runID: runID)
    let parentPath = try WorkflowFilePath.canonical(modelURL)
    let workspacePath = try WorkflowFilePath.canonical(runWorkspaceURL)
    guard recipe.exactParent == parentPath else {
      throw WorkflowCLIClientError.invalidPathRelationship(
        "The canonical recipe parent does not match the selected model.")
    }
    guard workspacePath != parentPath, !workspacePath.hasPrefix(parentPath + "/") else {
      throw WorkflowCLIClientError.invalidPathRelationship(
        "The run workspace must not be inside the exact parent.")
    }
    let planURL = try planOutputURL(runID: runID)
    let recipeURL = try recipeOutputURL(runID: runID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(recipe).write(to: recipeURL, options: .atomic)
    let request = makeRequest(
      arguments: [
        runtime.cliURL.path,
        "--machine",
        "plan",
        "--workspace",
        runWorkspaceURL.path,
        "--run-id",
        runID,
        "--model",
        parentPath,
        "--recipe",
        recipeURL.path,
        "--output",
        planURL.path,
      ])
    let execution = try await coordinator.execute(request, onEvent: onEvent)
    let plan =
      FileManager.default.fileExists(atPath: planURL.path)
      ? try WorkflowPlan.decode(Data(contentsOf: planURL)) : nil
    return WorkflowCLIPlanResult(
      planURL: planURL,
      planSHA256: try Self.sha256(of: planURL),
      execution: execution,
      plan: plan)
  }

  func commandDisclosure(planURL: URL) throws -> CommandDisclosure {
    let data = try Data(contentsOf: planURL)
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let steps = document["steps"] as? [[String: Any]],
      !steps.isEmpty
    else {
      throw WorkflowCLIClientError.missingRuntimeFile("Plan has no structured executable step.")
    }
    let commands = try steps.map { step -> CommandInvocationDisclosure in
      guard let executable = step["executable"] as? String,
        let arguments = step["arguments"] as? [String]
      else {
        throw WorkflowCLIClientError.missingRuntimeFile(
          "A plan step has no structured executable or argument array.")
      }
      let display = ([executable] + arguments)
        .map(Self.redactedDisplayArgument)
        .joined(separator: " ")
      return CommandInvocationDisclosure(
        executableIdentity: executable,
        arguments: arguments,
        redactedDisplay: display)
    }
    return CommandDisclosure(commands: commands)
  }

  func fixturePlanDisclosure(planURL: URL) throws -> PlanDisclosure {
    let data = try Data(contentsOf: planURL)
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let recipe = document["recipe"] as? [String: Any],
      let scenario = recipe["fixture_scenario"] as? String,
      let runDirectory = document["run_directory"] as? String
    else {
      throw WorkflowCLIClientError.missingRuntimeFile(
        "The deterministic fixture plan is missing its fixture identity or run directory.")
    }
    let blockers: [PlanBlockerDisclosure] =
      (document["blockers"] as? [[String: Any]] ?? []).compactMap { blocker in
        guard let code = blocker["code"] as? String,
          let message = blocker["message"] as? String
        else { return nil }
        return PlanBlockerDisclosure(code: code, message: message)
      }
    return PlanDisclosure(
      runDirectory: runDirectory,
      exactParent: "deterministic-fixture://\(scenario)",
      quantModes: ["fixture-only"],
      evidenceKind: "deterministic-fixture-not-measured",
      uncertainty: "fixture-values-not-measured",
      estimatedOutputBytes: nil,
      estimatedTemporaryBytes: nil,
      requiredFreeDiskBytes: nil,
      observedFreeDiskBytes: 0,
      estimatedPeakMemoryBytes: nil,
      observedUnifiedMemoryBytes: nil,
      estimatedDurationSeconds: nil,
      timeBudgetSeconds: 0,
      feasibility: blockers.isEmpty ? "fixture-only" : "blocked",
      reasonCodes: [],
      requiredGates: ["fixture-only-no-qualification"],
      blockers: blockers)
  }

  func startRun(
    planURL: URL,
    expectedPlanSHA256: String? = nil,
    onEvent: @escaping EventHandler = { _ in }
  ) -> WorkflowCLIRunHandle {
    var arguments = [
      runtime.cliURL.path,
      "--machine",
      "run",
      "--plan",
      planURL.standardizedFileURL.path,
    ]
    if let expectedPlanSHA256 {
      arguments.append(contentsOf: ["--expected-plan-sha256", expectedPlanSHA256])
    }
    let request = makeRequest(
      arguments: arguments)
    let coordinator = coordinator
    let task = Task {
      try await coordinator.execute(request, onEvent: onEvent)
    }
    return WorkflowCLIRunHandle(
      requestID: request.id,
      coordinator: coordinator,
      task: task
    )
  }

  func recoverRun(runID: String) async throws -> RecoveredWorkflowRun {
    try validate(runID: runID)
    return try await coordinator.recoverRun(runID: runID)
  }

  func qualifyRun(
    runID: String,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowExecution {
    try validate(runID: runID)
    let request = makeRequest(
      arguments: [
        runtime.cliURL.path,
        "--machine",
        "qualify",
        "--run-dir",
        runWorkspaceURL.appendingPathComponent(runID, isDirectory: true).path,
      ])
    return try await coordinator.executeContinuation(
      request,
      runID: runID,
      onEvent: onEvent)
  }

  func resumeRun(
    runID: String,
    onEvent: @escaping EventHandler = { _ in }
  ) async throws -> WorkflowCLIRunHandle {
    try validate(runID: runID)
    let recovered = try await coordinator.recoverRun(runID: runID)
    guard recovered.effectiveState == .interrupted,
      recovered.effectiveResumability == .safe
    else {
      throw WorkflowCLIClientError.runNotSafelyResumable(runID)
    }
    let request = makeRequest(
      arguments: [
        runtime.cliURL.path,
        "--machine",
        "resume",
        "--run-dir",
        recovered.runDirectoryURL.path,
      ])
    let coordinator = coordinator
    let task = Task {
      try await coordinator.executeContinuation(
        request,
        runID: runID,
        onEvent: onEvent)
    }
    return WorkflowCLIRunHandle(
      requestID: request.id,
      coordinator: coordinator,
      task: task)
  }

  func interruptRun(requestID: UUID) async -> Bool {
    await coordinator.interrupt(requestID: requestID)
  }

  func recoverAllRuns() async throws -> WorkflowRecoveryBatch {
    try await coordinator.recoverAllRuns()
  }

  func cancelRecoveredRun(
    runID: String,
    pollInterval: Duration = .milliseconds(100),
    timeout: Duration = .seconds(15)
  ) async throws -> RecoveredWorkflowRun {
    try validate(runID: runID)
    return try await coordinator.cancelRecoveredRun(
      runID: runID,
      pollInterval: pollInterval,
      timeout: timeout)
  }

  private func makeRequest(arguments: [String]) -> ProcessRequest {
    ProcessRequest(
      executableURL: runtime.pythonURL,
      arguments: arguments,
      workingDirectoryURL: runtime.sourceWorkspaceURL,
      environment: environment
    )
  }

  private func planOutputURL(runID: String) throws -> URL {
    let directory = runWorkspaceURL.appendingPathComponent(".plans", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(runID).plan.json")
  }

  private func recipeOutputURL(runID: String) throws -> URL {
    let directory = runWorkspaceURL.appendingPathComponent(".recipes", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(runID).recipe.json")
  }

  private func validate(runID: String) throws {
    guard Self.isValidRunID(runID) else { throw WorkflowCLIClientError.invalidRunID(runID) }
  }

  private nonisolated static func isValidRunID(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      CharacterSet.alphanumerics.contains(first),
      value.unicodeScalars.count <= 128
    else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }

  private nonisolated static func redactedDisplayArgument(_ value: String) -> String {
    let lowered = value.lowercased()
    if ["token=", "secret=", "password=", "api_key=", "api-key="].contains(where: {
      lowered.contains($0)
    }) {
      return "<redacted>"
    }
    if value.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:".contains($0) }) {
      return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private nonisolated static func sha256(of url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
