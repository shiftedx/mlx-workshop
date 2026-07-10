#!/usr/bin/env python3
"""Deterministic child process used by MLX Workflow integration tests."""

from __future__ import annotations

import argparse
import os
import signal
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()

    if args.scenario in {"success", "warning"}:
        print("fixture midpoint", flush=True)
        if args.scenario == "warning":
            print("api_key=fixture-secret", file=sys.stderr, flush=True)
        artifact = args.run_dir / "artifacts" / "candidate"
        artifact.mkdir(parents=True, exist_ok=True)
        (artifact / "fixture.txt").write_text("complete\n", encoding="utf-8")
        return 0
    if args.scenario == "failure":
        print("deterministic failure", file=sys.stderr, flush=True)
        return 23
    if args.scenario == "stderr-flood":
        chunk = "x" * 4096
        for index in range(256):
            print(f"{index:04d}:{chunk}", file=sys.stderr)
        sys.stderr.flush()
        return 0
    if args.scenario in {"cancel", "interrupt-once"}:
        marker = args.run_dir / "artifacts" / ".interrupt-once-started"
        if args.scenario == "interrupt-once" and marker.exists():
            print("resumed fixture completed", flush=True)
            return 0
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(str(os.getpid()), encoding="utf-8")

        def stop(_signal: int, _frame: object) -> None:
            print("fixture received termination", file=sys.stderr, flush=True)
            raise SystemExit(143)

        signal.signal(signal.SIGTERM, stop)
        print("fixture waiting for cancellation", flush=True)
        while True:
            time.sleep(0.05)
    parser.error(f"unknown scenario: {args.scenario}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
