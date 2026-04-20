#!/usr/bin/env python3
"""Render the reusable MCS template JSON into an instance-specific JSON file."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


DEFAULT_TEMPLATE = Path(__file__).resolve().parent / "mcs_template_bedrock_process.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render MCS template placeholders")
    parser.add_argument("--name", required=True, help="Server/instance name")
    parser.add_argument(
        "--template",
        default=str(DEFAULT_TEMPLATE),
        help="Path to template JSON (default: mcs_template_bedrock_process.json)",
    )
    parser.add_argument(
        "--output",
        default="",
        help="Output file path (default: ./mcs_instance_<name>.json)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    template_path = Path(args.template).resolve()
    if not template_path.exists():
        raise SystemExit(f"Template not found: {template_path}")

    raw = template_path.read_text(encoding="utf-8")
    rendered = raw.replace("{{SERVER_NAME}}", args.name)

    output_path = Path(args.output) if args.output else Path.cwd() / f"mcs_instance_{args.name}.json"
    output_path.write_text(json.dumps(json.loads(rendered), indent=2) + "\n", encoding="utf-8")
    print(str(output_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
