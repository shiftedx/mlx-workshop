---
name: MLX Workshop
description: A calm native instrument for bespoke Apple Silicon model optimization.
colors:
  canvas: "#0C0D0F"
  chrome: "#101214"
  surface: "#15171A"
  surface-raised: "#1C1E21"
  surface-selected: "#1B3147"
  divider: "#2D3035"
  ink: "#ECF0F4"
  ink-secondary: "#ADB6C0"
  ink-quiet: "#808894"
  measured-sky: "#3C99ED"
  measured-sky-bright: "#5BB5FF"
  measured-sky-wash: "#17344E"
  qualified: "#61C985"
  caution: "#F2B04D"
  blocked: "#ED6374"
typography:
  headline:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.22
  title:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.28
  body:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "11.5px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "SF Pro, system-ui, sans-serif"
    fontSize: "10.5px"
    fontWeight: 500
    lineHeight: 1.3
  evidence:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "10.5px"
    fontWeight: 500
    lineHeight: 1.3
rounded:
  control: "6px"
  panel: "9px"
  feature: "12px"
spacing:
  xxs: "4px"
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "24px"
  xl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.measured-sky-bright}"
    textColor: "#FFFFFF"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "9px 12px"
  button-quiet:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink-secondary}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "7px 11px"
  navigation-selected:
    backgroundColor: "{colors.surface-selected}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "8px 10px"
  atlas-selected:
    backgroundColor: "{colors.surface-selected}"
    textColor: "{colors.ink}"
    typography: "{typography.evidence}"
    rounded: "0px"
    padding: "5px 16px"
---

# Design System: MLX Workshop

## 1. Overview

**Creative North Star: "The Quiet Instrument Bench"**

MLX Workshop is a graphite precision studio: calm at rest, densely informative under inspection, and immediately responsive to direct manipulation. Its spatial model follows a native Mac professional tool—persistent sidebar, focused work surface, contextual inspector, and optional evidence drawer—rather than a browser dashboard.

Hierarchy comes from alignment, tonal surfaces, typography, and selection state. The Sensitivity Atlas is the signature instrument and receives the largest uninterrupted area. Easy and expert controls operate on the same recipe; depth expands contextually without switching products or concealing the generated command.

The implementation rejects Grafana-style tile walls, terminal cosplay, decorative glass, and cyberpunk color. Reward appears only when evidence converges: qualification green and promotion language are earned states rather than ambient decoration.

**Key Characteristics:**

- Native three-region macOS workspace with optional bottom evidence drawer
- Graphite tonal hierarchy without persistent shadows
- Restrained Measured Sky interaction color under ten percent of the surface
- SF Pro interface hierarchy with SF Mono reserved for machine evidence
- Compact 4-point spacing scale tuned for professional density
- State motion between 140 and 220 milliseconds; no page choreography
- Every chart and status remains intelligible without color

## 2. Colors

The palette uses cool-neutral graphite surfaces, clear high-contrast ink, and one measured blue interaction voice. Semantic colors are reserved for qualification, caution, and blockers.

### Primary

- **Measured Sky:** Primary actions, active precision assignments, selected chart points, focus, and current experiment paths.
- **Measured Sky Bright:** Filled primary buttons and selected precision controls.
- **Measured Sky Wash:** Recommendation explanations and quiet selected context.

### Secondary

- **Qualified:** Structural and behavioral gates that have passed.
- **Caution:** Pending evidence, elevated KL, active workloads, and recoverable constraints.
- **Blocked:** Critical regressions and adapter-required states.

### Neutral

- **Canvas:** Deepest work surface behind data and plots.
- **Chrome:** Sidebar, inspector, toolbar-adjacent regions, and persistent navigation.
- **Surface:** Headers, drawers, and grouped controls.
- **Surface Raised:** Control tracks and higher dark-mode elevation.
- **Surface Selected:** Full-row or navigation selection fill.
- **Divider:** One-pixel structure between persistent regions and table rows.
- **Instrument Ink:** Primary text.
- **Secondary Ink:** Explanations, inactive controls, and supporting values.
- **Quiet Ink:** Metadata and tertiary labels only.

**The Ten-Percent Rule.** Measured Sky occupies no more than ten percent of a normal workspace. Its rarity preserves meaning.

**The Earned Reward Rule.** Qualified appears only after declared gates pass. Success color is evidence, not encouragement.

**The Grayscale Rule.** Every state also has a symbol, label, position, or shape. Color is never the sole carrier.

## 3. Typography

**Display Font:** SF Pro with the macOS system fallback  
**Body Font:** SF Pro with the macOS system fallback  
**Label/Mono Font:** SF Mono with the system monospaced fallback

**Character:** The native sans carries all human-facing hierarchy. SF Mono marks commands, tensor paths, hashes, aligned measurements, and literal machine output. Light-on-dark labels use decisive weight and comfortable line height rather than faint typography.

