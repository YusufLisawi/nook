const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const folder=process.argv[2],listeners={},calls=[];
const payload={id:'chat',items:[{id:'tool',text:'café 😀 '+ 'x'.repeat(1300000)}]}, bytes=Buffer.from(JSON.stringify(payload)),chunks=[];
for(let i=0;i<bytes.length;i+=384*1024)chunks.push(bytes.subarray(i,i+384*1024).toString('base64'));
const emit=(event,data)=>{for(const callback of listeners[event]||[])callback(data)};
const nook={plugin:{id:'agents'},on:(event,cb)=>(listeners[event]??=[]).push(cb),_emit:emit,open:async()=>{},settings:{open:async()=>{}},native:{on:(event,cb)=>(listeners['native:'+event]??=[]).push(cb),call:async(method,p)=>{calls.push([method,p]);if(method==='agents.open')return {__nookTransfer:'token',chunks:chunks.length};if(method==='transport.read')return chunks[p.index];if(method==='transport.release')return null;return []}}};
vm.runInNewContext(fs.readFileSync(path.join(folder,'sdk.js'),'utf8'),{window:{nook},atob:s=>Buffer.from(s,'base64').toString('binary'),TextDecoder,Uint8Array,setTimeout,clearTimeout});
(async()=>{
 assert.equal(JSON.stringify(await nook.agents.open('chat')),JSON.stringify(payload));
 assert(calls.some(([m])=>m==='transport.release'),'References must be released after assembly');
 let received;nook.on('agentSession',value=>received=value);
 for(let i=chunks.length-1;i>=0;i--)emit('native:transport.event',{token:'event',event:'agentSession',index:i,count:chunks.length,data:chunks[i]});
 assert.equal(JSON.stringify(received),JSON.stringify(payload));
 console.log('PASS Agents: >1 MiB UTF-8 history references and out-of-order tool event chunks reassemble without changing engine frame limits');
})().catch(error=>{console.error(error);process.exit(1)});
