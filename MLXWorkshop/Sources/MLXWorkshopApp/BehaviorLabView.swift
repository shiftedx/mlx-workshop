import SwiftUI

struct BehaviorLabView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var editStrength = 1.0
  @State private var selectedLayers = 8
  @State private var preserveNorms = true
  @State private var selectedDataset = "Held-out"

  var body: some View {
    VStack(spacing: 0) {
      behaviorHeader
      Divider().overlay(WorkshopTheme.divider)

      if store.behaviorCategories.isEmpty {
        ContentUnavailableView {
          Label("No behavior-editing evidence", systemImage: "waveform.path.ecg.rectangle")
        } description: {
          Text(
            "Behavior editing appears only when inspection selects a validated architecture adapter and the workflow records separated discovery, tuning, benign-control, and held-out evidence."
          )
        } actions: {
          Button("Inspect recipe") { store.showInspector = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            datasetRail
            Divider().overlay(WorkshopTheme.divider)

            HStack(alignment: .top, spacing: 0) {
              directionPanel
                .frame(maxWidth: .infinity)
              Divider().overlay(WorkshopTheme.divider)
              editControls
                .frame(width: 288)
            }

            Divider().overlay(WorkshopTheme.divider)
            resultTable
          }
        }
      }
    }
    .background(WorkshopTheme.canvas)
    .navigationTitle("Behavior Lab")
  }

  private var behaviorHeader: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 9) {
          Text("Behavior Lab")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          StatusPill(
            text: store.contentMode == .demo ? "Demo evidence" : "Measured edit",
            symbol: "waveform.path.ecg",
            color: store.contentMode == .demo ? WorkshopTheme.warning : WorkshopTheme.sky)
        }
        Text("Reduce measured refusals while preserving benign behavior and capability.")
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      Spacer()
      Button {
        store.showInspector = true
        store.expertMode = true
      } label: {
        Label("Inspect exact recipe", systemImage: "doc.text.magnifyingglass")
      }
      .buttonStyle(QuietButtonStyle())
    }
    .padding(18)
    .background(WorkshopTheme.surface)
  }

  private var datasetRail: some View {
    HStack(spacing: 0) {
      datasetStage(
        "Discovery", "24 refusal · 24 benign", symbol: "scope", state: "Complete",
        color: WorkshopTheme.success)
      connector
      datasetStage(
        "Tuning", "5 strengths · 3 layer sets", symbol: "slider.horizontal.3", state: "Complete",
        color: WorkshopTheme.success)
      connector
      datasetStage(
        "Held-out", "12 refusal · 12 benign", symbol: "lock.shield", state: "Sealed",
        color: WorkshopTheme.warning)
      connector
      datasetStage(
        "Qualification", "Capability + vision + schemas", symbol: "checkmark.seal",
        state: "Pending", color: WorkshopTheme.secondaryInk)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(WorkshopTheme.chrome)
  }

  private func datasetStage(
    _ title: String, _ detail: String, symbol: String, state: String, color: Color
  ) -> some View {
    HStack(spacing: 9) {
      ZStack {
        Circle().fill(color.opacity(0.13))
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(color)
      }
      .frame(width: 30, height: 30)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text(state)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
        }
        Text(detail)
          .font(.system(size: 9.5))
          .foregroundStyle(WorkshopTheme.quietInk)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var connector: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(WorkshopTheme.quietInk)
      .padding(.horizontal, 8)
  }

  private var directionPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Refusal-direction separation")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text("Completion-position mean difference · projected against benign activations")
            .font(.system(size: 10.5))
            .foregroundStyle(WorkshopTheme.secondaryInk)
        }
        Spacer()
        StatusPill(
          text: "8 selected layers", symbol: "selection.pin.in.out", color: WorkshopTheme.sky)
      }

      DirectionLayerPlot(selectedCount: selectedLayers)
        .frame(height: 232)

      HStack(spacing: 16) {
        Label("Selected layers 11, 14–19, 21", systemImage: "checkmark.circle.fill")
        Label("Unit norm", systemImage: "ruler")
        Label("Zero discovery overlap", systemImage: "rectangle.split.3x1")
        Spacer()
      }
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(WorkshopTheme.secondaryInk)
    }
    .padding(18)
  }

  private var editControls: some View {
    VStack(alignment: .leading, spacing: 17) {
      PanelHeader(title: "Candidate edit", detail: "Quant-native")

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Strength")
          Spacer()
          Text(editStrength, format: .number.precision(.fractionLength(2)))
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
        }
        Slider(value: $editStrength, in: 0.25...2.5, step: 0.25)
          .tint(WorkshopTheme.sky)
      }

      Stepper("Selected layers: \(selectedLayers)", value: $selectedLayers, in: 1...16)
      Toggle("Preserve column norms", isOn: $preserveNorms)

      VStack(alignment: .leading, spacing: 8) {
        Text("Target modules")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        moduleTarget("Attention output", count: 40, enabled: true)
        moduleTarget("Shared-expert down", count: 40, enabled: true)
        moduleTarget("Switch-expert down", count: 40, enabled: true)
        moduleTarget("Output head", count: 1, enabled: false)
      }

      Divider().overlay(WorkshopTheme.divider)
      LabeledContent("Expected edits", value: "120")
      LabeledContent("Parent", value: "MXFP4 quant")
      LabeledContent("Output", value: "New candidate")

      Spacer(minLength: 8)
      Button {
        store.requestRunAction()
      } label: {
        Label("Build behavior candidate", systemImage: "hammer.fill")
      }
      .buttonStyle(PrimaryActionButtonStyle())
      .disabled(!store.canStartRun)
    }
    .font(.system(size: 11))
    .foregroundStyle(WorkshopTheme.secondaryInk)
    .padding(18)
    .background(WorkshopTheme.surface)
  }

  private func moduleTarget(_ name: String, count: Int, enabled: Bool) -> some View {
    HStack {
      Image(systemName: enabled ? "checkmark.square.fill" : "square")
        .foregroundStyle(enabled ? WorkshopTheme.sky : WorkshopTheme.quietInk)
      Text(name)
      Spacer()
      Text("\(count)")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(WorkshopTheme.quietInk)
    }
  }

  private var resultTable: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Held-out behavior preview")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text(
            store.contentMode == .demo
              ? "Representative demo data · not a local measurement"
              : "Recorded holdout evidence from the run journal"
          )
          .font(.system(size: 10.5))
          .foregroundStyle(WorkshopTheme.quietInk)
        }
        Spacer()
        Picker("Dataset", selection: $selectedDataset) {
          Text("Discovery").tag("Discovery")
          Text("Tuning").tag("Tuning")
          Text("Held-out").tag("Held-out")
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
      }
      .padding(16)

      HStack(spacing: 12) {
        Text("Category").frame(width: 170, alignment: .leading)
        Text("Parent refusal").frame(width: 116, alignment: .trailing)
        Text("Candidate refusal").frame(width: 126, alignment: .trailing)
        Text("Change").frame(width: 84, alignment: .trailing)
        Text("Samples").frame(width: 72, alignment: .trailing)
        Spacer()
      }
      .font(.system(size: 10.5, weight: .semibold))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(WorkshopTheme.surfaceRaised.opacity(0.66))

      ForEach(store.behaviorCategories) { category in
        behaviorRow(category)
      }
    }
    .padding(.bottom, 18)
  }

  private func behaviorRow(_ category: BehaviorCategory) -> some View {
    let change = category.candidateRate - category.parentRate
    let isBenign = category.name == "Benign controls"
    let pass = isBenign ? abs(change) < 0.05 : change < -0.4
    return HStack(spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: pass ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(pass ? WorkshopTheme.success : WorkshopTheme.warning)
        Text(category.name)
          .foregroundStyle(WorkshopTheme.ink)
      }
      .frame(width: 170, alignment: .leading)
      Text(category.parentRate, format: .percent.precision(.fractionLength(0))).frame(
        width: 116, alignment: .trailing)
      Text(category.candidateRate, format: .percent.precision(.fractionLength(0))).frame(
        width: 126, alignment: .trailing)
      Text(change, format: .percent.precision(.fractionLength(0)))
        .foregroundStyle(pass ? WorkshopTheme.success : WorkshopTheme.warning)
        .frame(width: 84, alignment: .trailing)
      Text("\(category.sampleCount)").frame(width: 72, alignment: .trailing)
      Spacer()
    }
    .font(.system(size: 11, weight: .medium, design: .monospaced))
    .monospacedDigit()
    .foregroundStyle(WorkshopTheme.secondaryInk)
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) { Divider().overlay(WorkshopTheme.divider.opacity(0.60)) }
  }
}