### Hierarchy

- **Headline:** Semibold 18px for page identity and model-level headings.
- **Title:** Semibold 14px for instrument and inspector titles.
- **Body:** Regular 11.5px for concise professional explanations, capped near 70 characters when prose runs long.
- **Label:** Medium 10.5px for controls, table headers, statuses, and metadata.
- **Evidence:** Medium 10.5px monospaced with tabular numerals for tensor names and measurements.

**The Native Voice Rule.** Labels use plain sentence case and platform vocabulary. Tiny tracked uppercase labels are forbidden.

**The Mono Evidence Rule.** Monospaced type marks literal machine evidence only. It never becomes the brand voice.

## 4. Elevation

Persistent surfaces are flat. Depth comes from the four-step graphite surface scale, full-width dividers, selection fills, and the native window hierarchy. The production interface does not cast shadows between the sidebar, atlas, inspector, or run drawer. Native menus, sheets, popovers, drag previews, and system tooltips retain platform elevation.

**The Resting Surface Rule.** If every region appears to float, the hierarchy has failed.

**The Dark Elevation Rule.** Higher dark-mode surfaces become slightly lighter; they do not receive heavier shadows.

## 5. Components

### Buttons

- **Shape:** Gently curved native control radius (6px).
- **Primary:** Measured Sky Bright fill, white semibold label, and 9px vertical padding. Reserved for Run, Review for promotion, and other current primary actions.
- **Hover / Focus:** Native focus ring; hover brightens slightly; press returns to Measured Sky over 140ms.
- **Quiet:** Surface fill, full Divider hairline, and Secondary Ink. Used for reversible secondary actions.
- **Disabled:** Surface Raised fill and reduced opacity, with the blocking reason available in help text.

### Chips

- **Style:** Capsule with a 12% semantic wash, matching symbol, full hairline, and explicit text.
- **State:** Blue for current allocation, green for qualified, amber for pending, red for blocked, gray for provenance.

### Cards / Containers

- **Corner Style:** Persistent workspace regions are square; only recommendation explanations and self-contained transient groups use 9px corners.
- **Background:** Canvas, Chrome, Surface, and Surface Raised establish hierarchy.
- **Shadow Strategy:** No persistent shadow.
- **Border:** Full one-pixel Divider border when a bounded group needs separation.
- **Internal Padding:** 12px compact groups, 16–18px primary workspace sections.

### Inputs / Fields

- **Style:** Native macOS controls using the 6px control radius and visible labels.
- **Focus:** Measured Sky native focus treatment with no replacement of keyboard focus.
- **Error / Disabled:** Blocked symbol plus explanation; never red alone.

### Navigation

The leading sidebar uses SF Symbols, sentence-case labels, 31px compact rows, and a full Surface Selected fill for the current destination. All destinations have menu commands and keyboard-accessible equivalents.

### Sensitivity Atlas

Each compact row aligns layer identity, an 18-segment sensitivity strip, explicit 4/8-bit controls, size delta, KL delta, and a lock-shaped guard. Selection spans the complete row. Protected modules disable incompatible precision choices and state why.

### Evidence Drawer

The drawer combines exact metrics, Pareto plot, run state, remaining work, and promotion action in one horizontal instrument. It is collapsible, keyboard accessible, and never replaces raw logs or the generated command.

## 6. Do's and Don'ts

### Do:

- **Do** preserve the native sidebar, focused atlas, contextual inspector, and optional evidence drawer composition.
- **Do** use only the defined 4, 8, 12, 16, 24, and 32px spacing steps.
- **Do** reveal Easy and Expert controls from the same recipe object.
- **Do** make every recommendation expandable into rationale, command, thresholds, parent, and evidence.
- **Do** use SF Symbols consistently and provide text labels or accessibility names for icon-only actions.
- **Do** support VoiceOver, full keyboard operation, visible focus, Reduce Motion, Reduce Transparency, increased contrast, and color-independent status.
- **Do** keep source models immutable and describe promotion as staging a new candidate.

### Don't:

- **Don't** build “a cross-platform web dashboard placed inside a desktop window.”
- **Don't** use terminal cosplay, cyberpunk neon, glowing AI brains, or science-fiction control-room decoration.
- **Don't** make opaque “one-click optimize” claims that hide commands, assumptions, calibration data, or regressions.
- **Don't** imitate enterprise observability dashboards with tiles, gauges, and unrelated status cards; Grafana is the named anti-reference.
- **Don't** sacrifice macOS conventions for lowest-common-denominator platform parity.
- **Don't** use decorative glass, excessive cards, gradient text, side-stripe accents, or animation that competes with long-running work.
- **Don't** split the product into an intimidating expert console and a simplified mode that conceals the real recipe.
- **Don't** reinvent standard controls, scrollbars, sheets, menus, inspectors, or keyboard navigation for visual novelty.
