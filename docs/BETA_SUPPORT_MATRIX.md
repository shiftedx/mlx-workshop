# MLX Workshop Beta Support Matrix

This matrix distinguishes qualified release paths from experimental tools and
fail-closed capability checks. “Implemented” does not mean every model family is
compatible or that an experimental candidate is safe to promote.

| Path | Beta evidence | Classification | User-visible rule |
| --- | --- | --- | --- |
| Dense Llama uniform MXFP4/MXFP8/affine conversion | Inspect, plan review, explicit confirmation, immutable output, reload, exact-parent verification, and three hashed gates | Supported when inspection and resource review pass | The original model is never modified |
| Run lifecycle | Streaming logs, cancellation, interruption, relaunch recovery, safe resume, and recovered cancellation | Supported | Every mutating run requires confirmation |
| Compare and local release staging | Parent/candidate fingerprints, gate evidence, honest optional metrics, and immutable reference-only release records | Supported for qualified uniform candidates | Missing speed, KL, or score data is shown as “Not measured” |
| Calibration-driven mixed precision | Real parent-relative logits/KL measurements, Llama layer-group adapter, Pareto assignments, exact saved assignment, and reload verification | Experimental and unqualified | Analyze and materialize are available; the result cannot be promoted without full qualification |
| Refusal-direction behavior editing | Reviewed six-step allowlisted executor, separated dataset groups, provenance hashes, adapter checks, logs, and held-out gate manifest | Experimental; executable only for eligible quantized Qwen3.5 models | Critical/tool/template parity is not yet measured, so promotion fails closed |
| Vision smoke test | Capability gate plus a local image-to-text generation through the bundled `mlx-vlm` runtime | Capability check for models that advertise vision weights | Text-only models block before launching inference; this is not vision grafting |
| MTPLX compatibility | Read-only local `mtplx inspect --require-mtp --json` | Capability check | Never starts, stops, or reconfigures an MTPLX daemon |
| Host snapshot | Chip, memory, disk, runtime versions, power/thermal context, and sanitized MLX-related workload names | Supported and read-only | Active workloads are reported, never stopped |
| Unknown tensor semantics, native FP8 inputs, unknown architectures, or missing adapters | Explicit blocker with remediation guidance | Supported fail-closed outcome | No conversion is attempted |
| Generated tiny dense Llama fixture | Real MXFP4 conversion, reload/generation, parent immutability, mixed-precision measurement, qualification, and a second full run through the bundled Release-app runtime without manifest drift | Required CI/reference evidence; no quality claim | Tiny and deterministic, not representative of model quality |

Beta v1 does not claim universal model compatibility, automatic vision grafting,
automatic MTP packaging, canonical-model replacement, behavior-edit promotion, or
model quality. Public source builds and ad-hoc local packages are ready; a binary
that friends can open without Gatekeeper workarounds still requires Developer ID
signing and Apple notarization as recorded in [../BETA_REPORT.md](../BETA_REPORT.md).
