#!/usr/bin/env python3
"""Allocate an IP for a server from expanded pool values.

Allocation is inventory-driven only:
- candidates come from pool expansion;
- in-use IPs come from servers.txt mappings.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]


def parse_servers_ips(servers_file: Path) -> set[str]:
    used: set[str] = set()
    for line in read_lines(servers_file):
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            used.add(parts[1])
    return used


def expand_pool(pool_file: Path, repo_dir: Path) -> list[str]:
    helper = repo_dir / "expand_pool.py"
    result = subprocess.run(
        [str(helper), str(pool_file)],
        check=True,
        capture_output=True,
        text=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def allocate_inventory_safe(pool: list[str], used_ips: set[str]) -> str | None:
    for ip in pool:
        if ip not in used_ips:
            return ip
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Allocate an unused IP from pool")
    parser.add_argument("--pool-file", required=True, help="Path to pool.txt")
    parser.add_argument("--servers-file", required=True, help="Path to servers.txt")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_dir = Path(__file__).resolve().parent
    pool_file = Path(args.pool_file)
    servers_file = Path(args.servers_file)

    pool = expand_pool(pool_file, repo_dir)
    used_ips = parse_servers_ips(servers_file)

    selected = allocate_inventory_safe(pool, used_ips)

    if not selected:
        print("No free IPs available", file=sys.stderr)
        return 1

    print(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
