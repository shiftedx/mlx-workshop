# Bundled runtime design

`runtime.lock.json` is the distribution boundary for the MLX Workshop Python
runtime. Beta packages must eventually contain one immutable arm64 runtime at
`Contents/Resources/Runtime`, with this exact layout:

```text
Runtime/
  bin/python3
  lib/python3.11/site-packages/
  scripts/mlx_workflow_cli.py
  scripts/workflow_*.py
  scripts/inspect_mlx_model.py
  runtime.lock.json
```

The lock records the interpreter, required top-level packages, and SHA-256 digests
of every protocol driver. A release build must be assembled from a clean arm64
environment, strip caches/tests/metadata that are not required at runtime, verify
imports offline, verify every driver digest, and then sign the complete app only
after the runtime is frozen.

The current lock is intentionally marked `design-lock-not-yet-bundled`. The first
packaging tracer bullet bundles the lock, privacy manifest, and native app, but not
the interpreter or Python packages. Distribution must remain blocked until Swift's
runtime locator resolves this bundle-relative layout, verifies the lock before
launching a child process, and the lock status changes to `bundled-and-verified`.

