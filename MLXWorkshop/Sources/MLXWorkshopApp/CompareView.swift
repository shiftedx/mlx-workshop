import AppKit
import SwiftUI

struct CompareView: View {
  @EnvironmentObject private var store: WorkshopStore
  let onStage: (String) async -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(WorkshopTheme.divider)
      if store.candidates.isEmpty {
        ContentUnavailableView {
          Label("No verified candidates yet", systemImage: "arrow.left.arrow.right")
        } description: {
          Text(
            "Complete and verify a run. Its exact parent, candidate size, lineage, and gate records will appear here—unmeasured values stay visibly unmeasured."
          )
        } actions: {
          Button("Return to workbench") { store.section = .workbench }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          lineage.frame(width: 270)
          Divider().overlay(WorkshopTheme.divider)
          detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .background(WorkshopTheme.canvas)
    .navigationTitle("Compare")
  }

  private var header: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Verified comparison")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text("Parent-relative facts revalidated from immutable run evidence.")
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      Spacer()
      StatusPill(
        text: "\(store.candidates.filter { $0.status == .qualified }.count) qualified",
        symbol: "checkmark.seal.fill", color: WorkshopTheme.success)
      Button {
        store.section = .workbench
      } label: {
        Label("New recipe", systemImage: "slider.horizontal.3")
      }
      .buttonStyle(QuietButtonStyle())
    }
    .padding(18)
    .background(WorkshopTheme.surface)
  }

  private var lineage: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("LINEAGE")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(WorkshopTheme.quietInk)
        .padding(14)
      ScrollView {
        LazyVStack(spacing: 5) {
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
      Label("Every result is tied to one exact parent hash.", systemImage: "lock.shield")
        .font(.system(size: 10))
        .foregroundStyle(WorkshopTheme.quietInk)
        .padding(12)
    }
    .background(WorkshopTheme.chrome)
  }

  private func candidateRow(_ candidate: CandidateRecord) -> some View {
    let selected = store.selectedCandidateID == candidate.id
    return HStack(spacing: 10) {
      Image(systemName: candidate.status.symbol)
        .foregroundStyle(candidate.status.color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text(candidate.name)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
          .lineLimit(1)
        Text(candidate.recipe)
          .font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .lineLimit(1)
        Text(candidate.sizeGB.map { String(format: "%.2f GB", $0) } ?? "Size not measured")
          .font(.system(size: 9.5, weight: .medium, design: .rounded))
          .foregroundStyle(WorkshopTheme.quietInk)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(
      selected ? WorkshopTheme.surfaceSelected : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .contentShape(Rectangle())
    .accessibilityLabel("\(candidate.name), \(candidate.status.rawValue)")
  }

  private var detail: some View {
    let candidate = store.selectedCandidate ?? store.candidates[0]
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top) {
          PanelHeader(title: candidate.name, detail: candidate.status.rawValue)
          Spacer()
          if let directory = candidate.candidateDirectory ?? candidate.exactParent {
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([directory])
            } label: {
              Label("Show artifact", systemImage: "folder")
            }
            .buttonStyle(QuietButtonStyle())
          }
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 10)], spacing: 10) {
          fact(
            "Artifact size", candidate.sizeGB.map { String(format: "%.2f GB", $0) },
            "Filesystem bytes")
          fact(
            "Decode speed", candidate.throughput.map { String(format: "%.1f tok/s", $0) },
            "Requires a measured performance run")
          fact(
            "Validation KL", candidate.kl.map { String(format: "+%.3f", $0) },
            "Requires paired logits evidence")
          fact(
            "Frozen suite", candidate.score.map(String.init), "Requires a scored evaluation suite")
        }

        if candidate.status == .parent {
          callout(
            title: "Immutable baseline",
            detail:
              "This is the exact parent recorded by the reviewed plan. The qualification evidence verifies it was unchanged.",
            symbol: "lock.fill", color: WorkshopTheme.secondaryInk)
        } else {
          gates(candidate)
          releaseAction(candidate)
        }
      }
      .padding(20)
    }
  }

  private func fact(_ label: String, _ value: String?, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label.uppercased())
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(WorkshopTheme.quietInk)
      Text(value ?? "Not measured")
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(value == nil ? WorkshopTheme.warning : WorkshopTheme.ink)
        .monospacedDigit()
      Text(detail)
        .font(.system(size: 9.5))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
    .padding(12)
    .background(WorkshopTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(WorkshopTheme.divider))
  }

  private func gates(_ candidate: CandidateRecord) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Qualification gates")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Spacer()
        Text("\(candidate.gates.count) recorded")
          .font(.system(size: 10.5))
          .foregroundStyle(WorkshopTheme.quietInk)
      }
      .padding(.bottom, 8)

      ForEach(candidate.gates) { gate in
        HStack(spacing: 12) {
          Image(
            systemName: gate.status == "passed"
              ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
          )
          .foregroundStyle(gate.status == "passed" ? WorkshopTheme.success : WorkshopTheme.danger)
          VStack(alignment: .leading, spacing: 2) {
            Text(gate.name)
              .font(.system(size: 11.5, weight: .medium))
              .foregroundStyle(WorkshopTheme.ink)
            Text(gate.evidence.joined(separator: " · "))
              .font(.system(size: 9.5, design: .monospaced))
              .foregroundStyle(WorkshopTheme.secondaryInk)
              .lineLimit(1)
          }
          Spacer()
          Text(gate.status.capitalized)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(gate.status == "passed" ? WorkshopTheme.success : WorkshopTheme.danger)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().overlay(WorkshopTheme.divider.opacity(0.7)) }
      }
    }
    .padding(14)
    .background(WorkshopTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(WorkshopTheme.divider))
  }

  private func releaseAction(_ candidate: CandidateRecord) -> some View {
    let staged = candidate.runID.flatMap { id in
      store.runs.first(where: { $0.runID == id })?.stagedDirectory
    }
    return HStack(alignment: .center, spacing: 14) {
      callout(
        title: staged == nil ? "Ready to prepare" : "Local release prepared",
        detail: staged == nil
          ? "Creates a reference-only release record after revalidating both source artifacts. It never changes or copies the model."
          : "The immutable release record is ready to inspect and share with its referenced candidate.",
        symbol: staged == nil ? "shippingbox" : "checkmark.seal.fill",
        color: staged == nil ? WorkshopTheme.sky : WorkshopTheme.success)
      Button {
        if let staged {
          NSWorkspace.shared.activateFileViewerSelecting([staged])
        } else if let runID = candidate.runID {
          Task { await onStage(runID) }
        }
      } label: {
        Label(
          staged == nil ? "Prepare local release" : "Show release",
          systemImage: staged == nil ? "shippingbox" : "folder")
      }
      .buttonStyle(PrimaryActionButtonStyle())
      .disabled(candidate.status != .qualified || candidate.runID == nil)
    }
  }

  private func callout(title: String, detail: String, symbol: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WorkshopTheme.ink)
        Text(detail).font(.system(size: 10)).foregroundStyle(WorkshopTheme.secondaryInk)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
