# Live-line accuracy of bench runs: each live-line update (the run's drafts replayed through the plugin's live line)
# against the reference text of its sentence. Finals are scored too, like score.mjs (same normalization, CER).
# usage: python -I bench/live_accuracy.py [--refs refs.json] [--words words.json] bench/out/<NAME>.jsonl...
#   (default: bench/clips/refs.json). With --words (when each word ends, from bench/english.py): how long after a
#   word is said it is on screen, in the live line or a finished line.
import importlib.util
import json
import os
import sys
import types
import unicodedata

sys.modules["Plugins"] = types.SimpleNamespace(Base=object)
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sdp", os.path.join(here, "..", "Plugins", "subtitle_display_plugin.py"))
sdp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdp)
device = "cuda"  # the run's profile's, as the plugin asks the engine for it
sys.modules["settings"] = types.SimpleNamespace(GetOption=lambda name: device if name == "ai_device" else None)
plugin = sdp.SubtitleDisplayPlugin()
plugin.is_enabled = lambda default: True
plugin.update_label = lambda text, result, is_final: updates.append((now, text))


def norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower()
    return "".join(c for c in s if not c.isspace() and unicodedata.category(c)[0] not in "PSZ")


def align(ref, hyp):
    """Where each hyp position falls in ref, and the CER."""
    D = [list(range(len(hyp) + 1))]
    for i, r in enumerate(ref, 1):
        row, prev = [i], D[-1]
        for j, h in enumerate(hyp, 1):
            row.append(min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (r != h)))
        D.append(row)
    pos, i, j = [0] * (len(hyp) + 1), len(ref), len(hyp)
    while j:
        pos[j] = i
        if i and D[i][j] == D[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            i, j = i - 1, j - 1
        elif i and D[i][j] == D[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return pos, D[-1][-1] / max(1, len(ref))


def errors(shown, span):
    """Edits from `shown` to the best-matching start of `span` (a live line is the start of its sentence), and its length."""
    prev, best = list(range(len(shown) + 1)), (len(shown), 0)
    for k, r in enumerate(span, 1):
        cur = [k]
        for j, h in enumerate(shown, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
        if cur[-1] <= best[0]:
            best = (cur[-1], k)
    return best[0], max(best[1], len(shown), 1)


def right(shown, span):
    """The characters of `span` that `shown` (the start of its sentence) has right: their offsets."""
    D = [list(range(len(shown) + 1))]
    for i, r in enumerate(span, 1):
        D.append([i] + [0] * len(shown))
        for j, h in enumerate(shown, 1):
            D[i][j] = min(D[i - 1][j] + 1, D[i][j - 1] + 1, D[i - 1][j - 1] + (r != h))
    k = min(range(len(D)), key=lambda i: (D[i][-1], -i))  # the best-matching start of span, as errors() picks it
    i, j, out = k, len(shown), []
    while i and j:
        if D[i][j] == D[i - 1][j - 1] + (span[i - 1] != shown[j - 1]):
            if span[i - 1] == shown[j - 1]:
                out.append(i - 1)
            i, j = i - 1, j - 1
        elif D[i][j] == D[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return out


args = sys.argv[1:]
opts = {"--refs": os.path.join(here, "clips", "refs.json"), "--words": None}
while args[:1] and args[0] in opts:
    opts[args[0]], args = args[1], args[2:]
refs = json.load(open(opts["--refs"], encoding="utf-8"))
ref = norm("".join(r["text"] for r in refs))
said = None  # when each character of ref was said, ms
if opts["--words"]:
    said = [t for turn in json.load(open(opts["--words"], encoding="utf-8")) for w, t in turn for _ in norm(w)]
    assert len(said) == len(ref), "words don't match refs"
for run in args:
    try:
        device = next((x.split(":", 1)[1].strip() for x in open(run[:-6] + ".yaml", encoding="utf-8")
                       if x.startswith("ai_device:")), "cuda")
    except OSError:
        device = "cuda"
    finals, sentences, drafts = [], [], []
    for line in open(run, encoding="utf-8"):
        row = json.loads(line) if line.strip() else {}
        if row.get("type") == "transcript":
            text = str(row["result"].get("text") or "")
            if row["final"]:
                finals.append(norm(text))
                sentences.append((row["t"], drafts))
                drafts = []
            elif text.strip():
                drafts.append((row["t"], text))
    pos, cer = align(ref, "".join(finals))
    wrong, total, every_wrong, every_total, start, seen, done = 0, 0, 0, 0, 0, {}, []
    for final, (final_t, drafts) in zip(finals, sentences):
        at = pos[start]
        span = ref[at:pos[start + len(final)] + 10]  # a draft may run past where the final cut
        if said and final:
            done.append(final_t - said[min(pos[start + len(final) - 1], len(said) - 1)])
        start += len(final)
        updates = []
        for now, d in drafts:
            e, n = errors(norm(d), span)  # as before 1.4.16: every draft shown
            every_wrong += e
            every_total += n
            plugin.stt_intermediate(d, {"text": d})
        plugin.stt("", {})  # the sentence ends: the next one starts fresh
        for now, u in updates:
            e, n = errors(norm(u), span)
            wrong += e
            total += n
        for now, u in updates + [(final_t, final)]:
            for i in right(norm(u), span) if said else ():
                seen.setdefault(at + i, now)
    print(f"{os.path.basename(run)}: live line {100 * (1 - wrong / max(1, total)):.1f}% accurate "
          f"(every draft shown: {100 * (1 - every_wrong / max(1, every_total)):.1f}%), finals {100 * (1 - cer):.1f}%")
    if said:
        lag = sorted(t - said[i] for i, t in seen.items() if i < len(said))
        print(f"  words on screen {lag[len(lag) // 2] / 1000:.2f} s after they're said (median; 90% within "
              f"{lag[int(len(lag) * .9)] / 1000:.2f} s), {100 * len(lag) / len(said):.0f}% of words")
        done.sort()
        print(f"  finished lines {done[len(done) // 2] / 1000:.2f} s after their last word (median; 90% within "
              f"{done[int(len(done) * .9)] / 1000:.2f} s)")
