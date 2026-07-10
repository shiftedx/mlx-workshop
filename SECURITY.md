# Security policy

## Supported version

Security fixes are provided for the newest published beta.

## Report a vulnerability

Please use GitHub's private **Report a vulnerability** flow in the Security tab.
Do not open a public issue containing exploit details, private paths, model data,
tokens, logs, or credentials.

Include the affected version, macOS version, reproduction steps, impact, and the
smallest non-sensitive evidence needed to understand the report. You should receive
an acknowledgment within seven days.

## Security boundaries

- The app runs only closed, allowlisted local executable identities and argument shapes.
- Recipe and protocol payloads cannot supply shell command strings or executables.
- Run IDs and outputs are constrained below the selected workspace; the exact parent
  cannot be the run directory or contain it.
- Reviewed plan bytes are SHA-256 pinned before execution.
- Bundled runtime files have a generated manifest; critical runtime and driver files
  are verified by the app, while release tooling verifies the complete file set.
- Gate failures, future protocol versions, corrupt journals, and unknown semantics
  fail closed.

These controls reduce risk; they do not make untrusted model repositories safe.
Only open models and workspaces from sources you trust, and keep independent backups.
