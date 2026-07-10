import Darwin
import Foundation

struct ProcessRequest: Sendable {
  let id: UUID
  let executableURL: URL
  let arguments: [String]
  let workingDirectoryURL: URL
  let environment: [String: String]
  let retainedOutputLimitBytes: Int

  init(
    id: UUID = UUID(),
    executableURL: URL,
    arguments: [String],
    workingDirectoryURL: URL,
    environment: [String: String],
    retainedOutputLimitBytes: Int = 256 * 1024
  ) {
    self.id = id
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectoryURL = workingDirectoryURL
    self.environment = environment
    self.retainedOutputLimitBytes = max(0, retainedOutputLimitBytes)
  }
}

enum ProcessOutputStream: Equatable, Sendable {
  case stdout
  case stderr
}

struct ProcessOutputChunk: Sendable {
  let stream: ProcessOutputStream
  let data: Data
}

struct ProcessOutputSummary: Equatable, Sendable {
  let totalBytes: Int
  let retainedData: Data

  var text: String {
    String(decoding: retainedData, as: UTF8.self)
  }
}

struct ProcessRunResult: Equatable, Sendable {
  let requestID: UUID
  let processIdentifier: Int32
  let exitCode: Int32
  let terminationReason: Process.TerminationReason
  let cancellationRequested: Bool
  let stdout: ProcessOutputSummary
  let stderr: ProcessOutputSummary
}

actor ProcessRunner {
  typealias OutputHandler = @Sendable (ProcessOutputChunk) async -> Void

  private var activeProcesses: [UUID: Process] = [:]
  private var cancellationRequests: Set<UUID> = []

  func run(
    _ request: ProcessRequest,
    onOutput: @escaping OutputHandler = { _ in }
  ) async throws -> ProcessRunResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let waiter = ProcessTerminationWaiter()
    let capture = ProcessOutputCapture(limit: request.retainedOutputLimitBytes)

    process.executableURL = request.executableURL
    process.arguments = request.arguments
    process.currentDirectoryURL = request.workingDirectoryURL
    process.environment = request.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { _ in
      Task { await waiter.signal() }
    }

    try process.run()
    activeProcesses[request.id] = process

    async let stdoutDrain: Void = Self.drain(
      stdoutPipe.fileHandleForReading,
      stream: .stdout,
      capture: capture,
      handler: onOutput
    )
    async let stderrDrain: Void = Self.drain(
      stderrPipe.fileHandleForReading,
      stream: .stderr,
      capture: capture,
      handler: onOutput
    )

    await withTaskCancellationHandler {
      await waiter.wait()
    } onCancel: {
      Task { _ = await self.cancel(id: request.id) }
    }
    _ = await (stdoutDrain, stderrDrain)

    activeProcesses[request.id] = nil
    let wasCancelled = cancellationRequests.remove(request.id) != nil
    let summaries = await capture.summaries()
    return ProcessRunResult(
      requestID: request.id,
      processIdentifier: process.processIdentifier,
      exitCode: process.terminationStatus,
      terminationReason: process.terminationReason,
      cancellationRequested: wasCancelled,
      stdout: summaries.stdout,
      stderr: summaries.stderr
    )
  }

  @discardableResult
  func cancel(id: UUID, grace: Duration = .seconds(2)) async -> Bool {
    guard let process = activeProcesses[id], process.isRunning else { return false }
    cancellationRequests.insert(id)
    process.terminate()
    try? await Task.sleep(for: grace)
    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
    return true
  }

  @discardableResult
  func interrupt(id: UUID) -> Bool {
    guard let process = activeProcesses[id], process.isRunning else { return false }
    return Darwin.kill(process.processIdentifier, SIGINT) == 0
  }

  func activeProcessIDs() -> Set<UUID> {
    Set(activeProcesses.keys)
  }

  private nonisolated static func drain(
    _ handle: FileHandle,
    stream: ProcessOutputStream,
    capture: ProcessOutputCapture,
    handler: @escaping OutputHandler
  ) async {
    await Task.detached(priority: .utility) {
      while true {
        let data = handle.availableData
        guard !data.isEmpty else { break }
        await capture.append(data, stream: stream)
        await handler(ProcessOutputChunk(stream: stream, data: data))
      }
      try? handle.close()
    }.value
  }
}

private actor ProcessTerminationWaiter {
  private var completed = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if completed { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func signal() {
    guard !completed else { return }
    completed = true
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting {
      continuation.resume()
    }
  }
}

private actor ProcessOutputCapture {
  private let limit: Int
  private var stdout = BoundedDataBuffer()
  private var stderr = BoundedDataBuffer()

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ data: Data, stream: ProcessOutputStream) {
    switch stream {
    case .stdout: stdout.append(data, limit: limit)
    case .stderr: stderr.append(data, limit: limit)
    }
  }

  func summaries() -> (stdout: ProcessOutputSummary, stderr: ProcessOutputSummary) {
    (stdout.summary, stderr.summary)
  }
}

private struct BoundedDataBuffer: Sendable {
  private(set) var totalBytes = 0
  private var retained = Data()

  mutating func append(_ data: Data, limit: Int) {
    totalBytes += data.count
    guard limit > 0 else {
      retained.removeAll(keepingCapacity: false)
      return
    }
    retained.append(data)
    if retained.count > limit {
      retained.removeFirst(retained.count - limit)
    }
  }

  var summary: ProcessOutputSummary {
    ProcessOutputSummary(totalBytes: totalBytes, retainedData: retained)
  }
}
