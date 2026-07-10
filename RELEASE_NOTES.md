# MLX Workshop 0.1.0-beta.1

This first beta focuses on one trustworthy path: inspect a compatible local float
model, review an exact uniform quantization plan, create a new candidate, and qualify
it without changing the parent.

Supported conversion modes are MXFP4, MXFP8, and affine. Already-quantized models,
unknown tensor semantics, generic mixed precision, behavior editing, vision grafting,
MTP packaging, and promotion/replacement remain outside the binary beta.

The app is Apple Silicon-only, requires macOS 14+, and includes its complete locked
Python/MLX runtime. No separate developer tools are needed for the notarized DMG.

Verification evidence:

- 56 Python unit/integration tests
- 91 Swift unit/integration tests
- Real tiny-model conversion with source immutability and three hashed qualification gates
- 7,340-file bundled-runtime manifest and import/host smoke test
- arm64 Release bundle, sandbox/privacy checks, and verified drag-to-Applications DMG

Completion is not qualification. The app keeps those states visually and
semantically separate, and never starts or resumes a run on launch.
