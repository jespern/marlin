#!/usr/bin/env python3
"""External app-server peer: launch the actual MCP bridge with Codex's config."""
import json
import os
import pathlib
import subprocess
import sys
import re


def send(value):
    print(json.dumps(value), flush=True)


# Parse the bridge's deliberately small inline-TOML surface using only the
# system Python standard library (macOS /usr/bin/python3 predates tomllib).
config = next(sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1])
              if arg == "-c" and sys.argv[i + 1].startswith("mcp_servers.marlin="))
quoted = r'"(?:[^"\\]|\\.)*"'
command = re.search(r'command = (' + quoted + r')', config).group(1)
args = re.search(r'args = (\[[^\]]*\])', config).group(1)
env_vars = re.search(r'env_vars = (\[[^\]]*\])', config).group(1)
bridge = {"command": json.loads(command), "args": json.loads(args),
          "env_vars": json.loads(env_vars)}
for required in ('enabled = true', 'required = true', 'enabled_tools = ["ask_user"]',
                 'disabled_tools = []', 'tool_timeout_sec = 604800'):
    assert required in config
sid = bridge["args"][-1]
thread = "question-thread-" + sid

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        send({"id": request["id"], "result": {}})
    elif method == "account/read":
        send({"id": request["id"], "result": {"account": {"type": "chatgpt"}}})
    elif method in ("thread/start", "thread/resume"):
        instructions = request["params"]["developerInstructions"]
        assert "mcp__marlin__ask_user" in instructions
        assert "request_user_input_async" in instructions
        assert "Keep the user informed" in instructions
        if method == "thread/resume":
            assert request["params"]["threadId"] == thread
        send({"id": request["id"], "result": {"thread": {"id": thread}}})
    elif method == "turn/start":
        send({"id": request["id"], "result": {"turn": {"id": "question-turn"}}})
        # MCP subprocesses inherit only allowed variables, unlike the app-server.
        env = {key: os.environ[key] for key in bridge["env_vars"] if key in os.environ}
        with subprocess.Popen(
            [bridge["command"], *bridge["args"]], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        ) as peer:
            def rpc(rid, name, params):
                peer.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid,
                                            "method": name, "params": params}) + "\n")
                peer.stdin.flush()
                result = json.loads(peer.stdout.readline())
                assert result["id"] == rid and "error" not in result, result
                return result["result"]

            rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "codex-fixture", "version": "1"}})
            assert any(t["name"] == "ask_user" for t in rpc(2, "tools/list", {})["tools"])
            result = rpc(3, "tools/call", {"name": "ask_user", "arguments": {
                "question": "Where should history live?", "options": ["Per session", "Globally"]}})
            answer = result["content"][0]["text"]
            pathlib.Path("answer-" + sid).write_text(answer)
            peer.stdin.close()
            assert peer.wait(timeout=5) == 0
        send({"method": "item/completed", "params": {"item": {
            "id": "reply", "type": "agentMessage", "text": answer, "phase": "final_answer"}}})
        send({"method": "turn/completed", "params": {
            "threadId": thread, "turn": {"id": "question-turn", "status": "completed"}}})
