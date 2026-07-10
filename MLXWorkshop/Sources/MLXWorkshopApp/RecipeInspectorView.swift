import SwiftUI

struct RecipeInspectorView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var showCommand = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: WorkshopTheme.spaceXXS) {
          Text("Optimization recipe")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text(store.recipeName)
            .font(.system(size: 10.5))
            .foregroundStyle(WorkshopTheme.secondaryInk)
        }
        Spacer()
        Button {
          store.showInspector = false
        } label: {
          Image(systemName: "xmark")
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .help("Hide inspector")
      }
      .padding(WorkshopTheme.spaceM)

      Picker("Recipe depth", selection: $store.expertMode) {
        Text("Easy").tag(false)
        Text("Expert").tag(true)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .padding(.horizontal, WorkshopTheme.spaceM)
      .padding(.bottom, WorkshopTheme.spaceS)

      Divider().overlay(WorkshopTheme.divider)

      ScrollView {
        VStack(alignment: .leading, spacing: WorkshopTheme.spaceM) {
          if store.expertMode {
            expertControls
          } else {
            easyControls
          }

          if let plan = store.currentRun?.plan {
            verifiedPlan(plan)
          }

          DisclosureGroup(isExpanded: $showCommand) {
            commandDisclosure
              .font(.system(size: 10, weight: .regular, design: .monospaced))
              .foregroundStyle(WorkshopTheme.secondaryInk)
              .textSelection(.enabled)
              .padding(WorkshopTheme.spaceS)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                WorkshopTheme.canvas,
                in: RoundedRectangle(
                  cornerRadius: WorkshopTheme.radiusSmall, style: .continuous)
              )
              .padding(.top, WorkshopTheme.spaceXS)
          } label: {
            Label("Underlying command", systemImage: "terminal")
              .font(.system(size: 11.5, weight: .semibold))
              .foregroundStyle(WorkshopTheme.secondaryInk)
          }
        }
        .padding(WorkshopTheme.spaceM)
      }
      .disabled(!store.mutatingActionsAllowed)

      Divider().overlay(WorkshopTheme.divider)
      VStack(spacing: WorkshopTheme.spaceXS) {
        Button {
          if store.isRunning {
            Task { await store.requestCancellation() }
          } else {
            store.requestRunAction()
          }
        } label: {
          Label(
            store.isRunning ? "Cancel current run" : "Plan this recipe",
            systemImage: store.isRunning ? "stop.fill" : "play.fill")
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .disabled(!store.canStartRun && !store.canCancelRun)
        .help(
          store.canPlanRun
            ? "Create or cancel an immutable local run"
            : "Choose and inspect a model, then choose a run workspace")

        Button {
          store.section = store.contentMode == .demo ? .compare : .runs
        } label: {
          Label(
            store.contentMode == .demo ? "Compare candidates" : "View run history",
            systemImage: store.contentMode == .demo
              ? "arrow.left.arrow.right" : "clock.arrow.trianglehead.counterclockwise.rotate.90"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButtonStyle())
      }
      .padding(WorkshopTheme.spaceM)
    }
    .background(WorkshopTheme.chrome)
  }

  private var easyControls: some View {
    VStack(alignment: .leading, spacing: WorkshopTheme.spaceM) {
      VStack(alignment: .leading, spacing: WorkshopTheme.spaceXS) {
        Label(
          store.contentMode == .demo ? "Representative demo recipe" : "Recipe priorities",
          systemImage: "slider.horizontal.3"
        )
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(WorkshopTheme.skyBright)
        Text(
          store.contentMode == .demo
            ? "Demo: balanced 4/8-bit keeps selected residual writers at higher precision. These values are not local measurements."
            : "Easy and Expert edit this same recipe. Estimates and commands appear only when the coordinator produces a verified plan."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(WorkshopTheme.spaceS)
      .background(
        WorkshopTheme.skyWash,
        in: RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous).stroke(
          WorkshopTheme.sky.opacity(0.32), lineWidth: 1))

      if store.contentMode == .demo {
        InspectorSection(title: "Priorities", detail: "Drag to rebalance") {
          labeledSlider("Fidelity", value: $store.recipe.qualityPriority, trailing: "High")
          labeledSlider(
            "Smaller artifact", value: $store.recipe.sizePriority, trailing: "Balanced")
        }
      }

      InspectorSection(title: "Workload") {
        LabeledContent("Quantization") {
          Picker("Quantization", selection: quantizationMode) {
            Text("MXFP4").tag("mxfp4")
            Text("MXFP8").tag("mxfp8")
            Text("Affine 4-bit").tag("affine")
          }
          .labelsHidden()
          .frame(maxWidth: 170)
        }

        LabeledContent("Calibration") {
          Picker("Calibration", selection: $store.recipe.calibrationSuite) {
            Text("Not applicable (uniform)").tag("not-applicable")
            Text("Agent + code balanced").tag("Agent + code balanced")
            Text("Long-context retrieval").tag("Long-context retrieval")
            Text("Prose and chat").tag("Prose and chat")
          }
          .labelsHidden()
          .frame(maxWidth: 170)
          .disabled(store.contentMode == .live)
          .help("The public beta supports uniform quantization without calibration")
        }

        LabeledContent("Context target") {
          Picker("Context target", selection: $store.recipe.contextLength) {
            Text("16K").tag("16K")
            Text("32K").tag("32K")
            Text("64K").tag("64K")
          }
          .labelsHidden()
          .frame(width: 88)
        }

        LabeledContent("Time budget") {
          Stepper(value: $store.recipe.timeBudgetSeconds, in: 300...86_400, step: 300) {
            Text(duration(store.recipe.timeBudgetSeconds))
              .monospacedDigit()
          }
          .frame(width: 126)
        }
      }

      InspectorSection(title: "Safeguards") {
        Toggle("Protect sensitive layers", isOn: $store.recipe.protectSensitiveLayers)
        Toggle("Keep embeddings at 8-bit", isOn: $store.recipe.preserveEmbeddings)
        Toggle("Keep output head at 8-bit", isOn: $store.recipe.preserveOutputHead)
        if store.contentMode == .live {
          Text(
            "Per-tensor protection requires measured mixed-precision evidence and is unavailable in this beta."
          )
          .font(.system(size: 10))
          .foregroundStyle(WorkshopTheme.quietInk)
        }
      }
      .disabled(store.contentMode == .live)
    }
  }

  private var expertControls: some View {
    VStack(alignment: .leading, spacing: WorkshopTheme.spaceM) {
      if store.contentMode == .live {
        Label(
          "Public beta: uniform MXFP4, MXFP8, and affine quantization only",
          systemImage: "checkmark.shield"
        )
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(WorkshopTheme.skyBright)
      }
      if let layer = store.selectedLayer {
        VStack(alignment: .leading, spacing: WorkshopTheme.spaceXS) {
          HStack {
            Image(systemName: "scope")
              .foregroundStyle(WorkshopTheme.skyBright)
            Text("Selected module")
              .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text("L\(layer.index)")
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .foregroundStyle(WorkshopTheme.quietInk)
          }
          Text(layer.name)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
          Text(
            "KL +\(layer.klDelta, specifier: "%.3f") · sensitivity \(Int(layer.sensitivity * 100))% · \(layer.precision.title)"
          )
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(WorkshopTheme.secondaryInk)
        }
        .padding(WorkshopTheme.spaceS)
        .background(
          WorkshopTheme.surface,
          in: RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous).stroke(
            WorkshopTheme.divider, lineWidth: 1))
      }

      InspectorSection(title: "Allocation") {
        LabeledContent("Strategy") {
          Picker("Strategy", selection: $store.recipe.allocationStrategy) {
            Text("Uniform").tag(OptimizationAllocationStrategy.uniform)
            Text("Mixed precision").tag(OptimizationAllocationStrategy.mixedPrecision)
          }
          .labelsHidden()
          .frame(maxWidth: 170)
          .disabled(store.contentMode == .live)
        }
        LabeledContent("Quantization") {
          Picker("Quantization", selection: quantizationMode) {
            Text("MXFP4").tag("mxfp4")
            Text("MXFP8").tag("mxfp8")
            Text("Affine 4-bit").tag("affine")
          }
          .labelsHidden()
          .frame(maxWidth: 170)
        }
        LabeledContent("Target BPW") {
          Stepper(value: $store.recipe.targetBPW, in: 3.5...8.0, step: 0.05) {
            Text(store.recipe.targetBPW, format: .number.precision(.fractionLength(2)))
              .monospacedDigit()
          }
          .frame(width: 126)
          .disabled(store.contentMode == .live)
        }
        if store.recipe.allocationStrategy == .mixedPrecision {
          labeledSlider(
            "KL tolerance", value: $store.recipe.klTolerance, range: 0.02...0.50,
            trailing: String(format: "%.2f", store.recipe.klTolerance))
        }
        Toggle("Use per-module overrides", isOn: $store.recipe.perModuleOverrides)
          .disabled(store.contentMode == .live)
      }

      InspectorSection(title: "Calibration") {
        TextField("Calibration suite", text: $store.recipe.calibrationSuite)
          .textFieldStyle(.roundedBorder)
        LabeledContent("Samples") {
          Stepper(value: $store.recipe.calibrationSampleBudget, in: 0...10_000, step: 8) {
            Text("\(store.recipe.calibrationSampleBudget)")
              .monospacedDigit()
          }
          .frame(width: 126)
        }
        LabeledContent("Token budget") {
          Stepper(
            value: $store.recipe.calibrationTokenBudget, in: 0...10_000_000, step: 1_024
          ) {
            Text("\(store.recipe.calibrationTokenBudget)")
              .monospacedDigit()
          }
          .frame(width: 126)
        }
        LabeledContent("Reference", value: store.model?.displayName ?? "Not inspected")
        LabeledContent(
          "Metric", value: store.contentMode == .demo ? "Forward KL (demo)" : "Not planned")
      }
      .disabled(store.contentMode == .live)

      InspectorSection(title: "Protected tensors") {
        Toggle("Embedding table", isOn: $store.recipe.preserveEmbeddings)
        Toggle("Output projection", isOn: $store.recipe.preserveOutputHead)
        Toggle("Residual writers above threshold", isOn: $store.recipe.protectSensitiveLayers)
        LabeledContent("Expected protected", value: "\(store.protectedCount) modules")
      }
      .disabled(store.contentMode == .live)

      InspectorSection(title: "Promotion gates") {
        if let gates = store.currentRun?.plan?.requiredGates {
          ForEach(gates, id: \.self) { gate in
            Label(gate, systemImage: "circle.dashed")
          }
        } else {
          Text(
            store.contentMode == .demo
              ? "Representative thresholds: zero critical schema errors, parent-relative capability, and a declared performance gate."
              : "Promotion gates will be disclosed from the verified plan; the interface does not invent defaults."
          )
        }
      }
    }
  }

  private func verifiedPlan(_ plan: PlanDisclosure) -> some View {
    InspectorSection(title: "Verified plan", detail: "\(plan.evidenceKind) · \(plan.feasibility)") {
      LabeledContent("Parent", value: URL(fileURLWithPath: plan.exactParent).lastPathComponent)
        .help(plan.exactParent)
      LabeledContent("Output estimate", value: bytes(plan.estimatedOutputBytes))
      LabeledContent("Temporary estimate", value: bytes(plan.estimatedTemporaryBytes))
      LabeledContent("Required free disk", value: bytes(plan.requiredFreeDiskBytes))
      LabeledContent("Observed free disk", value: bytes(plan.observedFreeDiskBytes))
      LabeledContent("Peak memory estimate", value: bytes(plan.estimatedPeakMemoryBytes))
      LabeledContent("Time budget", value: duration(plan.timeBudgetSeconds))
      LabeledContent(
        "Duration estimate",
        value: plan.estimatedDurationSeconds.map(duration) ?? "Unknown — review required")
      Text(plan.uncertainty)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(WorkshopTheme.quietInk)
      ForEach(plan.reasonCodes, id: \.self) { reason in
        Label(reason, systemImage: "exclamationmark.triangle")
          .foregroundStyle(WorkshopTheme.warning)
      }
      ForEach(plan.blockers, id: \.code) { blocker in
        Label(blocker.message, systemImage: "exclamationmark.octagon.fill")
          .foregroundStyle(WorkshopTheme.danger)
          .help(blocker.code)
      }
    }
  }

  @ViewBuilder
  private var commandDisclosure: some View {
    if let command = store.currentRun?.command {
      VStack(alignment: .leading, spacing: WorkshopTheme.spaceXS) {
        ForEach(Array(command.commands.enumerated()), id: \.offset) { commandIndex, item in
          if command.commands.count > 1 {
            Text("Command \(commandIndex + 1)")
              .foregroundStyle(WorkshopTheme.quietInk)
          }
          Text(item.executableIdentity)
            .fontWeight(.semibold)
          ForEach(Array(item.arguments.enumerated()), id: \.offset) { index, argument in
            Text("[\(index)]  \(argument)")
          }
          Text("Redacted display: \(item.redactedDisplay)")
          if commandIndex < command.commands.count - 1 {
            Divider().overlay(WorkshopTheme.divider)
          }
        }
      }
    } else {
      Text(
        "The coordinator has not produced an argument array yet. No command will be inferred from these controls."
      )
    }
  }

  private func labeledSlider(
    _ label: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, trailing: String
  ) -> some View {
    VStack(spacing: WorkshopTheme.spaceXXS) {
      HStack {
        Text(label)
        Spacer()
        Text(trailing)
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      .font(.system(size: 11))
      Slider(value: value, in: range)
        .tint(WorkshopTheme.sky)
    }
  }

  private var quantizationMode: Binding<String> {
    Binding(
      get: { store.recipe.requestedQuantModes.first ?? "mxfp4" },
      set: { mode in
        store.recipe.requestedQuantModes = [mode]
        if store.recipe.allocationStrategy == .uniform {
          store.recipe.targetBPW = mode == "mxfp8" ? 8 : 4
        }
      })
  }

  private func bytes(_ value: Int?) -> String {
    guard let value else { return "Unknown" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
  }

  private func duration(_ seconds: Int) -> String {
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    if hours > 0 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }
}

private struct InspectorSection<Content: View>: View {
  let title: String
  let detail: String?
  let content: Content

  init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkshopTheme.spaceS) {
      HStack {
        Text(title)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Spacer()
        if let detail {
          Text(detail)
            .font(.system(size: 10))
            .foregroundStyle(WorkshopTheme.quietInk)
        }
      }
      content
        .font(.system(size: 11))
        .foregroundStyle(WorkshopTheme.secondaryInk)
    }
  }
}
