# Tests and benchmarks

For working on the app. The download leaves `bench/` out, so it is never installed.

## Tests

Offline (no engine, graphics card or network), about 25 s in all. GitHub Actions runs them on every push, on Python
3.11 like the engine. Run them from the repository folder as listed in the runbook's
[Before any change](../docs/runbook.md#before-any-change).

- The plugin: `test_captions.py` (the roll-up never re-wraps a line), `test_translator.py` (a final reuses its
  draft's translation), `test_overlay.py` (the caption window and its style, off-screen).
- The app: `test_app.ps1` (the window builds, Help draws the README), `test_compat.ps1` (graphics card, mode,
  browser and language picks), `test_exe.ps1` (`Hushsub Translate.exe`), `test_log_privacy.ps1` (**Copy** in
  **Show log** hides the folder and user name), `test_update.ps1` (updates), `test_zip.ps1` (installing from the
  ZIP).

## Benchmarks

These run the real engine (`audioWhisper/`) on test audio and write to `bench/out/` (`mt/`: `bench/mt/out/`). They
need `sh` (Git Bash) and Node.js. The test audio (`bench/test.raw`, `bench/clips/`) isn't in the repository: make some
with `english.py` or `fleurs.py`.

- `sh bench/bench.sh NAME:profile`: one mode's profile, scored for errors, delay and peak GPU memory. It runs
  `run.sh`, `feed.mjs` and `waitws.mjs`, puts `zz_bench_harness.py` in `Plugins/` for the run, and scores with
  `score.mjs` and `overlay.mjs`.
- `python bench/live_accuracy.py bench/out/NAME.jsonl`: how right the live line was.
- `python bench/english.py`: English test audio from `english.txt`, read by the Windows voices.
- `sh bench/langs.sh`: recognition per language on FLEURS clips (`fleurs.py` fetches them), ~6 min a language.
- `sh bench/mt/mt-run.sh`: translation only, on the sentences in `mt/` (`mt/fleurs_mt.py` makes more).
- `node bench/osv.mjs`: known advisories in the engine's Python packages (sends only names and versions to OSV.dev).
