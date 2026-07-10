import SwiftUI

struct SensitivityAtlasView: View {
  @EnvironmentObject private var store: WorkshopStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.layers.isEmpty ? "Create an optimized copy" : "Sensitivity Atlas")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text(
            store.layers.isEmpty
              ? "Choose a supported format; the original model always stays unchanged"
              : "Measured KL response for each candidate precision"
          )
          .font(.system(size: 11))
          .foregroundStyle(WorkshopTheme.secondaryInk)
        }
        Spacer()
        if store.layers.isEmpty {
          StatusPill(
            text: "Supported beta path", symbol: "checkmark.shield", color: WorkshopTheme.sky)
        } else {
          StatusPill(
            text: "\(store.eightBitCount) at 8-bit", symbol: "shield.lefthalf.filled",
            color: WorkshopTheme.sky)
          StatusPill(
            text: "\(store.protectedCount) protected", symbol: "lock.fill",
            color: WorkshopTheme.secondaryInk)
        }
        Button {
          store.expertMode.toggle()
          store.showInspector = true
        } label: {
          Label("Adjust settings", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("workbench.editRecipe")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 11)

      if store.layers.isEmpty {
        ContentUnavailableView {
          Label("Ready to create a smaller copy", systemImage: "shippingbox.and.arrow.forward")
        } description: {
          Text(
            "Choose a format in Settings, then review the plan. You will see disk and memory estimates before confirming anything."
          )
        } actions: {
          Button("Adjust settings") {
            store.showInspector = true
          }
          .accessibilityIdentifier("workbench.empty.editRecipe")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        tableHeader
        Divider().overlay(WorkshopTheme.divider)

        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.layers) { layer in
              layerRow(layer)
              Divider()
                .overlay(WorkshopTheme.divider.opacity(0.58))
                .padding(.leading, 14)
            }
          }
        }
        .scrollIndicators(.visible)
      }

      HStack(spacing: 16) {
        Label(
          store.layers.isEmpty
            ? "The exact parent remains read-only" : "Higher sensitivity stays at 8-bit",
          systemImage: "info.circle")
        Text("Selected recipe: \(store.recipeName)")
        Spacer()
        Text(
          store.layers.isEmpty
            ? "A finished copy still needs verification"
            : "Target \(store.recipe.targetBPW, specifier: "%.2f") BPW"
        )
        .monospacedDigit()
      }
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(WorkshopTheme.quietInk)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(WorkshopTheme.surface)
    }
  }

  private var tableHeader: some View {
    HStack(spacing: 12) {
      Text("Layer / module").frame(width: 232, alignment: .leading)
      Text("Sensitivity").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
      Text("Precision").frame(width: 116, alignment: .leading)
      Text("Size Δ").frame(width: 58, alignment: .trailing)
      Text("KL Δ").frame(width: 58, alignment: .trailing)
      Text("Guard").frame(width: 42, alignment: .center)
    }
    .font(.system(size: 10.5, weight: .semibold))
    .foregroundStyle(WorkshopTheme.secondaryInk)
    .padding(.horizontal, 16)
    .padding(.vertical, 7)
    .background(WorkshopTheme.surfaceRaised.opacity(0.62))
  }

  private func layerRow(_ layer: LayerRecord) -> some View {
    let isSelected = store.selectedLayerID == layer.id
    return HStack(spacing: 12) {
      HStack(spacing: 9) {
        Text(layer.index == 40 ? "OUT" : "L\(layer.index)")
          .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(isSelected ? WorkshopTheme.skyBright : WorkshopTheme.quietInk)
          .frame(width: 30, alignment: .trailing)
        VStack(alignment: .leading, spacing: 1) {
          Text(layer.name)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(WorkshopTheme.ink)
            .lineLimit(1)
          Text(layer.kind)
            .font(.system(size: 9.5))
            .foregroundStyle(WorkshopTheme.quietInk)
            .lineLimit(1)
        }
      }
      .frame(width: 232, alignment: .leading)

      SensitivityStrip(value: layer.sensitivity, isSelected: isSelected)
        .frame(minWidth: 150, maxWidth: .infinity)

      HStack(spacing: 4) {
        precisionButton(.four, layer: layer)
        precisionButton(.eight, layer: layer)
      }
      .frame(width: 116, alignment: .leading)

      Text(String(format: "%.1f%%", layer.sizeDelta))
        .frame(width: 58, alignment: .trailing)
        .foregroundStyle(layer.sizeDelta < 0 ? WorkshopTheme.success : WorkshopTheme.secondaryInk)
      Text(String(format: "+%.3f", layer.klDelta))
        .frame(width: 58, alignment: .trailing)
        .foregroundStyle(layer.klDelta > 0.065 ? WorkshopTheme.warning : WorkshopTheme.secondaryInk)

      Button {
        store.toggleProtection(for: layer.id)
      } label: {
        Image(systemName: layer.isProtected ? "lock.fill" : "lock.open")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(layer.isProtected ? WorkshopTheme.skyBright : WorkshopTheme.quietInk)
          .frame(width: 28, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(width: 42)
      .help(layer.isProtected ? "Remove protection" : "Protect at 8-bit")
      .accessibilityLabel(
        layer.isProtected
          ? "Remove protection from \(layer.name)" : "Protect \(layer.name) at 8-bit")
    }
    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
    .monospacedDigit()
    .padding(.horizontal, 16)
    .padding(.vertical, 5)
    .background(isSelected ? WorkshopTheme.surfaceSelected : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { store.selectedLayerID = layer.id }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "Layer \(layer.index), \(layer.name), sensitivity \(Int(layer.sensitivity * 100)) percent, \(layer.precision.title)\(layer.isProtected ? ", protected" : "")"
    )
  }

  private func precisionButton(_ precision: Precision, layer: LayerRecord) -> some View {
    let isActive = layer.precision == precision
    return Button {
      store.setPrecision(precision, for: layer.id)
    } label: {
      Text("\(precision.rawValue)")
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(isActive ? .white : WorkshopTheme.secondaryInk)
        .frame(width: 34, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isActive ? WorkshopTheme.sky : WorkshopTheme.surfaceRaised)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(
              isActive ? WorkshopTheme.skyBright.opacity(0.75) : WorkshopTheme.divider, lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .disabled(layer.isProtected && precision == .four)
    .opacity(layer.isProtected && precision == .four ? 0.42 : 1)
    .help(
      layer.isProtected && precision == .four
        ? "Protected modules remain at 8-bit" : "Set \(precision.title)"
    )
    .accessibilityLabel("Set \(layer.name) to \(precision.title)")
    .accessibilityHint(
      layer.isProtected && precision == .four
        ? "Unavailable because this module is protected" : "Changes this recipe's module precision")
  }
}

private struct SensitivityStrip: View {
  let value: Double
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<18, id: \.self) { index in
        let threshold = Double(index + 1) / 18.0
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(threshold <= value ? activeColor(index: index) : WorkshopTheme.surfaceRaised)
          .frame(height: 12)
      }
    }
    .overlay(alignment: .trailing) {
      Text("\(Int(value * 100))")
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .padding(.leading, 5)
        .background(WorkshopTheme.canvas.opacity(0.92))
        .offset(x: 28)
    }
    .padding(.trailing, 30)
  }

  private func activeColor(index: Int) -> Color {
    let base = isSelected ? WorkshopTheme.skyBright : WorkshopTheme.sky
    return base.opacity(0.42 + Double(index) / 31.0)
  }
}
