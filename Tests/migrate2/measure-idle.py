#!/usr/bin/env python3
"""Warm release helpers with inert host APIs. Never launch Nook or start capture/network work."""
import importlib.util,pathlib,tempfile,plistlib,time,sys
sys.dont_write_bytecode=True
here=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('protocol',here/'helper_protocol.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
for package in ['commands','agents','dictation','mixer']:
 root=pathlib.Path(tempfile.mkdtemp(prefix='nook-release-idle-',dir='/tmp'))
 legacy=root/'legacy';legacy.mkdir();work=root/'data';work.mkdir()
 (legacy/'preferences.plist').write_bytes(plistlib.dumps({'dictationImportedFreeFlow':True,'dictationImportedFreeFlowMic':True,'dictationKeepAudioHours':0}))
 client=module.Client(module.ROOT/'store/plugins'/package/'bin/helper',package,work,legacy)
 end=time.monotonic()+3
 while time.monotonic()<end:client.pump()
 print(package,client.sample(),flush=True);client.close()
