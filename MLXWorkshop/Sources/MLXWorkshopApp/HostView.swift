import SwiftUI

struct HostView: View {
  @EnvironmentObject private var store: WorkshopStore
  var onRefresh: (() async -> Void)? = nil

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(WorkshopTheme.divider)
      if let snapshot = store.hostSnapshot {
        hostContent(snapshot)
      } else {
        ContentUnavailableView {
          Label("Host baseline not collected", systemImage: "macstudio")
        } description: {
          Text(
            "Chip, memory, disk, tool versions, and active workloads appear only after the local workflow records a host snapshot."
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(WorkshopTheme.canvas)
    .navigationTitle("Host")
  }

  private var header: some View {
    HStack(spacing: 13) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(WorkshopTheme.skyWash)
        Image(systemName: "macstudio.fill")
          .font(.system(size: 20))
          .foregroundStyle(WorkshopTheme.skyBright)
      }
      .frame(width: 42, height: 42)
      VStack(alignment: .leading, spacing: 3) {
        Text("This Mac")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text(
          store.hostSnapshot.map {
            "\($0.chip) · \($0.unifiedMemory) unified memory · \($0.operatingSystem)"
          } ?? "No recorded host evidence"
        )
        .font(.system(size: 11.5))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      Spacer()
      if let onRefresh, store.contentMode == .live {
        Button {
          Task { await onRefresh() }
        } label: {
          Label("Refresh host", systemImage: "arrow.clockwise")
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("host.refresh")
      }
      if store.contentMode == .demo {
        StatusPill(text: "Demo baseline", symbol: "theatermasks", color: WorkshopTheme.warning)
      } else if store.hostSnapshot != nil {
        StatusPill(text: "Recorded", symbol: "doc.text", color: WorkshopTheme.sky)
      }
    }
    .padding(18)
    .background(WorkshopTheme.surface)
  }

  private func hostContent(_ snapshot: HostSnapshot) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 0) {
          VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "Hardware and environment")
            fact("Chip", snapshot.chip, "memorychip")
            fact("Unified memory", snapshot.unifiedMemory, "square.stack.3d.up")
            fact(
              "Available memory", snapshot.availableMemory ?? "Not reported",
              "gauge.with.dots.needle.33percent")
            fact("Free disk", snapshot.freeDisk, "internaldrive")
            fact("Operating system", snapshot.operatingSystem, "desktopcomputer")
            fact("MLX", snapshot.mlxVersion ?? "Not reported", "cube")
            fact("MLX-LM", snapshot.mlxLMVersion ?? "Not reported", "shippingbox")
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)

          Divider().overlay(WorkshopTheme.divider)

          VStack(alignment: .leading, spacing: 14) {
            PanelHeader(
              title: "Active ML workloads", detail: "\(snapshot.activeWorkloads.count) recorded")
            if snapshot.activeWorkloads.isEmpty {
              Label("No active ML workloads were recorded", systemImage: "checkmark.circle")
                .foregroundStyle(WorkshopTheme.secondaryInk)
            } else {
              ForEach(snapshot.activeWorkloads, id: \.self) { workload in
                Label(workload, systemImage: "waveform")
                  .foregroundStyle(WorkshopTheme.warning)
              }
              Text("MLX Workshop never stops an existing workload without explicit approval.")
                .font(.system(size: 10.5))
                .foregroundStyle(WorkshopTheme.secondaryInk)
            }
          }
          .font(.system(size: 11))
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider().overlay(WorkshopTheme.divider)
        VStack(alignment: .leading, spacing: 8) {
          PanelHeader(title: "Capability routing")
          Text(store.model?.supportSummary ?? "No inspected model capability report is available.")
            .font(.system(size: 11.5))
            .foregroundStyle(WorkshopTheme.secondaryInk)
          Text(
            "Unsupported tensor semantics are an adapter-required safety outcome, not a failed host."
          )
          .font(.system(size: 10.5))
          .foregroundStyle(WorkshopTheme.quietInk)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func fact(_ label: String, _ value: String, _ symbol: String) -> some View {
    HStack {
      Label(label, systemImage: symbol)
        .foregroundStyle(WorkshopTheme.secondaryInk)
      Spacer()
      Text(value)
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(WorkshopTheme.ink)
    }
    .font(.system(size: 11))
  }
}
