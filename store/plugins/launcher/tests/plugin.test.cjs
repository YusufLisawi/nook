// Package UI, inert window.nook and DOM under /tmp. No app/browser is launched.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const scratch = fs.mkdtempSync('/tmp/nook-launcher-ui-');
const source = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(source, 'index.html'), 'utf8');
assert.match(html, /<button[^>]+id="open"[^>]+data-nk-autofocus/);
fs.copyFileSync(path.join(source, 'main.js'), path.join(scratch, 'main.js'));
const elements = Object.fromEntries(['open','retry','clear','loading','empty','status','error'].map(id => [id, {hidden:false,textContent:'',onclick:null}]));
const calls = [], events = {}, nativeEvents = {};
let failure = false, recent = 3;
const nook = {native:{
  call:async method => {calls.push(method); if(failure) throw new Error('Helper unavailable'); if(method==='launcher.clearHistory') recent=0; return {applications:0,recent};},
  on:(name,callback)=>{nativeEvents[name]=callback;}
},host:{call:async method=>{calls.push(method);}},on:(name,callback)=>{events[name]=callback;}};
const tick=async()=>{for(let i=0;i<5;i++) await new Promise(setImmediate);};
(async()=>{
  vm.runInNewContext(fs.readFileSync(path.join(scratch,'main.js'),'utf8'),{document:{getElementById:id=>elements[id]},window:{nook},nook});
  await tick(); assert.equal(elements.loading.hidden,true); assert.equal(elements.empty.hidden,false); assert.equal(elements.error.hidden,true);
  assert.match(elements.status.textContent,/0 applications.*3 recent/);
  await elements.open.onclick(); assert.equal(calls.at(-1),'launcher.open');
  failure=true; await elements.retry.onclick(); assert.equal(elements.error.hidden,false); assert.equal(elements.error.textContent,'Helper unavailable');
  failure=false; await elements.retry.onclick(); assert.equal(elements.error.hidden,true);
  await elements.clear.onclick(); assert.match(elements.status.textContent,/0 recent/);
  nativeEvents.error('Shortcut in use'); assert.equal(elements.error.textContent,'Shortcut in use');
  nativeEvents.ready(); await tick(); assert.equal(elements.error.hidden,true);
  events.show(); events.settings(); await tick(); assert.equal(elements.loading.hidden,true);
  console.log('PASS: launcher control UI loading/empty/error/retry, actions, recents, settings and helper reconnect under /tmp');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>fs.rmSync(scratch,{recursive:true,force:true}));
