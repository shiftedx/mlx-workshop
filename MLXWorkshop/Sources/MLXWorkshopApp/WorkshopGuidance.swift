import AppKit
import SwiftUI

enum WorkshopGuideAction: Equatable {
  case reviewPlan
  case reviewAndConfirm
  case cancel
  case verifyResult
  case stageResult
  case resume
  case cancelRecovered
  case openSettings
  case showEvidence
  case showResult
  case none
}

struct WorkshopGuidance: Equatable {
  let step: Int
  let isComplete: Bool
  let title: String
  let detail: String
  let action: WorkshopGuideAction
  let actionTitle: String

  static func resolve(
    run: WorkshopRun?,
    planRequestPending: Bool,
    canCancel: Bool
  ) -> Self {
    if planRequestPending {
      return Self(
        step: 1, isComplete: false,
        title: "Preparing a safe plan",
        detail:
          "Checking this Mac, the selected model, required disk space, and the exact output path.",
        action: .none, actionTitle: "")
    }

    guard let run else {
      return Self(
        step: 1, isComplete: false,
        title: "Review a safe plan",
        detail:
          "See the estimated disk and memory use before anything starts. Your original model stays unchanged.",
        action: .reviewPlan, actionTitle: "Review plan")
    }

    switch run.state {
    case .planned:
      return Self(
        step: 2, isComplete: false,
        title: "Review and confirm",
        detail:
          "Check the new model format, output folder, resource estimates, and exact command. You stay in control.",
        action: .reviewAndConfirm, actionTitle: "Review and confirm")
    case .blocked:
      return Self(
        step: 2, isComplete: false,
        title: "The plan needs attention",
        detail: "Nothing has started. Adjust the settings or choose a different compatible model.",
        action: .openSettings, actionTitle: "Open settings")
    case .running:
      return Self(
        step: 3, isComplete: false,
        title: "Creating your optimized copy",
        detail: "The original model remains untouched. Progress and raw logs are available below.",
        action: canCancel ? .cancel : .cancelRecovered,
        actionTitle: canCancel ? "Cancel safely" : "Stop recovered run")
    case .cancelling:
      return Self(
        step: 3, isComplete: false,
        title: "Stopping safely",
        detail: "Waiting for the active command to record a clean cancellation state.",
        action: .none, actionTitle: "")
    case .completed where !run.isQualified:
      return Self(
        step: 4, isComplete: false,
        title: "Verify the result",
        detail:
          "The copy was created. Now check that it loads, behaves deterministically, and still matches its original parent.",
        action: .verifyResult, actionTitle: "Verify result")
    case .completed where run.stagedDirectory == nil:
      return Self(
        step: 5, isComplete: false,
        title: "Your optimized copy is verified",
        detail:
          "All required checks passed. Prepare immutable release metadata so this exact result remains reproducible.",
        action: .stageResult,
        actionTitle: "Prepare local release")
    case .completed:
      return Self(
        step: 5, isComplete: true,
        title: "Your local release is ready",
        detail:
          "The verified result now has immutable hashes, limitations, provenance, and rollback metadata.",
        action: .showResult,
        actionTitle: "Show release in Finder")
    case .interrupted where run.resumability == "safe":
      return Self(
        step: 3, isComplete: false,
        title: "This run can continue safely",
        detail: "The journal contains a safe resume point; continuing keeps the same run identity.",
        action: .resume, actionTitle: "Resume safely")
    case .interrupted:
      return Self(
        step: 3, isComplete: false,
        title: "This run was interrupted",
        detail:
          "Review the evidence before deciding what to do next. It will not resume automatically.",
        action: .showEvidence, actionTitle: "See what happened")
    case .cancelled:
      return Self(
        step: 3, isComplete: false,
        title: "The run was cancelled",
        detail:
          "No result was verified. Review the evidence or start a new plan when you are ready.",
        action: .showEvidence, actionTitle: "View evidence")
    case .failed, .protocolMismatch:
      return Self(
        step: 3, isComplete: false,
        title: "The run needs attention",
        detail:
          "Nothing was marked verified. Open the evidence to see the recorded error and raw logs.",
        action: .showEvidence, actionTitle: "See what happened")
    }
  }
}

