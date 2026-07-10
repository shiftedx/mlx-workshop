import SwiftUI
import UniformTypeIdentifiers

enum WorkshopFileImport {
  enum Target: Equatable {
    case model
    case workspace
  }

  static func isCancellation(_ error: Error) -> Bool {
    let cocoa = error as NSError
    return cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError
  }
}

struct WorkshopRootView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var selectingFolder = false
  @State private var folderTarget: WorkshopFileImport.Target?
  @StateObject private var workflowSession = WorkshopWorkflowSession()

  var body: some View {
    Group {
      switch store.setupState {
      case .empty:
        setupView
      case .loading(let activity):
        if activity == .selectingModel || activity == .selectingWorkspace
          || (activity == .inspectingModel && store.runWorkspace == nil)
        {
          setupView
        } else {
          loadingView(activity)
        }
      case .blocked(let diagnostic):
        blockedView(diagnostic)
      case .ready:
        workspace
      }
    }
    .fileImporter(
      isPresented: $selectingFolder, allowedContentTypes: [.folder],
      allowsMultipleSelection: false, onCompletion: handleFolderSelection
    )
    .task {
      guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-live=") }) else {
        return
      }
      #if DEBUG
        if CommandLine.arguments.contains("--ui-test-reset") {
          workflowSession.resetPersistenceForUITesting()
        }
        if let workspacePath = uiTestPath(prefix: "--ui-test-workspace="),
          let modelPath = uiTestPath(prefix: "--ui-test-model=")
        {
          await workflowSession.bootstrapForUITesting(
            modelURL: URL(fileURLWithPath: modelPath, isDirectory: true),
            workspaceURL: URL(fileURLWithPath: workspacePath, isDirectory: true),
            into: store)
          return
        }
        if CommandLine.arguments.contains("--ui-test-reset") { return }
      #endif
      await workflowSession.restore(into: store)
    }
    .onChange(of: store.planRequestSequence) {
      Task { await workflowSession.planSelectedModel(store) }
    }
    .sheet(isPresented: $store.showConfirmation) {
      if let confirmation = store.pendingConfirmation {
        RunConfirmationView(
          confirmation: confirmation,
          onConfirm: { await workflowSession.confirmPendingRun(store) },
          onDecline: { workflowSession.declinePendingRun(store) })
      }
    }
    .onChange(of: store.showConfirmation) { _, isPresented in
      if !isPresented, store.pendingConfirmation != nil {
        workflowSession.declinePendingRun(store)
      }
    }
  }

  private var workspace: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      WorkshopSidebarView()
        .navigationSplitViewColumnWidth(min: 188, ideal: 212, max: 252)
    } detail: {
      content.background(WorkshopTheme.canvas)
    }
    .navigationSplitViewStyle(.balanced)
    .inspector(isPresented: $store.showInspector) {
      RecipeInspectorView().inspectorColumnWidth(min: 286, ideal: 316, max: 370)
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button(action: chooseModel) {
          Label("Choose model", systemImage: "folder.badge.plus")
        }
        .keyboardShortcut("o", modifiers: [.command])
        .disabled(!store.canChangeSelection)
        .help("Choose a different local model directory")
        Button(action: chooseWorkspace) {
          Label("Choose run workspace", systemImage: "externaldrive.badge.plus")
        }
        .keyboardShortcut("o", modifiers: [.command, .option])
        .disabled(!store.canChangeSelection)
        .help("Choose where immutable run directories are created")
      }

      ToolbarItem(placement: .principal) {
        HStack(spacing: 8) {
          Text(store.model?.displayName ?? "No model")
            .font(.system(size: 13, weight: .semibold))
          Text(store.recipe.name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(WorkshopTheme.secondaryInk)
          if store.contentMode == .demo {
            StatusPill(text: "Demo data", symbol: "theatermasks", color: WorkshopTheme.warning)
          }
        }
      }

      ToolbarItemGroup(placement: .primaryAction) {
        if store.contentMode == .demo {
          Button {
            store.section = .compare
          } label: {
            Label("Compare", systemImage: "arrow.left.arrow.right")
          }
          .disabled(store.candidates.isEmpty)
        }

        Button {
          store.showRunDrawer.toggle()
        } label: {
          Label("Run evidence", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .disabled(store.currentRun == nil)

        Button {
          store.showInspector.toggle()
        } label: {
          Label("Recipe inspector", systemImage: "sidebar.trailing")
        }

        Button {
          if store.isRunning {
            Task { await store.requestCancellation() }
          } else {
            store.requestRunAction()
          }
        } label: {
          Label(
            store.isRunning
              ? "Cancel" : store.currentRun?.state == .planned ? "Review plan" : "Plan run",
            systemImage: store.isRunning ? "stop.fill" : "play.fill")
        }
        .disabled(!store.canStartRun && !store.canCancelRun)
        .tint(WorkshopTheme.sky)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .accessibilityIdentifier("workflow.primaryAction")
      }
    }
    .background(WorkshopTheme.chrome)
  }

  private var setupView: some View {
    VStack(spacing: 16) {
      Image(systemName: "shippingbox.and.arrow.backward")
        .font(.system(size: 38, weight: .medium))
        .foregroundStyle(WorkshopTheme.skyBright)
        .accessibilityHidden(true)
      Text("Start with a local model")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      Text(
        "Choose a model directory and a separate run workspace. MLX Workshop inspects capabilities before it offers an operation; unknown tensor semantics stop with an adapter requirement."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 520)

      HStack(spacing: 12) {
        Button(action: chooseModel) {
          Label(
            store.model == nil ? "Choose model…" : "Choose another model…", systemImage: "folder")
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .accessibilityIdentifier("setup.chooseModel")
        .frame(width: 210)
        .keyboardShortcut("o", modifiers: [.command])
        Button(action: chooseWorkspace) {
          Label(
            store.runWorkspace == nil ? "Choose run workspace…" : "Change workspace…",
            systemImage: "externaldrive")
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("setup.chooseWorkspace")
        .keyboardShortcut("o", modifiers: [.command, .option])
      }

      VStack(alignment: .leading, spacing: 7) {
        setupFact("Model", store.model?.directory.path(percentEncoded: false) ?? "Not selected")
        setupFact(
          "Run workspace", store.runWorkspace?.path(percentEncoded: false) ?? "Not selected")
      }
      .frame(maxWidth: 520, alignment: .leading)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkshopTheme.canvas)
    .accessibilityElement(children: .contain)
  }

  private func setupFact(_ label: String, _ value: String) -> some View {
    LabeledContent(label, value: value)
      .font(.system(size: 10.5, design: .monospaced))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .lineLimit(1)
  }

  private func loadingView(_ activity: SetupActivity) -> some View {
    VStack(spacing: 12) {
      ProgressView().controlSize(.small)
      Text(activity.rawValue)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      Text(
        "Waiting for verified local workflow evidence. No capability or measurement is inferred by the app."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 460)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkshopTheme.canvas)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(activity.rawValue). Waiting for local workflow evidence.")
  }

  private func blockedView(_ diagnostic: WorkshopDiagnostic) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.octagon")
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(WorkshopTheme.danger)
        .accessibilityHidden(true)
      Text(diagnostic.title)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      Text(diagnostic.message)
        .font(.system(size: 11.5))
        .foregroundStyle(WorkshopTheme.secondaryInk)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
      if let action = diagnostic.recovery {
        Button(action.rawValue) { perform(action) }
          .buttonStyle(PrimaryActionButtonStyle())
          .frame(width: 220)
      }
      Button("Choose a different model…", action: chooseModel)
        .buttonStyle(QuietButtonStyle())
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkshopTheme.canvas)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var content: some View {
    switch store.section {
    case .workbench:
      WorkbenchView(
        onQualify: { await workflowSession.qualifyRun(runID: $0, into: store) },
        onResume: { await workflowSession.resumeRun(runID: $0, into: store) },
        onCancelRecovered: {
          await workflowSession.requestRecoveredCancellation(runID: $0, into: store)
        })
    case .runs:
      RunsView(
        onQualify: { await workflowSession.qualifyRun(runID: $0, into: store) },
        onResume: { await workflowSession.resumeRun(runID: $0, into: store) },
        onCancelRecovered: {
          await workflowSession.requestRecoveredCancellation(runID: $0, into: store)
        })
    case .compare: CompareView()
    case .behavior: BehaviorLabView()
    case .host: HostView(onRefresh: { await workflowSession.refreshHost(store) })
    }
  }

  private func chooseModel() {
    store.beginModelSelection()
    folderTarget = .model
    selectingFolder = true
  }

  private func chooseWorkspace() {
    store.beginWorkspaceSelection()
    folderTarget = .workspace
    selectingFolder = true
  }

  private func perform(_ action: WorkshopDiagnostic.RecoveryAction) {
    switch action {
    case .chooseModel, .retryInspection: chooseModel()
    case .chooseWorkspace: chooseWorkspace()
    case .revealRun, .openLog: break
    }
  }

  private func handleFolderSelection(_ result: Result<[URL], Error>) {
    guard let target = folderTarget else { return }
    folderTarget = nil
    switch target {
    case .model:
      handleModelSelection(result)
    case .workspace:
      handleWorkspaceSelection(result)
    }
  }

  private func handleModelSelection(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        store.cancelModelSelection()
        return
      }
      do {
        let path = try SecurityScopedPath(url: url, accessMode: .readOnly)
        Task { await workflowSession.selectModel(path, into: store) }
      } catch {
        store.selectionFailed(.selectingModel, message: error.localizedDescription)
      }
    case .failure(let error):
      if WorkshopFileImport.isCancellation(error) {
        store.cancelModelSelection()
      } else {
        store.selectionFailed(.selectingModel, message: error.localizedDescription)
      }
    }
  }

  private func handleWorkspaceSelection(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        store.cancelWorkspaceSelection()
        return
      }
      do {
        let path = try SecurityScopedPath(url: url, accessMode: .readWrite)
        Task { await workflowSession.selectWorkspace(path, into: store) }
      } catch {
        store.selectionFailed(.selectingWorkspace, message: error.localizedDescription)
      }
    case .failure(let error):
      if WorkshopFileImport.isCancellation(error) {
        store.cancelWorkspaceSelection()
      } else {
        store.selectionFailed(.selectingWorkspace, message: error.localizedDescription)
      }
    }
  }

  #if DEBUG
    private func uiTestPath(prefix: String) -> String? {
      CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }).map {
        String($0.dropFirst(prefix.count))
      }
    }
  #endif
}
