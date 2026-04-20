#!/usr/bin/env python3
"""Register or update an MCS process instance for this bedrock cluster wrapper flow.

This script upserts an MCS instance and can optionally maintain a per-server
partial server.properties profile file.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional

from mcs_bedrock_actions import build_action_commands, schema_for_custom_card

REPO_DIR = Path(__file__).resolve().parent
DEFAULT_PROPERTIES_DIR = REPO_DIR / "properties.d"


def parse_key_values(entries: list[str]) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for entry in entries:
        if "=" not in entry:
            raise ValueError(f"Invalid --property value (expected key=value): {entry}")
        key, value = entry.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"Invalid empty key in --property value: {entry}")
        values[key] = value
    return values


def read_properties(path: Path) -> Dict[str, str]:
    props: Dict[str, str] = {}
    if not path.exists():
        return props
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in raw:
            raise ValueError(f"Invalid properties line in {path}: {raw}")
        key, value = raw.split("=", 1)
        props[key.strip()] = value.strip()
    return props


def write_properties(path: Path, props: Dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{k}={v}" for k, v in sorted(props.items())]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def has_mcs_credentials(panel_url: str, api_key: str, daemon_id: str) -> bool:
    return bool(panel_url and api_key and daemon_id)


def api_request(base_url: str, method: str, route: str, api_key: str, query: Dict[str, Any], body: Any | None = None) -> Dict[str, Any]:
    query_pairs = {"apikey": api_key}
    query_pairs.update(query)
    full_url = f"{base_url.rstrip('/')}{route}?{urllib.parse.urlencode(query_pairs, doseq=True)}"

    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")

    request = urllib.request.Request(
        url=full_url,
        method=method,
        data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "X-Requested-With": "XMLHttpRequest",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"MCS API HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"MCS API connection failed: {exc}") from exc

    if payload.get("status") != 200:
        raise RuntimeError(f"MCS API error: {payload}")

    return payload


def find_instance_by_name(base_url: str, api_key: str, daemon_id: str, name: str) -> Optional[str]:
    payload = api_request(
        base_url,
        "GET",
        "/api/service/remote_service_instances",
        api_key,
        {
            "daemonId": daemon_id,
            "page": 1,
            "page_size": 200,
            "instance_name": name,
            "status": "",
        },
    )

    items = payload.get("data", {}).get("data", [])
    for item in items:
        config = item.get("config", {})
        if config.get("nickname") == name:
            return item.get("instanceUuid")
    return None


def build_instance_config(name: str, repo_dir: Path, profile_arg: str | None) -> Dict[str, Any]:
    create_script = repo_dir / "create-server.sh"
    destroy_script = repo_dir / "destroy-server.sh"
    terminate_script = repo_dir / "terminate-server.sh"
    update_script = repo_dir / "update-server.sh"
    quoted_name = shlex.quote(name)

    if profile_arg:
        start_command = (
            f"{shlex.quote(str(create_script))} -p {shlex.quote(profile_arg)} {quoted_name}"
        )
    else:
        start_command = f"{shlex.quote(str(create_script))} {quoted_name}"

    actions = build_action_commands(name, repo_dir)
    actions.append(
        {
            "name": "Terminate Server (Destroy Container)",
            "command": f"{shlex.quote(str(terminate_script))} --force {quoted_name}",
        }
    )

    return {
        "nickname": name,
        "startCommand": start_command,
        "stopCommand": f"{shlex.quote(str(destroy_script))} {quoted_name}",
        "cwd": str(repo_dir),
        "ie": "utf-8",
        "oe": "utf-8",
        "type": "universal",
        "tag": ["bedrock-cluster", "bedrock-settings-ui-v1"],
        "processType": "",
        "updateCommand": f"{shlex.quote(str(update_script))} --verify {quoted_name}",
        "actionCommandList": actions,
        "crlf": 0,
        "docker": {},
        "terminalOption": {
            "haveColor": True,
            "pty": True,
        },
        "eventTask": {
            "autoStart": False,
            "autoRestart": False,
            "ignore": False,
        },
        "pingConfig": {
            "ip": "",
            "port": 19132,
            "type": 1,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Upsert MCS instance for bedrock cluster wrapper")
    parser.add_argument("--panel-url", default=os.getenv("MCSM_PANEL_URL", ""), help="MCS panel base URL, e.g. http://host:23333")
    parser.add_argument("--api-key", default=os.getenv("MCSM_API_KEY", ""), help="MCS user API key")
    parser.add_argument("--daemon-id", default=os.getenv("MCSM_DAEMON_ID", ""), help="MCS daemon ID")
    parser.add_argument("--name", required=True, help="Instance/server name")
    parser.add_argument("--properties-file", default="", help="Path to partial server.properties profile")
    parser.add_argument("--property", action="append", default=[], help="Add/update profile key=value (repeatable)")
    args = parser.parse_args()

    try:
        profile_path: Optional[Path] = None
        profile_ref: Optional[str] = None
        if args.properties_file:
            profile_path = Path(args.properties_file).resolve()
            profile_ref = str(profile_path)
        elif args.property:
            profile_path = (DEFAULT_PROPERTIES_DIR / f"{args.name}.server.properties").resolve()
            profile_ref = str(profile_path)

        if profile_path is not None:
            current = read_properties(profile_path)
            current.update(parse_key_values(args.property))
            write_properties(profile_path, current)
            print(f"Profile updated: {profile_path}")

        schema_path = REPO_DIR / "properties.d" / f"{args.name}.ui.schema.json"
        schema_path.write_text(
            json.dumps(schema_for_custom_card(), indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"UI schema refreshed: {schema_path}")

        if not has_mcs_credentials(args.panel_url, args.api_key, args.daemon_id):
            if profile_path is not None:
                print("MCS credentials not set; skipped instance registration and applied local profile update only")
                return 0
            print("panel-url, api-key, and daemon-id are required (or set MCSM_PANEL_URL/MCSM_API_KEY/MCSM_DAEMON_ID)", file=sys.stderr)
            return 2

        config = build_instance_config(args.name, REPO_DIR, profile_ref)
        existing_uuid = find_instance_by_name(args.panel_url, args.api_key, args.daemon_id, args.name)

        if existing_uuid:
            api_request(
                args.panel_url,
                "PUT",
                "/api/instance",
                args.api_key,
                {"daemonId": args.daemon_id, "uuid": existing_uuid},
                config,
            )
            print(f"Updated instance: {args.name} ({existing_uuid})")
        else:
            created = api_request(
                args.panel_url,
                "POST",
                "/api/instance",
                args.api_key,
                {"daemonId": args.daemon_id},
                config,
            )
            instance_uuid = created.get("data", {}).get("instanceUuid", "<unknown>")
            print(f"Created instance: {args.name} ({instance_uuid})")

        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"Registration failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
