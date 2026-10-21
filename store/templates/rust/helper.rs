use std::io::{self, BufRead, Write};
use serde_json::{json, Value};

fn send(message: Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{}", message);
    let _ = out.flush();
}
fn main() {
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.len() > 1_048_576 { eprintln!("RPC frame too large"); break; }
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        if message["jsonrpc"] != "2.0" || message["method"].is_null() || message["id"].is_null() { continue; }
        if message["method"] == "hello" {
            let name = message["params"]["name"].as_str().unwrap_or("Nook");
            send(json!({"jsonrpc":"2.0","id":message["id"],"result":{"message":format!("Hello, {}!", name)}}));
        } else {
            send(json!({"jsonrpc":"2.0","id":message["id"],"error":{"code":-32601,"message":"Unknown method"}}));
        }
    }
}
// To call the host, send {jsonrpc:"2.0",id:"helper-1",method:"host.storage.get",params:{key:"name"}}.
// Handle the matching response in the loop; host.ready/host.event have no id.
