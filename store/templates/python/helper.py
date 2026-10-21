"""No dependencies. stdout is JSON-RPC; logging goes to stderr. EOF stops the helper."""
import json
import sys

def send(message):
    print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)

def host(method, params=None, request_id="helper-1"):
    # Read its eventual result in the loop below; avoid waiting inside a request handler.
    send({"id": request_id, "method": "host." + method, "params": params or {}})

for line in sys.stdin:
    try:
        if len(line.encode()) > 1048576:
            raise ValueError("RPC frame too large")
        message = json.loads(line)
        if message.get("jsonrpc") != "2.0" or "method" not in message or "id" not in message:
            continue  # host.ready, host.event, and responses to host() above
        if message["method"] == "hello":
            name = message.get("params", {}).get("name", "Nook")
            send({"id": message["id"], "result": {"message": "Hello, " + name + "!"}})
        else:
            send({"id": message["id"], "error": {"code": -32601, "message": "Unknown method"}})
    except (ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
