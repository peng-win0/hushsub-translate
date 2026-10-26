// Streams a 16 kHz mono PCM16 file into the engine's remote-audio input in real time (512-sample frames).
// usage: node feed.mjs <file.raw> <pairing-key-file> [port] [record.jsonl] [maxSeconds]
// Text messages the engine sends back are appended to record.jsonl with a timestamp.
import { readFileSync, writeFileSync, appendFileSync } from "node:fs";
const [file, keyFile, port = 5001, record, maxSecs] = process.argv.slice(2);
const token = readFileSync(keyFile, "utf8").trim();
const all = readFileSync(file), pcm = maxSecs ? all.subarray(0, Number(maxSecs) * 32000) : all;
if (record) writeFileSync(record, "");
const FRAME = 1024, MS = 32; // 512 samples * 2 bytes = 32 ms at 16 kHz
const ws = new WebSocket(`ws://127.0.0.1:${port}`);
ws.binaryType = "arraybuffer";
let origin = performance.now(); // reset when audio starts, so t lines up with the stream's timeline
ws.onmessage = (e) => {
  if (!record || typeof e.data !== "string") return;
  let m; try { m = JSON.parse(e.data); } catch { return; }
  appendFileSync(record, JSON.stringify({ t: Math.round(performance.now() - origin), ...m }) + "\n");
};
ws.onerror = (e) => { console.error("feed ws error", e.message || e); process.exit(1); };
ws.onclose = (e) => { if (e.code !== 1000) console.error("feed closed", e.code, e.reason); };
ws.onopen = () => {
  ws.send(JSON.stringify({ version: 1, token, name: "bench", speak: false, follow_profile: true }));
  const tStart = (origin = performance.now());
  if (record) appendFileSync(record, JSON.stringify({ t: 0, type: "origin", epoch: Date.now() }) + "\n");
  let i = 0;
  const tick = () => {
    // send every frame that is due, so timer jitter doesn't slow the stream down
    while (i * FRAME < pcm.length && performance.now() - tStart >= i * MS) {
      ws.send(pcm.subarray(i * FRAME, (i + 1) * FRAME).length === FRAME ? pcm.subarray(i * FRAME, (i + 1) * FRAME) : Buffer.alloc(FRAME));
      i++;
    }
    if (i * FRAME < pcm.length) setTimeout(tick, 8);
    else setTimeout(() => { ws.close(1000); console.log(`fed ${(pcm.length / 32000).toFixed(0)} s`); }, 4000);
  };
  tick();
};
