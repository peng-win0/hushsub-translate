// Scores a feed.mjs recording against the reference transcripts: character error rate + caption latency.
// usage: node score.mjs <record.jsonl> <refs.json> <test.raw.ends.json> [--lines] [--selftest]
import { readFileSync } from "node:fs";
const [rec, refsFile, endsFile] = process.argv.slice(2);

// compare characters only: drop punctuation, spaces, and fold full-width latin/digits
const norm = (s) => s.normalize("NFKC").toLowerCase().replace(/[\s\p{P}\p{S}]/gu, "");
function cer(ref, hyp) {
  let prev = Array.from({ length: hyp.length + 1 }, (_, j) => j);
  for (let i = 1; i <= ref.length; i++) {
    const cur = [i];
    for (let j = 1; j <= hyp.length; j++)
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ref[i - 1] === hyp[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[hyp.length] / Math.max(1, ref.length);
}
if (process.argv.includes("--selftest")) {
  console.assert(cer("abc", "abc") === 0 && cer("abcd", "abd") === 0.25 && cer("ab", "") === 1, "cer broken");
  console.assert(norm("ＡＢ、c ｄ。") === "abcd", "norm broken");
  console.log("selftest ok");
  process.exit(0);
}

const pct = (a, p) => (a.length ? [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))] : NaN);
const rows = readFileSync(rec, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((r) => r.type === "transcript");
const refs = JSON.parse(readFileSync(refsFile, "utf8")), ends = JSON.parse(readFileSync(endsFile, "utf8"));
const finals = rows.filter((r) => r.final), drafts = rows.filter((r) => !r.final);

const ref = norm(refs.map((r) => r.text).join("")), hyp = norm(finals.map((f) => f.result.text || "").join(""));
// latency: clip's speech ends -> first final caption after it (within the silence gap + slack)
const lat = ends.map((e) => finals.find((f) => f.t > e && f.t < e + 4500)).map((f, i) => f && f.t - ends[i]).filter((x) => x !== undefined);
const gaps = drafts.slice(1).map((d, i) => d.t - drafts[i].t).filter((g) => g < 3000);

console.log(`CER ${(100 * cer(ref, hyp)).toFixed(1)}%  | finals ${finals.length}, drafts ${drafts.length}`);
console.log(`speech end -> final caption ms: median ${pct(lat, 0.5)}, p90 ${pct(lat, 0.9)}  (${lat.length}/${ends.length} clips)`);
console.log(`live-line update gap ms: median ${pct(gaps, 0.5)}, p90 ${pct(gaps, 0.9)}`);
if (process.argv.includes("--lines"))
  for (const f of finals.slice(0, 10)) console.log(`  ${f.result.text}  ->  ${f.result.txt_translation ?? ""}`);
