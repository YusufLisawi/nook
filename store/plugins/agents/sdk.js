(() => {
 const n = window.nook;
 const rawCall = n.native.call.bind(n.native);
 const decode = parts => {
   const strings = parts.map(part => atob(part)), total = strings.reduce((sum,s) => sum+s.length,0);
   if (total > 32*1024*1024) throw Error('This chat exceeds the 32 MiB transfer limit. Start a new chat.');
   const bytes = new Uint8Array(total); let offset = 0;
   for (const text of strings) { for(let i=0;i<text.length;i++) bytes[offset++]=text.charCodeAt(i); }
   return JSON.parse(new TextDecoder().decode(bytes));
 };
 n.native.call = async (method, params = {}) => {
   const value = await rawCall(method, params);
   if (!value || typeof value.__nookTransfer !== 'string') return value;
   if (!Number.isInteger(value.chunks) || value.chunks<1 || value.chunks>96) throw Error('Invalid chat transfer.');
   try { const chunks=[]; for(let index=0;index<value.chunks;index++) chunks.push(await rawCall('transport.read',{token:value.__nookTransfer,index})); return decode(chunks); }
   finally { try { await rawCall('transport.release',{token:value.__nookTransfer}); } catch {} }
 };
 const transfers = new Map();
 n.native.on('transport.event', part => {
   if (!part || typeof part.token!=='string' || typeof part.event!=='string' || !Number.isInteger(part.count) || part.count<1 || part.count>96 || !Number.isInteger(part.index) || part.index<0 || part.index>=part.count || typeof part.data!=='string') return;
   if (!transfers.has(part.token)) { if(transfers.size>=4) { const oldest=transfers.keys().next().value; clearTimeout(transfers.get(oldest).timer); transfers.delete(oldest); } const row={parts:new Array(part.count),event:part.event}; transfers.set(part.token,row); row.timer=setTimeout(()=>transfers.delete(part.token),30000); }
   const transfer=transfers.get(part.token); if(transfer.parts.length!==part.count || transfer.event!==part.event)return;
   transfer.parts[part.index]=part.data;
   if(transfer.parts.filter(p=>typeof p==='string').length===part.count) {
     clearTimeout(transfer.timer); transfers.delete(part.token);
     try { n._emit('native:'+transfer.event,decode(transfer.parts)); } catch(error) { n._emit('agentStorageError',error.message); }
   }
 });
 const originalOpen = n.open;
 n.open = url => typeof url === 'string' && url === 'nook://settings/' + n.plugin.id ? n.settings.open() : /^https?:|^mailto:/.test(url) ? n.host.call('network.open',{url}) : originalOpen(url);
 n.agents = Object.fromEntries(["list", "save", "remove", "sessions", "open", "send", "cancel", "models"].map(fn => [fn, (...args) => n.native.call('agents.' + fn, {args})]));
 for (const event of ["agents", "agentSession", "agentStorageError"]) n.native.on(event, data => n._emit(event, data));
 n.native.on('ready', () => n._emit('open', {}));
})();
