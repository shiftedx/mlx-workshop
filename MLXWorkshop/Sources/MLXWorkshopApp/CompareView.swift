import SwiftUI

struct CompareView: View {
  @EnvironmentObject private var store: WorkshopStore

  var body: some View {
    VStack(spacing: 0) {
      compareHeader
      Divider().overlay(WorkshopTheme.divider)

      if store.candidates.isEmpty {
        ContentUnavailableView {
          Label("No measured candidates", systemImage: "arrow.left.arrow.right")
        } description: {
          Text(
            "Candidate comparison appears only after the workflow reports parent-relative measurements."
          )
        } actions: {
          Button("Return to workbench") { store.section = .workbench }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          candidateList.frame(width: 250)
          Divider().overlay(WorkshopTheme.divider)
          comparisonDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .background(WorkshopTheme.canvas)
    .navigationTitle("Compare")
  }

  private var compareHeader: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Candidate comparison")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text("Parent-relative evidence under the recorded runtime and frozen suite.")
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      Spacer()
      StatusPill(
        text: "\(store.candidates.count) measured", symbol: "circle.grid.2x2.fill",
        color: WorkshopTheme.sky)
      Button {
        store.section = .workbench
      } label: {
        Label("Adjust recipe", systemImage: "slider.horizontal.3")
      }
      .buttonStyle(QuietButtonStyle())
    }
    .padding(18)
    .background(WorkshopTheme.surface)
  }

  private var candidateList: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Lineage")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

      ScrollView {
        LazyVStack(spacing: 3) {
          ForEach(store.candidates) { candidate in
            Button {
              store.selectedCandidateID = candidate.id
            } label: {
              candidateRow(candidate)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
      }

      Divider().overlay(WorkshopTheme.divider)
      HStack(spacing: 7) {
        Image(systemName: "arrow.triangle.branch")
        Text("All candidates descend from the same immutable parent.")
      }
      .font(.system(size: 10))
      .foregroundStyle(WorkshopTheme.quietInk)
      .padding(12)
    }
    .background(WorkshopTheme.chrome)
  }

  private func candidateRow(_ candidate: CandidateRecord) -> some View {
    let selected = store.selectedCandidateID == candidate.id
    return HStack(spacing: 10) {
      VStack(spacing: 0) {
        Circle()
          .fill(candidate.status.color)
          .frame(width: 7, height: 7)
        Rectangle()
          .fill(WorkshopTheme.divider)
          .frame(width: 1, height: 38)
          .opacity(candidate.id == store.candidates.last?.id ? 0 : 1)
      }
      .frame(width: 10)

      VStack(alignment: .leading, spacing: 3) {
        Text(candidate.name)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text(candidate.recipe)
          .font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .lineLimit(1)
        HStack(spacing: 8) {
          Text("\(candidate.sizeGB, specifier: "%.1f") GB")
          Text("\(candidate.throughput, specifier: "%.1f") tok/s")
        }
        .font(.system(size: 9.5, weight: .medium, design: .rounded))
        .foregroundStyle(WorkshopTheme.quietInk)
        .monospacedDigit()
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 9)
    .padding(.top, 8)
    .background(
      selected ? WorkshopTheme.surfaceSelected : Color.clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .contentShape(Rectangle())
  }

  private var comparisonDetail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 0) {
          CandidateParetoPlot(candidates: store.candidates, selected: store.selectedCandidateID)
            .frame(minHeight: 300)
            .padding(18)
          Divider().overlay(WorkshopTheme.divider)
          selectedSummary
            .frame(width: 270)
            .padding(18)
        }

        Divider().overlay(WorkshopTheme.divider)
        if store.contentMode == .demo {
          evidenceTable
        } else {
          ContentUnavailableView(
            "Gate details unavailable", systemImage: "checklist",
            description: Text(
              "Raw promotion-gate records have not been projected for this candidate.")
          )
          .padding(24)
        }
      }
    }
  }

  private var selectedSummary: some View {
    let candidate = store.selectedCandidate ?? store.candidates[0]
    return VStack(alignment: .leading, spacing: 17) {
      PanelHeader(title: candidate.name, detail: candidate.status.rawValue)
      Text(
        store.contentMode == .demo ? "Representative demo candidate" : "Recorded candidate evidence"
      )
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(WorkshopTheme.ink)

      VStack(spacing: 10) {
        summaryMetric(
          "Artifact", String(format: "%.1f GB", candidate.sizeGB), "Recorded size",
          WorkshopTheme.secondaryInk)
        summaryMetric(
          "Decode", String(format: "%.1f tok/s", candidate.throughput), "Recorded throughput",
          WorkshopTheme.skyBright)
        summaryMetric(
          "Validation KL", String(format: "+%.2f", candidate.kl), "Parent-relative",
          WorkshopTheme.secondaryInk)
        summaryMetric(
          "Frozen suite", "\(candidate.score)/65",
          "\(candidate.criticalRegressions) critical errors",
          candidate.criticalRegressions == 0 ? WorkshopTheme.secondaryInk : WorkshopTheme.danger)
      }

      Spacer(minLength: 10)
      Button {
        store.section = .runs
      } label: {
        Label("Promote this candidate", systemImage: "checkmark.seal.fill")
      }
      .buttonStyle(PrimaryActionButtonStyle())
      .disabled(candidate.status != .qualified)

      Text(
        candidate.status == .qualified
          ? "Promotion creates a staged copy and preserves the parent."
          : "Resolve critical gates before promotion."
      )
      .font(.system(size: 9.5))
      .foregroundStyle(WorkshopTheme.quietInk)
    }
  }

