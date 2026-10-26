#!/bin/sh
# Recognition and translation per language on the FLEURS clips (fleurs.py fetches any it doesn't have yet): one
# bench.sh run per language, ~6 min each, all 45 in ~4.5 h. Needs an idle GPU (close the browser) and the user's
# captions off. Run it again after a stop ("GPU busy") to go on: languages with a result are skipped (delete
# bench/out/fleurs/<code>.txt to measure one again).
# usage (any folder): sh bench/langs.sh [code ...]   default: every language fleurs.py made
#   -> bench/out/lang_<code>.*, bench/out/fleurs/<code>.txt (bench.sh's output) and summary.txt (one CER line each)
B="$(cd "$(dirname "$0")" && pwd)"
F="$B/out/fleurs"
python -I "$B/fleurs.py" || exit 1
[ $# -eq 0 ] && set -- $(ls "$F" | sed -n 's/^lang_\(.*\)\.yaml$/\1/p')
for c in "$@"; do
  grep -q '^CER' "$F/$c.txt" 2>/dev/null && continue
  RAW="$F/$c.raw" REFS="$F/$c.refs.json" ENDS="$F/$c.ends.json" sh "$B/bench.sh" "lang_$c:$F/lang_$c.yaml" | tee "$F/$c.txt"
  grep -q "stopping before" "$F/$c.txt" && break
  echo "$c $(grep -m1 '^CER' "$F/$c.txt")" >> "$F/summary.txt"
done
