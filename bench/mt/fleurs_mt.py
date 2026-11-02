# Translation test sentences in each of the app's languages, into English: FLEURS (CC BY 4.0) has the same sentences
# in every language, so the English one is the reference. Fetches only the test.tsv files (~0.1 MB each).
# usage: python -I bench/mt/fleurs_mt.py [sentences per language, 10]   -> bench/mt/out/fleurs_mt.json, then
#   MT_RUNNERS=nllb,milmmt_int8 sh bench/mt/mt-run.sh out/fleurs_mt.json fleurs-results.json
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from fleurs import LANGS, URL  # noqa: E402

APP = {"zh", "es", "fr", "pt", "ru", "id", "de", "ja", "vi", "tr", "ko", "it", "pl", "nl",  # the app's languages but English
       "az", "bg", "ca", "hr", "da", "fi", "he", "hu", "kk", "no", "sk", "sl", "sv", "tl"}


def sentences(cfg):
    """FLEURS id -> the sentence as written (the first reading of each)."""
    with urllib.request.urlopen(URL.format(cfg) + "test.tsv", timeout=60) as r:
        rows = [line.split("\t") for line in r.read().decode("utf-8").splitlines()]
    out = {}
    for c in rows:
        if len(c) > 2:
            out.setdefault(c[0], c[2])
    return out


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    english = sentences("en_us")
    items = []
    for cfg, (code, nllb) in LANGS.items():
        if code not in APP:
            continue
        both = [(sid, text) for sid, text in sentences(cfg).items() if sid in english]
        items += [{"set": code, "src": nllb, "text": text, "ref": english[sid]} for sid, text in sorted(both)[:n]]
        print(code, len(both), "shared with English")
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "fleurs_mt.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    print(len(items), "sentences ->", out)


if __name__ == "__main__":
    main()
