// Scores what the overlay actually showed (probe/display.jsonl from the bench harness) against the feed timeline.
// usage: node overlay.mjs <record.jsonl> <display.jsonl> <test.raw.ends.json> [--lines]
import { readFileSync } from "node:fs";
const [rec, disp, endsFile] = process.argv.slice(2);
const read = (f) => readFileSync(f, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
const origin = read(rec).find((r) => r.type === "origin").epoch;
const ends = JSON.parse(readFileSync(endsFile, "utf8")).map((e) => e + origin);
const ev = read(disp).filter((e) => e.t >= origin - 1000);
const pct = (a, p) => (a.length ? [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))] : NaN);
const of = (name) => ev.filter((e) => e.ev === name);

const shown = of("final_shown"), upg = of("final_upgraded"), live = of("live_shown");
const drafts = of("draft_in"), finalsIn = of("final_in");
const firstAfter = (list, e) => list.find((x) => x.t > e && x.t < e + 4500);
const lat = ends.map((e) => firstAfter(shown, e)?.t - e).filter((x) => !Number.isNaN(x));
const latIn = ends.map((e) => firstAfter(finalsIn, e)?.t - e).filter((x) => !Number.isNaN(x));
const upLat = upg.map((u) => u.after_ms).filter((x) => x !== undefined);
const liveGaps = live.slice(1).map((l, i) => l.t - live[i].t).filter((g) => g < 3000);
const secs = (ends.at(-1) - origin) / 1000;

// Robust latency: match each final to its clip by text overlap (bigram Jaccard vs the reference), then
// clip latency = when the clip's LAST final reached the plugin minus when its speech ended (no time cap).
const refs = JSON.parse(readFileSync(new URL("./clips/refs.json", import.meta.url), "utf8"));
const norm = (s) => (s || "").normalize("NFKC").replace(/[\s\p{P}\p{S}]/gu, "");
const bigrams = (s) => new Set([...norm(s)].map((c, i, a) => c + (a[i + 1] || "")).slice(0, -1));
const overlap = (a, b) => { const A = bigrams(a), B = bigrams(b); let n = 0; for (const x of A) if (B.has(x)) n++; return n / Math.max(1, A.size); };
const lastIn = new Array(ends.length).fill(null);
for (const f of finalsIn) {
  let best = -1, score = 0.25;
  // only clips that ended in the last 20 s (short generic phrases otherwise match clips minutes earlier)
  refs.forEach((r, i) => { const s = overlap(f.text, r.text); if (s > score && ends[i] > f.t - 20000 && ends[i] < f.t + 3000) { score = s; best = i; } });
  if (best >= 0 && f.t > ends[best] - 500) lastIn[best] = f.t;
}
const matched = lastIn.map((t, i) => t && t - ends[i]).filter((x) => x !== null);
// the plugin's own display delay: each final_in -> the next final_shown within 3 s
const dispDelay = finalsIn.map((f) => shown.find((s) => s.t >= f.t && s.t < f.t + 3000)).map((s, i) => s && s.t - finalsIn[i].t).filter((x) => x !== undefined);
console.log(`clip speech end -> its last final reaches plugin (text-matched, uncapped): median ${pct(matched, 0.5)} ms, p90 ${pct(matched, 0.9)}, mean ${Math.round(matched.reduce((a, b) => a + b, 0) / matched.length)} (${matched.length}/${ends.length})`);
console.log(`plugin final_in -> English on screen: median ${pct(dispDelay, 0.5)} ms, p90 ${pct(dispDelay, 0.9)}`);
console.log(`final reaches plugin: median ${pct(latIn, 0.5)} ms, p90 ${pct(latIn, 0.9)} (${latIn.length}/${ends.length})`);
console.log(`English final on screen: median ${pct(lat, 0.5)} ms, p90 ${pct(lat, 0.9)} (${lat.length}/${ends.length})`);
if (upg.length) console.log(`upgrade ${upg.length}/${shown.length} finals, +${pct(upLat, 0.5)} ms median after first text (p90 +${pct(upLat, 0.9)})`);
console.log(`English live-line updates: ${live.length} (${(live.length / secs * 60).toFixed(0)}/min), gap median ${pct(liveGaps, 0.5)} ms, p90 ${pct(liveGaps, 0.9)}`);
console.log(`drafts into plugin: ${drafts.length}, finals into plugin: ${finalsIn.length}`);
if (process.argv.includes("--lines")) {
  for (const s of shown.slice(0, 12)) {
    const u = upg.find((x) => x.old === s.text && x.t >= s.t);
    console.log(`  ${s.text}${u ? `\n     => ${u.text}` : ""}`);
  }
  console.log("  live samples:", live.slice(20, 30).map((l) => l.text));
}
