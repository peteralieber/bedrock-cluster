#!/usr/bin/env python3
"""Apply a partial Bedrock server.properties profile to a target server.properties file."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, Tuple

# Focused set of important Bedrock server properties for strict validation.
# Unknown keys can be allowed via --allow-unknown.
ALLOWED_KEYS = {
    "server-name",
    "gamemode",
    "force-gamemode",
    "difficulty",
    "allow-cheats",
    "max-players",
    "online-mode",
    "allow-list",
    "server-port",
    "server-portv6",
    "enable-lan-visibility",
    "view-distance",
    "tick-distance",
    "player-idle-timeout",
    "max-threads",
    "level-name",
    "level-seed",
    "default-player-permission-level",
    "texturepack-required",
    "content-log-file-enabled",
    "compression-threshold",
    "compression-algorithm",
    "chat-restriction",
    "disable-player-interaction",
    "client-side-chunk-generation-enabled",
    "disable-custom-skins",
}

BOOL_KEYS = {
    "force-gamemode",
    "allow-cheats",
    "online-mode",
    "allow-list",
    "enable-lan-visibility",
    "texturepack-required",
    "content-log-file-enabled",
    "disable-player-interaction",
    "client-side-chunk-generation-enabled",
    "disable-custom-skins",
}

ENUM_KEYS = {
    "gamemode": {"survival", "creative", "adventure"},
    "difficulty": {"peaceful", "easy", "normal", "hard"},
    "default-player-permission-level": {"visitor", "member", "operator"},
    "compression-algorithm": {"zlib", "snappy"},
    "chat-restriction": {"None", "Dropped", "Disabled"},
}

KEY_LINE_RE = re.compile(r"^([^=#\s][^=]*)=(.*)$")


def parse_properties(path: Path) -> Tuple[Dict[str, str], list[str]]:
    props: Dict[str, str] = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = KEY_LINE_RE.match(raw)
        if not match:
            raise ValueError(f"Invalid properties syntax at {path}:{index}: {raw}")
        key = match.group(1).strip()
        value = match.group(2).strip()
        props[key] = value
    return props, lines


def validate_key_value(key: str, value: str, allow_unknown: bool) -> None:
    if key not in ALLOWED_KEYS and not allow_unknown:
        raise ValueError(f"Unknown key in profile: {key}")

    if key in BOOL_KEYS and value not in {"true", "false"}:
        raise ValueError(f"{key} must be true/false, got: {value}")

    if key in ENUM_KEYS and value not in ENUM_KEYS[key]:
        allowed = ", ".join(sorted(ENUM_KEYS[key]))
        raise ValueError(f"{key} must be one of [{allowed}], got: {value}")

    if key in {"max-players", "server-port", "server-portv6", "view-distance", "tick-distance", "player-idle-timeout", "max-threads", "compression-threshold"}:
        try:
            number = int(value)
        except ValueError as exc:
            raise ValueError(f"{key} must be an integer, got: {value}") from exc

        if key in {"server-port", "server-portv6"} and not (1 <= number <= 65535):
            raise ValueError(f"{key} must be in [1, 65535], got: {number}")
        if key == "view-distance" and number < 5:
            raise ValueError("view-distance must be >= 5")
        if key == "tick-distance" and not (4 <= number <= 12):
            raise ValueError("tick-distance must be in [4, 12]")
        if key == "max-players" and number <= 0:
            raise ValueError("max-players must be > 0")
        if key == "max-threads" and number <= 0:
            raise ValueError("max-threads must be > 0")
        if key in {"player-idle-timeout", "compression-threshold"} and number < 0:
            raise ValueError(f"{key} must be >= 0")


def merge_lines(base_lines: list[str], updates: Dict[str, str]) -> list[str]:
    remaining = dict(updates)
    merged: list[str] = []

    for raw in base_lines:
        match = KEY_LINE_RE.match(raw)
        if not match:
            merged.append(raw)
            continue

        key = match.group(1).strip()
        if key in remaining:
            merged.append(f"{key}={remaining.pop(key)}")
        else:
            merged.append(raw)

    if remaining:
        if merged and merged[-1].strip():
            merged.append("")
        merged.append("# Added from managed profile")
        for key in sorted(remaining):
            merged.append(f"{key}={remaining[key]}")

    return merged


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply partial Bedrock server.properties to target file")
    parser.add_argument("--profile", required=True, help="Path to partial profile file")
    parser.add_argument("--target", required=True, help="Path to full server.properties file")
    parser.add_argument("--allow-unknown", action="store_true", help="Allow keys outside the strict allow-list")
    args = parser.parse_args()

    profile_path = Path(args.profile)
    target_path = Path(args.target)

    if not profile_path.exists():
        print(f"Profile not found: {profile_path}", file=sys.stderr)
        return 2

    if not target_path.exists():
        print(f"Target file not found: {target_path}", file=sys.stderr)
        return 2

    try:
        profile_props, _ = parse_properties(profile_path)
        for key, value in profile_props.items():
            validate_key_value(key, value, args.allow_unknown)

        _, target_lines = parse_properties(target_path)
        # Re-read full text lines to preserve comments and blank lines exactly.
        target_lines = target_path.read_text(encoding="utf-8").splitlines()

        merged = merge_lines(target_lines, profile_props)
        target_path.write_text("\n".join(merged) + "\n", encoding="utf-8")
        print(f"Applied {len(profile_props)} key(s) from {profile_path} -> {target_path}")
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"Failed to apply properties: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
