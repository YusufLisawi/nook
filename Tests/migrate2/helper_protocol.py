#!/usr/bin/env python3
"""Real helper processes, inert host APIs, isolated migration fixtures. Never launch Nook."""
import base64, json, os, pathlib, plistlib, queue, shutil, subprocess, tempfile, threading, time, uuid, hashlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[2]
class Client:
    def __init__(self, executable, package, work, legacy, *, silent=False):
        self.calls=[]; self.events=[]; self.results={}; self.silent=silent; self.supports_insertion=True
        env={**os.environ,'NOOK_PLUGIN_ID':package,'NOOK_PLUGIN_DIR':str(ROOT/'store/plugins'/package),'NOOK_DATA_DIR':str(work),'NOOK_LEGACY_DIR':str(legacy)}
        self.proc=subprocess.Popen([str(executable),'--protocol-test'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,text=True,bufsize=1)
        self.lock=threading.Lock(); self.messages=queue.Queue()
        threading.Thread(target=self.reader,daemon=True).start()
        self.send({'jsonrpc':'2.0','method':'host.ready','params':{'apiVersion':2,'pluginID':package}})
        self.send({'jsonrpc':'2.0','id':'cold-probe','method':'preferences.get','params':{}})
        self.wait(lambda:any(e[0]=='ready' for e in self.events) and 'cold-probe' in self.results)
        assert 'error' not in self.results.pop('cold-probe'),'Calls arriving during startup must wait for host-ready initialization'
    def reader(self):
        for line in self.proc.stdout:
            self.messages.put(json.loads(line))
    def send(self, m):
        with self.lock:
            self.proc.stdin.write(json.dumps(m)+'\n');self.proc.stdin.flush()
    def pump(self):
        try: m=self.messages.get(timeout=.02)
        except queue.Empty: return
        method=m.get('method')
        if method and method.startswith('host.'):
            p=m.get('params',{}); self.calls.append((method,p)); value=None
            if method=='host.selection.capabilities' and not self.supports_insertion:
                self.send({'jsonrpc':'2.0','id':m['id'],'error':{'code':-32601,'message':'Unknown API'}});return
            if method=='host.settings.get': value={}
            elif method=='host.secrets.get': value='fixture-key'
            elif method=='host.selection.capture': value={'app':'Fixture Editor','clipboard':'original clipboard'}
            elif method=='host.selection.capabilities': value={'insertion':True,'prefix':True,'preserveCapture':True} if self.supports_insertion else None
            elif method=='host.selection.get': value='selected text'
            elif method=='host.microphone.devices': value=[{'id':'fixture-mic','name':'Fixture mic'}]
            elif method=='host.microphone.start':
                pathlib.Path(p['path']).write_bytes(b'RIFF fixture PCM'); value=None
            elif method=='host.microphone.stop': value={'duration':1.2,'peak':0 if self.silent else 100}
            elif method=='host.audioCapture.start': value={'handle':str(uuid.uuid4())}
            elif method=='host.audioCapture.state': value={'sawSignal':True}
            elif method=='host.audioCapture.update': value=True
            elif method=='host.hotkeys.record': value={'keyCode':47,'modifiers':1572864,'display':'⌥⌘.'}
            self.send({'jsonrpc':'2.0','id':m['id'],'result':value})
        elif method: self.events.append((method,m.get('params')))
        elif 'id' in m: self.results[str(m['id'])]=m
    def wait(self, predicate, timeout=12):
        end=time.monotonic()+timeout
        while not predicate():
            self.pump()
            if time.monotonic()>end:
                raise AssertionError(f'timeout: {self.events[-5:]} calls {self.calls[-5:]} code {self.proc.poll()}')
    def rpc(self, method, params=None):
        token=str(uuid.uuid4());self.send({'jsonrpc':'2.0','id':token,'method':method,'params':params or {}})
        self.wait(lambda:token in self.results); result=self.results.pop(token)
        if 'error' in result: raise RuntimeError(result['error']['message'])
        value=result.get('result')
        if isinstance(value,dict) and '__nookTransfer' in value:
            data=b''.join(base64.b64decode(self.rpc('transport.read',{'token':value['__nookTransfer'],'index':index})) for index in range(value['chunks']))
            self.rpc('transport.release',{'token':value['__nookTransfer']});return json.loads(data)
        return value
    def event(self, event, data): self.send({'jsonrpc':'2.0','method':'host.event','params':{'event':event,'data':data}})
    def close(self):
        self.proc.stdin.close(); self.proc.wait(timeout=5)
        err=self.proc.stderr.read(); assert self.proc.returncode==0,(self.proc.returncode,err)
    def sample(self):
        # No host process is launched. This is the helper's inert steady state only.
        started=time.monotonic(); rows=[]
        while time.monotonic()-started<1:
            self.pump()
            rows.append(subprocess.check_output(['/bin/ps','-p',str(self.proc.pid),'-o','%cpu=,rss='],text=True).strip())
        return rows[-1]

def tree(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}

def compiled_fixture(package, scratch):
    # Compile actual feature/runtime with deterministic provider substitutes. No shipped test switches/backdoors.
    source=ROOT/'store/plugins'/package/'native'; target=scratch/'source';shutil.copytree(source,target)
    if package=='commands':
        (target/'AIBrain.swift').write_text('''import Foundation
enum AIBrain {
 struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
 static func providers() async -> [[String:Any]] { [] }
 static func complete(provider:String,model:String,effort:String,prompt:String,onDelta:@escaping(String)->Void) async throws -> String {
  onDelta("MOCK:"); try await Task.sleep(nanoseconds:20_000_000); onDelta("MOCK:"+prompt); return "MOCK:"+prompt
 }
}
''')
    if package=='dictation':
        (target/'Groq.swift').write_text('''import Foundation
enum Groq {
 static func transcribe(file:URL,key:String,vocabulary:String) async throws -> String { "raw fixture" }
 static func cleanup(_ text:String,key:String,systemPrompt:String,vocabulary:String) async throws -> String { "cleaned fixture" }
}
''')
        (target/'OpenAITranscriber.swift').write_text('''import Foundation
enum OpenAITranscriber {
 static func readAuth() -> String? { "fixture" }
 static func transcribe(file:URL,hint:String) async throws -> String { "raw ChatGPT fixture" }
}
''')
    binary=scratch/'helper'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-warnings-as-errors','-parse-as-library','-target',os.uname().machine+'-apple-macos14.2',*[str(p) for p in target.glob('*.swift')],'-o',str(binary)],check=True)
    return binary

def run(package):
    scratch=pathlib.Path(tempfile.mkdtemp(prefix=f'nook-{package}-protocol-',dir='/tmp'))
    legacy=scratch/'legacy'; legacy.mkdir(); work=scratch/'data';work.mkdir()
    prefs={'dictationImportedFreeFlow':True,'dictationImportedFreeFlowMic':True,'dictationKeepAudioHours':0,'dictationEngine':'groq','dictationCleanup':True,'dictationHoldShortcut':json.dumps({'keyCode':None,'modifiers':786432,'display':'Saved hold'}).encode(),'dictationToggleShortcut':json.dumps({'keyCode':49,'modifiers':524288,'display':'Saved toggle'}).encode()}
    (legacy/'preferences.plist').write_bytes(plistlib.dumps(prefs))
    command={'id':'fixture-command','name':'Fixture command','prompt':'{selection}|{clipboard}|{app}','provider':'groq','model':'fixture','effort':'none','output':'replace','copyToo':True,'enabled':True,'hotkey':{'keyCode':44,'modifiers':1572864,'display':'Saved shortcut'}}
    if package=='commands': (legacy/'ai-commands.json').write_text(json.dumps([command]))
    if package=='agents': (legacy/'agents.json').write_text(json.dumps([{'id':str(uuid.uuid4()),'name':'Migrated agent','instructions':'Keep literal $() text','workingDirectory':'~','model':'fixture','effort':'low','fullAccess':False}]))
    if package=='agents':
        agent=json.loads((legacy/'agents.json').read_text())[0]; session_id=str(uuid.uuid4())
        folder=legacy/'AgentSessions'/agent['id'];folder.mkdir(parents=True)
        (folder/(session_id+'.json')).write_text(json.dumps({'id':session_id,'agentId':agent['id'],'title':'Large migrated chat','createdAt':1,'updatedAt':2,'status':'done','revision':1,'items':[{'id':'large','json':json.dumps({'type':'agent_message','text':'Large café 😀 '+ 'x'*1_300_000})}],'usage':{}}))
    if package=='dictation':
        (legacy/'Dictation/audio').mkdir(parents=True);(legacy/'Dictation/audio/old.wav').write_bytes(b'preserved audio')
        (legacy/'Dictation/history.json').write_text(json.dumps([{'id':'old','date':'2026-10-20T00:00:00Z','audio':'old.wav','raw':'old','text':'old text','status':'done','duration':1}]))
    before=tree(legacy)
    executable=compiled_fixture(package,scratch) if package in ['commands','dictation'] else ROOT/'store/plugins'/package/'bin/helper'
    c=Client(executable,package,work,legacy)
    if package=='commands':
        assert c.rpc('commands.list')[0]['hotkey']==command['hotkey']
        c.rpc('commands.run',{'args':[command['id']]})
        c.wait(lambda:any(m=='commandRun' and p['status']=='done' for m,p in c.events))
        assert any(m=='host.selection.paste' and p['text']=='MOCK:selected text|original clipboard|Fixture Editor' and p['keepOnClipboard'] for m,p in c.calls)
        for output in ['paste','copy','notch']:
            command['output']=output;c.rpc('commands.save',{'args':[command]});c.events=[];c.calls=[]
            c.event('hotkey',{'id':command['id'],'phase':'pressed'})
            c.wait(lambda:any(m=='commandRun' and p['status']=='done' for m,p in c.events))
            if output=='paste': assert any(m=='host.selection.paste' and p['after'] for m,p in c.calls)
            if output=='copy': assert any(m=='host.clipboard.write' for m,p in c.calls)
            if output=='notch': assert any(m=='host.notch.open' for m,p in c.calls) and sum(m=='commandRun' for m,p in c.events)>=2
        c.calls=[];c.events=[];c.event('beforeAction',{'context':'fixture-display-context'});c.event('action',command['id'])
        c.wait(lambda:any(m=='commandRun' and p['status']=='done' for m,p in c.events))
        assert any(m=='host.selection.get' and p.get('context')=='fixture-display-context' for m,p in c.calls),'Palette actions must retain their originating notch context'
        command['name']='Private edit';c.rpc('commands.save',{'args':[command]})
    elif package=='dictation':
        assert c.rpc('dictation.history')[0]['text']=='old text'
        assert c.rpc('dictation.state')['holdShortcut']=='Saved hold'
        c.event('hotkey',{'id':'hold','phase':'pressed'})
        c.wait(lambda:any(m=='host.microphone.start' for m,p in c.calls))
        c.event('hotkey',{'id':'hold','phase':'released'})
        c.wait(lambda:any(m=='host.selection.paste' and p['text']=='cleaned fixture' for m,p in c.calls))
        paste=next(p for m,p in c.calls if m=='host.selection.paste' and p['text']=='cleaned fixture')
        assert paste.get('insertion') is True and paste.get('prefix')==' ' and paste.get('keepOnClipboard') is True, 'Dictation must insert one space and the transcript without replacing existing text'
        assert c.rpc('dictation.history')[0]['status']=='done'
        c.calls=[];c.rpc('dictation.paste',{'args':['old'],'__context':'fixture-notch-context'})
        history_paste=next(p for m,p in c.calls if m=='host.selection.paste')
        assert history_paste.get('insertion') is True and history_paste.get('prefix')==' ' and history_paste.get('text')=='old text' and history_paste.get('context')=='fixture-notch-context' and history_paste.get('preserveCapture') is True, 'History paste must also preserve existing text'
        c.supports_insertion=False;c.calls=[]
        try: c.rpc('dictation.paste',{'args':['old']});assert False, 'Old hosts must not paste with unsafe semantics'
        except RuntimeError as error: assert 'Update Nook' in str(error)
        assert not any(m=='host.selection.paste' for m,p in c.calls),'An old host must never receive an unsafe paste request'
        c.calls=[];c.event('hotkey',{'id':'hold','phase':'pressed'})
        c.wait(lambda:any(m=='host.microphone.start' for m,p in c.calls));c.event('hotkey',{'id':'hold','phase':'released'})
        c.wait(lambda:c.rpc('dictation.history')[0]['status']=='failed')
        failed=c.rpc('dictation.history')[0]
        assert failed['text']=='cleaned fixture' and 'Update Nook' in failed['error'],'A failed insertion must retain the transcript for copying'
        assert not any(m=='host.selection.paste' for m,p in c.calls),'Automatic dictation must not paste into an older host'
        c.supports_insertion=True
        c.calls=[];c.rpc('dictation.toggle',{'args':[],'__context':'fixture-notch-context'})
        assert any(m=='host.selection.capture' and p.get('context')=='fixture-notch-context' for m,p in c.calls),'The notch toggle must capture the original app on that display'
        c.rpc('dictation.toggle',{'args':[],'__context':'fixture-notch-context'})
        c.wait(lambda:any(m=='host.selection.paste' for m,p in c.calls))
        c.silent=True;c.calls=[];c.event('hotkey',{'id':'toggle','phase':'pressed'})
        c.wait(lambda:any(m=='host.microphone.start' for m,p in c.calls));c.event('hotkey',{'id':'toggle','phase':'pressed'})
        c.wait(lambda:c.rpc('dictation.history')[0]['status']=='failed')
        entry=c.rpc('dictation.history')[0];assert 'no sound' in entry['error']
        c.rpc('dictation.retry',{'args':[entry['id']]});c.wait(lambda:c.rpc('dictation.history')[0]['status']=='done')
        c.rpc('preferences.set',{'key':'dictationPrompt','value':'private changed prompt'})
    elif package=='agents':
        agents=c.rpc('agents.list');assert agents[0]['name']=='Migrated agent'
        agents[0]['name']='Private edit';c.rpc('agents.save',{'args':[agents[0]]})
        sessions=c.rpc('agents.sessions',{'args':[agents[0]['id']]});assert len(sessions)==1
        opened=c.rpc('agents.open',{'args':[sessions[0]['id']]});assert len(opened['items'][0]['text'])>1_300_000 and 'café 😀' in opened['items'][0]['text']
    else:
        state=c.rpc('audio.state');assert all(k in state for k in ['output','input','apps','needsPermission'])
        assert not any(m=='host.audioCapture.start' for m,p in c.calls),'Unity settings must not capture audio'
        c.rpc('audio.setAppVolume',{'args':['fixture.nonexistent.app',0.5]})
        c.rpc('audio.setAppMute',{'args':['fixture.nonexistent.app',True]})
        saved=plistlib.loads((work/'preferences.plist').read_bytes())
        levels=json.loads(saved['audioAppLevels']);assert levels['fixture.nonexistent.app']=={'gain':0.5,'muted':True}
        assert not any(m=='host.audioCapture.start' for m,p in c.calls),'A nonexistent app must not capture audio'
        c.rpc('audio.resetApp',{'args':['fixture.nonexistent.app']})
        saved=plistlib.loads((work/'preferences.plist').read_bytes());assert json.loads(saved['audioAppLevels'])=={}
        c.rpc('audio.setPreferred',{'args':['input','fixture.nonexistent.mic']})
        saved=plistlib.loads((work/'preferences.plist').read_bytes());assert saved['audioPreferredInputUID']=='fixture.nonexistent.mic'
        assert any(m=='host.runtime.keepAlive' and p['enabled'] for m,p in c.calls),'Mixer policy must lease active preferences'

    try: c.rpc('unknown.call');assert False
    except RuntimeError: pass
    sample=c.sample();c.close();assert tree(legacy)==before,'Legacy data was modified'
    c=Client(executable,package,work,legacy)
    if package=='commands': assert c.rpc('commands.list')[0]['name']=='Private edit'
    if package=='agents': assert c.rpc('agents.list')[0]['name']=='Private edit'
    if package=='dictation': assert c.rpc('preferences.get')['dictationPrompt']=='private changed prompt'
    c.close();assert tree(legacy)==before
    if package in ['commands','dictation']:
        bad=scratch/'linked-legacy';bad.mkdir();(bad/'preferences.plist').write_bytes(plistlib.dumps(prefs))
        owned='ai-commands.json' if package=='commands' else 'Dictation'
        (bad/owned).symlink_to(legacy/owned)
        failed=subprocess.run([str(executable),'--protocol-test'],input='',capture_output=True,text=True,timeout=5,env={**os.environ,'NOOK_PLUGIN_ID':package,'NOOK_PLUGIN_DIR':str(ROOT/'store/plugins'/package),'NOOK_DATA_DIR':str(scratch/'refused-data'),'NOOK_LEGACY_DIR':str(bad)})
        assert 'Migration failed' in failed.stderr and not (scratch/'refused-data'/owned).exists(),'Linked legacy roots must fail closed without reseeding'
        assert tree(legacy)==before
    print(f'PASS {package}: migration, restart persistence, real RPC, inert host flows, EOF; idle %cpu/rssKiB={sample}; fixtures={scratch}')
if __name__=='__main__': run(sys.argv[1])
