import AppKit
import SwiftUI

struct RunsView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var selection: RunRecord.ID?
  @State private var lifecycleRunID: String?
  let onQualify: @MainActor (String) async -> Void
  let onResume: @MainActor (String) async -> Void
  let onCancelRecovered: @MainActor (String) async -> Void

  init(
    onQualify: @escaping @MainActor (String) async -> Void = { _ in },
    onResume: @escaping @MainActor (String) async -> Void = { _ in },
    onCancelRecovered: @escaping @MainActor (String) async -> Void = { _ in }
  ) {
    self.onQualify = onQualify
    self.onResume = onResume
    self.onCancelRecovered = onCancelRecovered
  }

  var body: some View {
    VStack(spacing: 0) {
      pageHeader
      Divider().overlay(WorkshopTheme.divider)

      if store.runs.isEmpty {
        ContentUnavailableView {
          Label("No runs yet", systemImage: "clock")
        } description: {
          Text(
            "Planned, running, interrupted, failed, cancelled, and completed runs will appear here from the run journal."
          )
        } actions: {
          Button("Return to workbench") { store.section = .workbench }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.runs) { run in
              runRow(run)
              Divider().overlay(WorkshopTheme.divider.opacity(0.65))
            }
          }
        }
      }
    }
    .background(WorkshopTheme.canvas)
    .navigationTitle("Runs")
  }

  private var pageHeader: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("Run history")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text("Journaled commands, artifacts, results, and failures remain reproducible.")
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      Spacer()
      Button {
        store.section = .workbench
        store.requestRunAction()
      } label: {
        Label("Run current recipe", systemImage: "play.fill")
      }
      .buttonStyle(QuietButtonStyle())
      .disabled(!store.canStartRun)
    }
    .padding(18)
    .background(WorkshopTheme.surface)
  }

  private func runRow(_ run: RunRecord) -> some View {
    HStack(spacing: 14) {
      ZStack {
        Circle().fill(run.state.color.opacity(0.13))
        Image(systemName: run.state.symbol)
          .foregroundStyle(run.state.color)
          .font(.system(size: 13, weight: .semibold))
      }
      .frame(width: 32, height: 32)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text("Run \(run.number)")
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(WorkshopTheme.quietInk)
          Text(run.title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
        }
        Text(run.summary)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Text(run.created)
        Text(run.duration)
      }
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(WorkshopTheme.quietInk)
      .frame(width: 130, alignment: .trailing)

      StatusPill(text: statusText(run), symbol: statusSymbol(run), color: run.state.color)
        .frame(width: 148, alignment: .trailing)
        .accessibilityLabel(statusAccessibilityLabel(run))

      if let action = lifecycleAction(run) {
        Button {
          perform(action, runID: run.runID)
        } label: {
          Label(action.label, systemImage: action.symbol)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5, weight: .semibold))
        .disabled(lifecycleRunID != nil)
        .accessibilityIdentifier("runs.\(run.runID).\(action.identifier)")
        .help(action.help)
      }

      Menu {
        Button {
          reveal(run.runDirectory)
        } label: {
          Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(run.runDirectory == nil)
        Button {
          open(run.stdoutLog)
        } label: {
          Label("Open raw stdout", systemImage: "doc.text")
        }
        .disabled(run.stdoutLog == nil)
        Button {
          open(run.stderrLog)
        } label: {
          Label("Open raw stderr", systemImage: "exclamationmark.bubble")
        }
        .disabled(run.stderrLog == nil)
        Divider()
        Button {
          copyRedactedCommand(run.command)
        } label: {
          Label("Copy redacted command", systemImage: "doc.on.doc")
        }
        .disabled(redactedCommandText(run.command) == nil)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 30, height: 30)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .help("Run evidence actions; unavailable artifacts are disabled")
      .accessibilityLabel("Evidence actions for run \(run.number)")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(selection == run.id ? WorkshopTheme.surfaceSelected : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { selection = run.id }
  }

  private func lifecycleAction(_ run: RunRecord) -> RunLifecycleAction? {
    RunLifecycleAction.recommended(
      state: run.state,
      resumability: run.resumability,
      isQualified: run.isQualified,
      isTrackedByThisProcess: false)
  }

  private func perform(_ action: RunLifecycleAction, runID: String) {
    guard lifecycleRunID == nil else { return }
    lifecycleRunID = runID
    Task { @MainActor in
      switch action {
      case .qualify: await onQualify(runID)
      case .resume: await onResume(runID)
      case .cancelRecovered: await onCancelRecovered(runID)
      }
      lifecycleRunID = nil
    }
  }

  private func statusText(_ run: RunRecord) -> String {
    if run.isQualified { return "Qualified" }
    if run.state == .completed { return "Completed · needs verification" }
    return run.state.rawValue
  }

  private func statusSymbol(_ run: RunRecord) -> String {
    run.isQualified ? "checkmark.seal.fill" : run.state.symbol
  }

  private func statusAccessibilityLabel(_ run: RunRecord) -> String {
    if run.isQualified { return "Run state: qualified; all required gates passed" }
    if run.state == .completed { return "Run state: completed; qualification not established" }
    let resumability = run.resumability.map { "; resumability \($0)" } ?? ""
    return "Run state: \(run.state.rawValue)\(resumability)"
  }

  private func redactedCommandText(_ disclosure: CommandDisclosure?) -> String? {
    guard let disclosure else { return nil }
    let displays = disclosure.commands.enumerated().compactMap { index, command -> String? in
      guard !command.redactedDisplay.isEmpty else { return nil }
      return disclosure.commands.count > 1
        ? "Command \(index + 1): \(command.redactedDisplay)" : command.redactedDisplay
    }
    return displays.isEmpty ? nil : displays.joined(separator: "\n")
  }

  private func copyRedactedCommand(_ disclosure: CommandDisclosure?) {
    guard let text = redactedCommandText(disclosure) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func reveal(_ runDirectory: URL?) {
    guard let runDirectory else { return }
    NSWorkspace.shared.activateFileViewerSelecting([runDirectory])
  }

  private func open(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.open(url)
  }
}
