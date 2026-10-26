#!/bin/sh
# One silent benchmark run through the bench harness (Plugins/zz_bench_harness.py + bench.flag).
# usage (from the project folder): sh bench/run.sh NAME PROFILE [warmupSeconds]   -> bench/out/NAME.*
# RAW=<16 kHz mono PCM16 file> feeds other audio than bench/test.raw.
B="$(dirname "$0")"
NAME=$1
PROF=$2
WARM=${3:-60}
O="$B/out/$NAME"
rm -f probe/display.jsonl .captions-paused  # a pause left by the app would silence the run
audioWhisper/audioWhisper.exe --config "$PROF" --remote_host > "$O.engine.log" 2>&1 &
EPID=$!
node "$B/waitws.mjs" 5002 400 || { kill $EPID; exit 1; }
sleep "$WARM"
node "$B/feed.mjs" "${RAW:-$B/test.raw}" .cache/remote-audio/pairing-key 5001 "$O.jsonl"
sleep 6
cp probe/display.jsonl "$O.display.jsonl"
kill $EPID
wait $EPID 2>/dev/null
echo "run $NAME done"
