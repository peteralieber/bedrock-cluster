#!/usr/bin/env python3
"""Bedrock settings schema and action-command generation for MCS integration."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

# Schema intended for custom MCS HTML card rendering (text boxes/selectors/toggles).
BEDROCK_UI_FIELDS: List[Dict[str, Any]] = [
    {
        "key": "server-name",
        "label": "Server Name",
        "control": "text",
        "required": False,
        "description": "Display name in server browser.",
    },
    {
        "key": "level-name",
        "label": "Level Name",
        "control": "text",
        "required": False,
        "description": "World folder to load from worlds/.",
    },
    {
        "key": "level-seed",
        "label": "Level Seed",
        "control": "text",
        "required": False,
        "description": "Seed string for world generation.",
    },
    {
        "key": "gamemode",
        "label": "Gamemode",
        "control": "select",
        "options": ["survival", "creative", "adventure"],
    },
    {
        "key": "difficulty",
        "label": "Difficulty",
        "control": "select",
        "options": ["peaceful", "easy", "normal", "hard"],
    },
    {
        "key": "allow-cheats",
        "label": "Allow Cheats",
        "control": "select",
        "options": ["false", "true"],
    },
    {
        "key": "allow-list",
        "label": "Allow List",
        "control": "select",
        "options": ["false", "true"],
    },
    {
        "key": "max-players",
        "label": "Max Players",
        "control": "number",
        "min": 1,
        "max": 200,
    },
]


def schema_for_custom_card() -> List[Dict[str, Any]]:
    """Return Bedrock UI field schema for custom MCS card rendering."""
    return [dict(field) for field in BEDROCK_UI_FIELDS]


def _setter_command(python_bin: str, repo_dir: Path, name: str, key: str, value: str) -> str:
    register_script = repo_dir / "mcs_register.py"
    return (
        f"{python_bin} {register_script} --name {name} "
        f"--property {key}={value}"
    )


def build_action_commands(name: str, repo_dir: Path, python_bin: str = "python3") -> List[Dict[str, str]]:
    """Build selector-style action commands visible in MCS instance UI.

    Each action writes a profile key/value using mcs_register.py.
    """
    actions: List[Dict[str, str]] = []

    for mode in ["survival", "creative", "adventure"]:
        actions.append(
            {
                "name": f"Set Gamemode: {mode}",
                "command": _setter_command(python_bin, repo_dir, name, "gamemode", mode),
            }
        )

    for difficulty in ["peaceful", "easy", "normal", "hard"]:
        actions.append(
            {
                "name": f"Set Difficulty: {difficulty}",
                "command": _setter_command(python_bin, repo_dir, name, "difficulty", difficulty),
            }
        )

    for value in ["false", "true"]:
        actions.append(
            {
                "name": f"Set Allow Cheats: {value}",
                "command": _setter_command(python_bin, repo_dir, name, "allow-cheats", value),
            }
        )
        actions.append(
            {
                "name": f"Set Allow List: {value}",
                "command": _setter_command(python_bin, repo_dir, name, "allow-list", value),
            }
        )

    return actions
