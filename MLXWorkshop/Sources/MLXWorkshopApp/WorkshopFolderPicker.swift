import AppKit
import Foundation

enum WorkshopFileImport {
  enum Target: Equatable, Sendable {
    case model
    case workspace
  }

  static func isCancellation(_ error: Error) -> Bool {
    let cocoa = error as NSError
    return cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError
  }
}

struct WorkshopFolderPickerConfiguration: Equatable, Sendable {
  let title: String
  let message: String
  let prompt: String
  let canChooseDirectories: Bool
  let canChooseFiles: Bool

  static func forTarget(_ target: WorkshopFileImport.Target) -> Self {
    switch target {
    case .model:
      return Self(
        title: "Choose a model folder",
        message:
          "Select the top-level folder containing config.json and model weights such as .safetensors files. Do not select an individual file.",
        prompt: "Choose Model",
        canChooseDirectories: true,
        canChooseFiles: false)
    case .workspace:
      return Self(
        title: "Choose a run workspace",
        message:
          "Select a separate writable folder where MLX Workshop can create immutable run directories. Do not choose a folder inside the model folder.",
        prompt: "Choose Workspace",
        canChooseDirectories: true,
        canChooseFiles: false)
    }
  }
}

enum WorkshopFolderPicker {
  @MainActor
  static func present(
    target: WorkshopFileImport.Target,
    onCompletion: @escaping (Result<[URL], Error>) -> Void
  ) {
    let configuration = WorkshopFolderPickerConfiguration.forTarget(target)
    let panel = NSOpenPanel()
    panel.title = configuration.title
    panel.message = configuration.message
    panel.prompt = configuration.prompt
    panel.canChooseDirectories = configuration.canChooseDirectories
    panel.canChooseFiles = configuration.canChooseFiles
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true

    panel.begin { response in
      if response == .OK {
        onCompletion(.success(panel.urls))
      } else {
        onCompletion(
          .failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
      }
    }
  }
}
