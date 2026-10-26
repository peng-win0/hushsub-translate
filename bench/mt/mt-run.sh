#!/bin/sh
# Translation-only eval inside a silent test engine (ports 5002/9011, --remote_host, overlay plugin off).
# usage: sh bench/mt/mt-run.sh [sentences.json [results.json]]   -> bench/mt/out/ (results.json, engine.log).
# First run downloads ~4.5 GB. chunks.json = stream-style fragments with names and jargon (glossary checks).
M="$(cd "$(dirname "$0")" && pwd)"
cd "$M/../.." || exit 1
mkdir -p "$M/out"
if tasklist //fi "imagename eq audioWhisper.exe" | grep -qi audioWhisper; then echo "an engine is running; not starting"; exit 0; fi
base=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
if [ "$base" -gt 1500 ]; then echo "GPU busy (${base} MiB); not starting"; exit 0; fi
sed -e "s/^websocket_ip: .*/websocket_ip: 127.0.0.1/" -e "s/^websocket_port: .*/websocket_port: 5002/" -e "s/^osc_server_port: .*/osc_server_port: 9011/" \
    -e "s/^settingsfilename: .*/settingsfilename: MTEVAL.yaml/" -e "s/^  SubtitleDisplayPlugin: true/  SubtitleDisplayPlugin: false/" \
    Profiles/fast.yaml > "$M/out/MTEVAL.yaml"
cp "$M/zz_mt_eval.py" Plugins/zz_mt_eval.py
printf '%s\n%s\n' "$(cygpath -m "$M/${1:-sentences.json}")" "$(cygpath -m "$M/out/${2:-results.json}")" > mt_eval.flag
nvidia-smi --query-gpu=timestamp,memory.used --format=csv,noheader -l 2 > "$M/out/vram.csv" &
VPID=$!
audioWhisper/audioWhisper.exe --config "$M/out/MTEVAL.yaml" --remote_host > "$M/out/engine.log" 2>&1 &
EPID=$!
for i in $(seq 1 480); do  # up to 40 min (download)
  grep -q "MT_EVAL: DONE" "$M/out/engine.log" && break
  kill -0 $EPID 2>/dev/null || { echo "engine exited early"; break; }
  sleep 5
done
kill $EPID 2>/dev/null
wait $EPID 2>/dev/null
kill $VPID 2>/dev/null
rm -f Plugins/zz_mt_eval.py mt_eval.flag
echo "== MT_EVAL lines"; grep -a "MT_EVAL" "$M/out/engine.log"
echo "== errors"; grep -a -A3 "Traceback" "$M/out/engine.log" | head -40
echo "== peak GPU memory: $(sort -t, -k2 -n "$M/out/vram.csv" | tail -1) (baseline $base MiB)"
echo "=== all done"
