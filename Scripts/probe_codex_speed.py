#!/usr/bin/env python3
"""Verify speed changes with a specified Codex binary and a synthetic loopback backend.

Uses an isolated HOME/CODEX_HOME, no real accounts or desktop process. Only the
observed tier and completion status are returned, never request or credential data.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

from probe_codex_replay_compatibility import AppServer, FixtureServer


def probe(binary: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="headroom-speed-probe-") as directory:
        root = Path(directory)
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory,
            "CODEX_HOME": directory, "TMPDIR": directory,
            "NO_PROXY": "127.0.0.1,localhost", "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        }
        server = FixtureServer()
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        config = f'''model = "gpt-6.1-sol"
model_provider = "fixture_provider"
service_tier = "default"
web_search = "disabled"
check_for_update_on_startup = false
[features]
fast_mode = true
[analytics]
enabled = false
[feedback]
enabled = false
[model_providers.fixture_provider]
name = "Headroom offline fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
'''
        (root / "config.toml").write_text(config)
        client = None
        try:
            version = subprocess.run([str(binary), "--version"], env=env, check=True,
                                     capture_output=True, text=True, timeout=10).stdout.strip()
            client = AppServer(binary, root, env)

            def start_thread():
                return client.rpc("thread/start", {
                    "model": "gpt-6.1-sol", "modelProvider": "fixture_provider", "ephemeral": True,
                    "approvalPolicy": "never", "sandbox": "read-only",
                })["thread"]["id"]

            def turn(thread_id, **overrides):
                before = len(server.requests)
                client.rpc("turn/start", {
                    "threadId": thread_id, "input": [{"type": "text", "text": "Reply OK. No tools."}],
                    **overrides,
                })
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    event = client.next_event(deadline)
                    if (event.get("method") == "turn/completed" and
                            event.get("params", {}).get("threadId") == thread_id):
                        if len(server.requests) != before + 1:
                            raise RuntimeError("Expected one synthetic request, no tool or retry requests.")
                        return {"tier": server.requests[-1].get("service_tier"),
                                "status": event["params"]["turn"]["status"]}
                raise TimeoutError("Isolated speed turn timed out.")

            def write_tier(tier):
                (root / "next.toml").write_text(config.replace(
                    'service_tier = "default"', f'service_tier = "{tier}"'))
                os.replace(root / "next.toml", root / "config.toml")

            thread_id = start_thread()
            results = {"initial_standard": turn(thread_id)}
            write_tier("fast")
            results["existing_thread_after_fast_write"] = turn(thread_id)
            results["new_thread_after_fast_write"] = turn(start_thread())
            write_tier("default")
            results["new_thread_after_standard_write"] = turn(start_thread())
            results["explicit_existing_thread_override"] = turn(thread_id, serviceTier="fast")
            results["explicit_existing_thread_standard"] = turn(thread_id, serviceTier="default")
            expected = {"initial_standard": None, "existing_thread_after_fast_write": None,
                        "new_thread_after_fast_write": "priority", "new_thread_after_standard_write": None,
                        "explicit_existing_thread_override": "priority", "explicit_existing_thread_standard": None}
            if any(results[key] != {"tier": tier, "status": "completed"} for key, tier in expected.items()):
                raise RuntimeError("Codex speed behavior changed; inspect the isolated probe before publishing.")
            return {"codex_version": version, "synthetic_backend": True, "checks": results,
                    "new_chats_read_disk_speed": True, "loaded_chats_read_disk_speed": False}
        finally:
            if client is not None:
                client.close()
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    receipt = probe(args.codex.resolve(strict=True))
    text = json.dumps(receipt, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
