#!/usr/bin/env python3
"""Atomic helpers for managing servers.txt inventory mappings."""

from __future__ import annotations

import argparse
import fcntl
import os
import tempfile
from pathlib import Path
from typing import List, Tuple


def parse_inventory(path: Path) -> Tuple[List[Tuple[str, str]], List[str]]:
    entries: List[Tuple[str, str]] = []
    comments: List[str] = []

    if not path.exists():
        return entries, comments

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            comments.append(raw)
            continue
        parts = line.split()
        if len(parts) >= 2:
            entries.append((parts[0], parts[1]))

    return entries, comments


def write_inventory_atomic(path: Path, entries: List[Tuple[str, str]], comments: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp") as tmp:
        tmp_path = Path(tmp.name)
        for comment in comments:
            tmp.write(f"{comment}\n")
        for name, ip in entries:
            tmp.write(f"{name} {ip}\n")
        tmp.flush()
        os.fsync(tmp.fileno())

    os.replace(tmp_path, path)


def add_mapping(path: Path, name: str, ip: str) -> None:
    entries, comments = parse_inventory(path)
    entries = [(n, existing_ip) for n, existing_ip in entries if n != name]
    entries.append((name, ip))
    write_inventory_atomic(path, entries, comments)


def remove_mapping(path: Path, name: str) -> str:
    entries, comments = parse_inventory(path)
    removed_ip = ""
    filtered: List[Tuple[str, str]] = []

    for n, ip in entries:
        if n == name and not removed_ip:
            removed_ip = ip
            continue
        filtered.append((n, ip))

    write_inventory_atomic(path, filtered, comments)
    return removed_ip


def main() -> int:
    parser = argparse.ArgumentParser(description="Atomic inventory update helper")
    parser.add_argument("--servers-file", required=True, help="Path to servers.txt")

    subparsers = parser.add_subparsers(dest="command", required=True)

    add_parser = subparsers.add_parser("add", help="Add or replace mapping")
    add_parser.add_argument("--name", required=True)
    add_parser.add_argument("--ip", required=True)

    remove_parser = subparsers.add_parser("remove", help="Remove mapping")
    remove_parser.add_argument("--name", required=True)

    args = parser.parse_args()
    servers_file = Path(args.servers_file)
    lock_path = servers_file.with_suffix(servers_file.suffix + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    with lock_path.open("w", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

        if args.command == "add":
            add_mapping(servers_file, args.name, args.ip)
            print(f"Added mapping: {args.name} {args.ip}")
        else:
            removed_ip = remove_mapping(servers_file, args.name)
            if removed_ip:
                print(f"Removed mapping: {args.name} {removed_ip}")
            else:
                print(f"No mapping found for: {args.name}")

        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
