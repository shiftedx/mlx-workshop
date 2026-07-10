# MLX Workshop Beta Manual QA Checklist

Date: 2026-07-10  
Scope: native keyboard, VoiceOver, window, and signed-install verification

Automated domain, process, packaging, and real tiny-model tests pass. XCUITest is
currently blocked before application launch because this macOS account times out
enabling automation mode; System Events is also denied Accessibility access. The
items below remain a deliberate beta gate rather than being inferred from source
labels or unit tests.

## Confirmation and workflow

- [ ] VoiceOver announces the confirmation title, parent, output, estimate
  uncertainty, feasibility, gates, commands, and weight-changing warning.
- [ ] Tab and Shift-Tab reach Decline and Confirm without a trap.
- [ ] Escape declines without creating a run; Return confirms exactly once.
- [ ] Import a tiny model and workspace through the sandbox file pickers, inspect,
  plan, confirm, observe completion, qualify, and reveal its evidence.
- [ ] Cancel a running fixture and verify the terminal state and logs.
- [ ] Relaunch with an interrupted fixture, resume it, and verify recovered cancel.

## Evidence and history

- [ ] VoiceOver distinguishes planned, blocked, running, cancelling, cancelled,
  interrupted, failed, completed-unqualified, and qualified states.
- [ ] Reveal/log/copy actions are enabled only when their artifacts exist.
- [ ] Exact and redacted command actions announce their different privacy behavior.
- [ ] A corrupt run appears as Protocol mismatch without hiding healthy rows.

## Window and system settings

- [ ] Repeat at 1180×720 and at 1440×860 or larger.
- [ ] Repeat with Reduce Motion and Reduce Transparency enabled.
- [ ] Verify visible keyboard focus on every action and no automatic start on launch.
- [ ] On a clean macOS 14+ account, install the notarized DMG, drag the app to
  Applications, launch it through Gatekeeper, run the tiny campaign, relaunch, and
  uninstall without leaving data outside the chosen workspace.

Manual execution status: **pending Accessibility permission and a notarized build**.
