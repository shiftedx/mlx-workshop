import AppKit
import SwiftUI

@main
struct MLXWorkshopApp: App {
  @StateObject private var store: WorkshopStore
  private let isDemoSnapshot: Bool
  private let snapshotOutput: String?

  init() {
    let demoArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") })
    let liveArgument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-live=") })
    isDemoSnapshot = demoArgument != nil
    if let demoArgument {
      snapshotOutput = String(demoArgument.dropFirst("--snapshot=".count))
    } else if let liveArgument {
      snapshotOutput = String(liveArgument.dropFirst("--snapshot-live=".count))
    } else {
      snapshotOutput = nil
    }
    _store = StateObject(
      wrappedValue: WorkshopStore(content: demoArgument == nil ? .live : .demo))
  }

  var body: some Scene {
    Window("MLX Workshop", id: "main") {
      Group {
        if isDemoSnapshot {
          WorkshopSnapshotView()
        } else {
          WorkshopRootView()
        }
      }
      .environmentObject(store)
      .preferredColorScheme(.dark)
      .frame(minWidth: 1_180, minHeight: 720)
      .task {
        await renderSnapshotIfRequested()
      }
    }
    .defaultSize(width: 1_440, height: 860)
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      CommandMenu("Workshop") {
        Button("Workbench") { store.section = .workbench }
          .keyboardShortcut("1", modifiers: .command)
        Button("Runs") { store.section = .runs }
          .keyboardShortcut("2", modifiers: .command)
        Button("Host") { store.section = .host }
          .keyboardShortcut("3", modifiers: .command)

        Divider()

        Button(
          store.isRunning
            ? "Cancel current run"
            : store.currentRun?.state == .planned ? "Review and confirm" : "Review plan"
        ) {
          if store.isRunning {
            Task { await store.requestCancellation() }
          } else {
            store.requestRunAction()
          }
        }
        .disabled(!store.canStartRun && !store.canCancelRun)
        .keyboardShortcut("r", modifiers: [.command, .shift])

        if store.contentMode == .demo {
          Button("Compare candidates") {
            store.section = .compare
          }
          .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        Divider()

        Toggle("Show settings", isOn: $store.showInspector)
          .keyboardShortcut("i", modifiers: [.command, .option])
        Toggle("Show run evidence", isOn: $store.showRunDrawer)
          .keyboardShortcut("j", modifiers: [.command])
      }
    }
  }

  @MainActor
  private func renderSnapshotIfRequested() async {
    guard let output = snapshotOutput else { return }
    guard !output.isEmpty else { return }

    try? await Task.sleep(for: .milliseconds(1_500))
    let visibleWindows = NSApplication.shared.windows.filter {
      $0.isVisible && $0.frame.width > 700
    }
    guard
      let window = visibleWindows.max(by: {
        ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
      }),
      let contentView = window.contentView,
      let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
    else {
      fputs("Could not locate a hosted window for snapshot\n", stderr)
      NSApplication.shared.terminate(nil)
      return
    }
    window.makeKeyAndOrderFront(nil)
    contentView.layoutSubtreeIfNeeded()
    contentView.displayIfNeeded()
    try? await Task.sleep(for: .milliseconds(250))
    contentView.cacheDisplay(in: contentView.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      fputs("Could not encode hosted window snapshot\n", stderr)
      NSApplication.shared.terminate(nil)
      return
    }

    do {
      try png.write(to: URL(fileURLWithPath: output), options: .atomic)
      print(output)
    } catch {
      fputs("Could not save snapshot: \(error)\n", stderr)
    }
    NSApplication.shared.terminate(nil)
  }
}
