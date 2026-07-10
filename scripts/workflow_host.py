"""Read-only, privacy-bounded local host snapshot for protocol v1."""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
import sys
from importlib import metadata
from pathlib import Path
from typing import Any

from workflow_protocol import timestamp


def _command_output(command: list[str]) -> str | None:
    try:
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _distribution_version(distribution: str) -> str | None:
    try:
        return metadata.version(distribution)
    except metadata.PackageNotFoundError:
        return None


def _mtplx_version() -> str | None:
    stable = Path("/opt/homebrew/bin/mtplx")
    executable = str(stable) if stable.is_file() else (shutil.which("mtplx") or str(stable))
    output = _command_output([executable, "--version"])
    if not output:
        return None
    match = re.search(r"\d+(?:\.\d+){1,3}(?:[-+._A-Za-z0-9]*)?", output)
    return match.group(0) if match else output.splitlines()[0][:80]


def _apple_hardware() -> dict[str, Any]:
    chip = _command_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"])
    memory = _test_memory_fixture() or _command_output(
        ["/usr/sbin/sysctl", "-n", "hw.memsize"]
    )
    try:
        memory_bytes = int(memory) if memory else None
    except ValueError:
        memory_bytes = None
    return {
        "chip": chip or platform.processor() or platform.machine() or "unknown",
        "unified_memory_bytes": memory_bytes,
        "logical_cpu_count": os.cpu_count(),
        "machine": platform.machine(),
    }


def _test_memory_fixture() -> str | None:
    """Return a deterministic memory fixture only from a source test checkout.

    The release runtime excludes ``tests/helpers``, and the Release Swift client
    never forwards these variables. This keeps production planning bound to the
    real sysctl observation while making host-fit tests portable to small CI Macs.
    """
    sentinel = Path(__file__).resolve().parents[1] / "tests" / "helpers" / "workflow_fake_stage.py"
    if os.environ.get("MLX_WORKFLOW_TEST_MODE") != "1" or not sentinel.is_file():
        return None
    raw = os.environ.get("MLX_WORKFLOW_TEST_HOST_MEMORY_BYTES")
    try:
        value = int(raw) if raw is not None else 0
    except ValueError:
        return None
    return str(value) if value > 0 else None


def _power_snapshot() -> dict[str, Any]:
    output = _command_output(["/usr/bin/pmset", "-g", "batt"])
    if not output:
        return {"source": "unavailable", "battery_percent": None}
    lowered = output.lower()
    if "ac power" in lowered:
        source = "ac"
    elif "battery power" in lowered:
        source = "battery"
    else:
        source = "unknown"
    percentage = re.search(r"(\d{1,3})%", output)
    return {
        "source": source,
        "battery_percent": int(percentage.group(1)) if percentage else None,
    }


def _thermal_snapshot() -> dict[str, Any]:
    output = _command_output(["/usr/bin/pmset", "-g", "therm"])
    if not output:
        return {"state": "unavailable", "source": "pmset"}
    lowered = output.lower()
    numeric_states = [int(value) for value in re.findall(r"notify state:\s*(\d+)", lowered)]
    if numeric_states:
        state = "nominal" if max(numeric_states) == 0 else "elevated"
    elif "no thermal warning" in lowered and "no performance warning" in lowered:
        state = "nominal"
    elif "no thermal warning" in lowered:
        state = "nominal"
    else:
        state = "reported"
    return {"state": state, "source": "pmset"}


def _workload_identity(executable: str) -> tuple[str, str] | None:
    lowered = executable.lower()
    command_path = executable.split(maxsplit=1)[0]
    process = Path(command_path).name
    if "lm studio" in lowered:
        return "lm-studio", "LM Studio"
    if "mtplx" in lowered:
        return "mtplx", process
    if "mlx_lm" in lowered or "mlx-lm" in lowered:
        return "mlx-lm", process
    if "mlx_vlm" in lowered or "mlx-vlm" in lowered:
        return "mlx-vlm", process
    return None


def _active_workloads() -> list[dict[str, Any]]:
    # Inspect arguments only for local classification, then discard them. `comm`
    # alone reports "python" for `python -m mtplx.server` and misses active jobs.
    output = _command_output(["/bin/ps", "-axo", "pid=,command="])
    if not output:
        return []
    workloads: list[dict[str, Any]] = []
    for line in output.splitlines():
        pieces = line.strip().split(maxsplit=1)
        if len(pieces) != 2 or not pieces[0].isdigit():
            continue
        identity = _workload_identity(pieces[1])
        if identity is None:
            continue
        kind, process = identity
        workloads.append({"pid": int(pieces[0]), "kind": kind, "process": process})
    return sorted(workloads, key=lambda item: item["pid"])


def snapshot_host(workspace: Path) -> dict[str, Any]:
    """Capture read-only host facts without retaining process arguments."""
    workspace = workspace.expanduser().resolve()
    if not workspace.is_dir():
        raise ValueError(f"workspace is not a directory: {workspace}")
    disk = shutil.disk_usage(workspace)
    macos_version = platform.mac_ver()[0] or None
    macos_build = _command_output(["/usr/bin/sw_vers", "-buildVersion"])
    versions = {
        "python": sys.version.split()[0],
        "mlx": _distribution_version("mlx"),
        "mlx_lm": _distribution_version("mlx-lm"),
        "transformers": _distribution_version("transformers"),
        "mtplx": _mtplx_version(),
    }
    return {
        "captured_at": timestamp(),
        "platform": platform.system(),
        "platform_release": platform.release(),
        "machine": platform.machine(),
        "python": versions["python"],
        "cpu_count": os.cpu_count(),
        "workspace": str(workspace),
        "hardware": _apple_hardware(),
        "macos": {"version": macos_version, "build": macos_build},
        "disk": {"total_bytes": disk.total, "free_bytes": disk.free},
        "versions": versions,
        "power": _power_snapshot(),
        "thermal": _thermal_snapshot(),
        "active_workloads": _active_workloads(),
    }
