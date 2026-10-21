const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { JSDOM, VirtualConsole } = require('jsdom');
const root = process.cwd();
const only = process.argv[2];
const selected = list => only ? list.filter(name => name === only) : list;
const pluginDir = name => path.join(root, ['commands','dictation','mixer','agents'].includes(name) ? 'store/plugins' : 'Plugins', name);
const rejections = []; process.on('unhandledRejection', error => rejections.push(error));
const wait = () => new Promise(resolve => setTimeout(resolve, 20));
const snap = () => ({ output: { devices: [{uid:'out',name:'Speakers',volume:.5,isDefault:true,muted:false}] }, input: {devices: [{uid:'mic1',name:'Mic 1',volume:.6,isDefault:true}, {uid:'mic2',name:'Mic 2',volume:.5,isDefault:false}]}, apps: [{id:'one',name:'One',volume:.5,playing:true,muted:false},{id:'two',name:'Two',volume:1,playing:true,muted:false}], needsPermission:false });
const hist = () => [{id:'d1',status:'done',text:'First transcript',date:new Date().toISOString(),duration:4},{id:'d2',status:'done',text:'Second transcript',date:new Date().toISOString(),duration:5},{id:'d3',status:'failed',error:'Offline',date:new Date().toISOString(),duration:0}];
const proxies = () => ({proxies:[{id:'p1',name:'One',host:'localhost',port:8000},{id:'p2',name:'Two',host:'localhost',port:8001}],activeId:null});
async function create(name, empty=false, fail=false) {
 const html=fs.readFileSync(path.join(pluginDir(name),'index.html'),'utf8');
 const errors=[], calls=[], events={}, registrations=[];
 const vc=new VirtualConsole(); vc.on('jsdomError',e=>errors.push(e.message));
 const dom=new JSDOM(html,{runScripts:'outside-only',pretendToBeVisual:true,url:'https://nook.test/',virtualConsole:vc});
 const w=dom.window; const d=w.document;
 w.Element.prototype.scrollIntoView=function(){};
 w.Element.prototype.getClientRects=function(){ for(let p=this;p;p=p.parentElement) if(p.hidden || w.getComputedStyle(p).display==='none') return []; return [{width:100,height:30}]; };
 w.HTMLCanvasElement.prototype.getContext=()=>new Proxy({}, {get:()=>()=>{}});
 w.matchMedia=()=>({matches:true,addListener(){},removeListener(){}});
 w.ResizeObserver=class{observe(){} disconnect(){}};
 const storage={notes: empty?[]:[1,2,3].map(n=>({id:'n'+n,text:'Note '+n,createdAt:n,updatedAt:n,pinned:false})),todos:empty?[]:[1,2,3].map(n=>({id:'t'+n,text:'Task '+n,done:false,created:n})),links:empty?[]:[1,2,3].map(n=>({id:'l'+n,url:'https://example.com/'+n,title:'Link '+n,domain:'example.com',addedAt:Date.now()-n})),folders:[],script:empty?'':'A short script with enough words to read.',settings:{}};
 const record=(api,value)=>async(...args)=>{calls.push([api,...args]);if(fail)throw Error('Mock offline');return typeof value==='function'?value(...args):value;};
 w.nook={plugin:{id:name,name},on:(e,cb)=>(events[e]??=[]).push(cb),
  actions:{register:record('actions.register', list=>registrations.push(list))},
  storage:{get:record('storage.get',k=>structuredClone(storage[k]??null)),set:record('storage.set',(k,v)=>storage[k]=structuredClone(v)),all:record('storage.all',()=>structuredClone(storage))},
  settings:{get:record('settings.get',{}),open:record('settings.open'),set:record('settings.set')},
  commands:{list:record('commands.list',empty?[]:[1,2,3].map(n=>({id:'c'+n,name:'Command '+n,enabled:true,output:'copy'}))),run:record('commands.run'),models:record('commands.models',[{id:'codex',available:true}]),lastRun:record('commands.lastRun',null)},
  clipboard:{write:record('clipboard.write'),read:record('clipboard.read','')},open:record('open'),notify:record('notify'),activity:{set:record('activity.set'),clear:record('activity.clear')},notch:{close:record('notch.close'),pin:record('notch.pin'),setHeight:record('notch.setHeight')},
  audio:Object.fromEntries(['state','setDefault','setDeviceVolume','setDeviceMute','setPreferred','setAppVolume','setAppMute','resetApp','openPrivacy'].map(k=>[k,record('audio.'+k,snap)])),
  dictation:{history:record('dictation.history',empty?[]:hist()),state:record('dictation.state',{recording:false,transcribing:false,hasKey:true}),copy:record('dictation.copy'),retry:record('dictation.retry'),toggle:record('dictation.toggle'),remove:record('dictation.remove'),clear:record('dictation.clear'),paste:record('dictation.paste')},
  proxy:{list:record('proxy.list',empty?{proxies:[],activeId:null}:proxies()),ip:record('proxy.ip',{ip:'127.0.0.1',city:'Test'}),connect:record('proxy.connect',proxies),rename:record('proxy.rename',proxies),disconnect:record('proxy.disconnect',proxies)},
  timer:{state:record('timer.state',{running:false}),start:record('timer.start',{running:true,mode:'timer',text:'15:00'}),stop:record('timer.stop',{})},
  system:record('system',{cpu:{usage:.1,cores:8},memory:{used:8e9,total:16e9},disk:{used:5e11,total:1e12,free:5e11},network:{downBps:10,upBps:10},battery:null,load:[1,2,3],thermal:'nominal',uptime:100}),
  shell:record('shell',{code:0,stdout: name==='monitor'?'%CPU RSS COMM\n12.0 12345 Test\n5.0 54321 Other\n':'/tmp/mock-home\n',stderr:''})};
 const aliases = {commands:w.nook.commands,dictation:w.nook.dictation,audio:w.nook.audio};
 w.nook._emit = (event,data) => { for (const cb of events[event] || []) cb(data); };
 w.nook.native = {on:(e,cb)=>(events['native:'+e]??=[]).push(cb),call:async(method,p={})=> { const [ns,fn]=method.split('.'); if (!aliases[ns]?.[fn]) throw Error('Unknown mock '+method); return aliases[ns][fn](...(p.args || [])); }};
 const style=d.createElement('style'); style.textContent=fs.readFileSync(path.join(root,'NookUI/nook-ui.css'),'utf8');d.head.append(style);
 w.eval(fs.readFileSync(path.join(root,'NookUI/nook-keyboard.js'),'utf8'));
 w.addEventListener('error',e=>errors.push(e.message));
 for(const script of d.querySelectorAll('script[src]')) vm.runInContext(fs.readFileSync(path.join(pluginDir(name),script.getAttribute('src')),'utf8'),dom.getInternalVMContext());
 await wait(); await wait();
 const fire=(el,key,props={})=>el.dispatchEvent(new w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true,...props}));
 const emit=async(e,p)=>{for(const cb of events[e]??[]) await cb(p);await wait();};
 return {dom,w,d,errors,calls,registrations,fire,emit,storage};
}
async function rovingUnit() {
 const dom=new JSDOM('<main><input id="text"><div class="nk-roving" data-nk-orientation="horizontal"><button data-nk-item="a">A</button><button hidden data-nk-item="b">B</button><button data-nk-item="c">C</button><button disabled data-nk-item="d">D</button></div><button id="end">End</button></main>',{runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,d=w.document; w.nook={};w.Element.prototype.getClientRects=function(){return this.closest('[hidden]')?[]:[{}]};w.Element.prototype.scrollIntoView=function(){};
 w.eval(fs.readFileSync('NookUI/nook-keyboard.js','utf8'));await wait();
 const fire=(el,key,extra={})=>el.dispatchEvent(new w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true,...extra}));
 const a=d.querySelector('[data-nk-item="a"]'),c=d.querySelector('[data-nk-item="c"]');
 assert.equal(a.tabIndex,0); assert.equal(c.tabIndex,-1);a.focus();fire(a,'ArrowRight');assert.equal(d.activeElement,c);fire(c,'ArrowRight');assert.equal(d.activeElement,a);
 let clicks=0,alt=0;a.onclick=()=>clicks++;a.addEventListener('nk:alt',()=>alt++);fire(a,'Enter');fire(a,'Enter',{metaKey:true});assert.equal(clicks,1);assert.equal(alt,1);
 const input=d.querySelector('#text');input.focus();fire(input,'ArrowRight');assert.equal(d.activeElement,input);fire(input,'Tab');assert.equal(d.activeElement,a);
 c.focus();const replacement=c.cloneNode(true);c.replaceWith(replacement);await wait();assert.equal(d.activeElement,replacement);assert.equal(replacement.tabIndex,0);
 fire(replacement,'End');assert.equal(d.activeElement,replacement);fire(replacement,'Home');assert.equal(d.activeElement,a);
 a.setAttribute('aria-disabled','true');await wait();assert.equal(a.tabIndex,-1);const beforeClicks=clicks;fire(a,'Enter');assert.equal(clicks,beforeClicks);a.removeAttribute('aria-disabled');await wait();
 a.setAttribute('data-nk-autofocus','');w.nook.keyboard.focus();assert.equal(d.activeElement,a);dom.window.dispatchEvent(new dom.window.Event('pagehide'));dom.window.close();console.log('PASS shared roving: disabled/hidden skip, wrap, Tab, Enter/alternate, caret, rerender, Home/End, autofocus');
}
(async()=>{
 await rovingUnit();
 for(const name of selected(['commands','links','notes','home','mixer','cleaner','dictation','proxy','teleprompter','monitor'])) {
  const t=await create(name);const {w,d,fire,calls}=t;
  assert.equal(t.errors.length,0,name+': '+t.errors.join('\n'));assert.ok(t.registrations[0]?.length,name+' actions');
  const definitions=JSON.parse(fs.readFileSync(path.join(pluginDir(name),'keyboard.js'),'utf8').match(/const definitions = (\[[\s\S]*?\]);/)[1]);
  for(const action of definitions) assert.ok(d.querySelector(action.selector),`${name}: action target ${action.id}`);
  for(const action of t.registrations[0]){assert.ok(action.id&&action.title);assert.ok(Object.values(action).every(v=>v!==undefined));}
  const rows=[...d.querySelectorAll('[data-nk-item]')].filter(el=>el.getClientRects().length&&!el.disabled&&el.getAttribute('aria-disabled')!=='true');
  assert.ok(rows.length || name==='teleprompter',name+' roving rows');
  if(name==='commands'){rows[0].focus();fire(rows[0],'ArrowRight');assert.equal(d.activeElement,rows[1]);fire(rows[1],'Enter');await wait();assert.ok(calls.some(c=>c[0]==='commands.run'&&c[1]==='c2'));}
  if(name==='notes'){rows[0].focus();fire(rows[0],'ArrowDown');assert.ok(d.activeElement.dataset.noteId);fire(d.activeElement,'Enter');await wait();assert.equal(d.activeElement.id,'editor');}
  if(name==='home'){rows[0].focus();fire(rows[0],'Enter');await wait();assert.ok(t.storage.todos.some(x=>x.done));const current=d.querySelector('[data-nk-item]');current.focus();fire(current,'Enter',{metaKey:true});assert.equal(d.activeElement.getAttribute('contenteditable'),'plaintext-only');fire(d.activeElement,'Enter');assert.ok(d.activeElement.hasAttribute('data-nk-item'),'Home returns focus to edited task');}
  if(name==='mixer'){let track=d.querySelector('.track');assert.equal(track.getAttribute('role'),'slider');track.focus();fire(track,'ArrowUp');await wait();assert.ok(calls.some(c=>c[0]==='audio.setDeviceVolume'&&c.at(-1)===.51));assert.equal(d.activeElement.getAttribute('role'),'slider');track=d.activeElement;fire(track,'End');await new Promise(r=>setTimeout(r,80));assert.ok(calls.some(c=>c[0]==='audio.setDeviceVolume'&&c.at(-1)===1));}
  if(name==='cleaner'){rows[0].focus();const check=rows[0].querySelector('input');const before=check.checked;fire(rows[0],'Enter');assert.equal(check.checked,!before);}
  if(name==='dictation'){rows[0].focus();fire(rows[0],'ArrowDown');assert.equal(d.activeElement,rows[1]);fire(rows[1],'Enter',{metaKey:true});await wait();assert.ok(calls.some(c=>c[0]==='dictation.copy'&&c[1]==='d2'));}
  if(name==='proxy'){rows[0].focus();fire(rows[0],'ArrowDown');assert.equal(d.activeElement,rows[1]);fire(rows[1],'Enter',{metaKey:true});await wait();assert.ok(d.querySelector('.rename-form input'));}
  if(name==='links'){const link=d.querySelector('.link-open');link.focus();fire(link,'Enter',{metaKey:true});await wait();assert.ok(calls.some(c=>c[0]==='clipboard.write'&&c[1].includes('example.com')));}
  if(name==='teleprompter'){const script=d.querySelector('#script');script.focus();fire(script,'Enter',{metaKey:true});await wait();assert.equal(d.querySelector('#play-view').hidden,false);}
  if(name==='monitor'){rows[0].focus();fire(rows[0],'ArrowRight');assert.equal(d.activeElement,rows[1]);assert.equal(rows[0].getAttribute('role'),'group');}
  if(['links','notes','home','dictation','monitor'].includes(name)) { const action={links:['search-links','search'],notes:['search-notes','search'],home:['add-todo','new'],dictation:['search-history','search'],monitor:['inspect-metrics','cpu-tile']}[name]; await t.emit('action',action[0]);assert.equal(d.activeElement.id,action[1]);await t.emit('actionAlternate',action[0]);assert.equal(d.activeElement.id,action[1]); }
  if(name==='commands') { await t.emit('action','edit-commands');assert.ok(calls.some(c=>c[0]==='settings.open')); }
  console.log('PASS '+name+' mocked bridge + actions + keyboard');t.dom.window.dispatchEvent(new w.Event('pagehide'));t.dom.window.close();
 }
 for(const name of selected(['commands','links','notes','home','mixer','cleaner','dictation','proxy','teleprompter','monitor'])) {
  for(const fail of [false,true]) {
   const start=rejections.length; const t=await create(name,true,fail);
   assert.equal(t.errors.length,0,`${name} ${fail?'error':'empty'}: ${t.errors.join('; ')}`);
   assert.equal(rejections.length,start,`${name} unhandled rejection: ${rejections.at(-1)?.message}`);
   if(fail) assert.ok([...t.d.querySelectorAll('.nk-error,[role=\"status\"],.inline-error')].some(el=>!el.hidden&&el.textContent.trim()),name+' error state');
   t.dom.window.dispatchEvent(new t.w.Event('pagehide'));t.dom.window.close();
  }
  console.log('PASS '+name+' empty/error states');
 }
})().catch(e=>{console.error(e);process.exit(1)});
