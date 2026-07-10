# Product

## Register

product

## Users

MLX Workshop serves people running local language and multimodal models on Apple Silicon: experienced model operators who expect complete control, and technically curious users who want expert decisions made approachable. They work on a single Mac, often with constrained unified memory and disk, and may leave conversion, calibration, editing, or evaluation jobs running for hours. They need to understand what the application recommends, intervene when desired, and reproduce every result without living in a terminal.

## Product Purpose

MLX Workshop is a native Swift control surface over deterministic local CLI workflows for model inspection, MLX conversion and quantization, calibration-driven mixed precision, refusal-direction behavior editing, runtime tuning, validation, comparison, and artifact promotion.

Its defining capability is bespoke per-host optimization. It fingerprints the Mac and active workloads, inspects the model and runtime, builds a feasible experiment space, measures sensitivity and parent parity, benchmarks candidate artifacts on the actual host, and recommends a quality/size/speed frontier rather than applying a universal recipe. Easy Mode turns user priorities and a time budget into a reviewed experiment plan. Expert controls expose every underlying parameter, command, artifact, threshold, and decision.

Success means a human can create the best defensible artifact for their Mac, understand why it won, reproduce it exactly, and safely return to any parent or prior candidate.

## Brand Personality

Relaxing, smooth, rewarding.

The product should feel like a finely made native instrument: quiet while work is underway, responsive to direct manipulation, and satisfying when evidence converges. Confidence comes from legibility and control, not spectacle.

## Anti-references

- A cross-platform web dashboard placed inside a desktop window.
- Terminal cosplay, cyberpunk neon, glowing AI brains, or science-fiction control-room decoration.
- Opaque “one-click optimize” claims that hide commands, assumptions, calibration data, or regressions.
- Enterprise observability dashboards that turn every screen into tiles, gauges, and unrelated status cards.
- Lowest-common-denominator controls that sacrifice macOS conventions for platform parity.
- Decorative glass, excessive cards, or animation that competes with long-running technical work.
- A permanently intimidating expert console, or a simplified mode that prevents users from discovering and editing the real recipe.

## Design Principles

1. **Instrument, not wrapper.** Transform CLI capabilities into a spatial, inspectable workflow with direct manipulation, meaningful comparison, and native feedback.
2. **One product, progressive depth.** Easy Mode and expert control share the same model and artifacts; disclosure expands in place instead of switching to a different interface.
3. **Evidence is the reward.** Completion is satisfying because the user sees quality retained, performance gained, risks resolved, and provenance captured.
4. **Tune the actual system.** Recommendations derive from this Mac, this model, this runtime, this workload, and the user’s declared priorities.
5. **Calm during expensive work.** Long jobs communicate stage, progress, resource pressure, recoverability, and useful intervention without demanding constant attention.
6. **Reversible by construction.** Sources are immutable, candidates are explicit, destructive actions are exceptional, and every result carries its recipe and rollback path.
7. **Native is behavioral.** Menus, commands, windows, drag and drop, keyboard navigation, inspection, undo, accessibility, and system integration should feel made for macOS—not merely styled like it.

## Accessibility & Inclusion

Target WCAG AA contrast from the first release. Support complete VoiceOver descriptions and navigation, keyboard-only operation, visible focus, reduced-motion alternatives, color-blind-safe data visualization, and state communication that never relies on color alone. Respect macOS text sizing, increased contrast, and Reduce Transparency preferences. Long-running jobs and alerts must remain understandable without sound, animation, or fine motor precision.
