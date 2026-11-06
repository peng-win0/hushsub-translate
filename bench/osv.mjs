// Lists the known advisories (OSV.dev, the database behind osv-scanner and pip-audit) for the Python packages the
// engine bundles, read from its *.dist-info folder names. Sends only package names and versions.
// usage: node bench/osv.mjs [audioWhisper/_internal] [--list]
//   prints one line per affected package (unique advisories by top severity); --list adds each advisory.
// Packages without a dist-info folder (faster_whisper, ctranslate2's C++ core) aren't covered: check those by hand.
import { readdirSync } from "node:fs";

const args = process.argv.slice(2);
const list = args.includes("--list");
const dir = args.find(a => !a.startsWith("--")) || "audioWhisper/_internal";
const pkgs = readdirSync(dir).filter(n => n.endsWith(".dist-info")).map(n => {
  const m = n.slice(0, -10).match(/^(.+?)-(\d[^-]*)$/);
  return m && { name: m[1], version: m[2].replace(/\+.*$/, "") };
}).filter(Boolean);

async function ask(url, body) {
  for (let attempt = 1; ; attempt++) {
    try {
      const r = await fetch(url, {
        method: body ? "POST" : "GET",
        headers: body ? { "content-type": "application/json" } : {},
        body: body && JSON.stringify(body),
        signal: AbortSignal.timeout(60000),
      });
      if (!r.ok) throw new Error(`${r.status} from ${url}`);
      return await r.json();
    } catch (e) {
      if (attempt === 3) throw e;
      await new Promise(res => setTimeout(res, 2000 * attempt));
    }
  }
}

const query = (p, token) => ({ package: { name: p.name, ecosystem: "PyPI" }, version: p.version, page_token: token });
const hits = [];
for (let i = 0; i < pkgs.length; i += 500) {
  const chunk = pkgs.slice(i, i + 500);
  const res = await ask("https://api.osv.dev/v1/querybatch", { queries: chunk.map(p => query(p)) });
  for (const [j, first] of res.results.entries()) {
    for (let r = first; ; ) {  // a package with many advisories comes back in pages
      for (const v of r.vulns || []) hits.push({ pkg: chunk[j], id: v.id });
      if (!r.next_page_token) break;
      r = (await ask("https://api.osv.dev/v1/querybatch", { queries: [query(chunk[j], r.next_page_token)] })).results[0];
    }
  }
}

// OSV lists one flaw under several ids (GHSA, PYSEC, CVE). Group a package's records that share any id, merging
// groups a later record links, and take each flaw's top severity across all packages it appears in.
const rank = s => ({ CRITICAL: 4, HIGH: 3, MODERATE: 2, LOW: 1 })[s] || 0;
const names = ["unrated", "low", "moderate", "high", "critical"];
const norm = n => n.toLowerCase().replace(/[-_.]+/g, "-");
const records = new Map();
for (const id of new Set(hits.map(h => h.id))) records.set(id, await ask(`https://api.osv.dev/v1/vulns/${id}`));
const sevOf = new Map();
for (const v of records.values()) for (const i of [v.id, ...(v.aliases || [])])
  sevOf.set(i, Math.max(sevOf.get(i) || 0, rank(v.database_specific?.severity)));
const byPkg = new Map();
for (const h of hits) {
  const v = records.get(h.id);
  const ids = [v.id, ...(v.aliases || [])];
  const key = `${h.pkg.name} ${h.pkg.version}`;
  let groups = byPkg.get(key) || [];
  const linked = groups.filter(g => ids.some(i => g.ids.has(i)));
  const g = { ids: new Set(ids), fixed: new Set(), summary: "" };
  for (const o of linked) { o.ids.forEach(i => g.ids.add(i)); o.fixed.forEach(f => g.fixed.add(f)); g.summary ||= o.summary; }
  groups = groups.filter(o => !linked.includes(o)).concat(g);
  for (const a of v.affected || []) {
    if (a.package?.ecosystem !== "PyPI" || norm(a.package.name) !== norm(h.pkg.name)) continue;
    for (const r of a.ranges || []) if (r.type !== "GIT") for (const e of r.events) if (e.fixed) g.fixed.add(e.fixed);
  }
  g.summary ||= (v.summary || "").replace(/\s+/g, " ");
  byPkg.set(key, groups);
}
for (const groups of byPkg.values()) for (const g of groups) g.sev = Math.max(...[...g.ids].map(i => sevOf.get(i) || 0));

let total = 0;
for (const [key, groups] of [...byPkg].sort()) {
  const count = [0, 0, 0, 0, 0];
  groups.forEach(g => count[g.sev]++);
  total += groups.length;
  console.log(`${key.padEnd(26)} ${String(groups.length).padStart(3)}  ` +
    [4, 3, 2, 1, 0].filter(i => count[i]).map(i => `${names[i]} ${count[i]}`).join(", "));
  if (list) for (const g of groups) {
    const id = [...g.ids].find(i => i.startsWith("CVE-")) || [...g.ids][0];
    console.log(`    ${id}  ${names[g.sev]}  fixed ${[...g.fixed].join(",") || "none"}  ${g.summary.slice(0, 90)}`);
  }
}
console.log(`${total} advisories on ${byPkg.size} of ${pkgs.length} packages (OSV.dev, ${new Date().toISOString().slice(0, 10)})`);
