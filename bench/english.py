# English test audio, made offline with the Windows voices: bench/english.txt read aloud in turns of 2-4 sentences
# (0.25 s apart, 1.5 s between turns) over light noise. Computer voices are easier than people: use it to compare.
# usage: python bench/english.py   -> bench/out/english.raw (16 kHz mono PCM16), english.refs.json and
#   english.words.json (when each word ends in the audio, ms, for the live line's delay)
#   RAW=bench/out/english.raw sh bench/bench.sh NAME:profile   (a profile copy with current_language: en, trg_lang
#   and src_lang: eng_Latn), then: python -I bench/live_accuracy.py --refs bench/out/english.refs.json bench/out/NAME.jsonl
import array
import json
import os
import random
import shutil
import subprocess
import tempfile
import wave

here = os.path.dirname(os.path.abspath(__file__))
lines = [x for x in open(os.path.join(here, "english.txt"), encoding="utf-8").read().splitlines() if x.strip()]
tmp = tempfile.mkdtemp()
open(os.path.join(tmp, "lines.txt"), "w", encoding="utf-8").write("\n".join(lines))
subprocess.run(["powershell", "-NoProfile", "-Command", r"""
Add-Type -AssemblyName System.Speech
Add-Type -ReferencedAssemblies ([System.Speech.Synthesis.SpeechSynthesizer].Assembly.Location) -TypeDefinition @"
using System.Collections.Generic; using System.Speech.Synthesis;
public static class Marks {
    public static List<string> L = new List<string>();
    public static void Hook(SpeechSynthesizer s) { s.SpeakProgress += (o, e) => L.Add(e.CharacterPosition + " " + (long)e.AudioPosition.TotalMilliseconds); }
}
"@
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
[Marks]::Hook($s)
$voices = @($s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, 'Sixteen', 'Mono')
$lines = [IO.File]::ReadAllLines("$env:EN_DIR\lines.txt", [Text.Encoding]::UTF8)
for ($i = 0; $i -lt $lines.Count; $i++) {
    $s.SelectVoice($voices[$i % $voices.Count]); $s.Rate = @(0, 1, -1, 2)[$i % 4]
    [Marks]::L.Clear()
    $s.SetOutputToWaveFile(("{0}\{1:D3}.wav" -f $env:EN_DIR, $i), $fmt); $s.Speak($lines[$i])
    [IO.File]::WriteAllLines(("{0}\{1:D3}.marks" -f $env:EN_DIR, $i), [Marks]::L)
}
$s.SetOutputToNull()
"""], env=dict(os.environ, EN_DIR=tmp), check=True, stdin=subprocess.DEVNULL)
rng = random.Random(7)
out, refs, words, i = array.array("h"), [], [], 0
out.extend([0] * 16000)
while i < len(lines):
    turn = lines[i:i + rng.randint(2, 4)]
    words.append([])
    for k in range(len(turn)):
        with wave.open(os.path.join(tmp, "%03d.wav" % (i + k))) as w:
            pcm = array.array("h", w.readframes(w.getnframes()))
        marks = [tuple(map(int, x.split())) for x in open(os.path.join(tmp, "%03d.marks" % (i + k))) if x.strip()]
        loud = [n for n in range(0, len(pcm), 160) if max(map(abs, pcm[n:n + 160])) > 600]  # 10 ms steps with voice
        for m, (c, ms) in enumerate(marks):  # a word ends where the voice stops before the next word starts
            nxt = marks[m + 1] if m + 1 < len(marks) else (len(turn[k]), len(pcm) // 16)
            end = max([n + 160 for n in loud if n < nxt[1] * 16] or [ms * 16])
            words[-1].append([turn[k][c:nxt[0]], round((len(out) + end) / 16)])
        out.extend(pcm)
        out.extend([0] * (4000 if k < len(turn) - 1 else 24000))
    refs.append({"file": "turn%02d" % len(refs), "text": " ".join(turn)})
    i += len(turn)
shutil.rmtree(tmp)
peak = max(abs(x) for x in out)
out = array.array("h", [max(-32768, min(32767, x + int(rng.gauss(0, peak * 0.015)))) for x in out])  # ~ -35 dB noise
os.makedirs(os.path.join(here, "out"), exist_ok=True)
open(os.path.join(here, "out", "english.raw"), "wb").write(out.tobytes())
json.dump(refs, open(os.path.join(here, "out", "english.refs.json"), "w", encoding="utf-8"), ensure_ascii=False)
json.dump(words, open(os.path.join(here, "out", "english.words.json"), "w", encoding="utf-8"), ensure_ascii=False)
print(len(lines), "sentences,", len(refs), "turns,", round(len(out) / 16000), "s")