  private func summaryMetric(_ label: String, _ value: String, _ detail: String, _ color: Color)
    -> some View
  {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(WorkshopTheme.quietInk)
        Text(detail)
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(color)
      }
      Spacer()
      Text(value)
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .foregroundStyle(WorkshopTheme.ink)
        .monospacedDigit()
    }
  }

  private var evidenceTable: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Representative qualification evidence")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Spacer()
        Text("Demo data · not measured on this launch")
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(WorkshopTheme.quietInk)
      }
      .padding(16)

      evidenceRow(
        "Structure and load", "Pass", "1,325 tensors · strict load", WorkshopTheme.success)
      evidenceRow("Tool and JSON schemas", "Pass", "12/12 critical cases", WorkshopTheme.success)
      evidenceRow("Code capability", "Pass", "3/3 smoke · 19/20 held-out", WorkshopTheme.success)
      evidenceRow("Long context", "Pass", "32K retrieval · 31.8 GiB peak", WorkshopTheme.success)
      evidenceRow(
        "Vision", "Pending", "Run multi-image parity before release", WorkshopTheme.warning)
      evidenceRow(
        "Sustained performance", "Pass", "68.2 tok/s · no thermal falloff", WorkshopTheme.success)
    }
    .padding(.bottom, 18)
  }

  private func evidenceRow(_ name: String, _ status: String, _ detail: String, _ color: Color)
    -> some View
  {
    HStack(spacing: 14) {
      Image(systemName: status == "Pass" ? "checkmark.circle.fill" : "clock.fill")
        .foregroundStyle(color)
        .frame(width: 20)
      Text(name)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(WorkshopTheme.ink)
        .frame(width: 170, alignment: .leading)
      Text(status)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 70, alignment: .leading)
      Text(detail)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(WorkshopTheme.surface.opacity(0.45))
    .overlay(alignment: .bottom) { Divider().overlay(WorkshopTheme.divider.opacity(0.6)) }
  }
}

private struct CandidateParetoPlot: View {
  let candidates: [CandidateRecord]
  let selected: CandidateRecord.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      PanelHeader(title: "Host Pareto frontier", detail: "Fidelity × size × throughput")
      GeometryReader { proxy in
        ZStack {
          plotGrid(size: proxy.size)
          frontier(size: proxy.size)
          ForEach(candidates) { candidate in
            let isSelected = candidate.id == selected
            Circle()
              .fill(isSelected ? WorkshopTheme.skyBright : candidate.status.color)
              .overlay(Circle().stroke(WorkshopTheme.ink, lineWidth: isSelected ? 2 : 0.8))
              .frame(width: isSelected ? 13 : 9, height: isSelected ? 13 : 9)
              .position(position(candidate, in: proxy.size))
              .accessibilityLabel(
                "\(candidate.name), \(candidate.sizeGB, specifier: "%.1f") gigabytes, KL \(candidate.kl, specifier: "%.2f")"
              )
          }
        }
      }
      HStack {
        Text("Smaller artifact")
        Spacer()
        Text("Larger artifact →")
      }
      .font(.system(size: 9.5, weight: .medium))
      .foregroundStyle(WorkshopTheme.quietInk)
    }
  }

  private func plotGrid(size: CGSize) -> some View {
    Path { path in
      for i in 0...4 {
        let x = size.width * CGFloat(i) / 4
        let y = size.height * CGFloat(i) / 4
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
      }
    }
    .stroke(WorkshopTheme.divider.opacity(0.58), lineWidth: 0.6)
  }

  private func frontier(size: CGSize) -> some View {
    let sorted = candidates.sorted(by: { $0.sizeGB < $1.sizeGB })
    return Path { path in
      guard let first = sorted.first else { return }
      path.move(to: position(first, in: size))
      for item in sorted.dropFirst() { path.addLine(to: position(item, in: size)) }
    }
    .stroke(
      WorkshopTheme.secondaryInk,
      style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
  }

  private func position(_ candidate: CandidateRecord, in size: CGSize) -> CGPoint {
    let x = ((candidate.sizeGB - 15) / 55).clamped(to: 0.03...0.97)
    let retention = (1 - candidate.kl / 0.35).clamped(to: 0.05...0.98)
    return CGPoint(x: x * size.width, y: (1 - retention) * size.height)
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
