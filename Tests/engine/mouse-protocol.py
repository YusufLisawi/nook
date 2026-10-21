"""Probe the compiled Mouse helper without an event tap, TCC prompt, GUI, or live Nook data."""
import json
import os
import subprocess
import sys

helper, temporary = sys.argv[1:]
env = {**os.environ, "NOOK_PLUGIN_ID": "mouse", "NOOK_PLUGIN_DIR": os.path.dirname(helper), "NOOK_DATA_DIR": os.path.join(temporary, "mouse-data")}
probe = subprocess.run([helper, "--probe"], capture_output=True, check=True, text=True, env=env)
assert json.loads(probe.stdout)["params"]["eventTapStarted"] is False
requests = [{"jsonrpc": "2.0", "id": 1, "method": "mouse.state", "params": {"args": []}}, {"jsonrpc": "2.0", "id": 2, "method": "missing", "params": {}}]
# Keep stdin open while awaiting replies so EOF doesn't intentionally shut down pending main-queue work.
process = subprocess.Popen([helper, "--protocol-test"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
for request in requests:
    process.stdin.write(json.dumps(request) + "\n")
process.stdin.flush()
responses = [json.loads(process.stdout.readline()) for _ in requests]
assert responses[0]["id"] == 1 and responses[0]["result"]["running"] is False
assert responses[1]["error"]["code"] == -32601
process.stdin.close()
assert process.wait(timeout=5) == 0
print("PASS: Universal Mouse helper probe, state RPC, unknown-method error and stdin-EOF shutdown; no event tap launched.")
