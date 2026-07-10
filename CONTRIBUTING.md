# Contributing

Small, reviewable contributions are welcome.

1. Open an issue describing the user-visible problem and evidence boundary.
2. Add or update a failing test before changing behavior.
3. Keep model parents immutable and every real output in a new run directory.
4. Do not add shell-string execution, credential-bearing arguments, implicit network
   access, inferred measurements, or automatic resume/start behavior.
5. Run the Python, Swift, format, and release-contract checks documented in README.

Test fixtures must be generated, redistributable, small enough for the repository,
and clearly separated from model-quality claims. Never commit private model weights,
datasets, logs, absolute personal paths, credentials, or proprietary prompts.
