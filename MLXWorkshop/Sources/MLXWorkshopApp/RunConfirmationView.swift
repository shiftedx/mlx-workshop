import SwiftUI

struct RunConfirmationView: View {
  let confirmation: RunConfirmation
  let onConfirm: () async -> Void
  let onDecline: () -> Void

  @State private var isConfirming = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(WorkshopTheme.divider)

      ScrollView {
        VStack(alignment: .leading, spacing: WorkshopTheme.spaceL) {
          if confirmation.changesWeights {
            weightChangeWarning
          }
          paths
          resourceEstimate
          reviewWarnings
          requiredGates
          exactCommands
          redactedCommands
        }
        .padding(WorkshopTheme.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider().overlay(WorkshopTheme.divider)
      actions
    }
    .frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 720)
    .background(WorkshopTheme.chrome)
    .accessibilityElement(children: .contain)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: WorkshopTheme.spaceS) {
      Image(systemName: confirmation.changesWeights ? "scalemass" : "checklist")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(
          confirmation.changesWeights ? WorkshopTheme.warning : WorkshopTheme.skyBright
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkshopTheme.spaceXXS) {
        Text(confirmation.changesWeights ? "Confirm weight-changing run" : "Confirm local run")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text("Review the immutable destination, planning estimates, gates, and exact arguments.")
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      Spacer()
      Text(confirmation.runID)
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(WorkshopTheme.quietInk)
        .textSelection(.enabled)
    }
    .padding(WorkshopTheme.spaceL)
  }

  private var weightChangeWarning: some View {
    HStack(alignment: .top, spacing: WorkshopTheme.spaceS) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(WorkshopTheme.warning)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkshopTheme.spaceXXS) {
        Text("This run changes model weights")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text(
          "It creates a new model artifact in the run directory. The exact parent remains read-only."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      }
    }
    .padding(WorkshopTheme.spaceS)
    .background(
      WorkshopTheme.warning.opacity(0.10),
      in: RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous)
        .stroke(WorkshopTheme.warning.opacity(0.35), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }

  private var paths: some View {
    confirmationSection("Immutable paths") {
      pathRow("Exact parent", confirmation.plan.exactParent)
      pathRow("New run directory", confirmation.plan.runDirectory)
    }
  }

  private var resourceEstimate: some View {
    confirmationSection("Planning estimate") {
      LabeledContent("Kind", value: confirmation.plan.evidenceKind)
      LabeledContent("Uncertainty", value: confirmation.plan.uncertainty)
      LabeledContent("Feasibility", value: confirmation.plan.feasibility)
      Divider().overlay(WorkshopTheme.divider.opacity(0.65))
      LabeledContent("Estimated output", value: bytes(confirmation.plan.estimatedOutputBytes))
      LabeledContent(
        "Estimated temporary space", value: bytes(confirmation.plan.estimatedTemporaryBytes))
      LabeledContent(
        "Required free disk", value: bytes(confirmation.plan.requiredFreeDiskBytes))
      LabeledContent(
        "Observed free disk", value: bytes(confirmation.plan.observedFreeDiskBytes))
      LabeledContent(
        "Estimated peak memory", value: bytes(confirmation.plan.estimatedPeakMemoryBytes))
      LabeledContent(
        "Observed unified memory", value: bytes(confirmation.plan.observedUnifiedMemoryBytes))
      LabeledContent(
        "Estimated duration",
        value: confirmation.plan.estimatedDurationSeconds.map(duration) ?? "Unknown")
      LabeledContent("Time budget", value: duration(confirmation.plan.timeBudgetSeconds))
    }
  }

  @ViewBuilder
  private var reviewWarnings: some View {
    if confirmation.hasActiveWorkloadWarning || confirmation.plan.estimatedDurationSeconds == nil {
      confirmationSection("Review required") {
        if confirmation.hasActiveWorkloadWarning {
          Label(
            "Relevant workloads are active on this Mac and may affect available resources.",
            systemImage: "cpu"
          )
        }
        if confirmation.plan.estimatedDurationSeconds == nil {
          Label(
            "Duration is unknown. The declared time budget is \(duration(confirmation.plan.timeBudgetSeconds)).",
            systemImage: "clock"
          )
        }
      }
      .foregroundStyle(WorkshopTheme.warning)
    }
  }

  private var requiredGates: some View {
    confirmationSection("Required gates") {
      if confirmation.plan.requiredGates.isEmpty {
        Label("No required gates were declared by the plan.", systemImage: "minus.circle")
          .foregroundStyle(WorkshopTheme.secondaryInk)
      } else {
        ForEach(confirmation.plan.requiredGates, id: \.self) { gate in
          Label(gate, systemImage: "circle.dashed")
        }
      }
    }
  }

  private var exactCommands: some View {
    confirmationSection("Exact local arguments") {
      Text("These are literal argument arrays. They are not the redacted display form.")
        .font(.system(size: 11.5))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      ForEach(Array(confirmation.command.commands.enumerated()), id: \.offset) { index, command in
        VStack(alignment: .leading, spacing: WorkshopTheme.spaceXS) {
          Text("Command \(index + 1)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text("Executable: \(command.executableIdentity)")
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
          ForEach(Array(command.arguments.enumerated()), id: \.offset) { argumentIndex, argument in
            Text("[\(argumentIndex)]  \(argument)")
              .font(.system(size: 10.5, design: .monospaced))
          }
        }
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .textSelection(.enabled)
        if index < confirmation.command.commands.count - 1 {
          Divider().overlay(WorkshopTheme.divider.opacity(0.65))
        }
      }
    }
  }

  private var redactedCommands: some View {
    confirmationSection("Redacted display") {
      Text(
        "Configured secrets may be redacted in this display. Local paths and other non-secret arguments can remain visible."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      ForEach(Array(confirmation.command.commands.enumerated()), id: \.offset) { index, command in
        Text("Command \(index + 1): \(command.redactedDisplay)")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .textSelection(.enabled)
      }
    }
  }

  private var actions: some View {
    HStack(spacing: WorkshopTheme.spaceS) {
      Button("Decline") { onDecline() }
        .keyboardShortcut(.cancelAction)
        .help("Decline this run without starting it or creating its run directory")
        .accessibilityLabel("Decline run")
        .accessibilityHint("Closes confirmation without starting the local workflow")
        .accessibilityIdentifier("confirmation.decline")
      Spacer()
      if isConfirming {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Starting confirmed run")
      }
      Button(confirmation.changesWeights ? "Confirm weight-changing run" : "Confirm run") {
        guard !isConfirming else { return }
        isConfirming = true
        Task {
          await onConfirm()
          isConfirming = false
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(WorkshopTheme.skyBright)
      .keyboardShortcut(.defaultAction)
      .disabled(isConfirming)
      .help("Confirm the reviewed plan and start its local argument-array workflow")
      .accessibilityLabel(
        confirmation.changesWeights ? "Confirm weight-changing run" : "Confirm run"
      )
      .accessibilityHint("Starts only the reviewed local workflow")
      .accessibilityIdentifier("confirmation.confirm")
    }
    .padding(WorkshopTheme.spaceL)
  }

  private func confirmationSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: WorkshopTheme.spaceS) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      content()
        .font(.system(size: 11.5))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pathRow(_ title: String, _ path: String) -> some View {
    VStack(alignment: .leading, spacing: WorkshopTheme.spaceXXS) {
      Text(title)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(WorkshopTheme.quietInk)
      Text(path)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(path)")
  }

  private func bytes(_ value: Int?) -> String {
    guard let value else { return "Unknown" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
  }

  private func bytes(_ value: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
  }

  private func duration(_ seconds: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
  }
}
