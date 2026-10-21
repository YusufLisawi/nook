// stdout is NDJSON, stderr is logs. No dependencies. Exit naturally on stdin EOF.
import { createInterface } from 'node:readline';
const send = message => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
const pending = new Map();
let sequence = 0;
export function host(method, params = {}) {
  const id = `helper-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Host request timed out')); }, 15000);
    pending.set(id, { resolve, reject, timer }); send({ id, method: `host.${method}`, params });
  });
}
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', async line => {
  try {
    if (Buffer.byteLength(line) > 1048576) throw new Error('RPC frame too large');
    const message = JSON.parse(line);
    if (message.jsonrpc !== '2.0') return;
    if (!message.method) {
      const request = pending.get(message.id); if (!request) return;
      pending.delete(message.id); clearTimeout(request.timer);
      message.error ? request.reject(new Error(message.error.message)) : request.resolve(message.result); return;
    }
    if (message.id == null) return; // host.ready / host.event notifications
    if (message.method === 'hello') send({ id: message.id, result: { message: `Hello, ${message.params?.name || 'Nook'}!` } });
    else send({ id: message.id, error: { code: -32601, message: 'Unknown method' } });
  } catch (error) { console.error(error.message); }
});
input.on('close', () => { for (const request of pending.values()) clearTimeout(request.timer); process.exit(0); });
