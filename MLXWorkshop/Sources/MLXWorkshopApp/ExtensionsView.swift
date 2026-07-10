import AppKit
import SwiftUI

struct ExtensionsView: View {
  @EnvironmentObject private var store: WorkshopStore
  let onInspectMTP: @MainActor () async -> Void
  let onVisionImage: @MainActor (URL) async -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Model extensions")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(WorkshopTheme.ink)
          Text(
            "Test optional vision and multi-token prediction capabilities without changing the selected model or interrupting local servers."
          )
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
        }

        extensionCard(
          title: "Vision", symbol: "photo.on.rectangle.angled",
          advertised: store.model?.visionAdvertised == true,
          status: store.visionCheckMessage,
          explanation:
            "Choose one local image. The app runs a 64-token mlx-vlm smoke test and preserves stdout/stderr as evidence. Text-only models block before loading.",
          actionTitle: "Choose image and test",
          action: chooseVisionImage)

        extensionCard(
          title: "MTP / speculative decoding", symbol: "forward.frame.fill",
          advertised: store.model?.mtpAdvertised == true,
          status: store.mtpCheckMessage,
          explanation:
            "Runs MTPLX’s read-only compatibility inspector. It does not start, stop, tune, or reconfigure the existing MTPLX daemon.",
          actionTitle: "Check MTPLX compatibility",
          action: { Task { await onInspectMTP() } })
      }
      .padding(22)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .background(WorkshopTheme.canvas)
    .navigationTitle("Extensions")
  }

  private func extensionCard(
    title: String, symbol: String, advertised: Bool, status: String?, explanation: String,
    actionTitle: String, action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(title, systemImage: symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Spacer()
        StatusPill(
          text: advertised ? "Advertised by model" : "Not advertised",
          symbol: advertised ? "checkmark.circle" : "questionmark.circle",
          color: advertised ? WorkshopTheme.success : WorkshopTheme.secondaryInk)
      }
      Text(explanation)
        .font(.system(size: 11))
        .foregroundStyle(WorkshopTheme.secondaryInk)
      if let status {
        Label(status, systemImage: "doc.text.magnifyingglass")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(WorkshopTheme.ink)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkshopTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
      }
      Button(actionTitle, action: action)
        .buttonStyle(PrimaryActionButtonStyle())
        .disabled(store.extensionCheckPending || store.model == nil || store.runWorkspace == nil)
    }
    .padding(16)
    .background(WorkshopTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(WorkshopTheme.divider))
  }

  private func chooseVisionImage() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await onVisionImage(url) }
  }
}
