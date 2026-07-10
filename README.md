# MLX Workshop

MLX Workshop is a native macOS app for inspecting compatible local MLX models,
reviewing an exact quantization plan, creating a new candidate without changing
the parent, and qualifying the result from hashed evidence.

The app presents that as a guided five-step journey: review a safe plan, confirm it,
create the optimized copy, verify it, and prepare an immutable local release record.
Setup explains which folders to choose, and one primary action identifies the next
step. Advanced settings, commands, logs, and raw evidence stay available on demand.

The beta is deliberately narrow. It supports capability-routed uniform MXFP4,
MXFP8, and affine conversion for inspected float models that MLX-LM can load.
Unknown tensor semantics, already-quantized sources, unsupported controls, unsafe
workspace paths, and incomplete evidence stop with an explicit blocker.

Live experimental tools can measure and materialize Llama mixed-precision candidates,
run a reviewed behavior-edit experiment for eligible quantized Qwen3.5 models, smoke
test an advertised vision model with a local image, and inspect MTPLX/MTP compatibility.
Experimental candidates are not silently promoted as qualified releases.

## Beta guarantees

- Model and run-workspace access uses user-selected folders and security-scoped bookmarks.
- Planning never starts a run. A dedicated sheet discloses the parent, destination,
  resource bounds, required gates, and literal argument arrays before confirmation.
- The exact reviewed plan is SHA-256 pinned across the launch boundary.
- Runs use new immutable directories, append-only journals, bounded live logs, and
  process-specific cooperative cancellation.
- Completion and qualification are separate states. Qualification requires hashed
  structural, deterministic runtime, and parent-parity evidence.
- Compare shows only recorded parent-relative facts; missing performance or quality
  metrics are labeled “Not measured.”
- Relaunch recovery never automatically starts or resumes work.
- The app has no telemetry, account system, upload path, or model registry integration.

The deterministic tiny Llama fixture proves the complete real conversion and
qualification route without making a model-quality claim.
Two native UI journeys exercise fresh setup and the complete deterministic interface
flow, while real backend and packaged-runtime tests execute independently.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- About 2 GB free for the app, installer, and temporary packaging files
- Additional free space appropriate to the model and reviewed plan

The release app contains its own arm64 CPython/MLX runtime. Friends do not need
Python, Homebrew, `uv`, or a source checkout.

## Install

Friend-installable binaries are published only after the Developer ID, hardened
runtime, Gatekeeper, notarization, and stapling gate passes. Download the DMG from
GitHub Releases, drag **MLX Workshop** to **Applications**, then launch it normally.

Do not redistribute an ad-hoc developer build: it is useful for local validation
but does not satisfy the public installation gate.

## Build from source

Install Xcode, `xcodegen`, and `uv`, then run:

```bash
git clone https://github.com/shiftedx/mlx-workshop.git
cd mlx-workshop
scripts/release/build_macos_app.sh
```

The verified app is written to:

```text
MLXWorkshop/build/Release/MLX Workshop.app
```

Create and verify the installer with:

```bash
scripts/release/create_macos_dmg.sh
```

Maintainers with a Developer ID identity and a `notarytool` keychain profile use:

```bash
SIGNING_IDENTITY='Developer ID Application: …' scripts/release/build_macos_app.sh
SIGNING_IDENTITY='Developer ID Application: …' NOTARYTOOL_PROFILE=mlx-workshop \
  scripts/release/notarize_macos_release.sh
```

## Test

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
(cd MLXWorkshop && swift test)
xcrun swift-format lint --recursive MLXWorkshop/Sources MLXWorkshop/Tests MLXWorkshop/UITests
scripts/release/verify_public_release.sh
```

The current release gate contains 67 Python tests, 101 Swift tests, two native UI
journeys, real tiny-model conversion/mixed-precision evidence, and package/DMG checks.

See [BETA_REPORT.md](BETA_REPORT.md),
[docs/BETA_SUPPORT_MATRIX.md](docs/BETA_SUPPORT_MATRIX.md), and
[docs/protocol/MLX_WORKFLOW_PROTOCOL_V1.md](docs/protocol/MLX_WORKFLOW_PROTOCOL_V1.md)
for the exact evidence boundary.

## Safety and privacy

Read [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) before using the beta.
Back up valuable models independently. MLX Workshop is designed to preserve the
selected parent, but beta software is not a substitute for backups.

## License

Apache-2.0. Bundled third-party components retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
