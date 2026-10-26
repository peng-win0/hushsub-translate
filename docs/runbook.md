# Runbook

What to do for the jobs that come up while maintaining the app. What the app does is in the [README](../README.md),
and how it is built in [details.md](details.md).

## Before any change

Run the offline tests and the lint (the same ones CI runs, about 25 s, no engine, GPU or network needed):

```
python bench/test_captions.py
python bench/test_translator.py
python bench/test_overlay.py
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_log_privacy.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_update.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_compat.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_exe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_app.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_zip.ps1
ruff check Plugins bench
```

Scripts must parse in Windows PowerShell 5.1 and be plain ASCII (CI checks both). The plugin runs on the engine's
Python 3.11.

## Release

1. Raise `version.txt` (`X.Y.Z`) in the commit that finishes the release, with the change in the subject line
   (`1.4.18: Fast mode never shows a line said before Stop`).
2. Push to `main` and wait for the Tests workflow to pass.
3. Tag the commit `vX.Y.Z` and publish a GitHub release for the tag with short notes. It needs no files: the app's
   updater downloads the tag's source ZIP, which `.gitattributes` keeps free of `bench/`, `docs/` and the dev files.
4. Every copy with **Update automatically** on installs it the next time the app opens, or within a day if it stays
   open (once no captions run). The updater checks the version and that every script parses before it replaces a
   file.

If `app/launcher.cs` changed, raise its `AssemblyVersion` too: the app rebuilds `Hushsub Translate.exe` only then.

## A bad release

- **For everyone:** publish a new, higher version with the fix or the previous code. The updater never goes back
  to a lower version, so deleting the release doesn't undo it for copies that already updated.
- **For one PC, now:** close the app and copy everything in its folder's `.update-backup\` back over the folder. It
  holds the files the last update replaced, `version.txt` included. Then turn off **Update automatically** until the
  fix is out.

## A problem report

**Report on GitHub** (under **Send feedback**) fills the issue form with the version, graphics card, mode and
settings, and no captions, names or paths. Ask for **Show log** next: `.captions-log` has the engine's status lines, never what was
said. Most reports are one of the README's troubleshooting entries.

## A new engine or model

- **Engine:** change the mirrors and `$sha256` in `app/install.ps1` (the SHA-256 of the engine's ZIP), then try
  each mode on a PC with an NVIDIA card and one without. Check that the plugin's hooks (`stt_caption`,
  `streaming_caption_text`) and the profile keys that `app/captions.ps1` and `CaptionsApp.ps1` write still exist.
- **A model:** change its entry (`File`, `Size`, `Sha`) at the top of `app/captions.ps1`. Measure it with the kit in
  `bench/` against the current one first (see the decision log for what was tried and rejected).

## CI fails

Run the failing step's command locally (above). If only CI fails, compare its Python (3.11) and PowerShell (5.1)
with yours. Dependabot opens a pull request monthly for the pinned actions: merge it once its checks pass.