struct WorkshopGuideView: View {
  @EnvironmentObject private var store: WorkshopStore
  @State private var actionInProgress = false
  let onQualify: @MainActor (String) async -> Void
  let onStage: @MainActor (String) async -> Void
  let onResume: @MainActor (String) async -> Void
  let onCancelRecovered: @MainActor (String) async -> Void

  private var guidance: WorkshopGuidance {
    WorkshopGuidance.resolve(
      run: store.currentRun,
      planRequestPending: store.planRequestPending,
      canCancel: store.canCancelRun)
  }

  var body: some View {
    HStack(spacing: WorkshopTheme.spaceM) {
      progress
      VStack(alignment: .leading, spacing: WorkshopTheme.spaceXXS) {
        Text(guidance.isComplete ? "Complete" : "Step \(guidance.step) of 5")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(guidance.isComplete ? WorkshopTheme.success : WorkshopTheme.skyBright)
        Text(guidance.title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(WorkshopTheme.ink)
        Text(guidance.detail)
          .font(.system(size: 11.5))
          .foregroundStyle(WorkshopTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: WorkshopTheme.spaceM)
      if guidance.action != .none {
        Button {
          perform(guidance.action)
        } label: {
          Label(guidance.actionTitle, systemImage: actionSymbol)
            .frame(minWidth: 142)
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .frame(width: 190)
        .disabled(actionInProgress)
        .accessibilityIdentifier("guide.nextAction")
      } else if store.planRequestPending || store.currentRun?.state == .cancelling {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(guidance.title)
      }
    }
    .padding(.horizontal, WorkshopTheme.spaceM)
    .padding(.vertical, WorkshopTheme.spaceS)
    .background(WorkshopTheme.surfaceRaised)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("guide.root")
  }

  private var progress: some View {
    HStack(spacing: WorkshopTheme.spaceXXS) {
      ForEach(1...5, id: \.self) { step in
        Image(
          systemName: step < guidance.step || guidance.isComplete
            ? "checkmark.circle.fill" : "circle"
        )
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(
          step <= guidance.step
            ? (guidance.isComplete ? WorkshopTheme.success : WorkshopTheme.sky)
            : WorkshopTheme.quietInk)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      guidance.isComplete ? "Workflow complete" : "Workflow step \(guidance.step) of 5")
  }

  private var actionSymbol: String {
    switch guidance.action {
    case .reviewPlan, .reviewAndConfirm: "checklist"
    case .cancel, .cancelRecovered: "stop.fill"
    case .verifyResult: "checkmark.seal"
    case .stageResult: "shippingbox"
    case .resume: "arrow.clockwise"
    case .openSettings: "slider.horizontal.3"
    case .showEvidence: "doc.text.magnifyingglass"
    case .showResult: "folder"
    case .none: "circle"
    }
  }

  private func perform(_ action: WorkshopGuideAction) {
    switch action {
    case .reviewPlan, .reviewAndConfirm:
      store.requestRunAction()
    case .cancel:
      Task { await store.requestCancellation() }
    case .openSettings:
      store.showInspector = true
    case .showEvidence:
      store.showRunDrawer = true
    case .showResult:
      if let directory = store.currentRun?.stagedDirectory ?? store.currentRun?.runDirectory {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
      } else {
        store.showRunDrawer = true
      }
    case .verifyResult, .stageResult, .resume, .cancelRecovered:
      guard let runID = store.currentRun?.id else { return }
      actionInProgress = true
      Task { @MainActor in
        switch action {
        case .verifyResult: await onQualify(runID)
        case .stageResult: await onStage(runID)
        case .resume: await onResume(runID)
        case .cancelRecovered: await onCancelRecovered(runID)
        default: break
        }
        actionInProgress = false
      }
    case .none:
      break
    }
  }
}
