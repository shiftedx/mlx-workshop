# MLX Workshop Beta Report

Date: 2026-07-10  
Protocol: MLX Workflow Local Protocol v1  
Readiness verdict: **source beta ready; friend-installable binary pending Apple trust credentials**

## Executive verdict

MLX Workshop now completes the supported beta path end to end: local model import,
capability inspection, canonical MXFP planning, explicit confirmation, immutable run
creation, MLX-LM conversion, durable progress and logs, recovery, qualification, and
evidence review, comparison, and immutable local release staging. The reference
campaign used a generated tiny dense Llama model and
performed a real MXFP4 weight conversion. Its provenance/structure,
deterministic-language-schema, and parent-parity gates passed. This is workflow
evidence only, not a model-quality claim.

The macOS app ships an exact, hash-verified CPython/MLX runtime. It builds as a
sandboxed arm64 application, passes package and runtime-manifest verification, and
can be assembled into a read-only DMG with an Applications shortcut. The public
source tree is separately allowlisted and scanned so local models, run outputs,
credentials, and workstation paths are excluded.

Measured mixed-precision analysis/materialization, reviewed behavior experiments,
vision smoke testing, and read-only MTPLX compatibility inspection are now live
surfaces. They retain narrower classifications: mixed and behavior candidates remain
experimental/unqualified, vision is a smoke test rather than grafting, and MTPLX
inspection never manages the daemon.

One external macOS distribution gate remains. This machine has no Developer ID
Application certificate or configured notarization profile, so the DMG cannot yet
pass Gatekeeper on friends' Macs. Native XCUITest automation now launches and covers
the setup screen plus the complete supported conversion and verification journey.
The full VoiceOver and keyboard checklist remains manual.

## Supported beta outcomes

| Outcome | Status | Evidence |
| --- | --- | --- |
| Inspect a local model and host | Pass | Security-scoped folder import, real capability and host snapshots, fail-closed adapter routing |
| Review an exact conversion | Pass | Guided plan review exposes settings, commands, disk/memory estimates, warnings, and gates without requiring them to understand the next action |
| Confirm and run MXFP conversion | Pass | Dedicated confirmation; immutable run directory; real tiny Llama MXFP4 conversion through MLX-LM |
| Observe and recover lifecycle | Pass | Streaming events/logs, request-bound cancel/interruption, journal recovery, safe resume, and recovered cancellation |
| Qualify and compare a completed candidate | Pass for declared gates | Three hashed evidence gates, parent-relative fingerprints, honest optional metrics, and reference-only staging |
| Measure and materialize mixed precision | Experimental | Real Llama layer-group KL measurement, Pareto assignments, exact assignment manifest, and reload verification; no automatic qualification |
| Run a behavior experiment | Experimental and eligibility-gated | Reviewed allowlisted Qwen3.5 path with separated datasets and held-out evidence; critical/tool/template parity remains fail-closed |
| Check vision and MTP extensions | Capability checks | Bundled `mlx-vlm` image smoke for advertised VLMs; read-only MTPLX JSON inspection |
| Protect the parent | Pass | Parent hashes unchanged; candidate is contained under a new run; no in-place promotion |
| Package the native app | Pass | Sandboxed arm64 app, bundled runtime, privacy/legal resources, full manifest verification |
| Install from a public DMG | Blocked externally | DMG structure/checksum pass; Developer ID signature, notarization, stapling, and Gatekeeper acceptance require Apple credentials |
| Automate the supported native UI path | Pass | Two XCUITests cover fresh setup and the full deterministic interface journey across every live section; backend and bundled-runtime execution are tested separately |

Universal architecture support, automatic vision grafting, automatic MTP packaging,
promotion of behavior-edited or mixed candidates, and model-quality claims remain
outside this beta.

## Verification summary

- Python: 67 unit and integration tests.
- Swift: 101 unit and integration tests.
- Native UI: 2 XCUITests, including the full deterministic navigation and action journey.
- Real reference run: tiny dense Llama to MXFP4, with three qualification gates.
- Real experimental reference: measured mixed-precision analysis and reloadable materialization on the tiny dense Llama fixture.
- Runtime: exact CPython 3.11.14 and fully hash-locked Python dependencies; every
  bundled file is recorded in `runtime-manifest.json`.
- Release app: arm64, macOS 14+, sandboxed, privacy manifest and legal notices
  bundled, runtime integrity checked at launch.
- DMG: read-only image, Applications link, and image checksum verified.
- Static gates: Python compilation, Swift formatting, shell syntax, JSON/plist
  validation, package contract, and sanitized-public-tree contract.

The detailed capability boundary is in
[docs/BETA_SUPPORT_MATRIX.md](docs/BETA_SUPPORT_MATRIX.md), security findings in
[docs/BETA_SECURITY_REVIEW.md](docs/BETA_SECURITY_REVIEW.md), and the remaining
interactive checks in
[docs/BETA_MANUAL_QA_CHECKLIST.md](docs/BETA_MANUAL_QA_CHECKLIST.md).

## Build and test

```bash
uv sync --frozen
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v

cd MLXWorkshop
swift test
xcrun swift-format lint --recursive Sources Tests UITests
cd ..

scripts/release/build_macos_app.sh
scripts/release/create_macos_dmg.sh
```

Real conversions always require review and explicit confirmation. Do not infer
support for a model family when inspection returns `adapter-required`.
