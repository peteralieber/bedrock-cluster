#!/usr/bin/env python3
"""Synchronize MCS ping target IP for a registered instance by name."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional


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


def get_ip_for_name(servers_file: Path, name: str) -> Optional[str]:
    if not servers_file.exists():
        return None

    for raw in servers_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[0] == name:
            return parts[1]

    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync MCS ping target to inventory IP")
    parser.add_argument("--name", required=True, help="Instance/server name")
    parser.add_argument("--panel-url", default=os.getenv("MCSM_PANEL_URL", ""), help="MCS panel URL")
    parser.add_argument("--api-key", default=os.getenv("MCSM_API_KEY", ""), help="MCS API key")
    parser.add_argument("--daemon-id", default=os.getenv("MCSM_DAEMON_ID", ""), help="MCS daemon ID")
    parser.add_argument("--servers-file", default="", help="Optional explicit servers.txt path")
    parser.add_argument("--best-effort", action="store_true", help="Return success when MCS is not configured or instance is missing")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    servers_file = Path(args.servers_file).resolve() if args.servers_file else script_dir / "servers.txt"

    ip = get_ip_for_name(servers_file, args.name)
    if not ip:
        message = f"No inventory IP found for {args.name} in {servers_file}"
        if args.best_effort:
            print(f"[MCSM] Ping sync skipped: {message}")
            return 0
        print(message, file=sys.stderr)
        return 2

    if not args.panel_url or not args.api_key or not args.daemon_id:
        message = "panel-url, api-key, and daemon-id are required for ping sync"
        if args.best_effort:
            print(f"[MCSM] Ping sync skipped: {message}")
            return 0
        print(message, file=sys.stderr)
        return 2

    try:
        instance_uuid = find_instance_by_name(args.panel_url, args.api_key, args.daemon_id, args.name)
        if not instance_uuid:
            message = f"Instance not found in MCS for name: {args.name}"
            if args.best_effort:
                print(f"[MCSM] Ping sync skipped: {message}")
                return 0
            print(message, file=sys.stderr)
            return 3

        api_request(
            args.panel_url,
            "PUT",
            "/api/instance",
            args.api_key,
            {"daemonId": args.daemon_id, "uuid": instance_uuid},
            {"pingConfig": {"ip": ip, "port": 19132, "type": 1}},
        )
        print(f"[MCSM] Ping sync updated for {args.name} -> {ip}:19132")
        return 0
    except Exception as exc:  # noqa: BLE001
        if args.best_effort:
            print(f"[MCSM] Ping sync skipped: {exc}")
            return 0
        print(f"Ping sync failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
