#!/usr/bin/env python3
"""Import a .mcworld archive into a Bedrock server container rootfs.

This script is intentionally non-destructive:
- it refuses to overwrite an existing destination world folder;
- it validates there is a world folder containing level.dat;
- it updates server.properties level-name to match the imported world folder name.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Import a .mcworld file into a Bedrock server container")
    parser.add_argument("--source", required=True, help="Path to .mcworld archive")
    parser.add_argument("--container-root", required=True, help="Container rootfs path")
    parser.add_argument("--server-name", required=True, help="Server/container name (for diagnostics)")
    return parser.parse_args()


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def find_world_dir(extract_root: Path) -> Path:
    candidates = []
    for path in extract_root.rglob("level.dat"):
        parent = path.parent
        if parent.is_dir():
            candidates.append(parent)

    if not candidates:
        fail("No world folder containing level.dat was found in archive")

    # Prefer shallowest path to avoid picking nested backup folders.
    candidates.sort(key=lambda p: len(p.relative_to(extract_root).parts))
    return candidates[0]


def update_level_name(server_properties: Path, level_name: str) -> None:
    if not server_properties.is_file():
        fail(f"Expected server.properties not found at: {server_properties}")

    lines = server_properties.read_text(encoding="utf-8").splitlines()
    out = []
    replaced = False
    for line in lines:
        if line.startswith("level-name="):
            out.append(f"level-name={level_name}")
            replaced = True
        else:
            out.append(line)

    if not replaced:
        out.append(f"level-name={level_name}")

    server_properties.write_text("\n".join(out) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()

    source = Path(args.source).resolve()
    if not source.is_file():
        fail(f"World archive not found: {source}")

    if source.suffix.lower() != ".mcworld":
        fail(f"Expected a .mcworld file, got: {source.name}")

    container_root = Path(args.container_root)
    bedrock_root = container_root / "opt" / "bedrock"
    worlds_root = bedrock_root / "worlds"
    server_properties = bedrock_root / "server.properties"

    if not bedrock_root.is_dir():
        fail(f"Expected Bedrock directory not found at: {bedrock_root}")

    worlds_root.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="mcworld-import-") as tmp_dir:
        extract_root = Path(tmp_dir)
        try:
            with zipfile.ZipFile(source) as archive:
                archive.extractall(extract_root)
        except zipfile.BadZipFile as exc:
            fail(f"Invalid .mcworld archive: {exc}")

        world_dir = find_world_dir(extract_root)
        world_name = world_dir.name
        destination = worlds_root / world_name

        if destination.exists():
            fail(
                "Destination world already exists; refusing to overwrite: "
                f"{destination}"
            )

        shutil.copytree(world_dir, destination)
        update_level_name(server_properties, world_name)

    print(
        f"Imported {source.name} into server {args.server_name} as world '{world_name}'"
    )


if __name__ == "__main__":
    main()
