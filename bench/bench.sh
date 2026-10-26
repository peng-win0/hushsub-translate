#!/bin/sh
# Silent benchmark of the real caption profiles (test ports 5002/9011, otherwise unchanged).
# usage (any folder): sh bench/bench.sh [NAME:profile ...]   default: FINAL_LIVE:accurate FINAL_LIGHT:fast
# profile = a name in app/Profiles/ or a path to a .yaml (a copy of a profile with one setting changed)
# Results go to bench/out/. Needs an idle GPU and the user's captions off.
B="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$B/out"
cd "$B/.." || exit 1
PATH="$PWD/toolchain/ffmpeg/bin:$PATH"  # the engine decodes audio with this ffmpeg (captions.ps1 does the same)
[ $# -eq 0 ] && set -- FINAL_LIVE:accurate FINAL_LIGHT:fast
for pair in "$@"; do
  N=${pair%%:*}; P=${pair#*:}
  O="$B/out/$N"
  src="app/Profiles/$P.yaml"; [ -f "$P" ] && src="$P"
  sed -e "s/^websocket_ip: .*/websocket_ip: 127.0.0.1/" -e "s/^websocket_port: .*/websocket_port: 5002/" -e "s/^osc_server_port: .*/osc_server_port: 9011/" \
      -e "s/^settingsfilename: .*/settingsfilename: $N.yaml/" "$src" > "$O.yaml"
  if tasklist //fi "imagename eq audioWhisper.exe" | grep -qi audioWhisper; then echo "an engine is running; stopping before $N"; break; fi
  base=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
  if [ "$base" -gt 1500 ]; then echo "GPU busy (${base} MiB in use, a game?); stopping before $N"; break; fi
  echo "=== $N (GPU idle baseline ${base} MiB) $(date +%T)"
  cp "$B/zz_bench_harness.py" Plugins/zz_bench_harness.py
  echo "temporary: enables Plugins/zz_bench_harness.py" > bench.flag
  nvidia-smi --query-gpu=timestamp,memory.used,utilization.gpu --format=csv,noheader -l 2 > "$O.vram.csv" &
  VPID=$!
  sh "$B/run.sh" "$N" "$O.yaml" 90
  kill $VPID 2>/dev/null
  rm -f Plugins/zz_bench_harness.py bench.flag
  grep -a "translator (\|translator ready\|unavailable\|Traceback" "$O.engine.log" | head -8
  node "$B/score.mjs" "$O.jsonl" "$B/clips/refs.json" "$B/test.raw.ends.json" | head -1
  node "$B/overlay.mjs" "$O.jsonl" "$O.display.jsonl" "$B/test.raw.ends.json" --lines
  echo "peak GPU memory: $(sort -t, -k2 -n "$O.vram.csv" | tail -1 | cut -d, -f2) (baseline ${base} MiB)"
  sleep 10
done
rm -f Plugins/zz_bench_harness.py bench.flag
rm -rf probe
echo "=== all done $(date +%T)"
