import AppKit
import SwiftUI

struct WorkshopRootView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
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
    .task {
      let hasLiveSnapshot = CommandLine.arguments.contains(where: {
        $0.hasPrefix("--snapshot-live=")
      })
      let hasUITestBootstrap =
        CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-test-model=") })
        && CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-test-workspace=") })
      guard !hasLiveSnapshot || hasUITestBootstrap else {
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
          Label("Choose model folder", systemImage: "folder.badge.plus")
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
          Label("Settings", systemImage: "sidebar.trailing")
        }

        Button {
          if store.isRunning {
            Task { await store.requestCancellation() }
          } else {
            store.requestRunAction()
          }
        } label: {
          Label(
            store.isRunning ? "Cancel" : "Review plan",
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
    VStack(spacing: WorkshopTheme.spaceM) {
      Image(systemName: "shippingbox.and.arrow.backward")
        .font(.system(size: 38, weight: .medium))
        .foregroundStyle(WorkshopTheme.skyBright)
        .accessibilityHidden(true)
      Text("Set up your first optimization")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      Text(
        "Choose two folders. Then MLX Workshop will walk you through the plan, create a separate optimized copy, and verify the result. Your original model is never changed."
      )
      .font(.system(size: 12))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 600)

      VStack(spacing: WorkshopTheme.spaceS) {
        setupStep(
          number: 1,
          title: "Choose the original model",
          detail:
            "Select the folder that contains config.json and the model weight files, usually ending in .safetensors.",
          selection: store.model?.directory.path(percentEncoded: false),
          buttonTitle: store.model == nil ? "Choose model folder…" : "Change model folder…",
          symbol: "folder",
          isPrimary: store.model == nil,
          identifier: "setup.chooseModel",
          action: chooseModel)

        setupStep(
          number: 2,
          title: "Choose where results should go",
          detail:
            "Select or create a separate writable folder. Each attempt gets its own run folder, logs, and evidence.",
          selection: store.runWorkspace?.path(percentEncoded: false),
          buttonTitle: store.runWorkspace == nil
            ? "Choose results folder…" : "Change results folder…",
          symbol: "externaldrive",
          isPrimary: store.model != nil && store.runWorkspace == nil,
          identifier: "setup.chooseWorkspace",
          action: chooseWorkspace)
      }
      .frame(maxWidth: 680)

      Label(
        "Next: review the format, required disk space, memory estimate, and exact output before anything runs.",
        systemImage: "arrow.right.circle"
      )
      .font(.system(size: 11))
      .foregroundStyle(WorkshopTheme.secondaryInk)
      .frame(maxWidth: 600, alignment: .leading)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkshopTheme.canvas)
    .accessibilityElement(children: .contain)
  }

  private func setupStep(
    number: Int,
    title: String,
    detail: String,
    selection: String?,
    buttonTitle: String,
    symbol: String,
    isPrimary: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: WorkshopTheme.spaceM) {
      Image(systemName: selection == nil ? "\(number).circle" : "checkmark.circle.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(selection == nil ? WorkshopTheme.skyBright : WorkshopTheme.success)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: WorkshopTheme.spaceXXS) {
        Text(title)
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        Text(selection ?? "No folder chosen yet")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(selection == nil ? WorkshopTheme.quietInk : WorkshopTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: WorkshopTheme.spaceS)

      if isPrimary {
        Button(action: action) {
          Label(buttonTitle, systemImage: symbol).frame(minWidth: 168)
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .accessibilityIdentifier(identifier)
      } else {
        Button(action: action) {
          Label(buttonTitle, systemImage: symbol).frame(minWidth: 168)
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier(identifier)
      }
    }
    .padding(WorkshopTheme.spaceM)
    .background(
      WorkshopTheme.surface,
      in: RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: WorkshopTheme.radiusMedium, style: .continuous)
        .stroke(WorkshopTheme.divider, lineWidth: 1)
    )
  }

  private func loadingView(_ activity: SetupActivity) -> some View {
    VStack(spacing: 12) {
      ProgressView().controlSize(.small)
      Text(activity.rawValue)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(WorkshopTheme.ink)
      Text(
        loadingDetail(activity)
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

  private func loadingDetail(_ activity: SetupActivity) -> String {
    switch activity {
    case .selectingModel:
      "Choose the folder that contains config.json and the model weight files."
    case .selectingWorkspace:
      "Choose or create a separate folder where optimized copies and run evidence can be saved."
    case .inspectingModel:
      "Reading model metadata and checking support. Your original files are not changed."
    case .preparingRecipe:
      "Checking this Mac and preparing safe starting settings for review."
    }
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
      Button("Choose a different model folder…", action: chooseModel)
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
        onStage: { await workflowSession.stageRun(runID: $0, into: store) },
        onResume: { await workflowSession.resumeRun(runID: $0, into: store) },
        onCancelRecovered: {
          await workflowSession.requestRecoveredCancellation(runID: $0, into: store)
        },
        onAnalyzeSensitivity: { await workflowSession.analyzeSensitivity(store) },
        onMaterializeMixed: { await workflowSession.materializeMixedCandidate(store) })
    case .runs:
      RunsView(
        onQualify: { await workflowSession.qualifyRun(runID: $0, into: store) },
        onStage: { await workflowSession.stageRun(runID: $0, into: store) },
        onResume: { await workflowSession.resumeRun(runID: $0, into: store) },
        onCancelRecovered: {
          await workflowSession.requestRecoveredCancellation(runID: $0, into: store)
        })
    case .compare:
      CompareView(onStage: { await workflowSession.stageRun(runID: $0, into: store) })
    case .behavior:
      BehaviorLabView(
        onPlan: { await workflowSession.planBehaviorExperiment(store) },
        onRun: { await workflowSession.runBehaviorExperiment(store) })
    case .extensions:
      ExtensionsView(
        onInspectMTP: { await workflowSession.inspectMTPExtension(store) },
        onVisionImage: { await workflowSession.runVisionSmoke(imageURL: $0, store: store) })
    case .host: HostView(onRefresh: { await workflowSession.refreshHost(store) })
    }
  }

  private func chooseModel() {
    store.beginModelSelection()
    WorkshopFolderPicker.present(target: .model, onCompletion: handleModelSelection)
  }

  private func chooseWorkspace() {
    store.beginWorkspaceSelection()
    WorkshopFolderPicker.present(target: .workspace, onCompletion: handleWorkspaceSelection)
  }

  private func perform(_ action: WorkshopDiagnostic.RecoveryAction) {
    switch action {
    case .chooseModel, .retryInspection: chooseModel()
    case .chooseWorkspace: chooseWorkspace()
    case .revealRun:
      if let directory = store.currentRun?.runDirectory {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
      } else {
        store.showRunDrawer = true
      }
    case .openLog:
      if let log = store.currentRun?.stderrLog ?? store.currentRun?.stdoutLog {
        NSWorkspace.shared.open(log)
      } else {
        store.showRunDrawer = true
      }
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
