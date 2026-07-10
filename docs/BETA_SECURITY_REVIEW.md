# MLX Workshop Beta Security Review

Date: 2026-07-10

## Executive summary

No critical or high-severity issue was found in the supported local workflow.
Execution uses allowlisted argument arrays rather than shell strings, constrains
artifacts to new run directories, minimizes child environments, binds lifecycle
signals to request IDs, and fails closed when evidence or capability adapters are
missing. The app does not upload models, emit telemetry, stop model services, or
replace a canonical model.

The former external-runtime finding is resolved. Release builds bundle an exact
CPython 3.11.14 environment with hash-locked dependencies. A generated manifest
records every runtime file; the app verifies the manifest and critical entry points
before execution, and release verification re-hashes the complete runtime.

The remaining distribution issue is trust, not application logic: this machine has
no Developer ID Application identity or notarization profile. An ad-hoc signed build
is useful for local QA but must not be distributed as a friend-installable release.

## Low-severity findings

### Exact command arguments are intentionally persisted

Exact secret-free argument arrays are stored for reproducibility alongside a
redacted display. Current protocol-v1 steps reject unknown command shapes and do not
accept credentials. Future adapters must keep credentials out of arguments, use an
ephemeral secret-reference mechanism if one is ever required, and add schema tests
for each new step kind.

### Stale security-scoped bookmarks require reselection

Bookmark resolution fails closed if macOS marks the bookmark stale. This is safe but
can interrupt access after a folder moves. The user must reselect the folder; the app
must validate it before replacing saved access.

## Verified controls

- No shell-string execution in the versioned workflow path.
- Executable identities, step kinds, and argument shapes are allowlisted.
- Run identifiers and artifacts cannot escape the selected workspace; runs cannot
  be created within the parent model.
- Cooperative cancellation precedes a bounded forceful fallback and only targets
  the recorded child request.
- Active-process reporting drops command arguments.
- Qualification evidence links are relative and contained beneath the evidence root.
- The parent is re-hashed and remains unchanged during the reference campaign.
- App sandbox, user-selected read/write access, security-scoped bookmarks, privacy
  manifest, Apache-2.0 license, CPython license, and generated third-party notices
  are included in release resources.
- The public repository is built from an explicit allowlist and scanned for large
  artifacts, private directories, workstation paths, and token-shaped values.

## Release gates

- Obtain a Developer ID Application certificate, sign nested executable content and
  the app with hardened runtime and timestamp, notarize, staple, and verify with
  Gatekeeper.
- Complete the interactive keyboard and VoiceOver checklist on a macOS account that
  permits UI automation.
