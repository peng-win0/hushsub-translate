#!/bin/sh
# Recognition and translation per language on the FLEURS clips (fleurs.py fetches any it doesn't have yet): one
# bench.sh run per language, ~6 min each, all 45 in ~4.5 h. Needs an idle GPU (close the browser) and the user's
# captions off. Run it again after a stop ("GPU busy") to go on: languages with a result are skipped (delete
# bench/out/fleurs/<code>.txt to measure one again).
# usage (any folder): sh bench/langs.sh [code ...]   default: fetch, then every language fleurs.py made (codes: no fetch)
#   -> bench/out/lang_<code>.*, bench/out/fleurs/<code>.txt (bench.sh's output) and summary.txt (one CER line each)
B="$(cd "$(dirname "$0")" && pwd)"
F="$B/out/fleurs"
if [ $# -eq 0 ]; then
  python -I "$B/fleurs.py" || exit 1
  set -- $(ls "$F" | sed -n 's/^lang_\(.*\)\.yaml$/\1/p')
fi
for c in "$@"; do
  [ -f "$F/lang_$c.yaml" ] || { echo "$c: no clips (sh bench/langs.sh with no codes fetches them)"; continue; }
  grep -q '^CER' "$F/$c.txt" 2>/dev/null && ! grep -q Traceback "$F/$c.txt" && continue
  RAW="$F/$c.raw" REFS="$F/$c.refs.json" ENDS="$F/$c.ends.json" sh "$B/bench.sh" "lang_$c:$F/lang_$c.yaml" | tee "$F/$c.txt"
  grep -q "stopping before" "$F/$c.txt" && break
  echo "$c $(grep -m1 '^CER' "$F/$c.txt")" >> "$F/summary.txt"
done
