#!/usr/bin/env python3
"""Generate the public runtime component and license inventory."""

from __future__ import annotations

import argparse
import importlib.metadata
from pathlib import Path


LICENSE_OVERRIDES = {
    "jinja2": "BSD-3-Clause",
    "markdown-it-py": "MIT",
    "mdurl": "MIT",
    "protobuf": "BSD-3-Clause",
    "safetensors": "Apache-2.0",
    "sentencepiece": "Apache-2.0",
    "tokenizers": "Apache-2.0",
    "transformers": "Apache-2.0",
}


def license_name(distribution: importlib.metadata.Distribution) -> str:
    name = (distribution.metadata.get("Name") or "").lower()
    expression = distribution.metadata.get("License-Expression")
    if expression:
        return expression.strip()
    raw = distribution.metadata.get("License")
    if raw and len(raw.strip()) < 120 and "\n" not in raw:
        return raw.strip()
    if name in LICENSE_OVERRIDES:
        return LICENSE_OVERRIDES[name]
    classifiers = [
        value.removeprefix("License :: ").strip()
        for value in distribution.metadata.get_all("Classifier", [])
        if value.startswith("License :: ")
    ]
    return "; ".join(classifiers) or "See bundled distribution license metadata"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    rows = []
    for distribution in sorted(
        importlib.metadata.distributions(),
        key=lambda item: (item.metadata.get("Name") or "").lower(),
    ):
        name = distribution.metadata.get("Name")
        if not name:
            continue
        rows.append((name, distribution.version, license_name(distribution)))

    lines = [
        "# Third-party notices",
        "",
        "MLX Workshop bundles CPython 3.11.14 under the Python Software Foundation",
        "License (PSF-2.0). The complete CPython license is retained at",
        "`Runtime/licenses/CPython-3.11.14-LICENSE.txt` in the application bundle.",
        "Tcl/Tk license terms distributed with CPython remain at their original runtime paths.",
        "",
        "Python package license files and metadata are retained inside each installed",
        "`.dist-info` directory. Nested vendored notices remain in their original package",
        "locations. This inventory is generated from the exact locked release runtime.",
        "",
        "| Component | Version | License |",
        "| --- | --- | --- |",
    ]
    lines.extend(f"| {name} | {version} | {license_value} |" for name, version, license_value in rows)
    lines.extend(
        [
            "",
            "MLX Workshop itself is licensed under Apache-2.0. Component names and",
            "trademarks belong to their respective owners.",
            "",
        ]
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
