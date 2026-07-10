import SwiftUI

struct WorkbenchView: View {
  @EnvironmentObject private var store: WorkshopStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
      modelHeader
      Divider().overlay(WorkshopTheme.divider)
      if let warnings = store.model?.warnings, !warnings.isEmpty {
        VStack(alignment: .leading, spacing: WorkshopTheme.spaceXS) {
          ForEach(warnings) { warning in
            Label(warning.message, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 10.5))
              .foregroundStyle(
                warning.severity == .blocker ? WorkshopTheme.danger : WorkshopTheme.warning)
          }
        }
        .padding(.horizontal, WorkshopTheme.spaceM)
        .padding(.vertical, WorkshopTheme.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkshopTheme.warning.opacity(0.08))
        .accessibilityIdentifier("workbench.inspectionWarnings")
        Divider().overlay(WorkshopTheme.divider)
      }
      SensitivityAtlasView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if store.showRunDrawer {
        Divider().overlay(WorkshopTheme.divider)
        RunDrawerView(
          onQualify: onQualify,
          onResume: onResume,
          onCancelRecovered: onCancelRecovered
        )
        .frame(height: 218)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .background(WorkshopTheme.canvas)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: store.showRunDrawer)
    .navigationTitle("MLX Workshop")
    .accessibilityIdentifier("workbench.root")
  }

  private var modelHeader: some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(WorkshopTheme.skyWash)
        Image(systemName: "cpu.fill")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(WorkshopTheme.skyBright)
      }
      .frame(width: 38, height: 38)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(store.model?.displayName ?? "Local model")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          StatusPill(text: "Inspected", symbol: "checkmark.circle", color: WorkshopTheme.sky)
        }
        Text(
          store.model?.detailLine.isEmpty == false
            ? store.model!.detailLine : "Inspection details are not available yet"
        )
        .font(.system(size: 11.5, weight: .regular))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      }

      Spacer()

      headerFact("Source", modelSize)
      headerFact("Capability", store.model?.supportSummary ?? "Unreported")
      headerFact(
        "Candidates",
        store.candidates.isEmpty ? "None measured" : "\(store.candidates.count) measured")
      headerFact("Workspace", store.runWorkspace?.lastPathComponent ?? "Not selected")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(WorkshopTheme.surface)
  }

  private var modelSize: String {
    guard let bytes = store.model?.sizeBytes else { return "Unreported" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func headerFact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .trailing, spacing: 3) {
      Text(label)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(WorkshopTheme.quietInk)
      Text(value)
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(WorkshopTheme.ink)
        .monospacedDigit()
    }
    .frame(minWidth: 72, alignment: .trailing)
  }
}
