import SwiftUI

struct WorkshopSnapshotView: View {
  var body: some View {
    HStack(spacing: 0) {
      SnapshotSidebar()
        .frame(width: 206)
      Divider().overlay(WorkshopTheme.divider)
      WorkbenchView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(WorkshopTheme.divider)
      SnapshotInspector()
        .frame(width: 318)
    }
    .background(WorkshopTheme.canvas)
  }
}

private struct SnapshotSidebar: View {
  @EnvironmentObject private var store: WorkshopStore

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 9) {
          ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WorkshopTheme.skyWash)
            Image(systemName: "cube.transparent.fill").foregroundStyle(WorkshopTheme.skyBright)
          }
          .frame(width: 28, height: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text("MLX Workshop")
              .font(.system(size: 12.5, weight: .semibold))
              .foregroundStyle(WorkshopTheme.ink)
            Text("Representative demo")
              .font(.system(size: 8.5, weight: .medium))
              .foregroundStyle(WorkshopTheme.warning)
          }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 8)

        ForEach(WorkshopSection.allCases) { section in
          Button {
            store.section = section
          } label: {
            HStack(spacing: 9) {
              Image(systemName: section.symbol)
                .frame(width: 18)
              Text(section.rawValue)
              Spacer()
              if section == .runs {
                Text("4")
                  .font(.system(size: 9, weight: .semibold, design: .rounded))
                  .foregroundStyle(WorkshopTheme.secondaryInk)
              }
            }
            .font(.system(size: 11.5, weight: section == .workbench ? .semibold : .medium))
            .foregroundStyle(section == .workbench ? WorkshopTheme.ink : WorkshopTheme.secondaryInk)
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(
              section == .workbench ? WorkshopTheme.surfaceSelected : Color.clear,
              in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(8)

      Spacer()

      VStack(alignment: .leading, spacing: 9) {
        Divider().overlay(WorkshopTheme.divider)
        HStack(spacing: 8) {
          Image(systemName: "memorychip").foregroundStyle(WorkshopTheme.sky)
          VStack(alignment: .leading, spacing: 2) {
            Text("M3 Ultra · 64 GiB")
              .font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(WorkshopTheme.ink)
            Text("26.1 GiB available")
              .font(.system(size: 9.5))
              .foregroundStyle(WorkshopTheme.secondaryInk)
          }
          Spacer()
          Circle().fill(WorkshopTheme.success).frame(width: 7, height: 7)
        }
        Label("Host details", systemImage: "slider.horizontal.3")
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      .padding(12)
    }
    .background(WorkshopTheme.chrome)
  }
}

private struct SnapshotInspector: View {
  @EnvironmentObject private var store: WorkshopStore

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Optimization recipe")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text("Balanced mixed precision")
            .font(.system(size: 10.5))
            .foregroundStyle(WorkshopTheme.secondaryInk)
        }
        Spacer()
        Image(systemName: "xmark").foregroundStyle(WorkshopTheme.secondaryInk)
      }
      .padding(14)

      HStack(spacing: 2) {
        Text("Easy")
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
          .background(WorkshopTheme.sky, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        Text("Expert")
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .font(.system(size: 10.5, weight: .semibold))
      .padding(3)
      .background(WorkshopTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(
          WorkshopTheme.divider, lineWidth: 1)
      )
      .padding(.horizontal, 14)
      .padding(.bottom, 12)

      Divider().overlay(WorkshopTheme.divider)

      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 7) {
          Label("Representative demo recipe", systemImage: "theatermasks")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(WorkshopTheme.skyBright)
          Text(
            "Illustrative 4/8-bit allocation for interface review. These values are not local measurements."
          )
          .font(.system(size: 10.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
          WorkshopTheme.skyWash, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(
            WorkshopTheme.sky.opacity(0.32), lineWidth: 1))

        snapshotSection("Priorities") {
          sliderRow("Fidelity", value: 0.78, detail: "High")
          sliderRow("Smaller artifact", value: 0.58, detail: "Balanced")
        }

        snapshotSection("Workload") {
          valueRow("Calibration", "Agent + code")
          valueRow("Context target", "32K")
        }

        snapshotSection("Safeguards") {
          checkRow("Protect sensitive layers")
          checkRow("Keep embeddings at 8-bit")
          checkRow("Keep output head at 8-bit")
        }

        snapshotSection("Estimate") {
          valueRow("Target", "4.65 BPW")
          valueRow("Candidates", "9")
          valueRow("Time budget", "2h 40m")
        }

        Spacer()
      }
      .padding(14)

      Divider().overlay(WorkshopTheme.divider)
      VStack(spacing: 8) {
        Button {
          store.requestRunAction()
        } label: {
          Label("Run this recipe", systemImage: "play.fill")
        }
        .buttonStyle(PrimaryActionButtonStyle())
        Button {
          store.section = .compare
        } label: {
          Label("Compare candidates", systemImage: "arrow.left.arrow.right")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButtonStyle())
      }
      .padding(14)
    }
    .background(WorkshopTheme.chrome)
  }

  private func snapshotSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 9) {
      Text(title)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      content()
    }
  }

  private func sliderRow(_ title: String, value: Double, detail: String) -> some View {
    VStack(spacing: 5) {
      HStack {
        Text(title)
        Spacer()
        Text(detail).foregroundStyle(WorkshopTheme.secondaryInk)
      }
      .font(.system(size: 10.5))
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(WorkshopTheme.surfaceRaised).frame(height: 4)
          Capsule().fill(WorkshopTheme.sky).frame(width: proxy.size.width * value, height: 4)
          Circle().fill(WorkshopTheme.ink).frame(width: 10, height: 10).offset(
            x: max(0, proxy.size.width * value - 5))
        }
      }
      .frame(height: 10)
    }
  }

  private func valueRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(WorkshopTheme.secondaryInk)
      Spacer()
      Text(value).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(
        WorkshopTheme.ink)
    }
    .font(.system(size: 10.5))
  }

  private func checkRow(_ title: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.square.fill").foregroundStyle(WorkshopTheme.sky)
      Text(title).foregroundStyle(WorkshopTheme.secondaryInk)
    }
    .font(.system(size: 10.5))
  }
}
