import Foundation

struct WorkshopDemoFixtures {
  let model: LocalModelReference
  let runWorkspace: URL
  let currentRun: WorkshopRun
  let recipe: OptimizationRecipe
  let hostSnapshot: HostSnapshot
  let layers: [LayerRecord]
  let candidates: [CandidateRecord]
  let runs: [RunRecord]
  let behaviorCategories: [BehaviorCategory]

  static let precisionStudio = WorkshopDemoFixtures(
    model: LocalModelReference(
      directory: URL(fileURLWithPath: "/Demo/Agents-A1"), displayName: "Agents-A1",
      architecture: "Qwen3.5 MoE", format: "safetensors", sizeBytes: 65_400_000_000,
      parameterSummary: "35B parameters", sourceState: "Publisher BF16 parent",
      supportSummary: "Demo capability route"),
    runWorkspace: URL(fileURLWithPath: "/Demo/Runs"),
    currentRun: WorkshopRun(
      id: "demo-run-23", title: "Balanced 4/8 sensitivity search", state: .completed,
      stage: "qualification", progress: RunProgress(completed: 40, total: 40, unit: "blocks"),
      statusDetail: "Representative demo — not a local measurement", resumability: "not-applicable",
      runDirectory: URL(fileURLWithPath: "/Demo/Runs/demo-run-23"),
      stdoutLog: URL(fileURLWithPath: "/Demo/Runs/demo-run-23/logs/qualify.stdout.log"),
      command: CommandDisclosure(
        executableIdentity: "python3",
        arguments: [
          "scripts/mlx_workflow_cli.py", "run", "--plan",
          "/Demo/Runs/demo-run-23.plan.json",
        ],
        redactedDisplay:
          "python3 scripts/mlx_workflow_cli.py run --plan <reviewed-plan>"),
      isQualified: true),
    recipe: OptimizationRecipe(
      name: "Balanced mixed precision", qualityPriority: 0.78, sizePriority: 0.58,
      allocationStrategy: .mixedPrecision, targetBPW: 4.65, klTolerance: 0.20,
      perModuleOverrides: true, contextLength: "32K", preserveEmbeddings: true,
      preserveOutputHead: true, protectSensitiveLayers: true,
      calibrationSuite: "Agent + code balanced", calibrationSampleBudget: 40,
      calibrationTokenBudget: 32_768, calibrationSeed: 42),
    hostSnapshot: HostSnapshot(
      chip: "Apple M3 Ultra", unifiedMemory: "64 GiB", availableMemory: "26.1 GiB",
      freeDisk: "318 GiB", operatingSystem: "macOS 26", mlxVersion: "0.31.2",
      mlxLMVersion: "0.31.3", activeWorkloads: ["MTPLX server", "LM Studio"]),
    layers: makeLayers(),
    candidates: [
      CandidateRecord(
        name: "Publisher BF16", recipe: "Immutable parent", sizeGB: 65.4, throughput: 19.8,
        kl: 0, score: 65, criticalRegressions: 0, status: .parent),
      CandidateRecord(
        name: "Uniform MXFP4", recipe: "4-bit · group 32", sizeGB: 18.9, throughput: 71.2,
        kl: 0.31, score: 57, criticalRegressions: 1, status: .rejected),
      CandidateRecord(
        name: "Balanced 4/8", recipe: "4.65 BPW · protected head", sizeGB: 22.6,
        throughput: 68.2, kl: 0.09, score: 63, criticalRegressions: 0, status: .qualified),
      CandidateRecord(
        name: "Fidelity 4/8", recipe: "5.12 BPW · 14 layers at 8-bit", sizeGB: 25.8,
        throughput: 61.7, kl: 0.04, score: 64, criticalRegressions: 0, status: .qualified),
      CandidateRecord(
        name: "Uniform MXFP8", recipe: "8-bit · group 32", sizeGB: 36.8, throughput: 43.3,
        kl: 0.02, score: 64, criticalRegressions: 0, status: .experimental),
    ],
    runs: [
      RunRecord(
        runID: "demo-run-23",
        number: 23, title: "Balanced 4/8 sensitivity search", created: "Today, 9:41 AM",
        duration: "2m 14s", state: .completed, summary: "22.6 GB · KL 0.09 · 68.2 tok/s"),
      RunRecord(
        runID: "demo-run-22",
        number: 22, title: "Fidelity 4/8 validation", created: "Yesterday, 7:18 PM",
        duration: "18m 42s", state: .completed,
        summary: "25.8 GB · 64/65 · no critical regressions"),
      RunRecord(
        runID: "demo-run-21",
        number: 21, title: "Uniform MXFP4 baseline", created: "Yesterday, 5:02 PM",
        duration: "11m 08s", state: .failed,
        summary: "Tool schema regression in parallel plan"),
      RunRecord(
        runID: "demo-run-20",
        number: 20, title: "Host baseline", created: "Jul 8, 2:31 PM", duration: "4m 16s",
        state: .completed, summary: "M3 Ultra · 64 GiB · MLX 0.31.2"),
    ],
    behaviorCategories: [
      BehaviorCategory(name: "Weapons", parentRate: 0.92, candidateRate: 0.18, sampleCount: 12),
      BehaviorCategory(
        name: "Cybersecurity", parentRate: 0.83, candidateRate: 0.25, sampleCount: 12),
      BehaviorCategory(
        name: "Sensitive advice", parentRate: 0.75, candidateRate: 0.17, sampleCount: 12),
      BehaviorCategory(
        name: "Benign controls", parentRate: 0.08, candidateRate: 0.08, sampleCount: 12),
    ])

  private static func makeLayers() -> [LayerRecord] {
    let rows: [(Int, String, String, Double, Precision, Double, Double, Bool)] = [
      (0, "embed_tokens", "Embedding", 0.91, .eight, 0.0, 0.003, true),
      (0, "attn.q_proj", "Attention", 0.78, .eight, -1.2, 0.012, false),
      (0, "attn.k_proj", "Attention", 0.36, .four, -3.8, 0.067, false),
      (0, "attn.v_proj", "Attention", 0.44, .four, -3.6, 0.041, false),
      (0, "attn.o_proj", "Residual writer", 0.86, .eight, -1.1, 0.011, true),
      (0, "mlp.gate_proj", "MLP", 0.70, .eight, -2.4, 0.052, false),
      (0, "mlp.up_proj", "MLP", 0.53, .four, -4.0, 0.031, false),
      (0, "mlp.down_proj", "Residual writer", 0.88, .eight, -4.2, 0.081, true),
      (1, "attn.q_proj", "Attention", 0.48, .four, -1.2, 0.018, false),
      (1, "attn.o_proj", "Residual writer", 0.82, .eight, -1.1, 0.014, true),
      (1, "shared_expert.down", "MoE residual", 0.76, .eight, -2.7, 0.044, true),
      (2, "switch_mlp.down", "MoE residual", 0.61, .four, -4.4, 0.072, false),
      (14, "attn.o_proj", "Residual writer", 0.94, .eight, -1.1, 0.009, true),
      (18, "shared_expert.down", "MoE residual", 0.84, .eight, -2.7, 0.039, true),
      (39, "final_norm", "Normalization", 0.89, .eight, 0.0, 0.006, true),
      (40, "lm_head", "Output projection", 0.98, .eight, 0.0, 0.002, true),
    ]
    return rows.map { row in
      LayerRecord(
        index: row.0, name: row.1, kind: row.2, sensitivity: row.3, precision: row.4,
        sizeDelta: row.5, klDelta: row.6, isProtected: row.7)
    }
  }
}
