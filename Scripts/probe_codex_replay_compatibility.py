#!/usr/bin/env python3
"""Isolated Codex replay probe using synthetic items and a loopback Responses server.

No real account, rollout, profile, login, route or desktop process is accessed. This
checks the HTTP request path of the explicitly supplied Codex executable, not desktop
middleware integration. It requires a built CodexBarCLI with history prepare-request.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import struct
import subprocess
import tempfile
import threading
import time
import zlib


def fixture_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff")) + chunk(b"IEND", b""))


class FixtureServer(http.server.HTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.requests = []


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(request)
        for index, item in enumerate(request.get("input", [])):
            if item.get("type") == "reasoning" and item.get("id", "").startswith("item_"):
                body = json.dumps({"error": {
                    "type": "invalid_request_error", "code": "invalid_id_prefix",
                    "param": f"input[{index}].id",
                    "message": f"Invalid 'input[{index}].id'. Expected an ID that begins with 'rs'.",
                }}).encode()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        message = {"type": "message", "id": "msg_fixture_reply", "role": "assistant",
                   "status": "completed", "content": [{"type": "output_text", "text": "Fixture continuation passed."}]}
        events = [
            {"type": "response.created", "response": {"id": "resp_fixture", "status": "in_progress", "output": []}},
            {"type": "response.output_item.added", "output_index": 0, "item": message},
            {"type": "response.output_text.delta", "output_index": 0, "content_index": 0,
             "item_id": message["id"], "delta": "Fixture continuation passed."},
            {"type": "response.output_item.done", "output_index": 0, "item": message},
            {"type": "response.completed", "response": {"id": "resp_fixture", "status": "completed", "output": [message],
             "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}},
        ]
        body = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class AppServer:
    def __init__(self, binary, root, env):
        self.events = queue.Queue()
        self.sequence = 0
        self.process = subprocess.Popen([str(binary), "app-server", "--stdio"], cwd=root, env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        text=True, start_new_session=True)
        self.reader = threading.Thread(target=self.read_events, daemon=True)
        self.reader.start()
        try:
            self.rpc("initialize", {"clientInfo": {"name": "headroom_replay_fixture", "version": "1.0"},
                                    "capabilities": {"experimentalApi": True}})
            self.write({"method": "initialized"})
        except BaseException:
            self.close()
            raise

    def read_events(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except json.JSONDecodeError:
                pass
        self.events.put(None)

    def write(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def next_event(self, deadline):
        event = self.events.get(timeout=max(0.01, deadline - time.monotonic()))
        if event is None:
            raise RuntimeError("Isolated app-server exited before completing the fixture.")
        return event

    def rpc(self, method, params):
        self.sequence += 1
        sequence = self.sequence
        self.write({"id": sequence, "method": method, "params": params})
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            event = self.next_event(deadline)
            if event.get("id") == sequence:
                if "error" in event:
                    raise RuntimeError(f"Isolated {method} rejected (code {event['error'].get('code')}).")
                return event["result"]
        raise TimeoutError(f"Isolated {method} timed out.")

    def turn(self, items, image_path=None):
        result = self.rpc("thread/start", {"model": "gpt-5.4", "modelProvider": "fixture_provider",
                                          "ephemeral": True, "approvalPolicy": "never", "sandbox": "read-only"})
        thread = result["thread"]["id"]
        self.rpc("thread/inject_items", {"threadId": thread, "items": items})
        turn_input = [{"type": "text", "text": "Continue the fixture."}]
        if image_path is not None:
            turn_input.append({"type": "localImage", "path": str(image_path)})
        self.rpc("turn/start", {"threadId": thread, "input": turn_input})
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            event = self.next_event(deadline)
            if event.get("method") == "turn/completed" and event.get("params", {}).get("threadId") == thread:
                turn = event["params"]["turn"]
                return {"status": turn["status"],
                        "invalid_id_prefix": "invalid_id_prefix" in json.dumps(turn.get("error"))}
        raise TimeoutError("Isolated fixture turn timed out.")

    def close(self):
        # Only this Popen's new process group is owned by the fixture. No broad process matching.
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.reader.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--headroom-cli", type=Path, required=True)
    args = parser.parse_args()
    codex = args.codex.resolve(strict=True)
    cli = args.headroom_cli.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="headroom-replay-fixture-") as directory:
        root = Path(directory)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory, "CODEX_HOME": directory, "TMPDIR": directory,
               "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1", "NO_PROXY": "127.0.0.1,localhost",
               "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1"}
        server = FixtureServer()
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        (root / "config.toml").write_text(f'''model = "gpt-5.4"
model_provider = "fixture_provider"
web_search = "disabled"
check_for_update_on_startup = false
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
''')
        client = None
        try:
            version = subprocess.run([str(codex), "--version"], env=env, capture_output=True, text=True,
                                     check=True, timeout=10).stdout.strip()
            image_bytes = fixture_png()
            items = [
                {"type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": "Keep pending work."},
                    {"type": "input_image", "image_url": "data:image/png;base64," +
                     base64.b64encode(image_bytes).decode()},
                ]},
                {"type": "reasoning", "id": "item_fixture_reasoning", "summary": [], "encrypted_content": None},
                {"type": "function_call", "call_id": "call_fixture", "name": "fixture_read", "arguments": "{}"},
                {"type": "function_call_output", "call_id": "call_fixture", "output": "already completed"},
            ]
            image_path = root / "fixture.png"
            image_path.write_bytes(image_bytes)
            client = AppServer(codex, root, env)
            baseline = client.turn(items, image_path=image_path)
            if not server.requests:
                raise RuntimeError("Codex did not reach the loopback fixture server.")
            raw = root / "request.json"
            raw.write_text(json.dumps(server.requests[-1]))
            original_hash = hashlib.sha256(raw.read_bytes()).hexdigest()
            output = root / "projected.json"
            checked = subprocess.run([str(cli), "history", "prepare-request", "--input-file", str(raw),
                                      "--cross-backend", "--output-file", str(output), "--json"],
                                     env=env, capture_output=True, text=True, timeout=15)
            if checked.returncode != 0:
                raise RuntimeError("Headroom projection rejected the captured synthetic request.")
            report = json.loads(checked.stdout)
            projected = json.loads(output.read_text())
            continuation = client.turn(projected["input"])
            final_input = server.requests[-1]["input"]
            tool_pair = [item for item in final_input if item.get("call_id") == "call_fixture"]
            tool_pair_preserved = (len(tool_pair) == 2 and tool_pair[0]["type"] == "function_call" and
                                   tool_pair[1]["type"] == "function_call_output" and
                                   tool_pair[1]["output"] == "already completed")
            def images(input_items):
                return [content.get("image_url")
                        for item in input_items if item.get("type") == "message"
                        for content in item.get("content", []) if content.get("type") == "input_image"]
            source_images = images(json.loads(raw.read_text())["input"])
            projected_images = images(projected["input"])
            final_images = images(final_input)
            image_projection_preserved = bool(source_images) and projected_images == source_images
            history_image_preserved = bool(source_images) and final_images == source_images
            report = {"codex_version": version, "transport": "http", "baseline": baseline,
                      "projected_continuation": continuation, "projection": report,
                      "original_request_unchanged": original_hash == hashlib.sha256(raw.read_bytes()).hexdigest(),
                      "tool_pair_preserved": tool_pair_preserved,
                      "image_projection_preserved": image_projection_preserved,
                      "runtime_history_image_preserved": history_image_preserved,
                      "image_counts": {"captured": len(source_images), "projected": len(projected_images),
                                       "continued": len(final_images)},
                      "synthetic_requests": len(server.requests), "desktop_hook_tested": False}
            print(json.dumps(report, indent=2, sort_keys=True))
            return 0 if (baseline["status"] == "failed" and baseline["invalid_id_prefix"] and
                         continuation["status"] == "completed" and report["original_request_unchanged"] and
                         tool_pair_preserved and image_projection_preserved) else 1
        finally:
            if client is not None:
                client.close()
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
