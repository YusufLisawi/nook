#!/usr/bin/env python3
"""Only inert RPC/read operations; never start polling, AX actions, index scans or input synthesis."""
import json, os, pathlib, selectors, subprocess, tempfile, time
package = pathlib.Path(__file__).resolve().parent.parent
plugin = json.loads((package/'plugin.json').read_text())['id']
with tempfile.TemporaryDirectory(prefix='nook-migration-rpc-', dir='/tmp') as scratch:
    env = dict(os.environ, NOOK_PLUGIN_ID=plugin, NOOK_PLUGIN_DIR=str(package), NOOK_DATA_DIR=scratch)
    proc = subprocess.Popen([str(package/'bin/helper'), '--protocol-test'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    selector = selectors.DefaultSelector(); selector.register(proc.stdout, selectors.EVENT_READ)
    buffer = b''
    host_calls = []
    proc.stdin.write(b'{"jsonrpc":"2.0","method":"host.ready","params":{"apiVersion":2}}\n'); proc.stdin.flush()
    def request(method, params={}):
        global buffer
        request_id = str(time.monotonic_ns())
        proc.stdin.write((json.dumps(dict(jsonrpc='2.0', id=request_id, method=method, params=params))+'\n').encode()); proc.stdin.flush()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if b'\n' not in buffer:
                if not selector.select(1): continue
                chunk=os.read(proc.stdout.fileno(), 65536)
                assert chunk, 'helper exited before reply'
                buffer += chunk
                continue
            line, buffer = buffer.split(b'\n',1)
            response=json.loads(line)
            if response.get('method','').startswith('host.'):
                host_calls.append(response['method'])
                assert response['method'] in ['host.settings.get', 'host.settings.set'], response
                defaults = {row['key']: row.get('default', '') for row in json.loads((package/'plugin.json').read_text()).get('settings',[])}
                result = defaults if response['method']=='host.settings.get' else None
                proc.stdin.write((json.dumps(dict(jsonrpc='2.0',id=response['id'],result=result))+'\n').encode()); proc.stdin.flush()
            if response.get('id') == request_id: return response
        raise AssertionError('RPC timeout')
    try:
        unknown=request('unknown.😀', {'text':'a\nb"c'})
        assert unknown['error']['code']==-32601
        if plugin=='launcher':
            assert request('launcher.status')['result']['applications']==0
            # Discovery, all local providers and place data are exercised over the real pipe.
            for _ in range(3):
                result=request('launcher.search',{'query':'2 + 3','items':[]})['result']
                if result.get('answer',{}).get('result')=='5': break
                time.sleep(.05)
            assert result['answer']['copyValue']=='5', result
            result=request('launcher.search',{'query':'arc','items':[{'id':'fixture','title':'Arc fixture','source':'plugins'}]})['result']
            assert any(row['id']=='fixture' for row in result['items'])
        elif plugin=='file-search':
            assert request('launcher.search',{'query':''})['result']['items']==[]
        elif plugin=='clips':
            assert request('clips.history',{'args':['']})['result']==[]
            assert request('clips.status',{'args':[]})['result']['clipboardLoading'] is True
        else:
            state=request('windows.state',{'args':[]})['result']
            assert state['target'] is None and len(state['actions'])==23
        assert 'host.settings.get' in host_calls
        proc.stdin.close(); assert proc.wait(timeout=4)==0
        assert proc.stderr.read()==b''
        print(f'PASS: {plugin} real universal helper RPC, inert state/query, errors, Unicode and EOF cleanup')
    finally:
        if proc.poll() is None: proc.kill(); proc.wait()
