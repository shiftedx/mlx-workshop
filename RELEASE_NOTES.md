# MLX Workshop 0.1.0-beta.1

> **Source prerelease.** The DMG is intentionally withheld until its Developer ID
> signature, notarization, stapling, and Gatekeeper checks pass. Do not redistribute
> an ad-hoc local build.

This first beta focuses on one trustworthy path: inspect a compatible local float
model, review an exact uniform quantization plan, create a new candidate, and qualify
it without changing the parent. A guided five-step flow leads from folder setup and
plan review through verification and immutable local release staging.

Supported conversion modes are MXFP4, MXFP8, and affine. Already-quantized models,
unknown tensor semantics, and unsupported model families fail closed. Measured Llama
mixed precision and eligible Qwen3.5 behavior experiments are live but experimental
and unqualified. Vision is an advertised-VLM smoke test, and MTP support is a read-only
MTPLX compatibility check; vision grafting, automatic MTP packaging, and canonical
model replacement remain outside the beta.

The app is Apple Silicon-only, requires macOS 14+, and includes its complete locked
Python/MLX runtime. No separate developer tools are needed for the notarized DMG.

Verification evidence:

- 67 Python unit/integration tests
- 101 Swift unit/integration tests
- 2 native UI journeys covering fresh setup and every live interface section
- Real tiny-model conversion with source immutability and three hashed qualification gates
- Real measured tiny-model mixed-precision analysis and reloadable materialization
- Fully hash-manifested 70-package bundled runtime with import/host smoke tests
- arm64 Release bundle, sandbox/privacy checks, and verified drag-to-Applications DMG

Completion is not qualification. The app keeps those states visually and
semantically separate, and never starts or resumes a run on launch.
