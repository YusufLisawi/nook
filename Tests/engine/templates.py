import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
request = json.dumps({"jsonrpc": "2.0", "id": "test", "method": "hello", "params": {"name": 'Nook "😀"'}}) + "\n"
for language, arguments in [
    ("node", ["node", "helper.mjs"]), ("python", ["python3", "helper.py"]),
    ("swift", ["bin/helper"]), ("rust", ["bin/helper"]),
]:
    result = subprocess.run(arguments, cwd=root / ("test-" + language), input=request, text=True, capture_output=True, check=True, timeout=15)
    response = json.loads(result.stdout)
    assert response["id"] == "test" and response["result"]["message"] == 'Hello, Nook "😀"!', (language, result.stdout)

# The internal launcher execs into the helper and retains a distinct process group.
result = subprocess.run([sys.argv[2], "_plugin-exec", "/usr/bin/python3", "-c", "import os; print(os.getpid()==os.getpgrp())"], capture_output=True, text=True, check=True)
assert result.stdout.strip() == "True"
print("PASS: Node/Python/Swift/Rust helpers preserve JSON escaping and Unicode, exit on stdin EOF, and the exec trampoline isolates a process group.")
