import AppKit
import SwiftUI

struct RunDrawerView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var lifecycleActionInProgress = false
  let onQualify: @MainActor (String) async -> Void
  let onResume: @MainActor (String) async -> Void
  let onCancelRecovered: @MainActor (String) async -> Void

  var body: some View {
    Group {
      if let run = store.currentRun {
        VStack(spacing: 0) {
          header(run)
          Divider().overlay(WorkshopTheme.divider)
          HStack(spacing: 0) {
            stateDetail(run).frame(maxWidth: .infinity)
            Divider().overlay(WorkshopTheme.divider)
            evidenceActions(run).frame(width: 300)
          }
        }
      } else {
        ContentUnavailableView(
          "No current run", systemImage: "clock",
          description: Text("A planned or recovered run will appear here."))
      }
    }
    .background(WorkshopTheme.surface)
  }

  private func header(_ run: WorkshopRun) -> some View {
    HStack(spacing: 10) {
      Text(run.id)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(WorkshopTheme.quietInk)
        .lineLimit(1)
      Text(run.title)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .lineLimit(1)
      Spacer()
      StatusPill(text: run.state.rawValue, symbol: run.state.symbol, color: run.state.color)
        .accessibilityLabel("Run state: \(run.state.rawValue)")
      Button {
        store.showRunDrawer = false
      } label: {
        Image(systemName: "chevron.down").frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .help("Hide run evidence")
      .accessibilityLabel("Hide run evidence")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private func stateDetail(_ run: WorkshopRun) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(run.stage.map { "Stage: \($0)" } ?? "Run-level state")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(WorkshopTheme.quietInk)
          Text(run.statusDetail ?? stateExplanation(run.state))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(WorkshopTheme.ink)
        }
        Spacer()
        if let resumability = run.resumability {
          Label("Resumability: \(resumability)", systemImage: resumabilitySymbol(resumability))
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(
              resumability == "safe" ? WorkshopTheme.success : WorkshopTheme.secondaryInk
            )
            .accessibilityLabel("Run resumability: \(resumability)")
        }
      }

      if let progress = run.progress {
        if let fraction = progress.fraction {
          ProgressView(value: fraction)
            .tint(WorkshopTheme.sky)
            .accessibilityLabel("Run progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
        } else if run.state.isActive {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Run active; total work is not reported")
        }
        Text(progressDescription(progress))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }

      ForEach(run.diagnostics) { diagnostic in
        Label(
          diagnostic.message,
          systemImage: diagnostic.severity == .blocker
            ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        )
        .font(.system(size: 10.5))
        .foregroundStyle(
          diagnostic.severity == .blocker ? WorkshopTheme.danger : WorkshopTheme.warning)
      }
    }
    .padding(14)
  }

  private func evidenceActions(_ run: WorkshopRun) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        run.isQualified ? "Qualified — all required gates passed" : "Qualification not established",
        systemImage: run.isQualified ? "checkmark.seal.fill" : "circle.dashed"
      )
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(run.isQualified ? WorkshopTheme.success : WorkshopTheme.secondaryInk)
      .accessibilityLabel(
        run.isQualified
          ? "Qualification state: qualified; all required gates passed"
          : "Qualification state: not established")

      HStack(spacing: 8) {
        Button("Reveal run") { reveal(run.runDirectory) }
          .disabled(run.runDirectory == nil)
          .help(
            run.runDirectory == nil
              ? "No run directory is available" : "Reveal the run directory in Finder"
          )
          .accessibilityLabel("Reveal current run in Finder")
        Button("Open stdout") { open(run.stdoutLog) }
          .disabled(run.stdoutLog == nil)
          .help(run.stdoutLog == nil ? "No stdout artifact is available" : "Open raw stdout")
          .accessibilityLabel("Open raw standard output")
        Button("Open stderr") { open(run.stderrLog) }
          .disabled(run.stderrLog == nil)
          .help(run.stderrLog == nil ? "No stderr artifact is available" : "Open raw stderr")
          .accessibilityLabel("Open raw standard error")
      }
      .buttonStyle(.borderless)
      .font(.system(size: 10.5, weight: .medium))

      HStack(spacing: 8) {
        Button("Copy redacted command") {
          copyToPasteboard(redactedCommandText(run.command))
        }
        .disabled(redactedCommandText(run.command) == nil)
        .help(
          redactedCommandText(run.command) == nil
            ? "No redacted command display is available"
            : "Copy the command's configured redacted display; local paths can remain visible"
        )
        .accessibilityLabel("Copy redacted command display")
        .accessibilityHint("Configured secrets may be redacted; local paths can remain visible")

        if exactArgumentsText(run.command) != nil {
          Button("Copy exact arguments (local)") {
            copyToPasteboard(exactArgumentsText(run.command))
          }
          .help("Copy literal local executable identities and indexed argument arrays")
          .accessibilityLabel("Copy exact local argument arrays")
          .accessibilityHint("May include exact local paths; use only on this Mac")
        }
      }
      .buttonStyle(.borderless)
      .font(.system(size: 10.5, weight: .medium))

      if let action = RunLifecycleAction.recommended(
        state: run.state,
        resumability: run.resumability,
        isQualified: run.isQualified,
        isTrackedByThisProcess: run.requestID != nil)
      {
        Button {
          perform(action, runID: run.id)
        } label: {
          Label(action.label, systemImage: action.symbol)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(lifecycleActionInProgress)
        .accessibilityIdentifier("run.lifecycle.\(action.identifier)")
        .help(action.help)
      } else if store.canCancelRun {
        Button {
          Task { await store.requestCancellation() }
        } label: {
          Label(
            run.state == .cancelling ? "Cancellation requested" : "Cancel run",
            systemImage: "stop.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("run.lifecycle.cancelTracked")
        .help("Request cooperative cancellation for this app's tracked process")
      }
    }
    .padding(14)
  }

  private func perform(_ action: RunLifecycleAction, runID: String) {
    guard !lifecycleActionInProgress else { return }
    lifecycleActionInProgress = true
    Task { @MainActor in
      switch action {
      case .qualify: await onQualify(runID)
      case .resume: await onResume(runID)
      case .cancelRecovered: await onCancelRecovered(runID)
      }
      lifecycleActionInProgress = false
    }
  }

  private func stateExplanation(_ state: WorkshopRunState) -> String {
    switch state {
    case .planned: "The plan is ready; execution has not started."
    case .blocked: "The plan is blocked and cannot be executed."
    case .running: "The local workflow is running."
    case .cancelling: "Waiting for cooperative cancellation to be journaled."
    case .cancelled: "The run stopped without qualification."
    case .interrupted: "The process ended unexpectedly; check resumability and raw logs."
    case .failed: "The run failed; inspect the diagnostic and raw logs."
    case .completed: "Execution completed. Qualification remains a separate evidence state."
    case .protocolMismatch:
      "This app cannot safely interpret the run protocol; mutating actions are disabled."
    }
  }

  private func progressDescription(_ progress: RunProgress) -> String {
    let unit = progress.unit.map { " \($0)" } ?? ""
    if let total = progress.total {
      return
        "\(String(format: "%.0f", progress.completed)) of \(String(format: "%.0f", total))\(unit)"
    }
    return "\(String(format: "%.0f", progress.completed))\(unit) completed · total not reported"
  }

  private func resumabilitySymbol(_ resumability: String) -> String {
    switch resumability {
    case "safe": "arrow.clockwise.circle.fill"
    case "unsafe": "nosign"
    case "unknown": "questionmark.circle"
    default: "minus.circle"
    }
  }

  private func redactedCommandText(_ disclosure: CommandDisclosure?) -> String? {
    guard let disclosure else { return nil }
    let displays = disclosure.commands.enumerated().compactMap { index, command -> String? in
      guard !command.redactedDisplay.isEmpty else { return nil }
      return disclosure.commands.count > 1
        ? "Command \(index + 1): \(command.redactedDisplay)" : command.redactedDisplay
    }
    guard !displays.isEmpty else { return nil }
    return displays.joined(separator: "\n")
  }

  private func exactArgumentsText(_ disclosure: CommandDisclosure?) -> String? {
    guard let disclosure, !disclosure.commands.isEmpty else { return nil }
    return disclosure.commands.enumerated().map { commandIndex, command in
      let arguments = command.arguments.enumerated().map { index, argument in
        "[\(index)]  \(argument)"
      }.joined(separator: "\n")
      let header = "Command \(commandIndex + 1)\nExecutable identity: \(command.executableIdentity)"
      return arguments.isEmpty ? "\(header)\nArguments: []" : "\(header)\nArguments:\n\(arguments)"
    }.joined(separator: "\n\n")
  }

  private func copyToPasteboard(_ text: String?) {
    guard let text, !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func reveal(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func open(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.open(url)
  }
}

extension RunLifecycleAction {
  var identifier: String {
    switch self {
    case .qualify: "qualify"
    case .resume: "resume"
    case .cancelRecovered: "cancelRecovered"
    }
  }

  var label: String {
    switch self {
    case .qualify: "Run qualification"
    case .resume: "Resume safe run"
    case .cancelRecovered: "Cancel recovered run"
    }
  }

  var symbol: String {
    switch self {
    case .qualify: "checkmark.seal"
    case .resume: "arrow.clockwise"
    case .cancelRecovered: "stop.fill"
    }
  }

  var help: String {
    switch self {
    case .qualify: "Run the recipe's required gates and record their evidence"
    case .resume: "Continue this journal-safe interrupted run without changing its identity"
    case .cancelRecovered: "Write this run's cooperative cancellation marker and await its journal"
    }
  }
}
