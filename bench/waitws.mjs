// Waits until the engine's websocket accepts connections. usage: node waitws.mjs <port> <timeoutSeconds>
const [port, timeout = 300] = process.argv.slice(2);
const deadline = Date.now() + Number(timeout) * 1000;
const tryOnce = () => new Promise((res) => {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  ws.onopen = () => { ws.close(); res(true); };
  ws.onerror = () => res(false);
});
while (Date.now() < deadline) {
  if (await tryOnce()) { console.log(`engine up on ${port}`); process.exit(0); }
  await new Promise((r) => setTimeout(r, 2000));
}
console.log(`timeout waiting for ${port}`);
process.exit(1);