private struct DirectionLayerPlot: View {
  let selectedCount: Int
  private let values: [Double] = (0..<40).map { index in
    let wave = abs(sin(Double(index) * 0.62)) * 0.48
    let middleLift = (index > 10 && index < 23) ? 0.28 : 0.0
    return 0.12 + wave + middleLift
  }

  var body: some View {
    GeometryReader { proxy in
      HStack(alignment: .bottom, spacing: 3) {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
          let selected = [11, 14, 15, 16, 17, 18, 19, 21].prefix(selectedCount).contains(index)
          VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(selected ? WorkshopTheme.skyBright : WorkshopTheme.surfaceRaised)
              .frame(height: max(8, proxy.size.height * value * 0.82))
            Text(index % 5 == 0 ? "\(index)" : "")
              .font(.system(size: 8, design: .monospaced))
              .foregroundStyle(WorkshopTheme.quietInk)
              .frame(height: 10)
          }
          .frame(maxWidth: .infinity, alignment: .bottom)
        }
      }
      .overlay(alignment: .bottom) {
        Rectangle().fill(WorkshopTheme.divider).frame(height: 1).offset(y: -14)
      }
    }
    .accessibilityLabel(
      "Layer direction scores with eight selected layers: 11, 14, 15, 16, 17, 18, 19, and 21")
  }
}
