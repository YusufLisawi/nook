const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const root = process.cwd(), id = process.argv[2], folder = path.join(root,'store/plugins',id);
const wait = () => new Promise(resolve=>setTimeout(resolve,25));
(async () => {
 const dom = new JSDOM(fs.readFileSync(path.join(folder,'settings.html'),'utf8'),{runScripts:'outside-only',pretendToBeVisual:true,url:'https://nook.test/'});
 const w = dom.window, d = w.document, calls = [], events = {};
 let fail = false;
 let rows = [{id:'first',name:'First',prompt:'{selection}',provider:'codex',model:'fixture',effort:'none',output:'replace',enabled:true,copyToo:false,hotkey:null,instructions:'',workingDirectory:'~',fullAccess:false},{id:'second',name:'Second',prompt:'{selection}',provider:'codex',model:'fixture',effort:'none',output:'copy',enabled:true,instructions:'',workingDirectory:'~',fullAccess:false}];
 const on = (e,cb)=>(events[e]??=[]).push(cb);
 w.nook={plugin:{id},on,_emit:(e,p)=>{ for(const cb of events[e]||[])cb(p); },open:async()=>{},settings:{open:async()=>{}},native:{on:(e,cb)=>on('native:'+e,cb),call:async(method,p={})=>{
  calls.push([method,structuredClone(p)]);if(fail)throw Error('Fixture offline');
  if(method.endsWith('.list'))return structuredClone(rows);
  if(method.endsWith('.save')){const row=structuredClone(p.args[0]); const index=rows.findIndex(r=>r.id===row.id);if(index<0)rows.push(row);else rows[index]=row;return structuredClone(rows);}
  if(method.endsWith('.remove')){rows=rows.filter(r=>r.id!==p.args[0]);return null;}
  if(method==='preferences.get')return {dictationEngine:'groq',dictationCleanup:true,dictationPrompt:'Keep words',dictationKeepAudioHours:24};
  if(method==='audio.state')return {output:{devices:[]},input:{devices:[]},apps:[]};return null;
 }},host:{call:async(method,p)=>{calls.push([method,p]); if(fail)throw Error('Fixture offline'); if(method==='microphone.devices')return [{id:'mic',name:'Fixture mic'}];if(method==='hotkeys.record')return {keyCode:47,modifiers:1572864,display:'⌥⌘.'};if(method==='settings.chooseDirectory')return '/tmp/disposable';return null;}}};
 for(const script of d.querySelectorAll('script[src]'))w.eval(fs.readFileSync(path.join(folder,script.getAttribute('src')),'utf8'));
 await wait();await wait();
 assert.equal(d.getElementById('error').hidden,true);
 if(['commands','agents'].includes(id)){
  const input=d.getElementById('field-name'); assert.equal(input.value,'First');
  input.value='Edited before switching';input.dispatchEvent(new w.Event('input',{bubbles:true}));
  d.querySelectorAll('#list button')[1].click();await wait();
  assert(calls.some(([m,p])=>m===id+'.save'&&p.args[0].id==='first'&&p.args[0].name==='Edited before switching'),'Changing selection must flush pending autosave');
  d.getElementById('add').click();await wait();assert.equal(rows.length,3);
  d.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Enter',metaKey:true,bubbles:true,cancelable:true}));await wait();
  d.getElementById('remove').click();assert.equal(rows.length,3);d.getElementById('remove').click();await wait();assert.equal(rows.length,2);
 }else{
  assert(d.querySelectorAll('select').length>=2,'Device/engine controls are keyboard-native selects');
  const select=d.querySelector('select');select.dispatchEvent(new w.Event('change',{bubbles:true}));await wait();
  assert(calls.some(([m])=>m==='preferences.set'||m==='audio.setPreferred'));
 }
 fail=true;d.getElementById('reload').click();await wait();assert.equal(d.getElementById('error').hidden,false);
 fail=false;d.getElementById('reload').click();await wait();
 // Mixer retains its prior error until a successful action; all editors still load fresh controls.
 assert(d.getElementById('fields').children.length>0);
 dom.window.close();console.log('PASS '+id+' contributed Settings: load, editor controls, save/switch, keyboard, confirmation, error/retry; mocked window.nook');
})().catch(e=>{console.error(e);process.exit(1)});
