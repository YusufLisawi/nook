#!/usr/bin/env python3
"""Fixture executable, not a model call. All files stay in the caller's /tmp directory."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

Path('last-args').write_text('\n'.join(sys.argv[1:]))
Path('last-prompt').write_text(sys.stdin.read())

def event(value):
    data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    for byte in data:
        os.write(1, bytes([byte]))

event({'type': 'thread.started', 'thread_id': 'test-codex-thread'})
event({'type': 'turn.started'})
mode = Path('mode').read_text() if Path('mode').exists() else ''
if mode == 'wait':
    # A child with its own process group exercises descendant enumeration as well as group cancellation.
    child = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
    Path('child-pid').write_text(str(child.pid))
    child.wait()
    time.sleep(60)
elif mode == 'error':
    event({'type': 'turn.failed', 'error': {'message': 'Test failure'}})
    sys.exit(1)
else:
    event({'type': 'item.completed', 'item': {'id': 'item_0', 'type': 'reasoning', 'text': 'Thinking…'}})
    event({'type': 'item.started', 'item': {'id': 'item_1', 'type': 'command_execution', 'command': 'ls', 'aggregated_output': '', 'exit_code': None, 'status': 'in_progress'}})
    event({'type': 'item.updated', 'item': {'id': 'item_1', 'type': 'command_execution', 'command': 'ls', 'aggregated_output': 'hello', 'exit_code': None, 'status': 'in_progress'}})
    event({'type': 'item.completed', 'item': {'id': 'item_1', 'type': 'command_execution', 'command': 'ls', 'aggregated_output': 'hello 🦉\n', 'exit_code': 0, 'status': 'completed'}})
    event({'type': 'item.completed', 'item': {'id': 'item_2', 'type': 'mcp_tool_call', 'server': 'test', 'tool': 'lookup', 'arguments': {'q': 'test'}, 'result': {'content': [{'type': 'text', 'text': 'Result'}]}, 'status': 'completed'}})
    event({'type': 'item.completed', 'item': {'id': 'item_3', 'type': 'web_search', 'query': 'Swift docs', 'action': {'type': 'search'}}})
    Path('created.txt').write_text('A new file\n')
    event({'type': 'item.completed', 'item': {'id': 'item_4', 'type': 'file_change', 'changes': [{'path': 'created.txt', 'kind': 'add'}], 'status': 'completed'}})
    event({'type': 'item.completed', 'item': {'id': 'item_5', 'type': 'agent_message', 'text': 'Hello **world**'}})
    event({'type': 'turn.completed', 'usage': {'input_tokens': 100, 'output_tokens': 12}})
