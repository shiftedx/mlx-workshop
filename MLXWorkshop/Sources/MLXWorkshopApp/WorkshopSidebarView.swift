import SwiftUI

struct WorkshopSidebarView: View {
  @EnvironmentObject private var store: WorkshopStore

  var body: some View {
    VStack(spacing: 0) {
      List(store.availableSections, selection: $store.section) { section in
        Label(section.rawValue, systemImage: section.symbol)
          .font(.system(size: 13, weight: section == store.section ? .semibold : .regular))
          .tag(section)
          .accessibilityIdentifier("sidebar.\(section.id)")
          .accessibilityHint("Show \(section.rawValue)")
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)

      VStack(alignment: .leading, spacing: 10) {
        Divider().overlay(WorkshopTheme.divider)
        HStack(spacing: 9) {
          Image(systemName: "memorychip")
            .foregroundStyle(WorkshopTheme.sky)
          VStack(alignment: .leading, spacing: 2) {
            Text(
              store.hostSnapshot.map { "\($0.chip) · \($0.unifiedMemory)" } ?? "Host not measured"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
            Text(
              store.hostSnapshot?.availableMemory.map { "\($0) available" }
                ?? "Collect a host baseline"
            )
            .font(.system(size: 10))
            .foregroundStyle(WorkshopTheme.secondaryInk)
          }
          Spacer()
          Image(systemName: store.hostSnapshot == nil ? "questionmark.circle" : "doc.text")
            .foregroundStyle(store.hostSnapshot == nil ? WorkshopTheme.quietInk : WorkshopTheme.sky)
            .accessibilityLabel(
              store.hostSnapshot == nil ? "Host baseline unavailable" : "Host baseline recorded")
        }

        Button {
          store.section = .host
        } label: {
          Label("Host details", systemImage: "slider.horizontal.3")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      }
      .padding(12)
      .background(WorkshopTheme.chrome)
    }
    .background(WorkshopTheme.chrome)
  }
}
