"""Where a bench run's Whisper time goes, from bench/out/NAME.display.jsonl (the harness logs each encoder and
decoder call). Usage: python bench/passes.py bench/out/NAME.display.jsonl [...]

- Pass time per thread, alone on the GPU or shared with another pass. The busiest thread is the engine's (drafts
  and its own finals); the one-pass threads are the plugin's early finished-line passes.
- How many early passes start while a draft is already running.
- How close the live line came: edit distance of each line's last draft, and of all its drafts, to its finished
  text (a share of the finished text's length; lower is better)."""
import json
import sys


def q(a, p):
    a = sorted(a)
    return a[min(len(a) - 1, int(len(a) * p))] if a else "-"


def dist(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def report(path):
    ev = [json.loads(line) for line in open(path, encoding="utf-8")]
    passes, cur = [], {}  # a pass = an encoder call and the decoder calls after it in the same thread
    for c in sorted((e for e in ev if e["ev"] in ("enc", "dec")), key=lambda c: c["t0"]):
        if c["ev"] == "enc":
            cur[c["th"]] = {"th": c["th"], "t0": c["t0"], "enc": c["ms"], "t1": c["t0"] + c["ms"]}
            passes.append(cur[c["th"]])
        elif c["th"] in cur:
            cur[c["th"]]["t1"] = c["t0"] + c["ms"]
    if not passes:
        print(f"{path}: no pass timing (run it with this harness)")
        return
    engine = max({p["th"] for p in passes}, key=lambda th: sum(p["th"] == th for p in passes))
    print(path)
    for name, group in (("engine", [p for p in passes if p["th"] == engine]),
                        ("early", [p for p in passes if p["th"] != engine])):
        for how in ("alone", "shared"):
            ps = [p for p in group if (how == "shared") == any(
                o is not p and o["t0"] < p["t1"] and o["t1"] > p["t0"] for o in passes)]
            if ps:
                print(f"  {name:6} {how:6} n={len(ps):3}  encoder median {q([p['enc'] for p in ps], .5)} ms,"
                      f" pass median {q([p['t1'] - p['t0'] for p in ps], .5)} ms, p90 {q([p['t1'] - p['t0'] for p in ps], .9)}")
    early = [p for p in passes if p["th"] != engine]
    busy = sum(any(d["th"] == engine and d["t0"] < p["t0"] < d["t1"] for d in passes) for p in early)
    print(f"  early passes that start while a draft runs: {busy} of {len(early)}")
    drafts, last, every = [], [], []
    for e in ev:
        if e["ev"] == "draft_in":
            drafts.append((e.get("text") or "").strip())
        elif e["ev"] == "final_in":
            final = (e.get("text") or "").strip()
            if drafts and final:
                errs = [dist(d, final) / len(final) for d in drafts]
                last.append(errs[-1])
                every += errs
            drafts = []
    if last:
        print(f"  live line vs finished text: last draft {100 * sum(last) / len(last):.1f}%,"
              f" all drafts {100 * sum(every) / len(every):.1f}% ({len(last)} lines)")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        report(p)
