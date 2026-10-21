const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { parseHTML } = require('linkedom');
const root = process.argv[2] || process.cwd();
setTimeout(() => { console.error('Mock bridge test timed out'); process.exit(1); }, 5000);
const { window } = parseHTML(fs.readFileSync(root + '/Plugins/files/index.html', 'utf8'));
const { document } = window;
const calls = [], listeners = {}, searches = [], previews = [], intervals = new Set();
const setInterval = callback => { intervals.add(callback); return callback; };
const clearInterval = callback => intervals.delete(callback);
const deferred = () => { let resolve, reject; const promise = new Promise((r,j) => {resolve=r; reject=j;}); return {promise,resolve,reject}; };
const wait = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
const $ = id => document.getElementById(id);
window.HTMLElement.prototype.scrollIntoView = function () {};
window.HTMLElement.prototype.focus = function () { document.focusedElement = this; this.dispatchEvent(new window.Event('focus')); };
// Linkedom has no native select UI; model browser option selection explicitly.
for (const id of ['scope','kind']) {
  let value = id === 'kind' ? 'all' : '';
  Object.defineProperty($(id), 'value', {get:()=>value,set:v=>{value=v;}});
}
const nook = {
  plugin: {id:'files'},
  on: (name, cb) => (listeners[name] ||= []).push(cb),
  settings: { get: async () => ({showPreview:true,resultLimit:60}) },
  notch: {close: async () => calls.push(['close'])},
  files: {
    search: (query, options) => { const d=deferred(); searches.push({query,options,...d}); return d.promise; },
    preview: path => { const d=deferred(); previews.push({path,...d}); return d.promise; },
    cancel: async id => calls.push(['cancel',id]),
    keepAlive: async id => calls.push(['keepAlive',id]),
    ...Object.fromEntries(['open','reveal','quickLook','copyPath','copyFile'].map(name => [name,async path=>calls.push([name,path])])),
    openWith: async (path,app) => { calls.push(['openWith',path,app]); return app ? null : [{name:'TextEdit',path:'/Applications/TextEdit.app'}]; }
  }
};
window.nook = nook;
const context = vm.createContext({window,document,nook,console,setTimeout,clearTimeout,Promise,Date,Math,setInterval,clearInterval});
vm.runInContext(fs.readFileSync(root+'/Plugins/files/model.js','utf8'),context);
vm.runInContext(fs.readFileSync(root+'/Plugins/files/main.js','utf8'),context);
function emit(name,data){ for(const cb of listeners[name] || []) cb(data); }
function input(value){$('search').value=value; $('search').dispatchEvent(new window.Event('input'));}
function key(key, options={},target=$('search')) {
 const event=new window.Event('keydown',{bubbles:true,cancelable:true});
 Object.assign(event,{key,metaKey:false,ctrlKey:false,shiftKey:false,altKey:false,isComposing:false,...options});
 target.dispatchEvent(event); return event;
}
function results(search, rows, gathering=false, extra={}) {
 return {clientID:search.options.clientID,requestID:search.options.requestID,results:rows,scope:'home',gathering,...extra};
}
const file=(name,path='/tmp/'+name)=>({name,path,kind:'Text',category:'code',size:25,modified:100});
(async()=>{
 await wait(); assert.equal(searches.length,1); assert.equal(document.focusedElement,$('search'));
 const first=searches[0];
 assert.equal(intervals.size,1,'one heartbeat while visible');
 await [...intervals][0](); assert.equal(calls.at(-1)[0],'keepAlive');
 const normalHeartbeat=nook.files.keepAlive;
 nook.files.keepAlive=async()=>false;
 const beforeWake=searches.length, wakeTick=[...intervals][0](); await wait();
 assert.equal(searches.length,beforeWake+1,'an expired query restarts after sleep');
 const wakeSearch=searches.at(-1); wakeSearch.resolve(results(wakeSearch,[])); await wakeTick;
 nook.files.keepAlive=normalHeartbeat;
 input('empty'); const empty=searches.at(-1);
 emit('files',results(empty,[],true));
 empty.resolve(results(empty,[file('stale-cache.swift')],true)); await wait();
 assert.equal($('results').children.length,0,'late initial reply must not overwrite an empty live update');
 input('a'); const a=searches.at(-1); input('beta'); const beta=searches.at(-1);
 emit('files',results(a,[file('old.swift')])); assert.equal($('results').children.length,0,'stale event rejected');
 emit('files',results(beta,[file('beta.swift'),file('my beta.txt')]));
 assert.equal($('results').children.length,2); assert.equal($('results').querySelector('mark').textContent,'beta');
 emit('files',results(beta,[file('beta.swift'),file('my beta.txt')],true));
 await wait(80); assert.ok(previews.length,'repeated incremental batches must not cancel the pending preview');
 beta.resolve(results(beta,[file('cached.swift')],true)); await wait();
 assert.match($('results').textContent,/beta.swift/,'late initial reply cannot overwrite live results');
 emit('files',{...results(beta,[file('other-screen')]),clientID:'another-screen'});
 assert.doesNotMatch($('results').textContent,/other-screen/,'cross-screen update rejected');
 key('ArrowDown'); key('Enter'); key('Enter',{metaKey:true}); key(' '); key('c',{metaKey:true}); key('c',{metaKey:true,shiftKey:true}); await wait();
 assert.deepEqual(calls.slice(-5),[['open','/tmp/my beta.txt'],['reveal','/tmp/my beta.txt'],['quickLook','/tmp/my beta.txt'],['copyPath','/tmp/my beta.txt'],['copyFile','/tmp/my beta.txt']]);
 emit('filesShortcut','copyFile'); await wait(); assert.equal(calls.at(-1)[0],'copyFile');
 key('k',{metaKey:true}); assert.equal($('menu').hidden,false); key('ArrowDown'); key('Enter'); await wait(); assert.equal(calls.at(-1)[0],'reveal');
 key('k',{metaKey:true}); key('Escape'); assert.equal($('menu').hidden,true); assert.notEqual(calls.at(-1)[0],'close');
 await wait(80); assert.ok(previews.length); const oldPreview=previews.at(-1);
 key('ArrowUp'); await wait(80); const newPreview=previews.at(-1); assert.notEqual(newPreview.path,oldPreview.path);
 newPreview.resolve({path:newPreview.path,name:'safe',kind:'Code',text:'<script>unsafe()</script>',size:42,modified:100}); await wait();
 oldPreview.resolve({path:oldPreview.path,name:'stale',text:'WRONG'}); await wait();
 assert.equal($('text-preview').textContent,'<script>unsafe()</script>'); assert.equal($('text-preview').querySelector('script'),null);
 input('<img onerror=bad()>'); const unsafe=searches.at(-1); emit('files',results(unsafe,[file('<img onerror=bad()>.txt')]));
 assert.equal($('results').querySelector('img'),null,'file names render as text');
 $('scope').value='Downloads'; $('scope').dispatchEvent(new window.Event('change')); assert.equal(searches.at(-1).options.scope,'Downloads');
 $('kind').value='pdf'; $('kind').dispatchEvent(new window.Event('change')); assert.equal(searches.at(-1).options.kind,'pdf');
 const before=searches.length;
 $('search').dispatchEvent(new window.Event('compositionstart')); input('入力'); assert.equal(searches.length,before);
 $('search').dispatchEvent(new window.Event('compositionend')); assert.equal(searches.length,before+1);
 const failure=searches.at(-1); failure.reject(new Error('Spotlight unavailable')); await wait();
 assert.equal($('error').hidden,false); assert.match($('error-text').textContent,/Spotlight unavailable/); assert.equal($('spinner').hidden,true);
 $('retry').click(); const retry=searches.at(-1); emit('files',results(retry,[])); assert.equal($('empty-title').textContent,'No matching files');
 emit('settings',{showPreview:false,resultLimit:10}); assert.equal($('preview').hidden,true); assert.equal(searches.at(-1).options.limit,10);
 const last=searches.at(-1); emit('files',results(last,[file('final.txt')]));
 key('k',{metaKey:true}); key('End'); key('Enter'); await wait(); assert.equal($('menu').children.length,1); key('Enter'); await wait();
 assert.deepEqual(calls.at(-1),['openWith','/tmp/final.txt','/Applications/TextEdit.app']);
 emit('close'); assert.equal(calls.at(-1)[0],'cancel'); assert.equal(intervals.size,0,'no heartbeat while closed');
 emit('files',results(last,[file('closed')])); assert.doesNotMatch($('results').textContent,/closed/);
 emit('show','notes'); const hiddenCount = searches.length; input('hidden'); assert.equal(searches.length,hiddenCount);
 emit('show','files'); await wait(); assert.equal(intervals.size,1,'heartbeat resumes on show'); assert.equal(document.focusedElement,$('search')); assert.ok(searches.length>before);
 emit('close'); const closedCount = searches.length; emit('open','files'); await wait(); assert.equal(searches.length,closedCount+1,'reopening same tab refreshes and focuses');
 key('Escape'); await wait(); assert.equal(calls.at(-1)[0],'close');
 emit('close'); assert.equal(intervals.size,0);
 const model=window.FileSearchModel;
 assert.equal(model.segments('Résumé.md','resume').filter(x=>x.match).map(x=>x.text).join(''),'Résumé');
 assert.equal(model.segments('😀 Résumé.md','résumé').filter(x=>x.match)[0].text,'Résumé');
 assert.equal(model.parent('/file'),'/'); assert.equal(model.size(0),'0 B'); assert.equal(model.size(1024),'1 KB');
 first.resolve(results(first,[])); a.resolve(results(a,[]));
 console.log('PASS: mocked bridge, stale requests/previews, multi-screen isolation, actions, keyboard, filters, IME, loading/empty/error, safe text, close cancellation, live settings');
 process.exit(0);
})().catch(error=>{console.error(error);process.exit(1)});
