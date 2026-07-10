# Privacy

MLX Workshop is a local-only macOS application.

## Data the app accesses

The app accesses only model and run-workspace folders selected by the user. It may
read model configuration, tokenizer, tensor metadata, and weights needed for
inspection, conversion, and qualification. It writes plans, candidates, journals,
logs, manifests, and evidence only inside the selected run workspace.

Host snapshots record bounded technical facts used for resource review: macOS and
tool versions, Apple chip and memory capacity, free disk space, power/thermal state,
and sanitized labels for relevant active ML workloads. Process arguments are used
only for local classification and are not retained.

Exact local paths and secret-free command arguments are stored in run evidence for
reproducibility. Users should avoid placing credentials in model or workspace paths.

## Data the app does not collect

MLX Workshop has no telemetry, analytics, advertising, account system, crash upload,
cloud sync, model upload, or remote registry integration. The protocol-v1 workflow
does not send models, prompts, logs, paths, or host facts over the network.

The bundled Python dependencies include general-purpose networking libraries because
they are dependencies of MLX-LM and Transformers. MLX Workshop's allowlisted beta
commands use local filesystem paths and do not invoke download or upload operations.

## Removal

Delete the app to remove it. Delete the run workspace to remove generated candidates
and evidence. Saved folder bookmarks and preferences can be removed with:

```bash
defaults delete com.cozylabs.MLXWorkshop
```

Questions may be filed in the public repository without attaching private model
paths, logs, weights, or prompts.
